# UiState

**Status:** current

## Kind
component

## Summary
**UiState** (`ui_state.gd`) — `class_name UiState extends RefCounted`: the base for one route/screen in the `UiRouter` stack. Its four lifecycle hooks (`enter`/`exit`/`suspend`/`resume`) are **await-able** — the router awaits each, so a hook may run an async transition (build + animate in, animate out + free) and the router will not proceed until it finishes. A `blocks_below` flag tells the router whether this route fully covers the one below.

## Purpose
It is the unit the router pushes and pops. By making the hooks coroutines and having every base hook yield exactly one process frame, a state that does *no* animation is still a valid coroutine (avoiding Godot's REDUNDANT_AWAIT) and any nodes it added are in-tree before it animates. Subclasses override the hooks to build their screen, animate it in/out, and free the nodes they own.

## Design notes
Why each base hook yields one process frame: it keeps a no-animation state a valid coroutine (no REDUNDANT_AWAIT warning when the router awaits it) and guarantees any nodes the state added are in-tree before it animates.

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- class `UiState` in `addons/ui_kit/ui_state.gd`
- function `enter` in `addons/ui_kit/ui_state.gd`

## Data model
A `RefCounted`, so states are reference-managed (not nodes) and own their screen nodes by parenting them under the router's `content_root`. Fields/methods:

- **`blocks_below: bool = true`** — true if this state fully covers the one below (a takeover/modal), so the router suspends the state beneath; false for transparent overlays.
- **`enter(_params: Dictionary)`** — became top (push/replace/reset). Override to build + animate in.
- **`exit()`** — left the stack (pop/replace). Override to animate out + free owned nodes.
- **`suspend()`** — another state was pushed on top (this one stays in the stack).
- **`resume()`** — became top again after the state above it popped.
- **`state_name() -> String`** — short name for logs/debug and the router's `route_names()`; base returns `"UiState"`.

Each base hook bodies `await Engine.get_main_loop().process_frame`.

## Usage
Subclass either `extends UiState` (via the `class_name`) or `extends "res://addons/ui_kit/ui_state.gd"` and reference the router autoload by name. Override `enter`/`exit` (and `suspend`/`resume` for states that stay in the stack) to manage the screen, and override `state_name()` for a meaningful label. For the common "load a scene, fade, pop on a signal" case, subclass `RouterSceneState` instead, which provides those hooks.

## Invariants & constraints
- All four lifecycle hooks are coroutines; even the no-op base implementations await one process frame, so the router can uniformly await any state.
- blocks_below controls suspension of the state beneath: true => the router suspends it (full takeover/modal); false => it stays live (transparent overlay).
- UiState is RefCounted, not a Node — it owns its screen nodes by parenting them under the router's content_root rather than being in the tree itself.

## Synced commit
_None._
