// GDExtension entry point for addons/snapser_kit_apple.
// The entry symbol name must match ios/snapser_kit_apple.gdextension
// [configuration] entry_symbol, and the export plugin's registration code.

#include "snapkit_apple_sign_in.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static void snapser_kit_apple_initialize(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(SnapKitAppleSignIn);
}

static void snapser_kit_apple_uninitialize(ModuleInitializationLevel p_level) {
}

extern "C" {

GDExtensionBool GDE_EXPORT snapser_kit_apple_init(GDExtensionInterfaceGetProcAddress p_get_proc_address, const GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(snapser_kit_apple_initialize);
	init_obj.register_terminator(snapser_kit_apple_uninitialize);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}

}
