@tool
extends RefCounted

## Package discovery for the editor_tool_kit self-update manager. etk acts as the
## package manager for The Golden Mule's vendored addons: any addon that carries
## an `[update]` section in its own `plugin.cfg` opts in to being managed from the
## single "Editor Tool Kit" dock — it needs NO update machinery of its own.
##
## The marker is the whole contract (folder-named, so it survives a repo move):
##
##   [update]
##   source = "thegoldenmule/godot-addons"   # GitHub owner/repo the addon ships from
##   branch = "main"                         # tracked branch (defaults to "main")
##   prefix = "addons/ui_kit/"               # the addon subtree, LOAD-BEARING
##
## `prefix` is authoritative for BOTH the raw-cfg URL and which archive subtree the
## install runner extracts — it is the value the per-addon updaters used to hold in
## an ADDON_REL_PREFIX constant, now travelling in the addon's own manifest.
##
## Everything here is static + ConfigFile/DirAccess only (no Control, no
## EditorInterface, no network), so the headless verifier exercises discovery and
## the URL builders with no editor.

const ADDONS_ROOT := "res://addons"

## Default tracked branch when a marker omits `branch`.
const DEFAULT_BRANCH := "main"


## Every managed addon under res://addons, as descriptor dictionaries (see
## `describe`). Skips addons with no `[update]` marker. Sorted by folder so the
## dock renders a stable order.
static func discover() -> Array:
	var out := []
	var dir := DirAccess.open(ADDONS_ROOT)
	if dir == null:
		return out
	var folders := dir.get_directories()
	folders.sort()
	for folder in folders:
		var cfg_path := "%s/%s/plugin.cfg" % [ADDONS_ROOT, folder]
		var desc := describe(cfg_path)
		if not desc.is_empty():
			out.append(desc)
	return out


## Build a descriptor from one addon's plugin.cfg, or {} if the file is missing,
## unreadable, or carries no `[update]` marker (so an addon opts in simply by
## adding the section). The descriptor is the single value passed around the
## manager / runner:
##
##   {
##     name, folder, cfg_path,           # identity
##     source, branch, prefix,           # the marker
##     remote_cfg_url, archive_url, repo_page,   # derived URLs
##   }
static func describe(cfg_path: String) -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load(cfg_path) != OK:
		return {}
	if not cfg.has_section("update"):
		return {}
	var prefix := _normalize_prefix(str(cfg.get_value("update", "prefix", "")))
	var source := str(cfg.get_value("update", "source", ""))
	if prefix.is_empty() or source.is_empty():
		return {}
	var branch := str(cfg.get_value("update", "branch", DEFAULT_BRANCH))
	if branch.is_empty():
		branch = DEFAULT_BRANCH
	return {
		"name": str(cfg.get_value("plugin", "name", prefix)),
		"folder": _folder_of(cfg_path),
		"cfg_path": cfg_path,
		"source": source,
		"branch": branch,
		"prefix": prefix,
		"remote_cfg_url": remote_cfg_url(source, branch, prefix),
		"archive_url": archive_url(source, branch),
		"repo_page": repo_page(source),
	}


# ── URL builders (pure; the verifier drives them with literal strings) ─────────

## Raw plugin.cfg on the tracked branch — the upstream version source of truth.
static func remote_cfg_url(source: String, branch: String, prefix: String) -> String:
	return "https://raw.githubusercontent.com/%s/%s/%splugin.cfg" % [
		source, branch, _normalize_prefix(prefix)
	]


## Branch archive zip (redirects to codeload; HTTPRequest follows the redirect).
static func archive_url(source: String, branch: String) -> String:
	return "https://github.com/%s/archive/refs/heads/%s.zip" % [source, branch]


static func repo_page(source: String) -> String:
	return "https://github.com/%s" % source


# ── Helpers ───────────────────────────────────────────────────────────────────

## A prefix is always stored with exactly one trailing slash and no leading slash,
## so it concatenates cleanly into URLs and archive-path comparisons.
static func _normalize_prefix(prefix: String) -> String:
	var p := prefix.strip_edges()
	if p.is_empty():
		return ""
	while p.begins_with("/"):
		p = p.substr(1)
	while p.ends_with("/"):
		p = p.substr(0, p.length() - 1)
	if p.is_empty():
		return ""
	return p + "/"


## "res://addons/ui_kit/plugin.cfg" → "ui_kit".
static func _folder_of(cfg_path: String) -> String:
	return cfg_path.get_base_dir().get_file()
