extends "res://tests/snapser_kit/snapkit_test_case.gd"

## SnapKitAnalytics: validation, body shape, size / interval flush, buffer cap,
## failure re-queue, offline / no-session behaviour.

const FakeTransport := preload("res://tests/snapser_kit/clients/fake_transport.gd")
const BATCH := "/v1/analytics/batch/user-events"

var t: FakeTransport
var an: SnapKitAnalytics
var received: Array = []


func before_each() -> void:
	received = []
	t = add_node(FakeTransport.new())
	t.route(HTTPClient.METHOD_PUT, BATCH, func(req: Dictionary) -> Dictionary:
		received.append(req.body)
		return {"status": 200, "json": {"events_ingested": req.body.data.size(), "events_failed": 0}})
	an = add_node(SnapKitAnalytics.new())
	an.setup(t, {"batch_size": 3, "flush_interval_s": 0.0, "buffer_cap": 5})


func _settle() -> void:
	for i in 4:
		await tree.process_frame


func test_validation() -> void:
	for ok_name in ["session_start", "run_end", "a", "x9_y"]:
		check(SnapKitAnalytics.is_valid_event_name(ok_name), "valid: " + ok_name)
	for bad in ["", "Run", "9lives", "run-end", "run end", "_x", "run.end"]:
		check(not SnapKitAnalytics.is_valid_event_name(bad), "invalid: '%s'" % bad)
	check(SnapKitAnalytics.is_flat_props({"a": 1, "b": "x", "c": 2.5, "d": true, "e": null}), "flat")
	check(not SnapKitAnalytics.is_flat_props({"a": [1]}), "array not flat")
	check(not SnapKitAnalytics.is_flat_props({"a": {"b": 1}}), "dict not flat")
	check(not SnapKitAnalytics.is_flat_props({1: "x"}), "non-string key")


func test_batch_body_shape() -> void:
	var body := SnapKitAnalytics.batch_body([
		{"event": "run_end", "id": 7, "created_at": 1760000000,
			"properties": {"score": 120, "ratio": 0.5, "whole": 3.0, "won": true, "mode": "story", "n": null}},
	], "user-9")
	check_eq(body.user_id, "user-9", "user_id in body")
	check_eq(body.data[0].event, "run_end", "event")
	check_eq(body.data[0].id, 1, "id = 1-based order in the batch (not the queue id)")
	check_eq(body.data[0].created_at, 1760000000, "created_at")
	check_eq(body.data[0].properties,
		{"score": "120", "ratio": "0.5", "whole": "3", "won": "1", "mode": "story", "n": ""},
		"props stringified")


func test_invalid_events_dropped() -> void:
	an.track("Bad Name")
	an.track("ok_event", {"nested": {"a": 1}})
	var many := {}
	for i in 13:
		many["p%d" % i] = i
	an.track("too_many", many)
	check_eq(an.pending_count(), 0, "all dropped")


func test_size_triggered_flush() -> void:
	an.track("a")
	an.track("b", {"x": 1})
	check_eq(t.calls.size(), 0, "below batch size: nothing sent")
	an.track("c")
	await _settle()
	check_eq(received.size(), 1, "one batch sent")
	check_eq(received[0].user_id, "user-1", "session user")
	var names: Array = []
	for e in received[0].data:
		names.append(e.event)
	check_eq(names, ["a", "b", "c"], "in order")
	check(int(received[0].data[0].id) < int(received[0].data[1].id), "ids increase")
	check_eq(an.pending_count(), 0, "queue drained")


func test_manual_flush_chunks() -> void:
	t.offline = true
	for i in 5:
		an.track("e%d" % i)
	t.offline = false
	var r: Dictionary = await an.flush()
	check(r.ok, "ok")
	check_eq(r.sent, 5, "sent all")
	check_eq(received.size(), 2, "chunks of 3 + 2")
	check_eq(received[1].data.size(), 2, "second chunk")
	r = await an.flush()
	check(r.ok and r.sent == 0, "empty flush is a no-op")
	check_eq(received.size(), 2, "no extra request")


func test_offline_buffer_cap_drops_oldest() -> void:
	t.offline = true
	for i in 7:
		an.track("e", {"n": i})
	check_eq(an.pending_count(), 5, "capped")
	check_eq(an.dropped_count, 2, "two dropped")
	var r: Dictionary = await an.flush()
	check_eq(r.error, "offline", "offline flush")
	check_eq(r.pending, 5, "kept")
	check_eq(t.calls.size(), 0, "no requests offline")
	t.offline = false
	await an.flush()
	check_eq(received[0].data[0].properties.n, "2", "oldest two were dropped")


func test_failure_requeues_in_order() -> void:
	t.respond(HTTPClient.METHOD_PUT, BATCH, 503)
	an.track("a")
	an.track("b")
	an.track("c")
	await _settle()
	check_eq(t.calls.size(), 1, "attempted once")
	check_eq(an.pending_count(), 3, "re-queued")
	an.track("d")
	an.track("e")
	an.track("f")
	await _settle()
	check_eq(t.calls.size(), 1, "size flush suppressed after a failure")
	t.route(HTTPClient.METHOD_PUT, BATCH, func(req: Dictionary) -> Dictionary:
		received.append(req.body)
		return {"status": 200, "json": {"events_ingested": req.body.data.size()}})
	var r: Dictionary = await an.flush()
	check(r.ok, "recovered")
	var names: Array = []
	for b in received:
		for e in b.data:
			names.append(e.event)
	check_eq(names, ["b", "c", "d", "e", "f"], "order kept; cap 5 dropped the oldest (a)")


func test_rejected_events_not_retried() -> void:
	t.respond(HTTPClient.METHOD_PUT, BATCH, 200, {"events_ingested": 1, "events_failed": 1})
	an.track("a")
	an.track("b")
	var r: Dictionary = await an.flush()
	check(r.ok, "ok")
	check_eq(r.sent, 1, "ingested")
	check_eq(r.failed, 1, "failed counted")
	check_eq(r.pending, 0, "not re-queued")


func test_no_session_keeps_queue() -> void:
	t.uid = ""
	an.track("a")
	var r: Dictionary = await an.flush()
	check_eq(r.error, SnapKitTransport.ERR_NO_SESSION, "no_session")
	check_eq(an.pending_count(), 1, "kept")
	check_eq(t.calls.size(), 0, "no request")


func test_interval_flush_and_inflight_guard() -> void:
	var an2: SnapKitAnalytics = add_node(SnapKitAnalytics.new())
	an2.setup(t, {"batch_size": 50, "flush_interval_s": 0.05})
	an2.track("tick")
	await wait(0.2)
	check_eq(received.size(), 1, "interval flushed")
	t.frames = 5
	an2.track("x")
	an2.flush()
	var second: Dictionary = await an2.flush()
	check_eq(second.sent, 0, "concurrent flush is a no-op")
	await _settle()
	await _settle()
	check_eq(an2.pending_count(), 0, "first flush finished")


func test_batch_ids_fit_uint32() -> void:
	# Live: the snap parses `id` as uint32; a millisecond-seeded id was rejected
	# with 400 "invalid value for uint32 type".
	var events := []
	for i in 5:
		events.append({"event": "screen_view", "id": 1791493544434 + i, "created_at": 1, "properties": {}})
	var body := SnapKitAnalytics.batch_body(events, "u")
	var ids := []
	for e in body.data:
		ids.append(e.id)
		check(e.id > 0 and e.id < 4294967296, "id %d fits uint32" % e.id)
	check_eq(ids, [1, 2, 3, 4, 5], "ingestion order preserved")
