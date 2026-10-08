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
##     "cloud_save": { "blob_key": "save_v1", "sync_prefixes": ["sax_prog_"],
##                     "sync_keys": ["legacy_unlocked_flag"] },
##     "link_providers": ["apple", "google"]
##   }
##
## Resolution order (first match wins for "offline" / "gateway_url"):
##   1. SNAPSER_OFFLINE=1 in the environment, or `--snapser-offline` on the
##      command line (user args after `--` or engine args) -> forced offline.
##   1b. A TEST / TOOL RUN -> offline unless SNAPSER_TESTS_ONLINE=1: any
##      command-line arg (scene or --script path) or the main scene under
##      res://tests/ or res://tools/ (also the bare "tests/..." / "tools/..."
##      spellings). Headless suites therefore never touch the network even
##      though the gateway is committed (DoD 7).
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
## Optional "declared" section (v0.2) mirrors what the snapend declares, so the
## kit can catch undeclared names before the server 404s them:
##   "declared": {"stats": [...], "boards": [...], "events": [...], "blobs": [...]}
## A kind that is absent is not checked. Boards are SNAPSER board names (the
## values of "leaderboards"). declaration_problems(manifest) cross-checks the
## section against the game's snapser/snapend-manifest.json.
##
## force_offline(reason) switches a resolved config offline at runtime
## (SnapKitService.force_offline() is the game-facing call).
##
## Unknown top-level keys are preserved in `raw` so games and later kit versions
## can read optional sections (e.g. "quests") without a schema change here.

const DEFAULT_PATH := "res://snapser_kit.config.json"
const OVERRIDE_PATH := "user://snapser_kit.override.json"
const ENV_OFFLINE := "SNAPSER_OFFLINE"
const ENV_GATEWAY := "SNAPSER_GATEWAY_URL"
const ARG_OFFLINE := "--snapser-offline"
const ENV_TESTS_ONLINE := "SNAPSER_TESTS_ONLINE"
## Path prefixes that mark a test / tool run (rule 1b).
const TEST_TOOL_PREFIXES := ["res://tests/", "res://tools/", "tests/", "tools/", "./tests/", "./tools/"]
## Declaration kinds accepted under "declared".
const DECLARED_KINDS := ["stats", "boards", "events", "blobs"]

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
## Root directory for EVERY file the kit writes (session file, cloud-save state,
## editor probe): one sandbox switch. Default "user://" (the game's normal data
## dir — real games never change it). Test harnesses point it at a scratch dir
## (tests/snapser_kit/run_tests.gd does; constructing a SnapKitMockGateway does
## too when it is still the default), so test runs never touch the real files.
## Read when a kit object is created, so set it before start().
static var data_root: String = "user://"

## kind ("stats"|"boards"|"events"|"blobs") -> PackedStringArray, only for the
## kinds present in the committed "declared" section.
var declared: Dictionary = {}

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
	env[ENV_TESTS_ONLINE] = OS.get_environment(ENV_TESTS_ONLINE)
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	var main_scene := str(ProjectSettings.get_setting("application/run/main_scene", ""))
	if main_scene != "":
		args.append(main_scene)
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
	if is_test_or_tool_run(args) \
			and not SnapKitJson.to_bool(str(env.get(ENV_TESTS_ONLINE, "")).strip_edges(), false):
		return cfg._set_offline("test/tool run (set %s=1 to allow the network)" % ENV_TESTS_ONLINE)

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


## A kit-owned file path under data_root.
static func data_path(file_name: String) -> String:
	return data_root.path_join(file_name)


## Make sure the directory holding `path` exists (data_root may be a scratch
## dir that does not exist yet). Never needed for plain user:// paths.
static func ensure_dir_for(path: String) -> void:
	var dir := path.get_base_dir()
	if dir != "" and dir != "user://" and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))


## Switch this config offline (idempotent). Returns self for chaining:
##   SnapKitConfig.from_project().force_offline("capture run")
func force_offline(reason: String = "forced offline") -> SnapKitConfig:
	return _set_offline(reason if reason != "" else "forced offline")


## True when any arg names a scene/script under res://tests/ or res://tools/
## (rule 1b). Pass OS.get_cmdline_args() (+ user args, + the main scene).
static func is_test_or_tool_run(args: PackedStringArray) -> bool:
	for a in args:
		var s := str(a).strip_edges()
		for p in TEST_TOOL_PREFIXES:
			if s.begins_with(p) and (p.begins_with("res://") or s.ends_with(".gd") or s.ends_with(".tscn") or s.ends_with(".scn")):
				return true
	return false


## True when `kind` has a "declared" list.
func has_declarations(kind: String) -> bool:
	return declared.has(kind)


## True when `name` is declared for `kind`, or when `kind` is not declared at
## all (no list = no check).
func is_declared(kind: String, name: String) -> bool:
	if not declared.has(kind):
		return true
	return (declared[kind] as PackedStringArray).has(name)


## Cross-check this config against a parsed snapend manifest
## (snapser/snapend-manifest.json). Returns human-readable problems; empty =
## consistent. Checks: every declared stat / board / event / blob exists on the
## manifest; every mapped leaderboard and the cloud-save blob key exist there;
## and, when a kind is declared, every manifest entry of that kind is declared
## (so the lists cannot silently drift).
func declaration_problems(manifest: Dictionary) -> PackedStringArray:
	var on_server := manifest_names(manifest)
	var out := PackedStringArray()
	for kind in DECLARED_KINDS:
		var server: PackedStringArray = on_server[kind]
		if declared.has(kind):
			for n in declared[kind]:
				if not server.has(n):
					out.append("%s '%s' is declared in the config but not on the snapend manifest" % [kind.trim_suffix("s"), n])
			for n in server:
				if not (declared[kind] as PackedStringArray).has(n):
					out.append("%s '%s' is on the snapend manifest but missing from config \"declared.%s\"" % [kind.trim_suffix("s"), n, kind])
	for logical in leaderboards:
		var board := leaderboard_id(str(logical))
		if not (on_server["boards"] as PackedStringArray).has(board):
			out.append("leaderboards['%s'] -> '%s' is not a board on the snapend manifest" % [logical, board])
	if cloud_save_enabled() and not (on_server["blobs"] as PackedStringArray).has(cloud_save_blob_key()):
		out.append("cloud_save blob '%s' is not a storage key on the snapend manifest" % cloud_save_blob_key())
	return out


## Names per kind on a snapend manifest: {stats, boards, events (custom user/app
## events, not snap_* built-ins), blobs}.
static func manifest_names(manifest: Dictionary) -> Dictionary:
	var out := {"stats": PackedStringArray(), "boards": PackedStringArray(),
		"events": PackedStringArray(), "blobs": PackedStringArray()}
	for s in SnapKitJson.get_array(manifest, "settings"):
		var data := SnapKitJson.get_dict(s, "data")
		match SnapKitJson.get_str(s, "id"):
			"statistics":
				for e in SnapKitJson.get_array(data, "statistics"):
					out.stats.append(SnapKitJson.get_str(e, "key"))
			"leaderboards":
				for e in SnapKitJson.get_array(data, "leaderboards"):
					out.boards.append(SnapKitJson.get_str(e, "name"))
			"analytics":
				for e in SnapKitJson.get_array(data, "events"):
					if not SnapKitJson.get_bool(e, "is_snap_event", false):
						out.events.append(SnapKitJson.get_str(e, "name"))
			"storage":
				for e in SnapKitJson.get_array(data, "keys"):
					out.blobs.append(SnapKitJson.get_str(e, "key"))
	return out


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


## cloud_save.sync_prefixes as a PackedStringArray.
func cloud_save_prefixes() -> PackedStringArray:
	var out := PackedStringArray()
	for p in SnapKitJson.get_array(cloud_save, "sync_prefixes"):
		if p is String and p != "":
			out.append(p)
	return out


## cloud_save.sync_keys: exact key names synced alongside the prefixes (for
## legacy keys that share no prefix).
func cloud_save_keys() -> PackedStringArray:
	var out := PackedStringArray()
	for k in SnapKitJson.get_array(cloud_save, "sync_keys"):
		if k is String and k != "" and not out.has(k):
			out.append(k)
	return out


## True when cloud save has anything to sync (prefixes or exact keys).
func cloud_save_enabled() -> bool:
	return not cloud_save_prefixes().is_empty() or not cloud_save_keys().is_empty()


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
	declared = {}
	var decl := SnapKitJson.get_dict(d, "declared")
	for kind in DECLARED_KINDS:
		if decl.get(kind) is Array:
			var names := PackedStringArray()
			for n in decl[kind]:
				if n is String and n != "":
					names.append(n)
			declared[kind] = names


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
