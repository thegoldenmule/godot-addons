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
## Linking (Wave 4): login_with_provider() / link_provider() use
## PUT /v1/auth/login/{apple|google} and PUT /v1/auth/associate-logins with an
## identity token supplied by the platform addon (snapser_kit_apple / _google).
##
## All HTTP goes through SnapKitTransport with opts {"auth": false}.
##
## SKELETON: signatures final for v0.1; bodies are stubs.

## A new session user id is live ("" = signed out / lost).
signal session_changed(uid: String)

const SESSION_PATH := "user://snapser_session.json"
const EXPIRY_MARGIN_S := 60
const HANDLE_BYTES := 16
const PATH_LOGIN_ANON := "/v1/auth/login/anon"
const PATH_LOGIN_PROVIDER := "/v1/auth/login/%s"     # % provider
const PATH_ASSOCIATE := "/v1/auth/associate-logins"

## Current session user id ("" before the first successful login).
var user_id: String = ""
## Current session token ("" before login). Never log this.
var session_token: String = ""

var _config: SnapKitConfig
var _transport: SnapKitTransport
var _username: String = ""
var _expires_at: int = 0
var _loaded: bool = false
var _logging_in: bool = false
var _linked: PackedStringArray = PackedStringArray()


## Wire dependencies. Called by SnapKitService before any request.
func setup(config: SnapKitConfig, transport: SnapKitTransport) -> void:
	_config = config
	_transport = transport


## The persisted anonymous handle ("" before first login).
func username() -> String:
	return _username


## True when a token is held and not within EXPIRY_MARGIN_S of local expiry.
## (Cannot detect server-side invalidation — the transport's 401 rule does.)
func has_session() -> bool:
	return false


## Gateway session headers for an authenticated request.
func auth_headers() -> PackedStringArray:
	return PackedStringArray(["Token: " + session_token, "User-Id: " + user_id])


## Ensure a live session: reuse the cached one, else log in anonymously (minting
## a handle on first run). Single-flight. Returns false offline or on failure.
## COROUTINE — `var ok: bool = await auth.ensure_session()`.
func ensure_session() -> bool:
	return false


## Discard the token (keep the handle) and log in again. Single-flight.
## COROUTINE.
func reauth() -> bool:
	return false


## Log in with a platform identity token, replacing the anonymous session with
## the provider-backed user. provider: "apple" | "google".
## Returns {ok, error, user_id}. COROUTINE. (Wave 4)
func login_with_provider(provider: String, identity_token: String) -> Dictionary:
	return SnapKitTransport.not_implemented()


## Associate a provider login with the CURRENT (anonymous) user so progress
## carries over. If the provider account already belongs to another user, returns
## {ok:false, error:"already_linked", other_user_id} so the game can offer to
## switch. Returns {ok, error, provider}. COROUTINE. (Wave 4)
func link_provider(provider: String, identity_token: String) -> Dictionary:
	return SnapKitTransport.not_implemented()


## Providers linked to the current user (from the last login / link response).
func linked_providers() -> PackedStringArray:
	return _linked


## Drop this device's identity: clear session + handle and delete SESSION_PATH.
## The next ensure_session() mints a fresh anonymous user. Emits
## session_changed("").
func sign_out() -> void:
	pass


## "<prefix><32 lowercase hex>" from HANDLE_BYTES crypto-random bytes.
static func generate_handle(prefix: String) -> String:
	return ""


## Parse an anon / provider login response.
## -> {ok, user_id, session_token, ttl_s, error}
static func parse_login_response(json: Variant) -> Dictionary:
	return SnapKitTransport.not_implemented()
