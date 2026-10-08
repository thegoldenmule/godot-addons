// SnapKitAppleSignIn: the native half of addons/snapser_kit_apple.
//
// A thin Godot-facing wrapper around ASAuthorizationController /
// ASAuthorizationAppleIDProvider (Sign in with Apple). One request at a time.
// Results arrive as signals on the main thread (deferred, so they never fire
// from inside the UIKit callback):
//
//   completed(identity_token, authorization_code, user, email)
//   failed(code, message)      code = ASAuthorizationError (1001 = canceled, ...)
//                              or a negative SnapKitAppleSignIn error below.
//
// Game code never touches this class directly; it goes through the GDScript
// SnapKitAppleBridge (addons/snapser_kit_apple/snapkit_apple_bridge.gd).
//
// This header is plain C++ (included by register_types.cpp). All Objective-C
// lives in snapkit_apple_sign_in.mm behind an opaque pointer.

#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace godot {

struct SnapKitAppleSignInImpl;

class SnapKitAppleSignIn : public RefCounted {
	GDCLASS(SnapKitAppleSignIn, RefCounted);

	SnapKitAppleSignInImpl *impl = nullptr;

protected:
	static void _bind_methods();

public:
	// Negative codes used in failed(code, message) for errors raised here
	// rather than by AuthenticationServices.
	enum {
		ERROR_UNEXPECTED_CREDENTIAL = -1,
		ERROR_EMPTY_AUTHORIZATION_CODE = -2,
	};

	// True on iOS (AuthenticationServices exists since iOS 13; our floor is 15).
	bool is_available() const;

	// True between sign_in() and the completed/failed signal.
	bool is_busy() const;

	// Starts a Sign in with Apple request. scopes may contain "email" and/or
	// "full_name". Returns OK, or ERR_BUSY if a request is already in flight.
	Error sign_in(const PackedStringArray &p_scopes);

	// Called by the Objective-C delegate (main thread).
	void _on_completed(const String &p_identity_token, const String &p_authorization_code, const String &p_user, const String &p_email);
	void _on_failed(int64_t p_code, const String &p_message);

	SnapKitAppleSignIn();
	~SnapKitAppleSignIn();
};

} // namespace godot
