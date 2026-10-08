@tool
class_name SnapKitTransport
extends Node

## The ONLY HTTP sender in Snapser Kit. Every client, SnapKitAuth's login, and
## the mock gateway go through request().
##
## ---------------------------------------------------------------------------
## CONTRACT (frozen for v0.1 — clients/ are written against it)
## ---------------------------------------------------------------------------
##   var res: Dictionary = await transport.request(method, path, body, opts)
##
## method  HTTPClient.METHOD_GET / PUT / POST / PATCH / DELETE.
## path    Relative to the gateway, starting with "/v1/...". May contain the
##         literal placeholder "{user_id}", which is replaced (uri-encoded) with
##         the session user id AFTER the session is ensured — so clients never
##         build a path with an empty user id. May include a query string; use
##         with_query() to build one.
## body    null (no body), a Dictionary/Array (sent as JSON), or a String sent
##         verbatim (Content-Type stays application/json).
## opts    Optional Dictionary:
##           "auth"      bool  = true   ensure a session first and send the
##                                      Token / User-Id headers. false for the
##                                      login call itself.
##           "timeout_s" float = DEFAULT_TIMEOUT_S  per attempt.
##           "retries"   int   = DEFAULT_RETRIES for idempotent methods (GET, PUT,
##                                      DELETE, HEAD), 0 for POST / PATCH. Retries
##                                      happen only on timeout, network failure,
##                                      HTTP 429 and HTTP 5xx, with exponential
##                                      backoff (BACKOFF_BASE_S * 2^n, jittered).
##           "headers"   PackedStringArray  extra request headers.
##           "no_retry"  bool  = false  disable BOTH the backoff retries and the
##                                      401 reauth-replay. Required for calls whose
##                                      payload is single-use (Apple authorization
##                                      codes on /v1/auth/login/apple).
##
## Result (always this shape, never throws, never pushes errors):
##   { "ok": bool, "status": int, "json": Variant, "error": String }
##   ok      true iff an HTTP 2xx response was received.
##   status  HTTP status, or 0 when no response (offline / timeout / network).
##   json    Parsed body (SnapKitJson.parse — lenient), or null.
##   error   "" when ok, else one of the ERR_* codes below, or "http_<status>".
##
## 401 rule (ALL methods unless "no_retry"): when "auth" is true and the response is 401, the
## transport calls auth.reauth() once (keeping the same anonymous handle) and
## replays the request once. A second 401 is returned as "http_401".
##
## Offline rule: when the config is offline, request() returns
## { ok:false, status:0, json:null, error:"offline" } immediately, with no
## network activity and no awaiting on timers.
##
## Web-safe: uses HTTPRequest nodes (children of this node) and SceneTree timers
## only — no threads.
##
## Higher layers (clients, SnapKitService) return this same dictionary augmented
## with parsed fields (e.g. "entries", "value"); they never remove ok / error.

const DEFAULT_TIMEOUT_S := 10.0
const DEFAULT_RETRIES := 2
const BACKOFF_BASE_S := 0.5
const BACKOFF_MAX_S := 4.0
const USER_ID_PLACEHOLDER := "{user_id}"

## Error codes (result["error"]). Clients reuse these; HTTP failures are
## "http_<status>" (see http_error()).
const ERR_OFFLINE := "offline"                    # config offline; no request made
const ERR_NO_SESSION := "no_session"              # login failed / no user id
const ERR_TIMEOUT := "timeout"                    # no response within timeout_s
const ERR_NETWORK := "network"                    # connect / TLS / DNS failure
const ERR_BAD_RESPONSE := "bad_response"          # 2xx but body unusable (client-level)
const ERR_INVALID_ARGUMENT := "invalid_argument"  # rejected before sending (client-level)
const ERR_DISABLED := "disabled"                  # feature not enabled in config
const ERR_NOT_IMPLEMENTED := "not_implemented"

var _config: SnapKitConfig
var _auth: SnapKitAuth
var _mock: SnapKitMockGateway
## Diagnostics: number of attempts sent (network or mock), for tests and logs.
var attempts_sent: int = 0
## Multiplier on retry backoff delays (tests set 0 to retry without waiting).
var backoff_scale: float = 1.0


## Wire dependencies. Called by SnapKitService.start_with_config(); tests may call
## it directly. auth may be null for unauthenticated-only use.
func setup(config: SnapKitConfig, auth: SnapKitAuth) -> void:
	_config = config
	_auth = auth


## Route every request to an in-process fake instead of the network (tests).
## Pass null to restore real HTTP. The config must still be online (non-empty
## gateway_url, e.g. "http://mock.invalid") or request() short-circuits offline.
func use_mock_gateway(mock: SnapKitMockGateway) -> void:
	_mock = mock


## True when request() would short-circuit with ERR_OFFLINE.
func is_offline() -> bool:
	return _config == null or _config.is_offline()


## The current session user id ("" before login). Clients use this for parsing
## (e.g. marking "me" in a leaderboard), never for building paths — use the
## "{user_id}" placeholder instead.
func user_id() -> String:
	return _auth.user_id if _auth != null else ""


## Perform one logical request (with retries / 401 replay). COROUTINE — await it.
## See the class doc for the full contract.
func request(method: int, path: String, body: Variant = null, opts: Dictionary = {}) -> Dictionary:
	if is_offline():
		return error_result(ERR_OFFLINE)
	var use_auth: bool = SnapKitJson.to_bool(opts.get("auth", true), true)
	var timeout_s: float = SnapKitJson.to_float(opts.get("timeout_s", DEFAULT_TIMEOUT_S), DEFAULT_TIMEOUT_S)
	var no_retry: bool = SnapKitJson.to_bool(opts.get("no_retry", false), false)
	var retries: int = 0 if no_retry else \
		SnapKitJson.to_int(opts.get("retries", DEFAULT_RETRIES if is_idempotent(method) else 0), 0)
	var extra: PackedStringArray = opts.get("headers", PackedStringArray()) if opts.get("headers") is PackedStringArray else PackedStringArray()
	var payload := ""
	if body is String:
		payload = body
	elif body != null:
		payload = JSON.stringify(body)

	if use_auth:
		if _auth == null or not await _auth.ensure_session():
			return error_result(ERR_NO_SESSION)

	var res := await _send_with_retries(method, path, payload, use_auth, timeout_s, retries, extra)
	# 401 on a locally-valid token = server-side invalidation (e.g. a snapend
	# apply). Re-login once with the same handle and replay once.
	if use_auth and not no_retry and int(res.status) == 401:
		if await _auth.reauth():
			res = await _send_with_retries(method, path, payload, use_auth, timeout_s, retries, extra)
	return res


func _send_with_retries(method: int, path: String, payload: String, use_auth: bool,
		timeout_s: float, retries: int, extra: PackedStringArray) -> Dictionary:
	var attempt := 0
	while true:
		var res := await _send_once(method, path, payload, use_auth, timeout_s, extra)
		if res.ok or attempt >= retries or not is_retryable(res):
			return res
		attempt += 1
		await _sleep(backoff_delay(attempt) * backoff_scale)
	return error_result(ERR_NETWORK)  # unreachable


func _send_once(method: int, path: String, payload: String, use_auth: bool,
		timeout_s: float, extra: PackedStringArray) -> Dictionary:
	var uid := user_id()
	if path.contains(USER_ID_PLACEHOLDER) and uid == "":
		return error_result(ERR_NO_SESSION)
	var rel := expand_path(path, uid)
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json"])
	if use_auth and _auth != null:
		headers.append_array(_auth.auth_headers())
	headers.append_array(extra)
	attempts_sent += 1

	if _mock != null:
		if _mock.latency_s > 0.0:
			await _sleep(_mock.latency_s)
		return _to_result(_mock.handle(method, rel, headers, payload))

	var http := HTTPRequest.new()
	http.timeout = timeout_s
	http.use_threads = false
	add_child(http)
	var err := http.request(_config.gateway_url + rel, headers, method, payload)
	if err != OK:
		http.queue_free()
		return error_result(ERR_NETWORK)
	var resp: Array = await http.request_completed
	http.queue_free()
	var result: int = resp[0]
	if result == HTTPRequest.RESULT_TIMEOUT:
		return error_result(ERR_TIMEOUT)
	if result != HTTPRequest.RESULT_SUCCESS:
		return error_result(ERR_NETWORK)
	return _to_result({"status": int(resp[1]), "text": (resp[3] as PackedByteArray).get_string_from_utf8()})


## Map a raw {status, text} | {timeout} | {network_error} response to a result.
static func _to_result(raw: Dictionary) -> Dictionary:
	if raw.get("timeout", false):
		return error_result(ERR_TIMEOUT)
	if raw.get("network_error", false):
		return error_result(ERR_NETWORK)
	var status := int(raw.get("status", 0))
	var json: Variant = SnapKitJson.parse(str(raw.get("text", "")))
	if status >= 200 and status < 300:
		return make_result(true, status, json, "")
	return make_result(false, status, json, http_error(status))


func _sleep(seconds: float) -> void:
	if seconds <= 0.0 or not is_inside_tree():
		return
	await get_tree().create_timer(seconds, true, false, true).timeout


## Backoff before retry `attempt` (1-based): BACKOFF_BASE_S * 2^(attempt-1),
## capped at BACKOFF_MAX_S, with +/-25% jitter.
static func backoff_delay(attempt: int) -> float:
	var base := minf(BACKOFF_BASE_S * pow(2.0, attempt - 1), BACKOFF_MAX_S)
	return base * randf_range(0.75, 1.25)


# ---- Pure helpers (implemented; usable by clients and tests) -----------------

## Build a result dictionary in the canonical shape.
static func make_result(ok: bool, status: int, json: Variant, error: String) -> Dictionary:
	return {"ok": ok, "status": status, "json": json, "error": error}


static func ok_result(json: Variant = null, status: int = 200) -> Dictionary:
	return make_result(true, status, json, "")


static func error_result(error: String, status: int = 0, json: Variant = null) -> Dictionary:
	return make_result(false, status, json, error)


static func not_implemented() -> Dictionary:
	return error_result(ERR_NOT_IMPLEMENTED)


## "http_<status>".
static func http_error(status: int) -> String:
	return "http_%d" % status


## Append a query string. Keys and values are uri-encoded; null values are
## skipped; Array values repeat the key; bools become "true"/"false".
##   with_query("/v1/x", {"a": 1, "tags": "daily"}) -> "/v1/x?a=1&tags=daily"
static func with_query(path: String, params: Dictionary) -> String:
	var parts := PackedStringArray()
	for k in params:
		var v: Variant = params[k]
		if v == null:
			continue
		var values: Array = v if v is Array else [v]
		for item in values:
			var s: String
			if typeof(item) == TYPE_BOOL:
				s = "true" if item else "false"
			else:
				s = str(item)
			parts.append("%s=%s" % [str(k).uri_encode(), s.uri_encode()])
	if parts.is_empty():
		return path
	return path + ("&" if path.contains("?") else "?") + "&".join(parts)


## Replace every "{user_id}" in path with the uri-encoded id.
static func expand_path(path: String, uid: String) -> String:
	return path.replace(USER_ID_PLACEHOLDER, uid.uri_encode())


## GET / PUT / DELETE / HEAD / OPTIONS are retried by default; POST / PATCH not.
static func is_idempotent(method: int) -> bool:
	return method in [HTTPClient.METHOD_GET, HTTPClient.METHOD_PUT, HTTPClient.METHOD_DELETE,
		HTTPClient.METHOD_HEAD, HTTPClient.METHOD_OPTIONS]


## True for failures worth retrying: timeout, network, 429, 5xx.
static func is_retryable(result: Dictionary) -> bool:
	var status := int(result.get("status", 0))
	var err := str(result.get("error", ""))
	return err == ERR_TIMEOUT or err == ERR_NETWORK or status == 429 or (status >= 500 and status < 600)
