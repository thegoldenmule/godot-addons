# godot-addons

Reusable, game-agnostic Godot 4.x addons by The Golden Mule. Each addon lives
under `addons/<name>/`, is committed into consuming projects (so a fresh clone
works offline), and self-updates in place from this repo (bump `plugin.cfg`
`version`, push to `main`).

This repo is itself a minimal Godot project so the addons can be opened, edited,
and tested in isolation.

## Addons

| Addon | What it is |
|---|---|
| [`ui_kit`](addons/ui_kit/README.md) | Generic UI shell infrastructure: an async stack-FSM router (`UiRouter`), `UiState`, `UiScreenScaffold`, control registration (`UiReg`), and a semantic UI/navigation automation driver (`UiDriver`). |
| [`editor_tool_kit`](addons/editor_tool_kit/README.md) | Editor-only base classes for in-editor authoring tools (`EditorToolPlugin`, `ToolService`, `ContentStore`, `EditorToolUi`, `BridgeServer`): a new tool is a *service + a view*, with the occult-arcade styling, persistence, and optional MCP/CLI access inherited from the bases. |
| [`remote_config_editor`](addons/remote_config_editor/README.md) | Editor-only authoring tool that aggregates committed content blobs (per a project-supplied manifest) into one backend "remote config" document, copies the full publish payload, and optionally checks live drift. Game-agnostic; configured per project via `res://remote_config_editor.config.json`. |
| [`build_kit`](addons/build_kit/README.md) | One-button builds from inside the editor: **iOS → TestFlight** (preflight diagnoses the Apple toolchain / App Store Connect state with inline fixes, then a cancellable staged pipeline — Godot headless export → `xcodebuild` archive with automatic cloud signing → direct upload), **Android → Device** (preflight diagnoses the SDK/JDK/preset/connected device, then Godot headless export → `adb install`), and **itch.io** (preflight diagnoses butler/API key/game/channels/templates, then per-channel Web/desktop headless exports → `butler push`). Plus `cli/release_ios.sh`: the whole TestFlight release, build-number commit included, in one command. Game-agnostic; configured per project via `res://build_kit.config.json`. |
| [`snapser_kit`](addons/snapser_kit/README.md) | Game-agnostic [Snapser](https://snapser.com) client: config resolution (committed JSON / env / offline flag), anonymous auth with Apple/Google linking, a hardened web-safe transport (timeouts, retries, 401 re-login), typed snap clients (stats, leaderboards, storage, remote config, quests, profiles, batched analytics), local-first cloud save, and `SnapKitService`, the base class for a game's `Snapser` autoload. Headless tests in `tests/snapser_kit/`; provisioning template + live smoke runner in `tools/snapser/`. |
| [`snapser_kit_apple`](addons/snapser_kit_apple/README.md) | Sign in with Apple for `snapser_kit` on iOS: a small GDExtension around `ASAuthorizationController` (prebuilt static `.xcframework`, iOS 15+), an export plugin that wires it into iOS builds, and `SnapKitAppleBridge`, whose `get_identity_token()` returns the Apple authorization code. Returns `unsupported_platform` everywhere else. Native source and build script in `tools/snapser_kit_apple/`. |

## Using an addon

Copy `addons/<name>/` into your project's `addons/`, enable it in
Project → Project Settings → Plugins, and follow that addon's README for any
autoload / wiring it needs. Updates are managed by **`editor_tool_kit`**, which
acts as the package manager: its "Editor Tool Kit" bottom-panel dock lists every
managed addon (any addon carrying an `[update]` marker, including etk itself),
checks this repo for newer versions, and pulls them in place — one UI for all
addons. A managed addon therefore needs `editor_tool_kit` vendored alongside it.

## Adding an addon

This repo is the home for extracted, game-agnostic addons. To add one, drop it at
`addons/<name>/` (sibling to the others — the extractor requires that exact path),
wire it up, add an `[update]` marker to its `plugin.cfg` to make it self-update,
and ship by bumping that `version` on `main`. See [`CLAUDE.md`](CLAUDE.md) for the
full new-addon checklist and the self-update marker contract.
