extends SnapKitTransport

## Test-local stand-in for SnapKitTransport used by the clients/ tests. It keeps
## the transport CONTRACT (result shape, "{user_id}" expansion, offline
## short-circuit) but answers from in-process route handlers instead of HTTP.
## Bodies and responses go through a real JSON text round trip, so tests see
## exactly what the wire would do to types (ints become floats, etc.).
##
## Once SnapKitMockGateway (agent A) is implemented, the same scenarios can also
## run through the real transport; these fakes keep clients/ testable without
## depending on core/ internals.
##
##   var t := FakeTransport.new(); add_node(t)
##   t.respond(HTTPClient.METHOD_GET, "/v1/x/{name}", 200, {"a": 1})
##   t.route(HTTPClient.METHOD_PUT, "/v1/y", func(req): return {"status": 200, "json": req.body})
## Handler req: {method, path (no query), raw_path, query:{k: String|Array},
##   params:{name: String}, body: Variant (parsed), opts}
## Handler return: {status, json?} or {error: "timeout"|"network"|...}.

## When true, request() returns ERR_OFFLINE without calling any handler.
var offline: bool = false
## The session user id substituted for "{user_id}".
var uid: String = "user-1"
## Process frames awaited per request (keeps calls asynchronous like real HTTP).
var frames: int = 1
## Every request received, in order.
var calls: Array = []

var _routes: Array = []


func route(method: int, pattern: String, handler: Callable) -> void:
	var names := PackedStringArray()
	var rx := "^"
	for seg in pattern.split("/", false):
		rx += "/"
		if seg.begins_with("{") and seg.ends_with("}"):
			names.append(seg.substr(1, seg.length() - 2))
			rx += "([^/]+)"
		else:
			rx += _escape(seg)
	rx += "$"
	_routes.push_front({"method": method, "re": RegEx.create_from_string(rx), "names": names, "handler": handler})


func respond(method: int, pattern: String, status: int, json: Variant = null) -> void:
	route(method, pattern, func(_req: Dictionary) -> Dictionary: return {"status": status, "json": json})


func calls_to(path_prefix: String, method: int = -1) -> Array:
	var out: Array = []
	for c in calls:
		if str(c.path).begins_with(path_prefix) and (method < 0 or int(c.method) == method):
			out.append(c)
	return out


func is_offline() -> bool:
	return offline


func user_id() -> String:
	return uid


func request(method: int, path: String, body: Variant = null, opts: Dictionary = {}) -> Dictionary:
	if offline:
		return error_result(ERR_OFFLINE)
	var full := expand_path(path, uid)
	var p := full
	var q := ""
	var qi := full.find("?")
	if qi >= 0:
		p = full.substr(0, qi)
		q = full.substr(qi + 1)
	var body_text := ""
	if body is String:
		body_text = body
	elif body != null:
		body_text = JSON.stringify(body)
	var req := {
		"method": method, "path": p, "raw_path": full, "query": _parse_query(q),
		"params": {}, "body": SnapKitJson.parse(body_text), "opts": opts,
	}
	calls.append(req)
	if is_inside_tree():
		for i in frames:
			await get_tree().process_frame
	for r in _routes:
		if int(r.method) != method:
			continue
		var m: RegExMatch = r.re.search(p)
		if m == null:
			continue
		var params := {}
		for i in r.names.size():
			params[r.names[i]] = m.get_string(i + 1).uri_decode()
		req.params = params
		var out: Dictionary = r.handler.call(req)
		if out.has("error"):
			return error_result(str(out.error))
		var status := int(out.get("status", 200))
		var text := JSON.stringify(out.json) if out.has("json") and out.json != null else ""
		# Same status/body -> result mapping as the real transport (error codes,
		# snap_code), so client tests see what a live call would return.
		return _to_result({"status": status, "text": text})
	return make_result(false, 404, null, http_error(404))


static func _parse_query(q: String) -> Dictionary:
	var out := {}
	if q == "":
		return out
	for pair in q.split("&", false):
		var kv := pair.split("=", true, 1)
		var k := kv[0].uri_decode()
		var v := kv[1].uri_decode() if kv.size() > 1 else ""
		if out.has(k):
			if out[k] is Array:
				out[k].append(v)
			else:
				out[k] = [out[k], v]
		else:
			out[k] = v
	return out


static func _escape(s: String) -> String:
	var out := ""
	for ch in s:
		if ch in [".", "+", "*", "?", "(", ")", "[", "]", "^", "$", "|", "\\"]:
			out += "\\" + ch
		else:
			out += ch
	return out
