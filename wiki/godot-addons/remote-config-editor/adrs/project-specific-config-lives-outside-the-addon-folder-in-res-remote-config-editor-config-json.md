# ADR-14: Project-specific config lives outside the addon folder, in res://remote_config_editor.config.json

**Status:** accepted

## Metadata
- **Date:** 2026-06-19
- **Scope:** remote_config_editor
- **Deciders:** Benjamin Jordan

## Context
The tool was extracted from one game, where the manifest path (`validator/content/app_config.manifest.json`), the content dir, the drift-check command (`bun appconfig.ts verify`), and the console branding (`Snapser App Config`) were hardcoded constants in the service + dock. To be reusable those must move out of the addon into something the consuming project owns. But the addon also self-updates in place: etk's updater overwrites the whole `addons/remote_config_editor/` subtree, so any config stored *inside* the addon folder would be clobbered on the next update.

## Decision
Project-specific configuration lives in a single file at the project root, res://remote_config_editor.config.json, OUTSIDE the addon folder. RemoteConfigService.load_config() merges it over a DEFAULTS dict; a missing file yields pure defaults and the dock shows a configure-me prompt instead of erroring.

The file carries root, manifest, content_dir, doc_version_field, document_label, publish_target, and an optional sync command. Relative paths resolve against root via _resolve(), and {root} in a sync arg is substituted with the resolved root dir, so one tool serves a flat project (root res://) and a project nested under its repo (root res://..).

```json
{
  "root": "res://..",
  "manifest": "validator/content/app_config.manifest.json",
  "content_dir": "validator/content",
  "sync": { "program": "bun", "args": ["{root}/validator/src/validator/tools/appconfig.ts", "verify", "--json"] }
}
```

## Consequences
A consuming project configures the tool by committing one JSON file; config.example.json ships as the template. The addon's .gd code and plugin.cfg carry zero game-specific values.

Because the config is outside the addon subtree, etk self-update overwrites the addon but never the project's config — no merge, no re-entry of settings after an update.

The config is loaded with ContentStore.load_json (no editor APIs), so the service stays headless-testable; the verifier exercises the DEFAULTS merge and the path resolver directly.

## Relations
_None._
