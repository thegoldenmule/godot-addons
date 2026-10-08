class_name SnapKitRemoteConfig
extends RefCounted

## Client for the Snapser Remote Config snap (remote-config.swagger3.json).
##
##   GET /v1/remote-config/app-config/{version}   GetAppConfig -> {config:object}
##
## fetch_app_config() returns the published app config as a Dictionary. The snap
## has no client write API; config is published from the Snapser console (or the
## remote_config_editor addon). Game-specific extraction (e.g. daily missions)
## lives in the game; extract_block() is the generic accessor — each feature
## reads its own sibling key, so features never disturb each other's payloads.
##
## Conventions: see SnapKitStats.

const APP_CONFIG_VERSION := "v1"
const BASE_PATH := "/v1/remote-config/app-config"

var _transport: SnapKitTransport


func _init(transport: SnapKitTransport) -> void:
	_transport = transport


static func app_config_path(version: String = APP_CONFIG_VERSION) -> String:
	return "%s/%s" % [BASE_PATH, version.uri_encode()]


## Normalize a GetAppConfig response into the config Dictionary ({} if unusable).
static func parse_app_config(json: Variant) -> Dictionary:
	return SnapKitJson.get_dict(json, "config")


## config[key] if it is a Dictionary, else {}.
static func extract_block(config: Dictionary, key: String) -> Dictionary:
	return SnapKitJson.get_dict(config, key)


## -> {ok, status, json, error, config:Dictionary}. A 2xx without a usable
## config object is ok:false, error "bad_response".
func fetch_app_config(version: String = APP_CONFIG_VERSION) -> Dictionary:
	if version == "":
		var bad := SnapKitTransport.error_result(SnapKitTransport.ERR_INVALID_ARGUMENT)
		bad["config"] = {}
		return bad
	var res: Dictionary = await _transport.request(HTTPClient.METHOD_GET, app_config_path(version))
	res["config"] = {}
	if res.ok:
		if not (SnapKitJson.dig(res.json, ["config"]) is Dictionary):
			res.ok = false
			res.error = SnapKitTransport.ERR_BAD_RESPONSE
		else:
			res["config"] = parse_app_config(res.json)
	return res
