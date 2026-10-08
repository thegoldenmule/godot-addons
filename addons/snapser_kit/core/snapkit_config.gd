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
##
## SKELETON: fields + signatures are final for v0.1; bodies are stubs.

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
	var cfg := SnapKitConfig.new()
	cfg.offline_reason = "not implemented"
	return cfg


## Pure resolution core, for unit tests (no file or OS access).
##   committed: parsed committed config ({} if missing)
##   env:       {"SNAPSER_OFFLINE": "...", "SNAPSER_GATEWAY_URL": "..."} subset
##   args:      command-line args (OS.get_cmdline_args() + get_cmdline_user_args())
##   override:  parsed override file ({} if missing)
##   is_debug:  OS.is_debug_build(); the override is ignored when false
static func resolve(committed: Dictionary, env: Dictionary, args: PackedStringArray,
		override: Dictionary, is_debug: bool) -> SnapKitConfig:
	var cfg := SnapKitConfig.new()
	cfg.offline_reason = "not implemented"
	return cfg


## Build directly from a dictionary shaped like the committed file, with no env /
## override resolution. Tests use this to point the kit at a mock gateway:
##   SnapKitConfig.from_dict({"game_id": "t", "gateway_url": "http://mock.invalid"})
## offline = gateway_url is empty or invalid.
static func from_dict(d: Dictionary) -> SnapKitConfig:
	var cfg := SnapKitConfig.new()
	cfg.offline_reason = "not implemented"
	return cfg


## True when a usable gateway is configured and nothing forced offline.
func is_ready() -> bool:
	return false


func is_offline() -> bool:
	return true


## Prefix used for new anonymous handles (anon_handle_prefix, else "<game_id>-",
## else "snapkit-").
func handle_prefix() -> String:
	return ""


## Map a logical board name to its Snapser leaderboard name. Unmapped names pass
## through unchanged so a game may use Snapser names directly.
func leaderboard_id(board: String) -> String:
	return board


## cloud_save.blob_key, default "save_v1".
func cloud_save_blob_key() -> String:
	return ""


## cloud_save.sync_prefixes as a PackedStringArray (empty = cloud save disabled).
func cloud_save_prefixes() -> PackedStringArray:
	return PackedStringArray()


## True when the committed file has a truthy optional "quests" section; gates the
## SnapKitService quests_* passthroughs.
func quests_enabled() -> bool:
	return false


## One-line description for logs and the editor page, e.g.
## "online via committed (https://gateway.snapser.com/...)" or
## "offline: SNAPSER_OFFLINE=1". Never includes secrets (there are none).
func describe() -> String:
	return "not implemented"


## True for an http(s) URL with a host and no placeholder ("<", "{").
static func is_valid_gateway_url(url: String) -> bool:
	return false
