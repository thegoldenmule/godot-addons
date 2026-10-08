class_name SnapKitStorage
extends RefCounted

## Client for the Snapser Storage snap's JSON blobs (storage.swagger3.json),
## owned by the session user.
##
##   GET    /v1/storage/owner/{owner_id}/{access_type}/json-blobs/{key}  GetJsonBlob
##   PUT    /v1/storage/owner/{owner_id}/{access_type}/json-blobs/{key}  ReplaceJsonBlob
##   POST   /v1/storage/owner/{owner_id}/{access_type}/json-blobs/{key}  InsertJsonBlob
##   DELETE /v1/storage/owner/{owner_id}/{access_type}/json-blobs/{key}  DeleteJsonBlob
##   GET    /v1/storage/owner/{owner_id}/{access_type}/cas/{key}         GetCas
##
## owner_id is always the session user ("{user_id}" placeholder). The CAS token
## gives optimistic concurrency: put_json_blob_cas() fails with
## {conflict:true} instead of overwriting a newer blob.
##
## Conventions: see SnapKitStats.
##
## SKELETON (owner: kit-clients agent): signatures final for v0.1; bodies stubbed.

const ACCESS_PRIVATE := "private"
const ACCESS_PROTECTED := "protected"
const ACCESS_PUBLIC := "public"

var _transport: SnapKitTransport


func _init(transport: SnapKitTransport) -> void:
	_transport = transport


## "/v1/storage/owner/{user_id}/<access>/json-blobs/<key>".
static func json_blob_path(key: String, access: String = ACCESS_PRIVATE) -> String:
	return ""


## "/v1/storage/owner/{user_id}/<access>/cas/<key>".
static func cas_path(key: String, access: String = ACCESS_PRIVATE) -> String:
	return ""


## Read a blob. -> {ok, status, json, error, value:Variant, cas:String,
## exists:bool}. A missing blob is ok:true, exists:false.
func get_json_blob(key: String, access: String = ACCESS_PRIVATE) -> Dictionary:
	return SnapKitTransport.not_implemented()


## Create-or-replace without concurrency check. -> {..., cas:String}
func put_json_blob(key: String, value: Variant, access: String = ACCESS_PRIVATE) -> Dictionary:
	return SnapKitTransport.not_implemented()


## Current CAS token for a blob. -> {..., cas:String}
func get_cas(key: String, access: String = ACCESS_PRIVATE) -> Dictionary:
	return SnapKitTransport.not_implemented()


## Replace only if the server CAS still equals `cas` ("" = blob must not exist).
## -> {..., cas:String (new), conflict:bool}
func put_json_blob_cas(key: String, value: Variant, cas: String,
		access: String = ACCESS_PRIVATE) -> Dictionary:
	return SnapKitTransport.not_implemented()


func delete_json_blob(key: String, access: String = ACCESS_PRIVATE) -> Dictionary:
	return SnapKitTransport.not_implemented()
