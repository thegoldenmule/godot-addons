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
##     kind "timeout" | "network" | "http_500" | "http_429".
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
## Transport-facing entry point: handle(). The transport awaits nothing extra
## for the mock except an optional `latency_s` it honours via a SceneTree timer.
##
## SKELETON: signatures final for v0.1; bodies are stubs.

## Enforce Token / User-Id on non-auth routes.
var require_auth: bool = true
## Simulated latency per request (seconds); 0 = immediate.
var latency_s: float = 0.0
## Log of every request dict received, in order.
var requests: Array = []


## Register a handler. path_pattern may contain {name} segments, matched against
## a single path segment and exposed in req.params. Later registrations win.
func route(method: int, path_pattern: String, handler: Callable) -> void:
	pass


## Shorthand: always answer method+path_pattern with status + json.
func respond(method: int, path_pattern: String, status: int, json: Variant = null) -> void:
	pass


## Make the next `count` requests fail with `kind` (see class doc).
func fail_next(count: int, kind: String) -> void:
	pass


## Invalidate every issued session token.
func invalidate_sessions() -> void:
	pass


## Requests whose path starts with prefix.
func requests_to(path_prefix: String) -> Array:
	return []


## Clear routes (built-ins kept), failures, sessions and the request log.
func reset() -> void:
	pass


## Called by SnapKitTransport instead of HTTP. url_path is the gateway-relative
## path including any query string. Returns one of:
##   {status:int, text:String}   (json responses are already stringified)
##   {timeout:true} | {network_error:true}
func handle(method: int, url_path: String, headers: PackedStringArray, body_text: String) -> Dictionary:
	return {"status": 501, "text": ""}
