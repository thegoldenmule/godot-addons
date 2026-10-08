// Objective-C++ half of SnapKitAppleSignIn. Compiled with -fobjc-arc.

#include "snapkit_apple_sign_in.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>

#import <AuthenticationServices/AuthenticationServices.h>
#import <UIKit/UIKit.h>

using namespace godot;

static String snapkit_to_string(NSString *p_str) {
	if (p_str == nil) {
		return String();
	}
	return String::utf8([p_str UTF8String]);
}

static String snapkit_data_to_string(NSData *p_data) {
	if (p_data == nil || p_data.length == 0) {
		return String();
	}
	return String::utf8((const char *)p_data.bytes, (int64_t)p_data.length);
}

// The delegate holds the owner's ObjectID, not a pointer, so a request that
// outlives its SnapKitAppleSignIn is dropped instead of touching freed memory.
@interface SnapKitAppleDelegate : NSObject <ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding>
@property(nonatomic, assign) uint64_t ownerId;
@end

@implementation SnapKitAppleDelegate

- (SnapKitAppleSignIn *)owner {
	return Object::cast_to<SnapKitAppleSignIn>(ObjectDB::get_instance(ObjectID(self.ownerId)));
}

- (void)authorizationController:(ASAuthorizationController *)controller didCompleteWithAuthorization:(ASAuthorization *)authorization {
	SnapKitAppleSignIn *owner = [self owner];
	if (owner == nullptr) {
		return;
	}
	if (![authorization.credential isKindOfClass:[ASAuthorizationAppleIDCredential class]]) {
		owner->_on_failed(SnapKitAppleSignIn::ERROR_UNEXPECTED_CREDENTIAL, "unexpected credential type");
		return;
	}
	ASAuthorizationAppleIDCredential *credential = (ASAuthorizationAppleIDCredential *)authorization.credential;
	String code = snapkit_data_to_string(credential.authorizationCode);
	if (code.is_empty()) {
		owner->_on_failed(SnapKitAppleSignIn::ERROR_EMPTY_AUTHORIZATION_CODE, "empty authorization code");
		return;
	}
	owner->_on_completed(
			snapkit_data_to_string(credential.identityToken),
			code,
			snapkit_to_string(credential.user),
			snapkit_to_string(credential.email));
}

- (void)authorizationController:(ASAuthorizationController *)controller didCompleteWithError:(NSError *)error {
	SnapKitAppleSignIn *owner = [self owner];
	if (owner == nullptr) {
		return;
	}
	owner->_on_failed((int64_t)error.code, snapkit_to_string(error.localizedDescription));
}

// The key window of the foreground scene. Godot's iOS app has one window.
- (ASPresentationAnchor)presentationAnchorForAuthorizationController:(ASAuthorizationController *)controller {
	UIWindow *fallback = nil;
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if (![scene isKindOfClass:[UIWindowScene class]]) {
			continue;
		}
		UIWindowScene *window_scene = (UIWindowScene *)scene;
		if (window_scene.keyWindow != nil) {
			return window_scene.keyWindow;
		}
		for (UIWindow *window in window_scene.windows) {
			if (window.isKeyWindow) {
				return window;
			}
			if (fallback == nil) {
				fallback = window;
			}
		}
	}
	if (fallback != nil) {
		return fallback;
	}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	// Apps without a scene manifest: fall back to the legacy window list.
	for (UIWindow *window in UIApplication.sharedApplication.windows) {
		if (window.isKeyWindow) {
			return window;
		}
		if (fallback == nil) {
			fallback = window;
		}
	}
#pragma clang diagnostic pop
	return fallback;
}

@end

namespace godot {

struct SnapKitAppleSignInImpl {
	SnapKitAppleDelegate *delegate = nil; // strong (ARC)
	ASAuthorizationController *controller = nil; // strong; nil when idle
};

void SnapKitAppleSignIn::_bind_methods() {
	ClassDB::bind_method(D_METHOD("is_available"), &SnapKitAppleSignIn::is_available);
	ClassDB::bind_method(D_METHOD("is_busy"), &SnapKitAppleSignIn::is_busy);
	ClassDB::bind_method(D_METHOD("sign_in", "scopes"), &SnapKitAppleSignIn::sign_in, DEFVAL(PackedStringArray()));

	ADD_SIGNAL(MethodInfo("completed",
			PropertyInfo(Variant::STRING, "identity_token"),
			PropertyInfo(Variant::STRING, "authorization_code"),
			PropertyInfo(Variant::STRING, "user"),
			PropertyInfo(Variant::STRING, "email")));
	ADD_SIGNAL(MethodInfo("failed",
			PropertyInfo(Variant::INT, "code"),
			PropertyInfo(Variant::STRING, "message")));
}

SnapKitAppleSignIn::SnapKitAppleSignIn() {
	impl = new SnapKitAppleSignInImpl();
	impl->delegate = [[SnapKitAppleDelegate alloc] init];
	impl->delegate.ownerId = (uint64_t)get_instance_id();
}

SnapKitAppleSignIn::~SnapKitAppleSignIn() {
	if (impl != nullptr) {
		impl->delegate.ownerId = 0;
		if (impl->controller != nil) {
			impl->controller.delegate = nil;
			impl->controller.presentationContextProvider = nil;
		}
		delete impl; // ARC releases the delegate and controller.
		impl = nullptr;
	}
}

bool SnapKitAppleSignIn::is_available() const {
	return true;
}

bool SnapKitAppleSignIn::is_busy() const {
	return impl->controller != nil;
}

Error SnapKitAppleSignIn::sign_in(const PackedStringArray &p_scopes) {
	if (impl->controller != nil) {
		return ERR_BUSY;
	}

	ASAuthorizationAppleIDProvider *provider = [[ASAuthorizationAppleIDProvider alloc] init];
	ASAuthorizationAppleIDRequest *request = [provider createRequest];
	NSMutableArray<ASAuthorizationScope> *scopes = [NSMutableArray array];
	if (p_scopes.has("email")) {
		[scopes addObject:ASAuthorizationScopeEmail];
	}
	if (p_scopes.has("full_name")) {
		[scopes addObject:ASAuthorizationScopeFullName];
	}
	request.requestedScopes = scopes;

	ASAuthorizationController *controller = [[ASAuthorizationController alloc] initWithAuthorizationRequests:@[ request ]];
	controller.delegate = impl->delegate; // weak in UIKit; impl keeps it alive
	controller.presentationContextProvider = impl->delegate;
	impl->controller = controller; // keep alive until a callback arrives
	[controller performRequests];
	return OK;
}

void SnapKitAppleSignIn::_on_completed(const String &p_identity_token, const String &p_authorization_code, const String &p_user, const String &p_email) {
	impl->controller = nil;
	call_deferred("emit_signal", "completed", p_identity_token, p_authorization_code, p_user, p_email);
}

void SnapKitAppleSignIn::_on_failed(int64_t p_code, const String &p_message) {
	impl->controller = nil;
	call_deferred("emit_signal", "failed", p_code, p_message);
}

} // namespace godot
