extends SceneTree

## Headless tests for addons/snapser_kit_apple on a non-iOS host:
##
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##       --script res://tests/snapser_kit_apple/run_tests.gd
##
## Covers the bridge's non-iOS path, its iOS flow against a fake native object
## (result mapping, busy handling), the identity-bridge interface the kit
## duck-types, the export plugin's pure helpers, and the packaging invariants
## (the iOS GDExtension is hidden from the editor scan and matches the export
## plugin). The real Apple flow needs a device; see the addon README.

const BRIDGE := "res://addons/snapser_kit_apple/snapkit_apple_bridge.gd"
const EXPORT_PLUGIN := "res://addons/snapser_kit_apple/snapkit_apple_export_plugin.gd"
const IOS_DIR := "res://addons/snapser_kit_apple/ios"

# Stands in for the native SnapKitAppleSignIn: same method and signals.
class FakeNative:
	extends RefCounted
	signal completed(identity_token: String, authorization_code: String, user: String, email: String)
	signal failed(code: int, message: String)
	var next_error := OK
	var outcome: Array = []  # ["completed", a, b, c, d] or ["failed", code, msg]
	var calls := 0
	var last_scopes := PackedStringArray()

	func sign_in(scopes: PackedStringArray) -> int:
		calls += 1
		last_scopes = scopes
		if next_error != OK:
			return next_error
		_emit.call_deferred()
		return OK

	func _emit() -> void:
		if outcome.is_empty():
			return  # stays in flight until finish() is called
		finish()

	func finish() -> void:
		if outcome[0] == "completed":
			completed.emit(outcome[1], outcome[2], outcome[3], outcome[4])
		else:
			failed.emit(outcome[1], outcome[2])


# The bridge with the platform check forced to iOS.
class IosBridge:
	extends SnapKitAppleBridge
	func _is_ios() -> bool:
		return true


var _passed := 0
var _failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await _test_non_ios_returns_unsupported_platform()
	await _test_repeated_calls_stay_unsupported()
	await _test_ios_success_returns_authorization_code()
	await _test_ios_cancel_maps_error()
	await _test_ios_busy_while_in_flight()
	await _test_ios_native_start_error()
	await _test_ios_without_native_library()
	_test_bridge_interface()
	_test_native_class_not_loaded_on_desktop()
	_test_error_names()
	_test_gdextension_hidden_and_consistent()
	_test_export_plugin_helpers()
	print("SNAPKIT APPLE TESTS: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _check(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("  ok   %s" % label)
	else:
		_failed += 1
		print("  FAIL %s" % label)


func _test_non_ios_returns_unsupported_platform() -> void:
	_check(OS.get_name() != "iOS", "host is not iOS (precondition)")
	var bridge: RefCounted = load(BRIDGE).new()
	var r: Dictionary = await bridge.get_identity_token()
	_check(r.get("ok") == false, "non-iOS: ok == false")
	_check(r.get("error") == "unsupported_platform", "non-iOS: error == unsupported_platform (got %s)" % r.get("error"))
	_check(r.get("token") == "", "non-iOS: token is empty")
	_check(r.has("ok") and r.has("token") and r.has("error"), "non-iOS: result has ok, token, error")


func _test_repeated_calls_stay_unsupported() -> void:
	var bridge: RefCounted = load(BRIDGE).new()
	for i in 3:
		var r: Dictionary = await bridge.get_identity_token()
		_check(r.get("error") == "unsupported_platform", "non-iOS call %d: unsupported_platform, never busy" % (i + 1))


func _ios_bridge(fake: FakeNative) -> SnapKitAppleBridge:
	var bridge := IosBridge.new()
	bridge._native = fake
	return bridge


func _test_ios_success_returns_authorization_code() -> void:
	var fake := FakeNative.new()
	fake.outcome = ["completed", "id.jwt.token", "c0de-single-use", "001234.abcd", "x@privaterelay.appleid.com"]
	var r: Dictionary = await _ios_bridge(fake).get_identity_token()
	_check(r.get("ok") == true, "iOS success: ok == true")
	_check(r.get("token") == "c0de-single-use", "iOS success: token is the AUTHORIZATION CODE (contract item 10)")
	_check(r.get("error") == "", "iOS success: error is empty")
	_check(r.get("identity_token") == "id.jwt.token", "iOS success: identity_token extra")
	_check(r.get("user") == "001234.abcd" and r.get("email") == "x@privaterelay.appleid.com", "iOS success: user and email extras")
	_check(fake.calls == 1 and fake.last_scopes == PackedStringArray(["email"]), "iOS success: one sign_in call with default scopes")


func _test_ios_cancel_maps_error() -> void:
	var fake := FakeNative.new()
	fake.outcome = ["failed", 1001, "The user canceled."]
	var bridge := _ios_bridge(fake)
	var r: Dictionary = await bridge.get_identity_token()
	_check(r.get("ok") == false and r.get("error") == "canceled", "iOS 1001: error == canceled")
	_check(r.get("token") == "" and r.get("code") == 1001, "iOS 1001: empty token, code 1001")
	fake.outcome = ["failed", 1000, "x"]
	r = await bridge.get_identity_token()
	_check(r.get("error") == "unknown", "iOS: bridge usable again after a failure (1000 -> unknown)")


func _test_ios_busy_while_in_flight() -> void:
	var fake := FakeNative.new()  # empty outcome: request stays in flight
	var bridge := _ios_bridge(fake)
	var box := {}
	var first := func() -> void:
		box["r"] = await bridge.get_identity_token()
	first.call()
	await process_frame
	var second: Dictionary = await bridge.get_identity_token()
	_check(second.get("error") == "busy", "iOS: second call while in flight -> busy")
	_check(fake.calls == 1, "iOS: busy call does not reach native")
	fake.outcome = ["completed", "", "code-2", "u", ""]
	fake.finish()
	await process_frame
	_check(box.get("r", {}).get("token") == "code-2", "iOS: first call resolves after the native callback")


func _test_ios_native_start_error() -> void:
	var fake := FakeNative.new()
	fake.next_error = ERR_BUSY
	var r: Dictionary = await _ios_bridge(fake).get_identity_token()
	_check(r.get("error") == "busy", "iOS: native ERR_BUSY -> busy")
	fake.next_error = ERR_CANT_CREATE
	r = await _ios_bridge(fake).get_identity_token()
	_check(r.get("error") == "start_failed", "iOS: other native error -> start_failed")


func _test_ios_without_native_library() -> void:
	var r: Dictionary = await IosBridge.new().get_identity_token()
	_check(r.get("ok") == false and r.get("error") == "native_missing", "iOS without the native library -> native_missing (got %s)" % r.get("error"))


# What SnapKitService.register_identity_provider(name, bridge) relies on.
func _test_bridge_interface() -> void:
	var bridge: Object = load(BRIDGE).new()
	_check(bridge.has_method("get_identity_token"), "bridge has get_identity_token()")
	_check(bridge is RefCounted, "bridge is RefCounted (the kit holds the reference)")
	_check(SnapKitAppleBridge != null, "class_name SnapKitAppleBridge is registered")
	_check(SnapKitAppleBridge.is_supported() == false, "is_supported() is false off iOS")
	_check(bridge.get("scopes") == PackedStringArray(["email"]), "default scopes == [email]")


func _test_native_class_not_loaded_on_desktop() -> void:
	_check(not ClassDB.class_exists(&"SnapKitAppleSignIn"), "native class absent on desktop")
	var loaded := GDExtensionManager.get_loaded_extensions()
	var found := false
	for path in loaded:
		if path.contains("snapser_kit_apple"):
			found = true
	_check(not found, "snapser_kit_apple GDExtension not loaded on desktop")


func _test_error_names() -> void:
	_check(SnapKitAppleBridge.error_name(1001) == "canceled", "1001 -> canceled")
	_check(SnapKitAppleBridge.error_name(1000) == "unknown", "1000 -> unknown")
	_check(SnapKitAppleBridge.error_name(1004) == "failed", "1004 -> failed")
	_check(SnapKitAppleBridge.error_name(-2) == "empty_authorization_code", "-2 -> empty_authorization_code")
	_check(SnapKitAppleBridge.error_name(4242) == "apple_error", "unknown code -> apple_error")


func _test_gdextension_hidden_and_consistent() -> void:
	_check(FileAccess.file_exists(IOS_DIR.path_join(".gdignore")), "ios/ has .gdignore (no desktop load errors)")
	var cfg := ConfigFile.new()
	var err := cfg.load(IOS_DIR.path_join("snapser_kit_apple.gdextension"))
	_check(err == OK, "ios/snapser_kit_apple.gdextension parses")
	var plugin: Script = load(EXPORT_PLUGIN)
	var consts := plugin.get_script_constant_map()
	_check(cfg.get_value("configuration", "entry_symbol", "") == consts["ENTRY_SYMBOL"], "entry_symbol matches the export plugin")
	_check(cfg.get_value("configuration", "compatibility_minimum", "") == "4.7", "compatibility_minimum == 4.7")
	var lib: String = cfg.get_value("libraries", "ios", "")
	_check(lib == consts["XCFRAMEWORK_PATH"], "libraries/ios matches the export plugin")
	_check(FileAccess.file_exists(lib.path_join("Info.plist")), "xcframework is present (Info.plist)")
	_check(FileAccess.file_exists(lib.path_join("ios-arm64/libsnapser_kit_apple.ios.template_release.arm64.a")), "xcframework has the ios-arm64 static library")
	_check(consts["GDEXTENSION_PATH"] == load(BRIDGE).get_script_constant_map()["GDEXTENSION_PATH"], "bridge and export plugin agree on the .gdextension path")


func _test_export_plugin_helpers() -> void:
	var plugin: Script = load(EXPORT_PLUGIN)
	var good := "<key>com.apple.developer.applesignin</key><array><string>Default</string></array>"
	_check(plugin.has_siwa_entitlement(good), "entitlement detected")
	_check(not plugin.has_siwa_entitlement(""), "empty entitlements -> missing")
	_check(not plugin.has_siwa_entitlement("<key>com.apple.developer.game-center</key><true/>"), "other entitlement -> missing")
	var code: String = plugin.registration_cpp_code("snapser_kit_apple_init")
	_check(code.contains("register_dynamic_symbol((char *)\"snapser_kit_apple_init\", (void *)snapser_kit_apple_init)"), "registration code registers the entry symbol")
	_check(not code.contains("$ENTRY"), "registration code has no unreplaced placeholders")
