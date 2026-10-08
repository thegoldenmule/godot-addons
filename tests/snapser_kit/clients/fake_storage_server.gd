extends RefCounted

## In-memory Snapser Storage json-blob server for the cloud-save tests, installed
## on a FakeTransport. Mirrors the documented semantics:
##   GET  .../json-blobs/{key}  -> 200 {value, cas} | 404 (5000)
##   POST .../json-blobs/{key}  -> 200 {cas} | 409 (5006, exists)
##   PUT  .../json-blobs/{key}  {value, cas?, create?} -> 200 {cas}
##        | 400 (5007, CAS mismatch) | 404 (missing and create not set)
##   GET  .../cas/{key}         -> 200 {cas} | 404
## Several FakeTransports (devices) may share one server. Values are stored as
## JSON text, as on the wire.

var blobs: Dictionary = {}   # "owner/access/key" -> {text, cas}
var _cas_seq: int = 1000
## Make the next N writes fail with this status (e.g. 500), for failure tests.
var fail_writes: int = 0
var fail_status: int = 500


func install(t: Variant) -> void:
	var blob := "/v1/storage/owner/{owner}/{access}/json-blobs/{key}"
	var cas := "/v1/storage/owner/{owner}/{access}/cas/{key}"
	t.route(HTTPClient.METHOD_GET, blob, _get_blob)
	t.route(HTTPClient.METHOD_POST, blob, _insert_blob)
	t.route(HTTPClient.METHOD_PUT, blob, _replace_blob)
	t.route(HTTPClient.METHOD_GET, cas, _get_cas)


## Decoded value of a stored blob (null if absent).
func value_of(owner: String, key: String, access: String = "private") -> Variant:
	var b: Variant = blobs.get("%s/%s/%s" % [owner, access, key])
	return SnapKitJson.parse(b.text) if b != null else null


## Overwrite a blob as another device would (bumps the CAS).
func put_raw(owner: String, key: String, value: Dictionary, access: String = "private") -> void:
	blobs["%s/%s/%s" % [owner, access, key]] = {"text": JSON.stringify(value), "cas": _next_cas()}


func _id(req: Dictionary) -> String:
	return "%s/%s/%s" % [req.params.owner, req.params.access, req.params.key]


func _next_cas() -> String:
	_cas_seq += 1
	return str(_cas_seq)


func _fail() -> Variant:
	if fail_writes > 0:
		fail_writes -= 1
		return {"status": fail_status, "json": {"message": "injected"}}
	return null


func _get_blob(req: Dictionary) -> Dictionary:
	var b: Variant = blobs.get(_id(req))
	if b == null:
		return {"status": 404, "json": {"error_code": 5000, "message": "Key not found"}}
	return {"status": 200, "json": {"value": SnapKitJson.parse(b.text), "cas": b.cas}}


func _get_cas(req: Dictionary) -> Dictionary:
	var b: Variant = blobs.get(_id(req))
	if b == null:
		return {"status": 404, "json": {"error_code": 5000}}
	return {"status": 200, "json": {"cas": b.cas}}


func _insert_blob(req: Dictionary) -> Dictionary:
	var f: Variant = _fail()
	if f != null:
		return f
	if blobs.has(_id(req)):
		return {"status": 409, "json": {"error_code": 5006, "message": "Document already exists"}}
	var c := _next_cas()
	blobs[_id(req)] = {"text": JSON.stringify(req.body.value), "cas": c}
	return {"status": 200, "json": {"cas": c}}


func _replace_blob(req: Dictionary) -> Dictionary:
	var f: Variant = _fail()
	if f != null:
		return f
	var b: Variant = blobs.get(_id(req))
	var body: Dictionary = req.body
	if b == null and not bool(body.get("create", false)):
		return {"status": 404, "json": {"error_code": 5000}}
	if b != null and body.has("cas") and str(body.cas) != str(b.cas):
		return {"status": 400, "json": {"error_code": 5007, "message": "CAS mismatch"}}
	var c := _next_cas()
	blobs[_id(req)] = {"text": JSON.stringify(body.value), "cas": c}
	return {"status": 200, "json": {"cas": c}}
