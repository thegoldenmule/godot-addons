@tool
class_name SnapKitAuth
extends Node

## The single Snapser session owner for the process.
##
## Exactly one SnapKitAuth exists per SnapKitService, and every request — every
## client, analytics, cloud save — gets its session through it via
## SnapKitTransport. (Moveborne had three auth objects and minted duplicate
## anonymous users; this class exists to make that impossible.)
##
## Anonymous identity:
##   - On first login a handle "<prefix><32 hex chars>" is minted from 16
##     crypto-random bytes (Crypto.generate_random_bytes) and persisted, so the
##     same Snapser user is reused across launches.
##   - Login: PUT /v1/auth/login/anon {"username": handle, "create_user": true}
##     -> {"user": {"id", "session_token", "token_validity_seconds"}}.
##   - Session headers: "Token: <session_token>", "User-Id: <user_id>" (not an
##     API key, not Bearer).
##   - Persisted at SESSION_PATH as {username, user_id, session_token,
##     expires_at}. This is the same file + format the pre-kit game layers used,
##     so existing dev installs keep their (older, 32-bit) handle.
##
## Concurrency: ensure_session() / reauth() are single-flight — concurrent
## callers await ONE login request and share its result.
##
## Server-side invalidation (a snapend apply logs everyone out): the transport
## sees a 401 on a locally-valid token and calls reauth(), which discards the
## token but keeps the handle, restoring the same user silently.
##
## Session refresh: when the cached token is locally expired, ensure_session()
## first tries PATCH /v1/auth/refresh {session_token}; if that fails it falls
## back to anonymous login with the persisted handle.
##
## Linking (implemented against the swagger + identity spike; NOT yet verified
## live — Wave 4 verifies):
##   link_provider(provider, token):
##     1. PUT /v1/auth/login/{provider} {token, create_user:true} with
##        {"no_retry": true} (Apple authorization codes are single-use).
##     2. user.created == true (fresh provider user): PUT
##        /v1/auth/associate-logins {keep_user_token: <current anon session>,
##        discard_user_token: <provider session>} -> the provider login joins
##        the anon user's keychain, so all progress stays. -> {ok:true, provider}
##     3. user.created == false (the account already exists): do NOT associate
##        (it would discard that user's data). -> {ok:false,
##        error:"account_exists", user_id:<existing>, switch_token:<its session
##        token>, switch_session:{user_id, session_token, ttl_s, linked}}.
##        The game may then adopt it with adopt_session(switch_session)
##        (SnapKitService.switch_account()).
##   After an adopted (switched) session, the local anon handle belongs to a
##   different user, so a lost session is NOT healed by anon login — only by
##   refresh; otherwise ensure_session() fails and the player must sign in
##   again (Wave 4 seam: the spike's "canonical anon handle" blob).
##
## All HTTP goes through SnapKitTransport with opts {"auth": false} (except
## associate-logins, which is sent as the current user).

## A new session user id is live ("" = signed out / lost).
signal session_changed(uid: String)
## Internal: single-flight login completion.
signal _login_finished(ok: bool)

const SESSION_PATH := "user://snapser_session.json"
const EXPIRY_MARGIN_S := 60
const DEFAULT_TTL_S := 3600
const HANDLE_BYTES := 16
const PATH_LOGIN_ANON := "/v1/auth/login/anon"
const PATH_LOGIN_PROVIDER := "/v1/auth/login/%s"     # % provider
const PATH_ASSOCIATE := "/v1/auth/associate-logins"
const PATH_REFRESH := "/v1/auth/refresh"
const SUPPORTED_PROVIDERS := ["apple", "google"]
const ERR_ACCOUNT_EXISTS := "account_exists"
const ERR_UNSUPPORTED_PROVIDER := "unsupported_provider"

## Current session user id ("" before the first successful login).
var user_id: String = ""
## Current session token ("" before login). Never log this.
var session_token: String = ""
## Where the session is persisted. Tests point this at a temp file.
var session_path: String = SESSION_PATH

var _config: SnapKitConfig
var _transport: SnapKitTransport
var _username: String = ""
var _expires_at: int = 0
var _loaded: bool = false
var _logging_in: bool = false
var _linked: PackedStringArray = PackedStringArray()
## True once a provider / switched session was adopted: the anon handle no
## longer identifies this user, so anon re-login is not allowed.
var _switched: bool = false


## Wire dependencies. Called by SnapKitService before any request.
func setup(config: SnapKitConfig, transport: SnapKitTransport) -> void:
	_config = config
	_transport = transport


## The persisted anonymous handle ("" before first login).
func username() -> String:
	_ensure_loaded()
	return _username


## True when a token is held and not within EXPIRY_MARGIN_S of local expiry.
## (Cannot detect server-side invalidation — the transport's 401 rule does.)
func has_session() -> bool:
	_ensure_loaded()
	return session_token != "" and user_id != "" \
		and int(Time.get_unix_time_from_system()) < _expires_at - EXPIRY_MARGIN_S


## Gateway session headers for an authenticated request.
func auth_headers() -> PackedStringArray:
	return PackedStringArray(["Token: " + session_token, "User-Id: " + user_id])


## Ensure a live session: reuse the cached one, else log in anonymously (minting
## a handle on first run). Single-flight. Returns false offline or on failure.
## COROUTINE — `var ok: bool = await auth.ensure_session()`.
func ensure_session() -> bool:
	if _offline():
		return false
	if has_session():
		return true
	return await _login_shared()


## Discard the token (keep the handle) and log in again. Single-flight.
## COROUTINE.
func reauth() -> bool:
	if _offline():
		return false
	_ensure_loaded()
	if not _logging_in:
		_expires_at = 0
		if not _switched:
			session_token = ""   # anon: re-login directly, skip refresh
	return await _login_shared()


## Sign in with a platform identity token, REPLACING the current session with
## the provider-backed user (no association). provider: "apple" | "google".
## Sent with no_retry. Returns {ok, error, user_id}. COROUTINE. (Wave 4)
func login_with_provider(provider: String, identity_token: String) -> Dictionary:
	if _offline():
		return SnapKitTransport.error_result(SnapKitTransport.ERR_OFFLINE)
	if not provider in SUPPORTED_PROVIDERS:
		return SnapKitTransport.error_result(ERR_UNSUPPORTED_PROVIDER)
	var res := await _provider_login(provider, identity_token)
	if not res.ok:
		return res
	adopt_session(res.session)
	res.erase("session")
	res["user_id"] = user_id
	return res


## Link a provider to the CURRENT (anonymous) user so progress carries over.
## See the class doc for the algorithm and results:
##   {ok:true, provider} | {ok:false, error:"account_exists", user_id,
##   switch_token, switch_session} | {ok:false, error:<transport error>}.
## COROUTINE. (Wave 4)
func link_provider(provider: String, identity_token: String) -> Dictionary:
	if _offline():
		return SnapKitTransport.error_result(SnapKitTransport.ERR_OFFLINE)
	if not provider in SUPPORTED_PROVIDERS:
		return SnapKitTransport.error_result(ERR_UNSUPPORTED_PROVIDER)
	if not await ensure_session():
		return SnapKitTransport.error_result(SnapKitTransport.ERR_NO_SESSION)
	var login := await _provider_login(provider, identity_token)
	if not login.ok:
		login["provider"] = provider
		return login
	var other: Dictionary = login.session
	login.erase("session")
	if other.user_id == user_id:
		_add_linked(provider)
		return _link_ok(login, provider)
	if not SnapKitJson.to_bool(SnapKitJson.dig(login.json, ["user", "created"], false)):
		var res := SnapKitTransport.error_result(ERR_ACCOUNT_EXISTS, login.status)
		res["provider"] = provider
		res["user_id"] = other.user_id
		res["switch_token"] = other.session_token
		res["switch_session"] = other
		return res
	var assoc := await _transport.request(HTTPClient.METHOD_PUT, PATH_ASSOCIATE,
		{"keep_user_token": session_token, "discard_user_token": other.session_token},
		{"no_retry": true})
	if not assoc.ok:
		assoc["provider"] = provider
		return assoc
	_add_linked(provider)
	return _link_ok(assoc, provider)


## Adopt another user's session (from link_provider's "account_exists"
## switch_session, or login_with_provider): it becomes this device's session and
## is persisted. Anon re-login is disabled from then on (see class doc).
## session: {user_id, session_token, ttl_s?, linked?}. Emits session_changed.
func adopt_session(session: Dictionary) -> bool:
	var parsed := {
		"user_id": SnapKitJson.get_str(session, "user_id"),
		"session_token": SnapKitJson.get_str(session, "session_token"),
		"ttl_s": SnapKitJson.get_int(session, "ttl_s", 0),
		"linked": session.get("linked", PackedStringArray()) if session.get("linked") is PackedStringArray else PackedStringArray(),
	}
	if parsed.user_id == "" or parsed.session_token == "":
		return false
	_ensure_loaded()
	_switched = true
	_apply_login(parsed)
	return true


## PATCH /v1/auth/refresh with the current token (no retry). True on a new
## session. Called by ensure_session() on local expiry; safe to call on warm
## launch. COROUTINE.
func refresh_session() -> bool:
	if _offline() or session_token == "":
		return false
	var res := await _transport.request(HTTPClient.METHOD_PATCH, PATH_REFRESH,
		{"session_token": session_token}, {"auth": false, "no_retry": true})
	var parsed := parse_login_response(res.json)
	if not res.ok or not parsed.ok:
		return false
	if parsed.linked.is_empty():
		parsed.linked = _linked
	_apply_login(parsed)
	return true


## Providers linked to the current user (from the last login / link response).
func linked_providers() -> PackedStringArray:
	_ensure_loaded()
	return _linked


## Drop this device's identity: clear session + handle and delete session_path.
## The next ensure_session() mints a fresh anonymous user. Emits
## session_changed("").
func sign_out() -> void:
	_loaded = true
	user_id = ""
	session_token = ""
	_expires_at = 0
	_username = ""
	_linked = PackedStringArray()
	_switched = false
	if FileAccess.file_exists(session_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(session_path))
	session_changed.emit("")


## "<prefix><32 lowercase hex>" from HANDLE_BYTES crypto-random bytes.
static func generate_handle(prefix: String) -> String:
	return prefix + Crypto.new().generate_random_bytes(HANDLE_BYTES).hex_encode()


## Parse an anon / provider login response.
## -> {ok, user_id, session_token, ttl_s, linked:PackedStringArray, error}
static func parse_login_response(json: Variant) -> Dictionary:
	var user := SnapKitJson.get_dict(json, "user")
	var uid := SnapKitJson.get_str(user, "id")
	var token := SnapKitJson.get_str(user, "session_token")
	var linked := PackedStringArray()
	for t in SnapKitJson.get_array(user, "login_types"):
		var name_l := str(t).to_lower()
		if name_l != "anon" and name_l != "unspecified_login_type" and not linked.has(name_l):
			linked.append(name_l)
	var ok := uid != "" and token != ""
	return {
		"ok": ok,
		"user_id": uid,
		"session_token": token,
		"ttl_s": SnapKitJson.get_int(user, "token_validity_seconds", 0),
		"linked": linked,
		"error": "" if ok else SnapKitTransport.ERR_BAD_RESPONSE,
	}


# ---- internals ---------------------------------------------------------------

func _offline() -> bool:
	return _config == null or _transport == null or _config.is_offline()


func _login_shared() -> bool:
	if _logging_in:
		return await _login_finished
	_logging_in = true
	var ok := false
	if session_token != "":
		ok = await refresh_session()
	if not ok:
		if _switched:
			push_warning("[SnapKit] session lost for a switched account; sign-in required")
		else:
			ok = await _login_anon()
	_logging_in = false
	_login_finished.emit(ok)
	return ok


func _login_anon() -> bool:
	_ensure_loaded()
	if _username == "":
		_username = generate_handle(_config.handle_prefix())
	var res := await _transport.request(HTTPClient.METHOD_PUT, PATH_LOGIN_ANON,
		{"username": _username, "create_user": true}, {"auth": false})
	var parsed := parse_login_response(res.json)
	if not res.ok or not parsed.ok:
		push_warning("[SnapKit] anonymous login failed: %s" % (res.error if res.error != "" else parsed.error))
		return false
	_apply_login(parsed)
	return true


func _apply_login(parsed: Dictionary) -> void:
	user_id = parsed.user_id
	session_token = parsed.session_token
	var ttl: int = parsed.ttl_s if parsed.ttl_s > 0 else DEFAULT_TTL_S
	_expires_at = int(Time.get_unix_time_from_system()) + ttl
	_linked = parsed.linked
	_save()
	session_changed.emit(user_id)


func _add_linked(provider: String) -> void:
	if not _linked.has(provider):
		_linked.append(provider)
		_save()


## login/{provider} with create_user=true and no retry. -> transport result +
## "session" (parse_login_response) on success.
func _provider_login(provider: String, identity_token: String) -> Dictionary:
	var res := await _transport.request(HTTPClient.METHOD_PUT, PATH_LOGIN_PROVIDER % provider,
		{"token": identity_token, "create_user": true}, {"auth": false, "no_retry": true})
	var parsed := parse_login_response(res.json)
	if res.ok and not parsed.ok:
		res["ok"] = false
		res["error"] = parsed.error
	if res.ok:
		res["session"] = parsed
	return res


static func _link_ok(res: Dictionary, provider: String) -> Dictionary:
	res["ok"] = true
	res["error"] = ""
	res["provider"] = provider
	return res


func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(session_path):
		return
	var data: Variant = SnapKitJson.parse(FileAccess.get_file_as_string(session_path))
	if not (data is Dictionary):
		return
	_username = SnapKitJson.get_str(data, "username")
	user_id = SnapKitJson.get_str(data, "user_id")
	session_token = SnapKitJson.get_str(data, "session_token")
	_expires_at = SnapKitJson.get_int(data, "expires_at", 0)
	_switched = SnapKitJson.get_bool(data, "switched", false)
	_linked = PackedStringArray()
	for p in SnapKitJson.get_array(data, "linked"):
		_linked.append(str(p))


func _save() -> void:
	var f := FileAccess.open(session_path, FileAccess.WRITE)
	if f == null:
		push_warning("[SnapKit] cannot write session file %s" % session_path)
		return
	f.store_string(JSON.stringify({
		"username": _username, "user_id": user_id,
		"session_token": session_token, "expires_at": _expires_at,
		"linked": Array(_linked),
		"switched": _switched,
	}, "  "))
