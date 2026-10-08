class_name SnapKitMockGateway
extends RefCounted

## In-process fake Snapser gateway for headless tests. No sockets.
##
##   var mock := SnapKitMockGateway.new()
##   mock.route(HTTPClient.METHOD_GET, "/v1/leaderboards/leaderboards/{board}",
##       func(req: Dictionary) -> Dictionary:
##           return {"status": 200, "json": {"user_scores": []}})
##   service.start_with_config(SnapKitConfig.from_dict(
##       {"game_id": "t", "gateway_url": "http://mock.invalid"}))
##   service.use_mock_gateway(mock)          # or transport.use_mock_gateway(mock)
##
## Built in:
##   - PUT /v1/auth/login/anon issues {user:{id, session_token,
##     token_validity_seconds}}; the same username always maps to the same id.
##   - Every other route requires valid "Token" / "User-Id" headers when
##     require_auth is true, else 401.
##   - invalidate_sessions(): every issued token becomes invalid (simulates a
##     snapend apply), to exercise 401 -> reauth -> retry.
##   - fail_next(count, kind): the next `count` requests (any route) fail with
##     kind "timeout" | "network" | "http_<status>" (e.g. "http_500").
##   - PATCH /v1/auth/refresh {session_token} (+ Token header, required as on
##     the live gateway): a still-valid token is swapped for a new one (same
##     user); an invalid one gets 401, a missing header 400.
##   - Paths under /v1/auth/login/ and /v1/auth/refresh never require a session.
##   - Custom routes are matched before the built-in anon login, so a test can
##     override it.
##
## Request dict passed to handlers and stored in `requests`:
##   {method:int, path:String (no query), query:Dictionary, params:Dictionary
##    (from {name} pattern segments), headers:Dictionary, body:Variant (parsed
##    JSON or null), text:String (raw body), user_id:String (from headers)}
## Handler return (any one):
##   {status:int, json:Variant}       body is JSON.stringify(json)
##   {status:int, text:String}        body sent verbatim (e.g. int64 strings,
##                                    malformed JSON)
##   {timeout:true} | {network_error:true}
## Unrouted paths -> 404.
##
## Transport-facing entry point: handle(). The transport honours `latency_s`
## with a SceneTree timer before calling it.

## Sandbox: constructing a mock gateway moves SnapKitConfig.data_root to a
## scratch directory (use_scratch_data_root) when it is still the default
## user://, so kit objects created afterwards never write the player's real
## session / cloud-save files. Set the root yourself first to choose another.

## Enforce Token / User-Id on non-login routes.
var require_auth: bool = true
## Simulated latency per request (seconds); 0 = immediate.
var latency_s: float = 0.0
## token_validity_seconds returned by the built-in anon login.
var token_ttl_s: int = 3600
## Log of every request dict received, in order.
var requests: Array = []
## Number of successful built-in anonymous logins.
var login_count: int = 0
## Number of successful built-in refreshes.
var refresh_count: int = 0

var _routes: Array = []          # [{method, parts: PackedStringArray, handler}]
var _fail_queue: Array = []      # pending failure kinds
var _sessions: Dictionary = {}   # session token -> user id
var _users: Dictionary = {}      # anon username -> user id
var _next_id: int = 1


func _init() -> void:
	use_scratch_data_root()


## Point SnapKitConfig.data_root at a per-process scratch dir under the OS temp
## dir, unless something already moved it off user://. Returns the root.
static func use_scratch_data_root() -> String:
	if SnapKitConfig.data_root == "user://":
		SnapKitConfig.data_root = OS.get_temp_dir().path_join("snapkit_sandbox_%d" % OS.get_process_id())
	return SnapKitConfig.data_root


## Register a handler. path_pattern may contain {name} segments, matched against
## a single path segment and exposed in req.params. Later registrations win.
func route(method: int, path_pattern: String, handler: Callable) -> void:
	_routes.push_front({"method": method, "parts": _split(path_pattern), "handler": handler})


## Shorthand: always answer method+path_pattern with status + json.
func respond(method: int, path_pattern: String, status: int, json: Variant = null) -> void:
	route(method, path_pattern, func(_req: Dictionary) -> Dictionary:
		return {"status": status, "json": json})


## Make the next `count` requests fail with `kind` (see class doc).
func fail_next(count: int, kind: String) -> void:
	for i in count:
		_fail_queue.append(kind)


## Invalidate every issued session token.
func invalidate_sessions() -> void:
	_sessions.clear()


## The user id the built-in anon login assigned to `username` ("" if none).
func user_for_handle(username: String) -> String:
	return str(_users.get(username, ""))


## Requests whose path starts with prefix.
func requests_to(path_prefix: String) -> Array:
	return requests.filter(func(r: Dictionary) -> bool: return str(r.path).begins_with(path_prefix))


## Clear routes (built-ins kept), failures, sessions and the request log.
func reset() -> void:
	_routes.clear()
	_fail_queue.clear()
	_sessions.clear()
	_users.clear()
	requests.clear()
	login_count = 0
	refresh_count = 0


## Called by SnapKitTransport instead of HTTP. url_path is the gateway-relative
## path including any query string. Returns one of:
##   {status:int, text:String}   (json responses are already stringified)
##   {timeout:true} | {network_error:true}
func handle(method: int, url_path: String, headers: PackedStringArray, body_text: String) -> Dictionary:
	var path := url_path.get_slice("?", 0)
	var query := {}
	if url_path.contains("?"):
		for pair in url_path.substr(url_path.find("?") + 1).split("&", false):
			var k := pair.get_slice("=", 0).uri_decode()
			var v := pair.substr(pair.find("=") + 1).uri_decode() if pair.contains("=") else ""
			if query.has(k):
				query[k] = (query[k] if query[k] is Array else [query[k]]) + [v]
			else:
				query[k] = v
	var hdrs := {}
	for h in headers:
		var idx := h.find(":")
		if idx > 0:
			hdrs[h.substr(0, idx).strip_edges().to_lower()] = h.substr(idx + 1).strip_edges()
	var req := {
		"method": method, "path": path, "query": query, "params": {},
		"headers": hdrs, "body": SnapKitJson.parse(body_text), "text": body_text,
		"user_id": str(hdrs.get("user-id", "")),
	}
	requests.append(req)

	if not _fail_queue.is_empty():
		var kind: String = _fail_queue.pop_front()
		match kind:
			"timeout":
				return {"timeout": true}
			"network":
				return {"network_error": true}
			_:
				return {"status": int(kind.trim_prefix("http_")), "text": "{\"message\":\"injected failure\"}"}

	var is_login := path.begins_with("/v1/auth/login/") or path == "/v1/auth/refresh"
	if require_auth and not is_login:
		var token := str(hdrs.get("token", ""))
		if token == "" or str(_sessions.get(token, "")) != req.user_id:
			return {"status": 401, "text": "{\"message\":\"unauthorized\"}"}

	var parts := _split(path)
	for r in _routes:
		if r.method != method:
			continue
		var params := _match(r.parts, parts)
		if params == null:
			continue
		req.params = params
		return _encode(r.handler.call(req))

	if method == HTTPClient.METHOD_PUT and path == "/v1/auth/login/anon":
		return _encode(_anon_login(req))
	if method == HTTPClient.METHOD_PATCH and path == "/v1/auth/refresh":
		return _encode(_refresh(req))
	return {"status": 404, "text": "{\"message\":\"no route\"}"}


# ---- internals ---------------------------------------------------------------

func _anon_login(req: Dictionary) -> Dictionary:
	var username := SnapKitJson.get_str(req.body, "username")
	if username == "":
		return {"status": 400, "json": {"message": "username required"}}
	var created := false
	if not _users.has(username):
		if not SnapKitJson.get_bool(req.body, "create_user", false):
			return {"status": 404, "json": {"message": "user not found"}}
		_users[username] = "mock-user-%d" % _next_id
		_next_id += 1
		created = true
	var uid: String = _users[username]
	var token := issue_session(uid)
	login_count += 1
	return {"status": 200, "json": {"user": {
		"id": uid, "session_token": token, "token_validity_seconds": token_ttl_s,
		"created": created, "login_types": ["ANON"],
	}}}


func _refresh(req: Dictionary) -> Dictionary:
	# As live: the Token header is required (400 code 10 without it).
	if str(req.headers.get("token", "")) == "":
		return {"status": 400, "json": {"api_error_code": 10, "message": "Session token not found"}}
	var old := SnapKitJson.get_str(req.body, "session_token")
	if not _sessions.has(old):
		return {"status": 401, "json": {"message": "invalid session"}}
	var uid: String = _sessions[old]
	_sessions.erase(old)
	var token := issue_session(uid)
	refresh_count += 1
	return {"status": 200, "json": {"user": {
		"id": uid, "session_token": token, "token_validity_seconds": token_ttl_s,
		"created": false, "login_types": ["ANON"],
	}}}


## Mint a valid session token for uid (tests use it to fake provider users).
func issue_session(uid: String) -> String:
	var token := "mock-token-%s" % Crypto.new().generate_random_bytes(8).hex_encode()
	_sessions[token] = uid
	return token


static func _encode(resp: Variant) -> Dictionary:
	if not (resp is Dictionary):
		return {"status": 500, "text": ""}
	if resp.get("timeout", false) or resp.get("network_error", false):
		return resp
	var text := ""
	if resp.has("text"):
		text = str(resp.text)
	elif resp.get("json") != null:
		text = JSON.stringify(resp.json)
	return {"status": int(resp.get("status", 200)), "text": text}


static func _split(path: String) -> PackedStringArray:
	return path.get_slice("?", 0).split("/", false)


## Dictionary of params on match, else null.
static func _match(pattern: PackedStringArray, parts: PackedStringArray) -> Variant:
	if pattern.size() != parts.size():
		return null
	var params := {}
	for i in pattern.size():
		var p := pattern[i]
		if p.begins_with("{") and p.ends_with("}"):
			params[p.substr(1, p.length() - 2)] = parts[i].uri_decode()
		elif p != parts[i]:
			return null
	return params
