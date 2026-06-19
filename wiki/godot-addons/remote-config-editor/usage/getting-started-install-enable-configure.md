# Getting started — install, enable & configure

**Status:** active

## Body
Remote Config Editor turns several committed JSON blobs into one publish document and, optionally, checks live drift against your backend. It is game-agnostic: every project-specific value comes from a config file you own, so the addon ships no game code.

## Install

1. Copy `addons/remote_config_editor/` and `addons/editor_tool_kit/` into your project's `addons/` — etk is required (it provides the base classes and the self-update dock).
2. Enable both in Project → Project Settings → Plugins.
3. Create `res://remote_config_editor.config.json` (see Configure, below).
4. Open the **Remote Config** bottom-panel tab.

## Configure

Author `res://remote_config_editor.config.json` — _not_ inside the addon folder, because a self-update overwrites the addon but never this file. Start from `config.example.json`:

```json
{
  "root": "res://..",
  "manifest": "validator/content/app_config.manifest.json",
  "content_dir": "validator/content",
  "doc_version_field": "app_config_version",
  "document_label": "app-config document",
  "publish_target": "the Snapser console App Config",
  "sync": {
    "program": "bun",
    "args": ["{root}/validator/src/validator/tools/appconfig.ts", "verify", "--json"],
    "hint": "cd validator && bun run appconfig:verify"
  }
}
```

| **Field** | **Meaning** |
| --- | --- |
| `root` | base every relative path resolves against — `res://` for a flat project, `res://..` when the Godot project is nested one level under its repo root. |
| `manifest` | path (relative to root) of the manifest JSON. Required. |
| `content_dir` | dir (relative to root) holding the content blobs. Required. |
| `doc_version_field` | manifest field naming the document version (default `app_config_version`). |
| `document_label` | noun used in the dock's messages. |
| `publish_target` | where the operator pastes the payload. |
| `sync` | optional drift-check command; omit it and the Check Sync button disappears. |

The `sync` block is `{program, args, hint}`. `args` are passed verbatim to the program with `{root}` replaced by the resolved root dir. The command must print one JSON object on stdout with a `results` array of `{key, status, committed_version, live_version}`; `hint` is shown when the program can't be run.

## A minimal flat project

A project with everything under `res://` and no live drift check needs only:

```json
{ "manifest": "content/app.manifest.json", "content_dir": "content" }
```

## Verify (headless)

The aggregation core is headless-testable (no editor). From the addon repo:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
    --script res://tools/verify_remote_config_editor.gd
```

## References
_None._

## Child pages
_None._
