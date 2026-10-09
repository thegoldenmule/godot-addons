# Getting started — install, enable & preflight

**Status:** active

## Body
Build Kit turns a Godot project into a TestFlight build from inside the editor. Everything below is macOS-only — the pipeline is `xcodebuild`.

## 1. Install

Copy `addons/build_kit/` **and** `addons/editor_tool_kit/` into your project's `addons/`, commit them, and enable both in Project → Project Settings → Plugins. `editor_tool_kit` supplies the base classes and is also the update dock that keeps Build Kit current.

A **Build Kit** tab appears in the bottom panel.

## 2. Run preflight

Press **⟳ Refresh preflight**. The checklist diagnoses the whole chain, and every row that is not green explains what to do — several repair themselves with a **Fix** button.

| Row | What it checks | Fix button? |
| --- | --- | --- |
| Xcode | `xcodebuild -version` answers | no — install Xcode, then `sudo xcode-select -s /Applications/Xcode.app` |
| iOS export templates | the pack for _this exact_ Godot version is installed | **yes** — downloads and installs it (~1 GB) |
| ETC2/ASTC textures | `import_etc2_astc` is on | **yes** — enables it (textures reimport once) |
| iOS export preset | exists, `export_project_only` on, Team ID set, no missing base keys | **yes** — plus a create-preset form when there is none |
| Xcode account | a team is signed into Xcode | no — Xcode → Settings → Accounts |
| Distribution certificate | an Apple Distribution identity is in the keychain | no — Xcode → Settings → Accounts → Manage Certificates… |
| App Store Connect API key | key id, issuer id and `.p8` all present and valid for your team | no — the inline form adopts a dropped `.p8` |
| App Store Connect app record | the app exists for your bundle id | **yes** for registering the bundle id; creating the app is manual |
| Paired device | `devicectl` sees a device | no — only needed for direct installs, not TestFlight |

## 3. The iOS export preset

If you have no iOS preset, type a reverse-DNS bundle id into the row's form (it is prefilled from your project name), pick your team, and press **Create preset** — the service writes a complete, ready-to-build preset.

If you already have one, press **Fix**. That sets `application/export_project_only = true`, backfills any base keys the preset is missing, and fills in the Team ID (automatically when exactly one team is signed into Xcode; otherwise pick one in the dropdown first).

**Leave the preset's signing fields empty.** Godot exports the Xcode project only; Build Kit owns every signing decision, and no secret is ever written into `export_presets.cfg`.

## 4. Optional but recommended — an API key

Without one, Build Kit rides your signed-in Xcode session: fine interactively, but sessions expire and the app-record check then only happens reactively at upload time. See **The App Store Connect API key** for the two-minute setup.

## 5. One-time steps no tool can automate

Preflight walks you through each of these, but they are yours to do:

- an **Apple Developer Program** membership;
- **creating the API key** (App Store Connect → Users and Access → Integrations);
- **creating the app record** — app creation is not in Apple's public API. Your bundle id appears in the New App dialog's dropdown because signing registered it (or because you pressed the app-record row's **Fix**, which registers it through the API key).

## Where state lives

|  | File | Committed? | Holds |
| --- | --- | --- | --- |
| Shared settings | `res://build_kit.config.json` | **yes** | `ios.preset`, `ios.build_number` |
| Credentials | repo `.env` (`res://.env`, else `res://../.env`) | **no** — gitignored | `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH` |

```json
{
	"ios": {
		"preset": "iOS",
		"build_number": 1
	}
}
```

Both live outside `addons/build_kit/`, so a self-update never clobbers them.

## Checking the addon itself

From the repo root:

```sh
godot --headless --path . --script res://tools/verify_build_kit.gd
```

## References
_None._

## Child pages
_None._
