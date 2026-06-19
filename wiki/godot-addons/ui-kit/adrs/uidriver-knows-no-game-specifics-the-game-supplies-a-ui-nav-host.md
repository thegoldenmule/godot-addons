# ADR-11: UiDriver knows no game specifics; the game supplies a ui_nav_host

**Status:** accepted

## Metadata
- **Date:** 2026-06-18
- **Scope:** ui_kit

## Context
ui_kit ships as a reusable, game-agnostic addon vendored into many different games, and its UiDriver is meant to be the semantic automation surface an LLM/MCP eval hook drives — goto a screen by name, press a control, run an ordered sequence. But the meaningful targets of navigation are entirely game-specific: which shell tabs exist, which modes/overlays can be launched, what cfg a mode needs, what 'ready' means after a transition, what custom verbs like 'swipe' do. If the driver hardcoded any of that, it would stop being reusable. The addon had to decide how a generic mechanism reaches game-specific content without depending on the game.

## Decision
UiDriver (ui_driver.gd) contains no game-specific screens, modes, or flows. It provides only mechanism: the live-tree control catalog (via UiReg groups), control invocation (press/toggle/set_value/set_text), the awaited goto, the run()/flow() step runner, and async settle helpers. All game content is delegated to a host — a node the consuming game places in the 'ui_nav_host' group and which implements the UiNavHost contract.

The host is resolved by GROUP, not by a global identifier or autoload name: _host() returns get_tree().get_first_node_in_group('ui_nav_host') and _router() likewise finds the router by its 'ui_router' group. This means the driver works regardless of what the project named its autoloads, and even in a hand-built headless tree with no autoloads at all. When no host is mounted the driver returns a structured NOT_READY result rather than failing.

The contract is small and capability-probed. Only three host methods are required — mcp_select_tab(id), mcp_current_tab_id(), mcp_start_match(cfg). Everything else (mcp_nav_tabs, mcp_nav_modes, mcp_mode_cfg, mcp_target_active, mcp_exit_to_shell, mcp_route_label, mcp_wait_ready, mcp_match_ready, mcp_flows, mcp_expand_flow, mcp_step) is optional: each accessor checks host.has_method(...) and falls back to a sane generic default (empty tab/mode lists, {'mode': id} cfg, popping the router stack to exit, deriving a label by trimming 'State'). Unrecognized run() verbs are handed to the host's mcp_step, so a game adds custom gameplay steps like 'swipe' without any change to the driver.

```gdscript
func _host():
	var tree := get_tree()
	if tree == null:
		return null
	return tree.get_first_node_in_group(HOST_GROUP)

func _nav_tabs(host) -> Array:
	return host.mcp_nav_tabs() if host != null and host.has_method("mcp_nav_tabs") else []
```

## Consequences
The driver is genuinely reusable: the same ui_driver.gd ships unchanged into any game, and 'porting' the automation layer to a new game means implementing the UiNavHost contract on that game's shell — not editing the addon.

Group-based resolution decouples the driver from naming and even from autoloads: it finds host and router by membership, so consuming projects pick their own autoload names (or none), and the driver still runs in a headless test tree assembled by hand.

Optional-with-fallback methods make adoption incremental: a game implements just the three required methods to get basic tab/mode/match driving, and progressively adds mcp_wait_ready, mcp_flows, mcp_step, etc. to deepen automation. The cost is that the host surface is a duck-typed convention checked at call time — a typo'd method name silently degrades to the generic fallback rather than erroring.

Correctness depends on the host honoring the contract's semantics (e.g. mcp_target_active truthfully reporting 'already here', mcp_exit_to_shell actually popping overlays). The driver guards what it can — it validates goto targets before any side effect so an unknown target leaves the UI untouched — but it cannot verify the host's content is correct, only that the mechanism ran.

## Relations
_None._
