class_name UiState
extends RefCounted
## One route/screen in the UiRouter stack. Lifecycle hooks are await-able: the
## router awaits enter()/exit()/suspend()/resume(), so a hook may run an async
## transition and the router will not proceed until it finishes.
##
## Subclasses either `extends UiState` (via this class_name) or
##   extends "res://addons/ui_kit/ui_state.gd"
## and reference the router autoload by name.
##
## Every base hook yields exactly one process frame, so a state that does no
## animation is still a valid coroutine (no REDUNDANT_AWAIT) and any nodes it added
## are in-tree before it animates.

## True if this state fully covers the one below (a takeover/modal): the router
## suspends the state beneath it. False for transparent overlays.
var blocks_below: bool = true


## Becomes top of the stack (push/replace/reset). Override to build + animate in.
func enter(_params: Dictionary) -> void:
	await Engine.get_main_loop().process_frame


## Leaves the stack (pop/replace). Override to animate out + free owned nodes.
func exit() -> void:
	await Engine.get_main_loop().process_frame


## Another state was pushed on top of this one (it stays in the stack).
func suspend() -> void:
	await Engine.get_main_loop().process_frame


## This state becomes top again after the one above it popped.
func resume() -> void:
	await Engine.get_main_loop().process_frame


## Short name for logs/debug.
func state_name() -> String:
	return "UiState"
