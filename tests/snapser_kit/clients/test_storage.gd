extends "res://tests/snapser_kit/snapkit_test_case.gd"

## SnapKitStorage: paths, json-blob get/put, CAS put (insert vs replace),
## conflict detection, delete.

const FakeTransport := preload("res://tests/snapser_kit/clients/fake_transport.gd")
const FakeStorageServer := preload("res://tests/snapser_kit/clients/fake_storage_server.gd")

var t: FakeTransport
var server: FakeStorageServer
var st: SnapKitStorage


func before_each() -> void:
	t = add_node(FakeTransport.new())
	server = FakeStorageServer.new()
	server.install(t)
	st = SnapKitStorage.new(t)


func test_paths_and_bodies() -> void:
	check_eq(SnapKitStorage.json_blob_path("save_v1"), "/v1/storage/owner/{user_id}/private/json-blobs/save_v1", "blob")
	check_eq(SnapKitStorage.json_blob_path("a b", "protected"),
		"/v1/storage/owner/{user_id}/protected/json-blobs/a%20b", "access + encoding")
	check_eq(SnapKitStorage.cas_path("k"), "/v1/storage/owner/{user_id}/private/cas/k", "cas")
	check_eq(SnapKitStorage.put_body({"a": 1}), {"value": {"a": 1}}, "plain")
	check_eq(SnapKitStorage.put_body({"a": 1}, "7", true), {"value": {"a": 1}, "cas": "7", "create": true}, "cas+create")
	check_eq(SnapKitStorage.parse_blob({"value": {"x": 1}, "cas": "9"}), {"value": {"x": 1}, "cas": "9"}, "parse")
	check_eq(SnapKitStorage.parse_blob(null), {"value": null, "cas": ""}, "parse null")


func test_get_missing_then_put() -> void:
	var r: Dictionary = await st.get_json_blob("k")
	check(r.ok, "missing ok")
	check_eq(r.exists, false, "exists false")
	check_eq(r.cas, "", "no cas")
	r = await st.put_json_blob("k", {"n": 1})
	check(r.ok, "put ok")
	check(r.cas != "", "cas returned")
	check_eq(t.calls[-1].body, {"value": {"n": 1.0}, "create": true}, "create flag")
	r = await st.get_json_blob("k")
	check(r.ok and r.exists, "exists")
	check_eq(r.value, {"n": 1.0}, "value")
	var c: Dictionary = await st.get_cas("k")
	check_eq(c.cas, r.cas, "get_cas matches")


func test_cas_insert_and_replace() -> void:
	var r: Dictionary = await st.put_json_blob_cas("k", {"v": 1}, "")
	check(r.ok, "insert ok")
	check_eq(t.calls[-1].method, HTTPClient.METHOD_POST, "empty cas -> POST insert")
	var cas1: String = r.cas
	r = await st.put_json_blob_cas("k", {"v": 2}, cas1)
	check(r.ok and not r.conflict, "replace ok")
	check_eq(t.calls[-1].method, HTTPClient.METHOD_PUT, "cas -> PUT")
	check_eq(t.calls[-1].body, {"value": {"v": 2.0}, "cas": cas1}, "cas sent")
	check(r.cas != cas1, "new cas")


func test_cas_conflicts_detected() -> void:
	server.put_raw("user-1", "k", {"v": 0})
	var r: Dictionary = await st.put_json_blob_cas("k", {"v": 1}, "")
	check(not r.ok, "insert over existing fails")
	check(r.conflict, "insert conflict")
	check(r.remote_cas != "", "remote cas reported")
	r = await st.put_json_blob_cas("k", {"v": 1}, "stale")
	check(not r.ok and r.conflict, "stale cas -> conflict")
	check_eq(r.error, "http_400", "http error kept")
	check(r.remote_cas != "", "remote cas read back")
	check_eq(t.calls_to("/v1/storage/owner/user-1/private/cas/").size(), 0,
		"never uses the plain-blob /cas/ route (live: 400 5001 on JSON blobs)")


func test_live_cas_mismatch_body_is_a_conflict() -> void:
	# Exactly what the live gateway answered to a stale CAS on 2026-10-08, with the
	# re-read also failing: still a conflict.
	t.respond(HTTPClient.METHOD_PUT, "/v1/storage/owner/{o}/{a}/json-blobs/{k}", 400,
		{"api_error_code": 5007, "details": null, "message": "CAS mismatch"})
	t.respond(HTTPClient.METHOD_GET, "/v1/storage/owner/{o}/{a}/json-blobs/{k}", 500)
	var r: Dictionary = await st.put_json_blob_cas("k", {"v": 1}, "old")
	check(not r.ok, "not ok")
	check(r.conflict, "5007 -> conflict")
	check_eq(SnapKitStorage.snap_error_code(r.json), 5007, "api_error_code parsed")


func test_get_cas_reads_json_blob() -> void:
	server.put_raw("user-1", "k", {"v": 0})
	var c: Dictionary = await st.get_cas("k")
	check(c.ok and c.cas != "", "cas from GET json-blobs")
	check_eq(t.calls_to("/v1/storage/owner/user-1/private/cas/").size(), 0, "no /cas/ route")


func test_non_conflict_errors() -> void:
	t.respond(HTTPClient.METHOD_PUT, "/v1/storage/owner/{o}/{a}/json-blobs/{k}", 403)
	var r: Dictionary = await st.put_json_blob_cas("k", {"v": 1}, "5")
	check(not r.ok, "403")
	check_eq(r.conflict, false, "403 is not a conflict")
	check_eq(t.calls_to("/v1/storage/owner/user-1/private/cas/").size(), 0, "no probe on 403")
	t.respond(HTTPClient.METHOD_PUT, "/v1/storage/owner/{o}/{a}/json-blobs/{k}", 400)
	t.respond(HTTPClient.METHOD_GET, "/v1/storage/owner/{o}/{a}/json-blobs/{k}", 200, {"value": {}, "cas": "5"})
	r = await st.put_json_blob_cas("k", {"v": 1}, "5")
	check_eq(r.conflict, false, "400 with unchanged server cas is not a conflict")


func test_invalid_and_offline() -> void:
	var r: Dictionary = await st.put_json_blob_cas("k", [1, 2], "")
	check_eq(r.error, SnapKitTransport.ERR_INVALID_ARGUMENT, "array value rejected (swagger: object)")
	r = await st.get_json_blob("")
	check_eq(r.error, SnapKitTransport.ERR_INVALID_ARGUMENT, "empty key")
	check_eq(t.calls.size(), 0, "no requests")
	t.offline = true
	r = await st.get_json_blob("k")
	check_eq(r.error, "offline", "offline")
	check_eq(r.exists, false, "offline exists false")
	r = await st.put_json_blob_cas("k", {}, "1")
	check_eq(r.error, "offline", "offline put")
	check_eq(r.conflict, false, "offline is not a conflict")


func test_delete() -> void:
	t.respond(HTTPClient.METHOD_DELETE, "/v1/storage/owner/{o}/{a}/json-blobs/{k}", 200, {"cas": "3"})
	var r: Dictionary = await st.delete_json_blob("k", SnapKitStorage.ACCESS_PRIVATE, "2")
	check(r.ok, "ok")
	check_eq(t.calls[0].query, {"cas": "2"}, "cas query")
	r = await st.delete_json_blob("k")
	check_eq(t.calls[1].query, {}, "unconditional")
