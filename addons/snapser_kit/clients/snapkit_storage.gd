class_name SnapKitStorage
extends RefCounted

## Client for the Snapser Storage snap's JSON blobs (storage.swagger3.json),
## owned by the session user.
##
##   GET    /v1/storage/owner/{owner_id}/{access_type}/json-blobs/{key}  GetJsonBlob     -> {value:object, cas}
##   PUT    /v1/storage/owner/{owner_id}/{access_type}/json-blobs/{key}  ReplaceJsonBlob {value, cas?, create?} -> {cas}
##   POST   /v1/storage/owner/{owner_id}/{access_type}/json-blobs/{key}  InsertJsonBlob  {value} -> {cas} (fails if it exists)
##   DELETE /v1/storage/owner/{owner_id}/{access_type}/json-blobs/{key}?cas=  DeleteJsonBlob -> {cas}
##   GET    /v1/storage/owner/{owner_id}/{access_type}/cas/{key}         GetCas -> {cas}
##
## owner_id is always the session user ("{user_id}" placeholder). The swagger
## types `value` as an object, so blobs must be Dictionaries. A missing blob is
## HTTP 404 (verified by the Moveborne validator's storage client).
##
## Optimistic concurrency (put_json_blob_cas): with a CAS token the write is a
## PUT {value, cas}; with "" it is a POST insert, which fails if the blob exists.
## Live behaviour (verified on a dev snapend, 2026-10-08): a stale CAS is
## HTTP 400 {"api_error_code": 5007, "message": "CAS mismatch"}, and that is
## reported as conflict:true directly. Any other rejected write (4xx other than
## 401/403/429) is double-checked by re-reading the blob's CAS: if it differs
## from the one we sent, the result carries conflict:true (and remote_cas)
## instead of a silent overwrite.
## The GetCas route (/cas/{key}) is for plain blobs only; on a JSON blob it
## answers 400 5001 "Storage type for key does not match", so get_cas() reads
## the token from GET json-blobs/{key} instead.
##
## Conventions: see SnapKitStats.

const ACCESS_PRIVATE := "private"
const ACCESS_PROTECTED := "protected"
const ACCESS_PUBLIC := "public"
const BASE_PATH := "/v1/storage/owner/{user_id}"
## Snapser storage api_error_code for a CAS mismatch.
const SNAP_ERR_CAS_MISMATCH := SnapKitErrors.SNAP_CAS_MISMATCH

var _transport: SnapKitTransport


func _init(transport: SnapKitTransport) -> void:
	_transport = transport


## "/v1/storage/owner/{user_id}/<access>/json-blobs/<key>".
static func json_blob_path(key: String, access: String = ACCESS_PRIVATE) -> String:
	return "%s/%s/json-blobs/%s" % [BASE_PATH, access.uri_encode(), key.uri_encode()]


## "/v1/storage/owner/{user_id}/<access>/cas/<key>".
static func cas_path(key: String, access: String = ACCESS_PRIVATE) -> String:
	return "%s/%s/cas/%s" % [BASE_PATH, access.uri_encode(), key.uri_encode()]


## ReplaceJsonBlob / InsertJsonBlob body. cas "" omits the token; create adds
## create:true (insert when missing).
static func put_body(value: Variant, cas: String = "", create: bool = false) -> Dictionary:
	var body := {"value": value}
	if cas != "":
		body["cas"] = cas
	if create:
		body["create"] = true
	return body


## GetJsonBlob response -> {value:Variant (null if absent), cas:String}.
static func parse_blob(json: Variant) -> Dictionary:
	var value: Variant = json.get("value") if json is Dictionary else null
	return {"value": value, "cas": SnapKitJson.get_str(json, "cas")}


## True for a write rejection that may be a CAS mismatch / already-exists.
static func is_possible_conflict(status: int) -> bool:
	return status >= 400 and status < 500 and not (status in [401, 403, 429])


## Read a blob. -> {ok, status, json, error, value:Variant, cas:String,
## exists:bool}. A missing blob is ok:true, exists:false.
func get_json_blob(key: String, access: String = ACCESS_PRIVATE) -> Dictionary:
	if key == "":
		return _invalid({"value": null, "cas": "", "exists": false})
	var res: Dictionary = await _transport.request(HTTPClient.METHOD_GET, json_blob_path(key, access))
	if int(res.status) == 404:
		return _missing(res, {"value": null, "cas": "", "exists": false})
	var parsed := parse_blob(res.json) if res.ok else {"value": null, "cas": ""}
	res["value"] = parsed.value
	res["cas"] = parsed.cas
	res["exists"] = bool(res.ok)
	return res


## Create-or-replace without concurrency check. -> {..., cas:String}
func put_json_blob(key: String, value: Variant, access: String = ACCESS_PRIVATE) -> Dictionary:
	if key == "" or not (value is Dictionary):
		return _invalid({"cas": ""})
	var res: Dictionary = await _transport.request(HTTPClient.METHOD_PUT, json_blob_path(key, access),
		put_body(value, "", true))
	res["cas"] = SnapKitJson.get_str(res.json, "cas") if res.ok else ""
	return res


## Current CAS token for a blob. -> {..., cas:String, exists:bool}. Missing blob
## is ok:true, cas "", exists:false.
func get_cas(key: String, access: String = ACCESS_PRIVATE) -> Dictionary:
	if key == "":
		return _invalid({"cas": "", "exists": false})
	# JSON blobs: the CAS rides on GetJsonBlob (the /cas/ route is plain-blob only).
	var res: Dictionary = await get_json_blob(key, access)
	res.erase("value")
	return res


## Snapser's numeric api_error_code from an error body (0 if absent).
## Kept for compatibility; see SnapKitErrors.snap_code / result["snap_code"].
static func snap_error_code(json: Variant) -> int:
	return SnapKitErrors.snap_code(json)


## Replace only if the server CAS still equals `cas` ("" = blob must not exist).
## -> {..., cas:String (new; "" on failure), conflict:bool, remote_cas:String
## (the server's token when conflict is true)}
func put_json_blob_cas(key: String, value: Variant, cas: String,
		access: String = ACCESS_PRIVATE) -> Dictionary:
	if key == "" or not (value is Dictionary):
		return _invalid({"cas": "", "conflict": false, "remote_cas": ""})
	var res: Dictionary
	if cas == "":
		res = await _transport.request(HTTPClient.METHOD_POST, json_blob_path(key, access), put_body(value))
	else:
		res = await _transport.request(HTTPClient.METHOD_PUT, json_blob_path(key, access), put_body(value, cas))
	res["cas"] = SnapKitJson.get_str(res.json, "cas") if res.ok else ""
	res["conflict"] = false
	res["remote_cas"] = ""
	if res.ok or not is_possible_conflict(int(res.status)):
		return res
	var mismatch := snap_error_code(res.json) == SNAP_ERR_CAS_MISMATCH
	# Rejected: is the server's blob actually different from what we last saw?
	var probe: Dictionary = await get_cas(key, access)
	if mismatch:
		res["conflict"] = true
		res["remote_cas"] = str(probe.get("cas", "")) if probe.get("ok", false) else ""
		return res
	if probe.ok:
		var remote_cas: String = probe.cas
		res["conflict"] = remote_cas != cas
		res["remote_cas"] = remote_cas
	else:
		res["conflict"] = int(res.status) in [409, 412]
	return res


## Delete a blob; cas "" deletes unconditionally. -> {..., cas:String}
func delete_json_blob(key: String, access: String = ACCESS_PRIVATE, cas: String = "") -> Dictionary:
	if key == "":
		return _invalid({"cas": ""})
	var path := json_blob_path(key, access)
	if cas != "":
		path = SnapKitTransport.with_query(path, {"cas": cas})
	var res: Dictionary = await _transport.request(HTTPClient.METHOD_DELETE, path)
	res["cas"] = SnapKitJson.get_str(res.json, "cas") if res.ok else ""
	return res


static func _missing(res: Dictionary, extra: Dictionary) -> Dictionary:
	res.ok = true
	res.error = ""
	res.merge(extra, true)
	return res


static func _invalid(extra: Dictionary) -> Dictionary:
	var res := SnapKitTransport.error_result(SnapKitTransport.ERR_INVALID_ARGUMENT)
	res.merge(extra, true)
	return res
