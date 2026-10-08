class_name SnapKitAnalytics
extends Node

## Batched analytics event queue -> Snapser Analytics snap
## (analytics.swagger3.json), D19.
##
##   PUT /v1/analytics/batch/user-events   BatchCreateUserEvents
##       {user_id, data:[{event, id:uint32 (1-based order in the batch), created_at:int64 (unix s),
##                        properties:{name: String}}]}
##       -> {events_ingested, events_failed, responses:[...]}
##
## track() only enqueues — it never blocks, never awaits and never fails. The
## queue flushes when it reaches batch_size, every flush_interval_s, and on
## NOTIFICATION_APPLICATION_PAUSED / NOTIFICATION_APPLICATION_FOCUS_OUT /
## NOTIFICATION_WM_CLOSE_REQUEST (best effort). While offline or failing, events
## stay buffered up to buffer_cap; beyond that the OLDEST are dropped silently.
## A failed flush re-queues its batch (subject to the cap) and pauses
## size-triggered flushes until the next interval tick, so a dead network is
## not hammered. Events the snap rejects individually (events_failed — e.g. an
## event table not created on the snapend) are counted, not retried.
##
## Event names must be snake_case (^[a-z][a-z0-9_]*$); props must be flat
## (String/int/float/bool/null values) and at most MAX_PROPS (the snap's limit).
## Invalid events are dropped with a one-time warning per name. The swagger
## types property values as strings and event columns accept only string,
## number and timestamp, so values are stringified on send: bools become "1" /
## "0" (number columns), integral floats lose the ".0", null becomes "".
##
## The body needs the user id, so a flush before the first login keeps the
## queue and returns error "no_session"; SnapKitService flushes after login.
## Each event carries a client timestamp and a monotonically increasing id
## (the snap's ingestion order).
##
## A Node (not RefCounted) because it owns a flush Timer and receives app
## lifecycle notifications; SnapKitService adds it as a child.

const BATCH_SIZE := 20
const FLUSH_INTERVAL_S := 30.0
const BUFFER_CAP := 500
const MAX_PROPS := 12
const EVENT_NAME_PATTERN := "^[a-z][a-z0-9_]*$"
const BATCH_PATH := "/v1/analytics/batch/user-events"

static var _name_re: RegEx

var batch_size: int = BATCH_SIZE
var flush_interval_s: float = FLUSH_INTERVAL_S
var buffer_cap: int = BUFFER_CAP
## Events dropped because the buffer was full (diagnostics).
var dropped_count: int = 0

var _transport: SnapKitTransport
var _queue: Array = []
var _next_id: int = 0
var _flushing: bool = false
var _size_flush_suppressed: bool = false
var _warned: Dictionary = {}
var _timer: Timer


## Wire the transport. opts may override "batch_size", "flush_interval_s",
## "buffer_cap" (tests use small values). flush_interval_s <= 0 disables the
## interval timer.
func setup(transport: SnapKitTransport, opts: Dictionary = {}) -> void:
	_transport = transport
	batch_size = maxi(1, int(opts.get("batch_size", BATCH_SIZE)))
	flush_interval_s = float(opts.get("flush_interval_s", FLUSH_INTERVAL_S))
	buffer_cap = maxi(1, int(opts.get("buffer_cap", BUFFER_CAP)))
	_next_id = int(Time.get_unix_time_from_system() * 1000.0)
	if _timer == null:
		_timer = Timer.new()
		_timer.name = "FlushTimer"
		_timer.one_shot = false
		_timer.timeout.connect(_on_interval)
		add_child(_timer)
	_timer.stop()
	if flush_interval_s > 0.0:
		_timer.wait_time = flush_interval_s
		if _timer.is_inside_tree():
			_timer.start()
		else:
			_timer.autostart = true


## Enqueue an event. Never blocks.
func track(event: String, props: Dictionary = {}) -> void:
	if not is_valid_event_name(event):
		_warn_once(event, "invalid event name (must be snake_case)")
		return
	if not is_flat_props(props) or props.size() > MAX_PROPS:
		_warn_once(event, "props must be flat scalars, at most %d" % MAX_PROPS)
		return
	_next_id += 1
	_queue.append({
		"event": event,
		"id": _next_id,
		"created_at": int(Time.get_unix_time_from_system()),
		"properties": props.duplicate(),
	})
	_enforce_cap()
	if _queue.size() >= batch_size and not _flushing and not _size_flush_suppressed \
			and _transport != null and not _transport.is_offline():
		flush()


## Send everything queued (in batch_size chunks). COROUTINE.
## -> {ok, status, json, error, sent:int, failed:int, pending:int}
## sent = accepted by the snap; failed = rejected individually (not retried).
## A flush already in flight makes this call return ok with sent 0.
func flush() -> Dictionary:
	var res := SnapKitTransport.ok_result()
	var sent := 0
	var failed := 0
	if _flushing:
		return _flush_result(res, 0, 0)
	if _queue.is_empty():
		return _flush_result(res, 0, 0)
	if _transport == null or _transport.is_offline():
		return _flush_result(SnapKitTransport.error_result(SnapKitTransport.ERR_OFFLINE), 0, 0)
	var uid := _transport.user_id()
	if uid == "":
		return _flush_result(SnapKitTransport.error_result(SnapKitTransport.ERR_NO_SESSION), 0, 0)
	_flushing = true
	while not _queue.is_empty():
		var chunk: Array = _queue.slice(0, batch_size)
		_queue = _queue.slice(chunk.size())
		var r: Dictionary = await _transport.request(HTTPClient.METHOD_PUT, BATCH_PATH, batch_body(chunk, uid))
		if not r.ok:
			# Put the batch back in front of anything tracked meanwhile.
			_queue = chunk + _queue
			_enforce_cap()
			_size_flush_suppressed = true
			res = r
			break
		var nf := SnapKitJson.get_int(r.json, "events_failed", 0)
		var ni := SnapKitJson.get_int(r.json, "events_ingested", chunk.size() - nf)
		failed += nf
		sent += ni
		res = r
	_flushing = false
	return _flush_result(res, sent, failed)


func pending_count() -> int:
	return _queue.size()


static func is_valid_event_name(event: String) -> bool:
	if _name_re == null:
		_name_re = RegEx.create_from_string(EVENT_NAME_PATTERN)
	return _name_re.search(event) != null


## True when every prop value is a flat scalar (String, StringName, int, float,
## bool or null) and every key is a non-empty String.
static func is_flat_props(props: Dictionary) -> bool:
	for k in props:
		if not (k is String or k is StringName) or str(k) == "":
			return false
		var t := typeof(props[k])
		if not (t in [TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_STRING_NAME]):
			return false
	return true


## A prop value as the string the snap expects.
static func prop_to_string(v: Variant) -> String:
	match typeof(v):
		TYPE_NIL:
			return ""
		TYPE_BOOL:
			return "1" if v else "0"
		TYPE_FLOAT:
			if is_equal_approx(v, floorf(v)) and absf(v) < 9.0e15:
				return str(int(v))
			return str(v)
	return str(v)


## Request body for a batch of queued events. user_id is the session user (the
## snap requires it in the body, not only in the path/headers).
static func batch_body(events: Array, user_id: String = "") -> Dictionary:
	var data: Array = []
	for e in events:
		var props := {}
		var raw: Dictionary = e.get("properties", {})
		for k in raw:
			props[str(k)] = prop_to_string(raw[k])
		data.append({
			"event": str(e.get("event", "")),
			# Ingestion order within this batch. The live snap parses `id` as
			# uint32 (the swagger says int64), so never send the queue's
			# millisecond-seeded id.
			"id": data.size() + 1,
			"created_at": int(e.get("created_at", 0)),
			"properties": props,
		})
	return {"user_id": user_id, "data": data}


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT \
			or what == NOTIFICATION_WM_CLOSE_REQUEST:
		if not _queue.is_empty() and _transport != null and not _transport.is_offline():
			flush()


func _on_interval() -> void:
	_size_flush_suppressed = false
	if not _queue.is_empty():
		flush()


func _enforce_cap() -> void:
	var over := _queue.size() - buffer_cap
	if over > 0:
		_queue = _queue.slice(over)
		dropped_count += over


func _flush_result(res: Dictionary, sent: int, failed: int) -> Dictionary:
	res["sent"] = sent
	res["failed"] = failed
	res["pending"] = _queue.size()
	return res


func _warn_once(event: String, why: String) -> void:
	if _warned.has(event):
		return
	_warned[event] = true
	push_warning("SnapKitAnalytics: dropped event '%s': %s" % [event, why])
