@tool
extends SceneTree

## Headless verifier for editor_tool_kit's self-update package manager. Exercises
## the static, editor-free helpers — version parse/compare, package discovery +
## URL building, and the install runner's archive-path mapping + traversal guard —
## with no editor and no network. Run:
##
##   godot --headless --path <project> --script res://tools/verify_editor_tool_kit.gd
##
## Exits 0 on success, 1 on the first failure (so CI / a pre-push hook can gate on
## it). These are the paths a broken refactor would silently corrupt: a bad prefix
## map could write archive files outside the addon, a bad compare could ship a
## downgrade.

const Registry := preload("res://addons/editor_tool_kit/package_registry.gd")
const Service := preload("res://addons/editor_tool_kit/update_service.gd")
const Runner := preload("res://addons/editor_tool_kit/update_reload_runner.gd")

var _failures := 0


func _initialize() -> void:
	_test_version_compare()
	_test_version_parse()
	_test_url_builders()
	_test_prefix_normalize()
	_test_describe_discover()
	_test_archive_rel()
	_test_is_safe()

	if _failures == 0:
		print("editor_tool_kit verify: OK")
		quit(0)
	else:
		printerr("editor_tool_kit verify: %d FAILED" % _failures)
		quit(1)


func _check(label: String, cond: bool) -> void:
	if not cond:
		_failures += 1
		printerr("  FAIL: %s" % label)


func _eq(label: String, got, want) -> void:
	if got != want:
		_failures += 1
		printerr("  FAIL: %s — got %s, want %s" % [label, str(got), str(want)])


# ── Version compare / parse ───────────────────────────────────────────────────

func _test_version_compare() -> void:
	_check("0.2.0 > 0.1.9", Service.is_newer("0.2.0", "0.1.9"))
	_check("1.0 > 0.9.9", Service.is_newer("1.0", "0.9.9"))
	_check("0.2 > 0.1.9 (missing component = 0)", Service.is_newer("0.2", "0.1.9"))
	_check("equal is not newer", not Service.is_newer("0.2.0", "0.2.0"))
	_check("older is not newer", not Service.is_newer("0.1.0", "0.2.0"))
	_check("0.2 == 0.2.0 (not newer)", not Service.is_newer("0.2", "0.2.0"))


func _test_version_parse() -> void:
	var text := "[plugin]\nname=\"x\"\nversion=\"1.4.2\"\n"
	_eq("parse_remote_version", Service.parse_remote_version(text), "1.4.2")
	_eq("parse garbage → empty", Service.parse_remote_version("not a cfg {"), "")


# ── Registry URL builders + prefix normalize ──────────────────────────────────

func _test_url_builders() -> void:
	_eq("remote_cfg_url", Registry.remote_cfg_url("thegoldenmule/godot-addons", "main", "addons/ui_kit/"),
		"https://raw.githubusercontent.com/thegoldenmule/godot-addons/main/addons/ui_kit/plugin.cfg")
	_eq("archive_url", Registry.archive_url("thegoldenmule/godot-addons", "main"),
		"https://github.com/thegoldenmule/godot-addons/archive/refs/heads/main.zip")
	_eq("repo_page", Registry.repo_page("thegoldenmule/godot-addons"),
		"https://github.com/thegoldenmule/godot-addons")


func _test_prefix_normalize() -> void:
	_eq("trailing slash added", Registry._normalize_prefix("addons/ui_kit"), "addons/ui_kit/")
	_eq("leading slash stripped", Registry._normalize_prefix("/addons/ui_kit/"), "addons/ui_kit/")
	_eq("already normal", Registry._normalize_prefix("addons/ui_kit/"), "addons/ui_kit/")
	_eq("empty stays empty", Registry._normalize_prefix("  "), "")


# ── Discovery over the real repo addons ───────────────────────────────────────

func _test_describe_discover() -> void:
	var etk := Registry.describe("res://addons/editor_tool_kit/plugin.cfg")
	_check("etk describe non-empty", not etk.is_empty())
	if not etk.is_empty():
		_eq("etk prefix", etk["prefix"], "addons/editor_tool_kit/")
		_eq("etk source", etk["source"], "thegoldenmule/godot-addons")
		_eq("etk folder", etk["folder"], "editor_tool_kit")

	# An addon with no [update] marker is not managed.
	_check("no marker → empty", Registry.describe("res://project.godot").is_empty())

	var found := Registry.discover()
	var folders := []
	for d in found:
		folders.append(d["folder"])
	_check("discover finds ui_kit", folders.has("ui_kit"))
	_check("discover finds editor_tool_kit", folders.has("editor_tool_kit"))


# ── Runner archive-path mapping (multi-prefix) ────────────────────────────────

func _test_archive_rel() -> void:
	var prefixes := ["addons/ui_kit/", "addons/editor_tool_kit/"]
	_eq("direct ui_kit path", Runner._archive_rel("addons/ui_kit/ui_router.gd", prefixes),
		"addons/ui_kit/ui_router.gd")
	_eq("wrapped archive path",
		Runner._archive_rel("godot-addons-main/addons/editor_tool_kit/plugin.gd", prefixes),
		"addons/editor_tool_kit/plugin.gd")
	_eq("unmanaged path → empty", Runner._archive_rel("godot-addons-main/README.md", prefixes), "")
	_eq("deeper-nested copy rejected → empty",
		Runner._archive_rel("godot-addons-main/templates/addons/ui_kit/x.gd", prefixes), "")
	_eq("sibling addon not in prefix list → empty",
		Runner._archive_rel("addons/other_kit/x.gd", prefixes), "")


func _test_is_safe() -> void:
	var prefixes := ["addons/ui_kit/", "addons/editor_tool_kit/"]
	_check("normal path safe", Runner._is_safe("addons/ui_kit/ui_router.gd", prefixes))
	_check("traversal rejected", not Runner._is_safe("addons/ui_kit/../../etc/passwd", prefixes))
	_check("absolute rejected", not Runner._is_safe("/etc/passwd", prefixes))
	_check("backslash rejected", not Runner._is_safe("addons/ui_kit\\x.gd", prefixes))
	_check("outside prefix rejected", not Runner._is_safe("addons/other/x.gd", prefixes))
