@tool
extends EditorPlugin

## ui_kit ships the generic UI shell infrastructure — UiRouter (an async stack-FSM
## router), UiState, UiScreenScaffold, UiReg (control registration), and UiDriver
## (a semantic UI/navigation automation layer). Those are RUNTIME singletons /
## classes: the consuming project declares UiRouter + UiDriver as autoloads
## (pointing at ui_router.gd / ui_driver.gd) and uses the rest by path/class_name.
##
## This is a near-empty EditorPlugin — it registers no autoloads (the project
## chooses their names; see addons/ui_kit/README.md for the wiring recipe) and no
## longer carries its own self-update dock. Updates are handled by the
## editor_tool_kit "package manager": ui_kit opts in with the `[update]` marker in
## its plugin.cfg, so the sibling addon's one panel checks + updates it in place.
## The plugin is kept (rather than removed) so ui_kit stays a togglable entry in
## the editor's Plugins panel and can grow editor-side behaviour later.
