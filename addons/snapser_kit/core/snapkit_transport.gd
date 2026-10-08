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
##
## Result (always this shape, never throws, never pushes errors):
##   { "ok": bool, "status": int, "json": Variant, "error": String }
##   ok      true iff an HTTP 2xx response was received.
##   status  HTTP status, or 0 when no response (offline / timeout / network).
##   json    Parsed body (SnapKitJson.parse — lenient), or null.
##   error   "" when ok, else one of the ERR_* codes below, or "http_<status>".
##
## 401 rule (ALL methods): when "auth" is true and the response is 401, the
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
##
## SKELETON: request() is stubbed; the static helpers are implemented.

const DEFAULT_TIMEOUT_S := 10.0
const DEFAULT_RETRIES := 2
const BACKOFF_BASE_S := 0.5
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
	return error_result(ERR_NOT_IMPLEMENTED)


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
