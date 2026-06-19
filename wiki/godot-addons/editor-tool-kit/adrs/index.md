# ADRs

**Status:** active

## Overview
Architectural decision records for Editor Tool Kit — the durable rationale behind the service/view split, the {ok, error} contract, the composition root, the cascaded theme, the duplicated palette, the vendored-but-sourced distribution, the prune-never self-update, and ContentStore's write/serialization boundary.

## Contents
- [ADR-1: Tool logic lives in a headless-testable ToolService; the editor view is optional](decision-record:mql3ckxx-01q4-k9gj7p)
- [ADR-2: Service methods return an {ok, error} Dictionary instead of throwing](decision-record:mql3d1it-01st-2lnrwz)
- [ADR-3: EditorToolPlugin is the composition root that constructs and injects the pieces](decision-record:mql3d2u7-01t5-imiqoo)
- [ADR-4: Style via one Theme cascaded from the panel root, not per-dock styling](decision-record:mql3d43y-01t7-28swd4)
- [ADR-5: The palette duplicates theme values by intent; the kit never imports a host theme](decision-record:mql3d596-01td-fdtwle)
- [ADR-6: Vendored-but-sourced distribution with in-editor self-update; version is the ship signal](decision-record:mql3d6a1-01th-xfycdx)
- [ADR-7: Self-update extracts only the addon subtree, never prunes, and rolls back on failure](decision-record:mql3d7rm-01tl-2ebxlo)
- [ADR-8: ContentStore owns the atomic write but not serialization, which stays per-tool](decision-record:mql3d8m5-01tn-my3yd)
- [ADR-9: editor_tool_kit is the package manager; addons opt in via an [update] marker and ship no update machinery](decision-record:mql6tar6-02c0-zgxeyx)
