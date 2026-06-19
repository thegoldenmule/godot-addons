@tool
class_name BridgeServer
extends Node

## Localhost-only HTTP bridge base for a tool that exposes an MCP/CLI shim:
## a TCPServer + _process poll loop, Content-Length request framing, async route
## dispatch, JSON responses, and a headless skip. A subclass plugs in two things:
##
##   _resolve_port() -> int                       the port to bind (env / config /
##                                                default — a subclass concern)
##   _route(method, path, query, body) -> {       its [method, path] table; MAY
##       "code": int, "payload": Dictionary }     await the service's coroutines
##
## The base owns connection lifecycle, framing, and the response. Connections
## stay open through long (10–60 s) async work: each request dispatches a
## coroutine that writes its response whenever the awaited route work finishes.
## Headless invocations (web export, verifier scripts) load @tool plugins too —
## the bridge skips binding so it never collides with an open editor's port.

var service: Node
var port := 0

var _server := TCPServer.new()
var _conns: Array = []


# ── subclass hooks ────────────────────────────────────────────────────────────


## Override: the port to listen on. Default keeps `port` as already set.
func _resolve_port() -> int:
	return port


## Override: dispatch one request to the service and return
## {"code": int, "payload": Dictionary}. May await service coroutines. The base
## default 404s every route.
func _route(method: String, path: String, _query: Dictionary, _body: Dictionary) -> Dictionary:
	return {"code": 404, "payload": {"ok": false, "error": "no route %s %s" % [method, path]}}


# ── lifecycle ─────────────────────────────────────────────────────────────────


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		set_process(false)
		return
	port = _resolve_port()
	var err := _server.listen(port, "127.0.0.1")
	if err != OK:
		push_error("%s: cannot listen on 127.0.0.1:%d (err %d)" % [_label(), port, err])
	else:
		print("%s listening on 127.0.0.1:%d" % [_label(), port])


func _exit_tree() -> void:
	_server.stop()


func _label() -> String:
	return name if String(name) != "" else "Bridge"


# ── poll loop ─────────────────────────────────────────────────────────────────


func _process(_delta: float) -> void:
	while _server.is_connection_available():
		_conns.append({"peer": _server.take_connection(), "buf": PackedByteArray(), "dispatched": false})
	for conn in _conns.duplicate():
		var peer: StreamPeerTCP = conn["peer"]
		peer.poll()
		var status := peer.get_status()
		if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
			_conns.erase(conn)
			continue
		if conn["dispatched"]:
			continue
		var available := peer.get_available_bytes()
		if available > 0:
			var chunk: Array = peer.get_data(available)
			if chunk[0] == OK:
				conn["buf"].append_array(chunk[1])
		if _request_complete(conn["buf"]):
			conn["dispatched"] = true
			_handle(conn)


func _request_complete(buf: PackedByteArray) -> bool:
	var text := buf.get_string_from_utf8()
	var header_end := text.find("\r\n\r\n")
	if header_end < 0:
		return false
	var content_length := 0
	for line in text.left(header_end).split("\r\n"):
		if line.to_lower().begins_with("content-length:"):
			content_length = line.get_slice(":", 1).strip_edges().to_int()
	return buf.size() >= header_end + 4 + content_length


func _handle(conn: Dictionary) -> void:
	var text: String = conn["buf"].get_string_from_utf8()
	var header_end := text.find("\r\n\r\n")
	var request_line := text.get_slice("\r\n", 0)
	var method := request_line.get_slice(" ", 0)
	var target := request_line.get_slice(" ", 1)
	var path := target.get_slice("?", 0)
	var query := _parse_query(target.get_slice("?", 1) if target.contains("?") else "")
	var body: Variant = JSON.parse_string(text.substr(header_end + 4))
	if typeof(body) != TYPE_DICTIONARY:
		body = {}

	var routed: Dictionary = await _route(method, path, query, body)
	_respond(conn, int(routed.get("code", 200)), routed.get("payload", {}))


func _respond(conn: Dictionary, code: int, payload: Dictionary) -> void:
	var peer: StreamPeerTCP = conn["peer"]
	peer.poll()
	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		var body := JSON.stringify(payload).to_utf8_buffer()
		var head := ("HTTP/1.1 %d %s\r\nContent-Type: application/json\r\n"
			+ "Content-Length: %d\r\nConnection: close\r\n\r\n") % [
				code, "OK" if code == 200 else "Error", body.size()]
		peer.put_data(head.to_utf8_buffer())
		peer.put_data(body)
		peer.disconnect_from_host()
	_conns.erase(conn)


func _parse_query(query_string: String) -> Dictionary:
	var out := {}
	for pair in query_string.split("&"):
		if pair.contains("="):
			out[pair.get_slice("=", 0)] = pair.get_slice("=", 1).uri_decode()
	return out
