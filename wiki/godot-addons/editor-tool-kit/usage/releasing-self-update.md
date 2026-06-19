# Releasing & self-update

**Status:** active

## Body
The **version is the ship signal**: there is no GitHub-release ceremony. The addon is vendored into consuming projects but sourced from this repo; consumers pull updates through the **Editor Tool Kit** bottom-panel tab.

## Releasing an update

1. Bump `version` in `addons/editor_tool_kit/plugin.cfg`.
2. Commit and push to the default branch.

The check reads `plugin.cfg` raw from the default branch (`raw.githubusercontent.com/thegoldenmule/godot-addons/.../addons/editor_tool_kit/plugin.cfg`) and the install downloads the branch-archive zip — so pushing is all it takes.

## How a consumer updates

1. Open the **Editor Tool Kit** bottom-panel tab in the Godot editor.
2. Press **Check for updates** (or leave _Check for updates when the editor opens_ on). It compares the installed version to the repo's.
3. If newer, press **Update now** — it downloads the archive, replaces `addons/editor_tool_kit/` in place, and reloads the plugin.

## Limits

- The install **overwrites + adds but never prunes**, so a file removed upstream lingers until deleted by hand.
- An update **clobbers local edits** to the vendored copy — land changes in this repo, not in a consumer.
- The in-editor reload needs Godot **4.4+**.

For the extract/rollback internals (anchored prefix, `FAILED_MIXED` guard), see Self-update & distribution.

## References
_None._

## Child pages
_None._
