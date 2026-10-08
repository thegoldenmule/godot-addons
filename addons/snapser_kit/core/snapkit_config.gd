@tool
class_name SnapKitConfig
extends RefCounted

## Snapser Kit connection + game settings, resolved once at startup.
##
## Source of truth is the game's COMMITTED res://snapser_kit.config.json (not a
## secret — it holds the public gateway URL, never an API key):
##
##   {
##     "game_id": "mygame",
##     "gateway_url": "https://gateway.snapser.com/<snapend-id>",
##     "anon_handle_prefix": "mygame-",
##     "leaderboards": { "career_wins": "career_wins" },
##     "cloud_save": { "blob_key": "save_v1", "sync_prefixes": ["sax_prog_"] },
##     "link_providers": ["apple", "google"]
##   }
##
## Resolution order (first match wins for "offline" / "gateway_url"):
##   1. SNAPSER_OFFLINE=1 in the environment, or `--snapser-offline` on the
##      command line (user args after `--` or engine args) -> forced offline.
##   2. SNAPSER_GATEWAY_URL environment variable -> gateway_url.
##   3. user://snapser_kit.override.json, DEBUG BUILDS ONLY. May contain
##      "gateway_url" and/or "offline": true. Other keys are ignored.
##   4. The committed res://snapser_kit.config.json.
##   5. Nothing resolved -> offline.
## All non-gateway keys (game_id, boards, cloud_save, ...) come only from the
## committed file.
##
## THE CLIENT NEVER READS AN API KEY. The Snapser platform key is a credential
## for snapctl / server tooling only.
##
## Unknown top-level keys are preserved in `raw` so games and later kit versions
## can read optional sections (e.g. "quests") without a schema change here.

const DEFAULT_PATH := "res://snapser_kit.config.json"
const OVERRIDE_PATH := "user://snapser_kit.override.json"
const ENV_OFFLINE := "SNAPSER_OFFLINE"
const ENV_GATEWAY := "SNAPSER_GATEWAY_URL"
const ARG_OFFLINE := "--snapser-offline"

## Values of `source` / `offline_reason`, for diagnostics and the editor page.
const SOURCE_NONE := "none"
const SOURCE_ENV := "env"
const SOURCE_OVERRIDE := "override"
const SOURCE_COMMITTED := "committed"

# ---- Committed game settings -------------------------------------------------
## Catalogue token for this game (e.g. "battleships"). Diagnostics + defaults.
var game_id: String = ""
## Prefix of newly minted anonymous handles. Empty -> "<game_id>-".
var anon_handle_prefix: String = ""
## Logical board name -> Snapser leaderboard name.
var leaderboards: Dictionary = {}
## { "blob_key": String, "sync_prefixes": Array[String] }.
var cloud_save: Dictionary = {}
## Providers the game offers for account linking ("apple", "google").
var link_providers: PackedStringArray = PackedStringArray()
## The whole parsed committed file, including keys this class does not model.
var raw: Dictionary = {}

# ---- Resolved connection -----------------------------------------------------
## https://gateway.snapser.com/<snapend-id>, no trailing slash. "" when offline.
var gateway_url: String = ""
## True when the kit must make no network calls at all.
var offline: bool = true
## Where gateway_url came from: one of SOURCE_*.
var source: String = SOURCE_NONE
## Human-readable reason when offline ("SNAPSER_OFFLINE=1", "--snapser-offline",
## "no gateway configured", "invalid gateway_url"); "" when online.
var offline_reason: String = ""




## Resolve from the real environment: OS env, command-line args, the debug
## override file (debug builds only) and the committed file at `path`.
## Never fails: a missing/invalid file yields an offline config.
static func from_project(path: String = DEFAULT_PATH) -> SnapKitConfig:
	var committed := _read_json_file(path)
	var env := {
		ENV_OFFLINE: OS.get_environment(ENV_OFFLINE),
		ENV_GATEWAY: OS.get_environment(ENV_GATEWAY),
	}
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	var is_debug := OS.is_debug_build()
	var override := _read_json_file(OVERRIDE_PATH) if is_debug else {}
	return resolve(committed, env, args, override, is_debug)


## Pure resolution core, for unit tests (no file or OS access).
##   committed: parsed committed config ({} if missing)
##   env:       {"SNAPSER_OFFLINE": "...", "SNAPSER_GATEWAY_URL": "..."} subset
##   args:      command-line args (OS.get_cmdline_args() + get_cmdline_user_args())
##   override:  parsed override file ({} if missing)
##   is_debug:  OS.is_debug_build(); the override is ignored when false
static func resolve(committed: Dictionary, env: Dictionary, args: PackedStringArray,
		override: Dictionary, is_debug: bool) -> SnapKitConfig:
	var cfg := SnapKitConfig.new()
	cfg._apply_committed(committed)

	# 1. Forced offline.
	if SnapKitJson.to_bool(str(env.get(ENV_OFFLINE, "")).strip_edges(), false):
		return cfg._set_offline("%s=%s" % [ENV_OFFLINE, str(env.get(ENV_OFFLINE))])
	if args.has(ARG_OFFLINE):
		return cfg._set_offline(ARG_OFFLINE)

	# 2-4. First gateway source that is set wins.
	var url := ""
	var src := SOURCE_NONE
	var env_url := str(env.get(ENV_GATEWAY, "")).strip_edges()
	if env_url != "":
		url = env_url
		src = SOURCE_ENV
	elif is_debug and not override.is_empty():
		if SnapKitJson.get_bool(override, "offline", false):
			cfg.source = SOURCE_OVERRIDE
			return cfg._set_offline("override: offline")
		var ov_url := SnapKitJson.get_str(override, "gateway_url").strip_edges()
		if ov_url != "":
			url = ov_url
			src = SOURCE_OVERRIDE
	if src == SOURCE_NONE:
		var c_url := SnapKitJson.get_str(committed, "gateway_url").strip_edges()
		if c_url != "":
			url = c_url
			src = SOURCE_COMMITTED

	# 5. Nothing / invalid -> offline.
	cfg.source = src
	if src == SOURCE_NONE:
		return cfg._set_offline("no gateway configured")
	url = url.rstrip("/")
	if not is_valid_gateway_url(url):
		return cfg._set_offline("invalid gateway_url (%s)" % src)
	cfg.gateway_url = url
	cfg.offline = false
	cfg.offline_reason = ""
	return cfg


## Build directly from a dictionary shaped like the committed file, with no env /
## override resolution. Tests use this to point the kit at a mock gateway:
##   SnapKitConfig.from_dict({"game_id": "t", "gateway_url": "http://mock.invalid"})
## offline = gateway_url is empty or invalid.
static func from_dict(d: Dictionary) -> SnapKitConfig:
	return resolve(d, {}, PackedStringArray(), {}, false)


## True when a usable gateway is configured and nothing forced offline.
func is_ready() -> bool:
	return not offline and gateway_url != ""


func is_offline() -> bool:
	return not is_ready()


## Prefix used for new anonymous handles (anon_handle_prefix, else "<game_id>-",
## else "snapkit-").
func handle_prefix() -> String:
	if anon_handle_prefix != "":
		return anon_handle_prefix
	if game_id != "":
		return game_id + "-"
	return "snapkit-"


## Map a logical board name to its Snapser leaderboard name. Unmapped names pass
## through unchanged so a game may use Snapser names directly.
func leaderboard_id(board: String) -> String:
	var mapped := SnapKitJson.get_str(leaderboards, board)
	return mapped if mapped != "" else board


## cloud_save.blob_key, default "save_v1".
func cloud_save_blob_key() -> String:
	var k := SnapKitJson.get_str(cloud_save, "blob_key")
	return k if k != "" else "save_v1"


## cloud_save.sync_prefixes as a PackedStringArray (empty = cloud save disabled).
func cloud_save_prefixes() -> PackedStringArray:
	var out := PackedStringArray()
	for p in SnapKitJson.get_array(cloud_save, "sync_prefixes"):
		if p is String and p != "":
			out.append(p)
	return out


## True when the committed file has a truthy optional "quests" section; gates the
## SnapKitService quests_* passthroughs.
func quests_enabled() -> bool:
	var q: Variant = raw.get("quests")
	if q is Dictionary:
		return SnapKitJson.get_bool(q, "enabled", true)
	return SnapKitJson.to_bool(q, false)


## One-line description for logs and the editor page, e.g.
## "online via committed (https://gateway.snapser.com/...)" or
## "offline: SNAPSER_OFFLINE=1". Never includes secrets (there are none).
func describe() -> String:
	if is_ready():
		return "online via %s (%s)" % [source, gateway_url]
	return "offline: %s" % offline_reason


## True for an http(s) URL with a host and no placeholder ("<", "{").
static func is_valid_gateway_url(url: String) -> bool:
	var u := url.strip_edges()
	if u.contains("<") or u.contains("{") or u.contains(" "):
		return false
	var rest := ""
	if u.begins_with("https://"):
		rest = u.trim_prefix("https://")
	elif u.begins_with("http://"):
		rest = u.trim_prefix("http://")
	else:
		return false
	var host := rest.get_slice("/", 0)
	return host != "" and host != ":" and not host.begins_with(":")


# ---- internals ---------------------------------------------------------------

func _apply_committed(d: Dictionary) -> void:
	raw = d.duplicate(true)
	game_id = SnapKitJson.get_str(d, "game_id")
	anon_handle_prefix = SnapKitJson.get_str(d, "anon_handle_prefix")
	leaderboards = SnapKitJson.get_dict(d, "leaderboards").duplicate()
	cloud_save = SnapKitJson.get_dict(d, "cloud_save").duplicate(true)
	link_providers = PackedStringArray()
	for p in SnapKitJson.get_array(d, "link_providers"):
		if p is String and p != "":
			link_providers.append(p)


func _set_offline(reason: String) -> SnapKitConfig:
	offline = true
	gateway_url = ""
	offline_reason = reason
	return self


static func _read_json_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = SnapKitJson.parse(text)
	if parsed is Dictionary:
		return parsed
	push_warning("[SnapKit] %s is not a JSON object; ignoring it" % path)
	return {}
