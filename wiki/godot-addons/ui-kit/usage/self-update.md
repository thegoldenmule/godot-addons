# Self-update

**Status:** active

## Body
UI Kit is **vendored**: a consuming project copies `addons/ui_kit/` into its own tree and commits it, so a fresh clone works offline. But the source of truth lives at [github.com/thegoldenmule/godot-addons](https://github.com/thegoldenmule/godot-addons), and the addon keeps itself current by pulling newer versions in place — no manual re-copy, no GitHub-release ceremony.

## The version is the ship signal

There is no release process beyond the version number. The `version` field in `addons/ui_kit/plugin.cfg` on `main` _is_ the ship signal. To publish an update:

1. Bump `version` in `addons/ui_kit/plugin.cfg`.
2. Commit the change.
3. Push to `main` of [github.com/thegoldenmule/godot-addons](https://github.com/thegoldenmule/godot-addons).

Consuming projects then see the newer version through the addon's dock.

## The 'UI Kit' dock pulls updates in place

Enabling the plugin mounts a **'UI Kit' bottom-panel dock**. It checks the source repo and, when a newer version is available, pulls it: Check for updates → Update now. Under the hood it downloads the whole-branch archive zip and extracts _only_ the `addons/ui_kit/` subtree, replacing it in place (atomic per-file, with rollback). Sibling addons are never touched.

## Overwrites and adds, never prunes

The extractor **overwrites + adds but never prunes**. A file that still exists upstream is overwritten with the new copy, and new files are added — but a file _removed_ upstream is left in place locally. If an update deletes a file from the addon, you must delete the stale local copy by hand.

> LOAD-BEARING: the addon must live at exactly `addons/ui_kit/` at the project root. The extractor strips one archive-wrapper segment (`godot-addons-main/`) and keeps only paths under `addons/ui_kit/`. Nest it deeper and self-update silently no-ops.

See Getting started — install & enable for the initial install + enable steps.

## References
_None._

## Child pages
_None._
