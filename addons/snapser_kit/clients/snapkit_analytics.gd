class_name SnapKitAnalytics
extends Node

## Batched analytics event queue -> Snapser Analytics snap
## (analytics.swagger3.json), D19.
##
##   PUT /v1/analytics/batch/user-events   BatchCreateUserEvents
##
## track() only enqueues — it never blocks, never awaits and never fails. The
## queue flushes when it reaches BATCH_SIZE, every FLUSH_INTERVAL_S, and on
## NOTIFICATION_APPLICATION_PAUSED / NOTIFICATION_APPLICATION_FOCUS_OUT /
## NOTIFICATION_WM_CLOSE_REQUEST (best effort). While offline or failing, events
## stay buffered up to BUFFER_CAP; beyond that the OLDEST are dropped silently.
## A failed flush re-queues its batch (subject to the cap).
##
## Event names must be snake_case (^[a-z][a-z0-9_]*$); props must be flat
## (String/int/float/bool values). Invalid events are dropped with a one-time
## warning per name. Each queued event records a client timestamp.
##
## A Node (not RefCounted) because it owns a flush Timer and receives app
## lifecycle notifications; SnapKitService adds it as a child.
##
## SKELETON (owner: kit-clients agent): signatures final for v0.1; bodies stubbed.

const BATCH_SIZE := 20
const FLUSH_INTERVAL_S := 30.0
const BUFFER_CAP := 500
const EVENT_NAME_PATTERN := "^[a-z][a-z0-9_]*$"

var _transport: SnapKitTransport


## Wire the transport. opts may override "batch_size", "flush_interval_s",
## "buffer_cap" (tests use small values).
func setup(transport: SnapKitTransport, opts: Dictionary = {}) -> void:
	_transport = transport


## Enqueue an event. Never blocks.
func track(event: String, props: Dictionary = {}) -> void:
	pass


## Send everything queued (in BATCH_SIZE chunks). COROUTINE.
## -> {ok, status, json, error, sent:int, pending:int}
func flush() -> Dictionary:
	return SnapKitTransport.not_implemented()


func pending_count() -> int:
	return 0


static func is_valid_event_name(event: String) -> bool:
	return false


## True when every prop value is a flat scalar.
static func is_flat_props(props: Dictionary) -> bool:
	return false


## Request body for a batch of queued events.
static func batch_body(events: Array) -> Dictionary:
	return {}
