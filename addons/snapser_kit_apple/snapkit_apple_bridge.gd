class_name SnapKitAppleBridge
extends RefCounted

## Sign in with Apple identity bridge for snapser_kit.
##
## Implements the identity-bridge interface that
## SnapKitService.register_identity_provider(name, bridge) expects:
##
##   var apple := SnapKitAppleBridge.new()
##   Snapser.register_identity_provider("apple", apple)
##   ...
##   var r: Dictionary = await apple.get_identity_token()
##   # r = {ok, token, error, ...extras}
##
## `token` is the Apple **authorization code**, not the identity token: the
## Snapser Apple connector exchanges the code with Apple itself. The code is
## single-use and expires after about 5 minutes, so send it straight to
## `login/apple` and never retry that call.
##
## Only works on iOS. Everywhere else get_identity_token() returns
## {ok:false, token:"", error:"unsupported_platform"} without touching native
## code, so games can register the bridge unconditionally.
##
## The native class (SnapKitAppleSignIn) lives in ios/, which carries a
## .gdignore so desktop editors and Web/desktop builds never try to load an
## iOS-only GDExtension. The export plugin packs it into iOS builds, and this
## bridge loads it on first use.

## Errors this bridge returns in `error`:
##   unsupported_platform  not running on iOS
##   native_missing        iOS build without the native library (plugin disabled at export?)
##   busy                  a sign-in is already in progress
##   start_failed          the native sign_in() call returned an error (see code/message)
##   canceled              the player dismissed the Apple sheet (ASAuthorizationError 1001)
##   unknown               ASAuthorizationError 1000; usually the entitlement or App ID capability is missing
##   invalid_response / not_handled / failed / not_interactive   ASAuthorizationError 1002–1005
##   unexpected_credential Apple returned a non-Apple-ID credential
##   empty_authorization_code
##   apple_error           any other code; see `code` and `message`

const NATIVE_CLASS := &"SnapKitAppleSignIn"
const GDEXTENSION_PATH := "res://addons/snapser_kit_apple/ios/snapser_kit_apple.gdextension"

const ERROR_NAMES := {
	1000: "unknown",
	1001: "canceled",
	1002: "invalid_response",
	1003: "not_handled",
	1004: "failed",
	1005: "not_interactive",
	-1: "unexpected_credential",
	-2: "empty_authorization_code",
}

signal _finished(result: Dictionary)

## Scopes to request: "email" and/or "full_name". Apple only returns them on
## the first authorization for this App ID; later sign-ins return "".
var scopes: PackedStringArray = PackedStringArray(["email"])

# SnapKitAppleSignIn, created on first use. Tests may preset a double with the
# same sign_in(scopes) method and completed/failed signals.
var _native: Object = null
var _busy := false


## True when Sign in with Apple can run here (iOS with the native library).
## Loads the native library on iOS as a side effect.
static func is_supported() -> bool:
	return OS.get_name() == "iOS" and _ensure_native_class()


## Map an ASAuthorizationError / native error code to this bridge's error string.
static func error_name(code: int) -> String:
	return ERROR_NAMES.get(code, "apple_error")


## -> {ok, token, error} plus extras: on success identity_token, user, email;
## on an Apple failure code and message.
func get_identity_token() -> Dictionary:
	if not _is_ios():
		return _fail("unsupported_platform")
	if _native == null:
		if not _ensure_native_class():
			return _fail("native_missing")
		_native = ClassDB.instantiate(NATIVE_CLASS)
	if _busy:
		return _fail("busy")
	if not _native.is_connected("completed", _on_completed):
		_native.connect("completed", _on_completed)
		_native.connect("failed", _on_failed)

	_busy = true
	var err: int = _native.call("sign_in", scopes)
	if err != OK:
		_busy = false
		return _fail("busy" if err == ERR_BUSY else "start_failed", err, error_string(err))
	var result: Dictionary = await _finished
	_busy = false
	return result


# Overridden by tests to exercise the iOS path on a desktop host.
func _is_ios() -> bool:
	return OS.get_name() == "iOS"


static func _ensure_native_class() -> bool:
	if ClassDB.class_exists(NATIVE_CLASS):
		return true
	# The GDExtension only has an iOS library; loading it anywhere else only
	# logs "No GDExtension library found".
	if OS.get_name() != "iOS" or not FileAccess.file_exists(GDEXTENSION_PATH):
		return false
	GDExtensionManager.load_extension(GDEXTENSION_PATH)
	return ClassDB.class_exists(NATIVE_CLASS)


static func _fail(error: String, code: int = 0, message: String = "") -> Dictionary:
	var out := {"ok": false, "token": "", "error": error}
	if code != 0:
		out["code"] = code
		out["message"] = message
	return out


func _on_completed(identity_token: String, authorization_code: String, user: String, email: String) -> void:
	_finished.emit({
		"ok": true,
		"token": authorization_code,
		"error": "",
		"identity_token": identity_token,
		"user": user,
		"email": email,
	})


func _on_failed(code: int, message: String) -> void:
	_finished.emit(_fail(error_name(code), code, message))
