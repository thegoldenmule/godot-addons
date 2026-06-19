# ADR-12: The addon registers no autoloads; the consuming project declares them

**Status:** accepted

## Metadata
- **Date:** 2026-06-18
- **Scope:** ui_kit

## Context
UiRouter and UiDriver are runtime singletons — the consuming game reaches them as global autoloads (UiRouter.reset(...), await UiDriver.goto(...)). A Godot EditorPlugin can register autoloads itself via add_autoload_singleton during _enter_tree, and many addons do exactly that so 'enable the plugin' is the only wiring step. ui_kit had to decide whether its plugin.gd should auto-register UiRouter/UiDriver as autoloads or leave that to the host project. The tension: convenience of zero-config enablement versus the addon imposing global names and lifecycle on every project that vendors it.

## Decision
ui_kit's plugin.gd registers NO autoloads. The EditorPlugin does exactly one editor-side job: it mounts the 'UI Kit' bottom-panel dock that checks the source repo for a newer version and self-updates in place (register a setting, build the update service, add the panel; tear them down in _exit_tree). It never calls add_autoload_singleton for UiRouter, UiDriver, or anything else. Declaring those autoloads is left to the consuming project.

The consuming project declares the autoloads itself, choosing its own names. The README's wiring recipe is to add UiRouter='*res://addons/ui_kit/ui_router.gd' and UiDriver='*res://addons/ui_kit/ui_driver.gd' to the project, then boot the router with UiRouter.reset(MyShellState.new()). The names are conventional, not required — which is precisely why the runtime resolves the router and host by group ('ui_router', 'ui_nav_host') rather than by autoload name. The other pieces (UiState, UiScreenScaffold, UiReg) are used by path/class_name and were never autoloads to begin with.

## Consequences
The project keeps control of its global namespace and autoload order. ui_kit never injects a singleton name a game might already use or want to name differently, and the game decides where UiRouter/UiDriver sit relative to its other autoloads — which can matter for boot ordering.

This is consistent with the group-based resolution decisions elsewhere in the addon: because UiDriver finds the router and host by group, the autoload names are free, and the addon does not need to own them. Auto-registering fixed names would have undercut that flexibility for no real gain.

The cost is a manual wiring step: enabling the plugin alone does not make the UI work — a project must also declare the two autoloads and implement the UiNavHost contract, per the README. A newcomer who only ticks the plugin checkbox gets the self-update dock but no running router until they follow the recipe.

Responsibilities stay cleanly split: the EditorPlugin is purely editor-side (the dock + self-update lifecycle, with care taken to tear the panel down before a hot-reload), while everything runtime is opt-in by the project. The addon folder stays copy-one-folder self-contained without reaching into project settings on enable.

## Relations
_None._
