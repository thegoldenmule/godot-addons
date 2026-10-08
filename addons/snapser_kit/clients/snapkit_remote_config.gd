class_name SnapKitRemoteConfig
extends RefCounted

## Client for the Snapser Remote Config snap (remote-config.swagger3.json).
##
##   GET /v1/remote-config/app-config/{version}   GetAppConfig
##
## fetch_app_config() returns the published app config as a Dictionary.
## Game-specific extraction (e.g. daily missions) lives in the game or in an
## opt-in helper, not here; extract_block() is the generic accessor.
##
## Conventions: see SnapKitStats.
##
## SKELETON (owner: kit-clients agent): signatures final for v0.1; bodies stubbed.

const APP_CONFIG_VERSION := "v1"

var _transport: SnapKitTransport


func _init(transport: SnapKitTransport) -> void:
	_transport = transport


static func app_config_path(version: String = APP_CONFIG_VERSION) -> String:
	return ""


## Normalize a GetAppConfig response into the config Dictionary ({} if unusable).
static func parse_app_config(json: Variant) -> Dictionary:
	return {}


## config[key] if it is a Dictionary, else {}.
static func extract_block(config: Dictionary, key: String) -> Dictionary:
	return {}


## -> {ok, status, json, error, config:Dictionary}
func fetch_app_config(version: String = APP_CONFIG_VERSION) -> Dictionary:
	return SnapKitTransport.not_implemented()
