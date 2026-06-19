# ADR-9: UiRouter is an async stack-FSM; navigation transitions are awaitable

**Status:** accepted

## Metadata
- **Date:** 2026-06-18
- **Scope:** ui_kit

## Context
A UI shell needs a navigation model: how do you get from Home to a match to a modal over that match, and back again? The naive approach is imperative scene-swapping — code that loads the next scene, frees the old one, and tracks 'where am I' in ad-hoc flags scattered across the shell. That makes Back-button handling, nested overlays, and 'wait until the destination is actually live' each their own bespoke problem. ui_kit is also meant to be driven by automation (an LLM/MCP eval hook through UiDriver), which needs a deterministic, observable answer to 'where am I' and a way to know a transition has finished. The router had to decide how navigation history is represented and how transitions are sequenced and observed.

## Decision
UiRouter (ui_router.gd) is a stack-based finite state machine: the stack IS the navigation history. Each entry is a UiState; push adds a level, pop removes one, and Back is simply pop. A typical stack reads [ShellState], then [ShellState, MatchState] in a match, then [ShellState, MatchState, Modal] for a dialog over that match. The router exposes top(), stack_depth(), and route_names() (bottom-up state names) so callers and the driver can read the current position without consulting any per-screen flag.

Every transition is async and awaitable. push, pop, replace, and reset are coroutines that await each affected state's lifecycle hook: push awaits the state below to suspend() then awaits the new state to enter(); pop awaits the leaving state to exit() then the revealed state to resume(); reset awaits exit() on every state it unwinds before entering the new root. Because a hook can itself await (load a scene, run a cover/reveal fade), an awaited call returns only once the destination screen is genuinely live. This is what lets UiDriver.goto(...) be awaited and return a settled state.

Transitions are serialized behind a single _busy flag. Any push/pop/replace/reset called while a transition is in flight is dropped (returns immediately) rather than interleaving — there is never more than one transition mutating the stack at a time. The Android/system Back request (NOTIFICATION_WM_GO_BACK_REQUEST) is routed through the same machine: it is ignored while busy, pops when stack_depth() > 1, and quits only at the root. The router takes set_quit_on_go_back(false) so the OS Back button cannot bypass the stack.

```gdscript
func push(state, params: Dictionary = {}) -> void:
	if _busy:
		return
	_busy = true
	var below = top()
	if below != null:
		await below.suspend()
	_stack.push_back(state)
	await state.enter(params)
	changed.emit(state)
	_busy = false
```

## Consequences
Back, nested overlays, and modals stop being special cases: history is the stack, so Back is pop and 'a dialog over a match' is just depth 3. No per-screen 'where did I come from' bookkeeping is needed.

Navigation becomes deterministically observable for automation. Because transitions await their lifecycle hooks and fades, await goto(...) returns only when the screen is live, and the driver's _settle() helper can yield frames while is_busy() is true — giving the LLM/MCP layer a reliable 'the transition is done' signal instead of guessing with timers.

Serialization via _busy trades richer transition semantics for safety: calls made mid-transition are silently dropped, not queued. Callers (and the driver) must settle/await before issuing the next navigation, or the call is a no-op. This is a deliberate simplicity-over-flexibility choice.

Every route must be modeled as a UiState with awaited enter/exit/suspend/resume hooks. Screens that only know how to instantiate themselves synchronously have to be wrapped in a state object, which is more ceremony than a bare scene swap but is what makes the whole model uniform.

## Relations
_None._
