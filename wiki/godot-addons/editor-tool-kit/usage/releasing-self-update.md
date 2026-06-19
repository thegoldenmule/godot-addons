# Releasing & self-update

**Status:** active

## Body
The **version is the ship signal**: there is no GitHub-release ceremony. Addons are vendored into consuming projects but sourced from this repo; consumers pull updates through the **Editor Tool Kit** bottom-panel tab, which is the **package manager** for every managed addon (including etk itself).

## Releasing an update

1. Bump `version` in `addons/editor_tool_kit/plugin.cfg`.
2. Commit and push to the default branch.

The check reads `plugin.cfg` raw from the default branch (`raw.githubusercontent.com/thegoldenmule/godot-addons/.../addons/editor_tool_kit/plugin.cfg`) and the install downloads the branch-archive zip — so pushing is all it takes.

## How a consumer updates

1. Open the **Editor Tool Kit** bottom-panel tab in the Godot editor.
2. Press **Check all** (or leave _Check for updates when the editor opens_ on). Each managed addon's installed version is compared to its upstream.
3. For any addon that is behind, press its row's **Update** (or **Update all**) — it downloads the branch archive once, replaces the addon subtree(s) in place, and reloads the affected plugins.

## Limits

- The install **overwrites + adds but never prunes**, so a file removed upstream lingers until deleted by hand.
- An update **clobbers local edits** to the vendored copy — land changes in this repo, not in a consumer.
- The in-editor reload needs Godot **4.4+**.

For the extract/rollback internals (anchored prefix, `FAILED_MIXED` guard), see Self-update & distribution.

## Managing other addons

The same tab manages every addon that carries an `[update]` marker in its `plugin.cfg` — not just etk. To make an addon self-update, add the marker (`source` / `branch` / `prefix`) and give it _no_ update machinery of its own; etk's dock discovers it and lists it as a row. The addon then needs etk vendored + enabled alongside it.

## References
_None._

## Child pages
_None._
