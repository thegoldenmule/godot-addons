class_name SnapKitProfiles
extends RefCounted

## Client for the Snapser Profiles snap (profiles.swagger3.json): the player's
## display name, which leaderboards show (D16).
##
##   GET   /v1/profiles/user/{user_id}   GetProfile
##   PUT   /v1/profiles/user/{user_id}   UpsertProfile
##   PATCH /v1/profiles/user/{user_id}   PatchProfile
##
## Display-name policy (client side; server moderation is a separate concern):
## sanitize_display_name() trims, collapses whitespace, strips control chars,
## clamps to NAME_MAX_LEN, and is_valid_display_name() rejects empty / too-short
## names and a basic word list. default_display_name() derives a stable
## auto-generated name (e.g. "Player 4F2A") from a seed (the user id or handle)
## for players who have not chosen one.
##
## Conventions: see SnapKitStats.
##
## SKELETON (owner: kit-clients agent): signatures final for v0.1; bodies stubbed.

const NAME_MIN_LEN := 3
const NAME_MAX_LEN := 20
const ATTR_DISPLAY_NAME := "display_name"

var _transport: SnapKitTransport


func _init(transport: SnapKitTransport) -> void:
	_transport = transport


## "/v1/profiles/user/{user_id}".
static func profile_path() -> String:
	return ""


## Profile attributes Dictionary from a GetProfile response ({} if none).
static func parse_profile(json: Variant) -> Dictionary:
	return {}


static func sanitize_display_name(raw_name: String) -> String:
	return ""


static func is_valid_display_name(display_name: String) -> bool:
	return false


## Stable default name derived from seed; same seed -> same name.
static func default_display_name(seed: String) -> String:
	return ""


## -> {ok, status, json, error, profile:Dictionary, display_name:String}
## A missing profile (404) is ok:true with profile {} and display_name "".
func fetch_profile() -> Dictionary:
	return SnapKitTransport.not_implemented()


## Sanitize, validate, then upsert. Invalid names -> ERR_INVALID_ARGUMENT, no
## request. -> {..., display_name:String (as stored)}
func set_display_name(display_name: String) -> Dictionary:
	return SnapKitTransport.not_implemented()
