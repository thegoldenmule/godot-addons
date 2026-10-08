@tool
extends EditorExportPlugin

## Adds Sign in with Apple to iOS exports.
##
## The GDExtension lives in ios/, which has a .gdignore so the editor never
## scans or loads it (an iOS-only .gdextension makes every desktop editor and
## Web/desktop build log "No GDExtension library found" on startup). So this
## plugin does by hand what Godot's built-in GDExtension export plugin would do
## for a static .xcframework, and only for iOS:
##   - links the .xcframework and registers its entry symbol,
##   - packs the .gdextension into the PCK so SnapKitAppleBridge can load it,
##   - links AuthenticationServices.framework.
## The Sign in with Apple entitlement stays in the preset
## (entitlements/additional); this plugin only warns when it's missing.

const GDEXTENSION_PATH := "res://addons/snapser_kit_apple/ios/snapser_kit_apple.gdextension"
const XCFRAMEWORK_PATH := "res://addons/snapser_kit_apple/ios/snapser_kit_apple.xcframework"
const ENTRY_SYMBOL := "snapser_kit_apple_init"
const FRAMEWORK := "AuthenticationServices.framework"
const ENTITLEMENT := "com.apple.developer.applesignin"


func _get_name() -> String:
	return "SnapKitApple"


func _supports_platform(platform: EditorExportPlatform) -> bool:
	return platform.get_os_name() == "iOS"


func _export_begin(features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	if not features.has("ios"):
		return
	add_shared_object(XCFRAMEWORK_PATH, PackedStringArray(["ios"]), "")
	add_apple_embedded_platform_cpp_code(registration_cpp_code(ENTRY_SYMBOL))
	add_apple_embedded_platform_linker_flags("-Wl,-U,_" + ENTRY_SYMBOL)
	add_apple_embedded_platform_framework(FRAMEWORK)
	add_file(GDEXTENSION_PATH, FileAccess.get_file_as_bytes(GDEXTENSION_PATH), false)

	var additional = get_option("entitlements/additional")
	if not has_siwa_entitlement(str(additional) if additional != null else ""):
		push_warning("snapser_kit_apple: the iOS preset's entitlements/additional has no %s entry, so Sign in with Apple will fail with ASAuthorizationError 1000. See addons/snapser_kit_apple/README.md." % ENTITLEMENT)


## True when an entitlements/additional string carries the SIWA entitlement.
static func has_siwa_entitlement(additional: String) -> bool:
	return additional.contains("<key>%s</key>" % ENTITLEMENT)


## The static-library registration code Godot's own GDExtension export plugin
## generates for .xcframework libraries (editor/export/gdextension_export_plugin.h,
## Godot 4.7.1). It registers the entry symbol so GDExtensionManager can find
## it in the app binary at runtime.
static func registration_cpp_code(entry: String) -> String:
	var code := "extern void register_dynamic_symbol(char *name, void *address);\n" \
			+ "extern void add_apple_embedded_platform_init_callback(void (*cb)());\n" \
			+ "\n" \
			+ "extern \"C\" void $ENTRY();\n" \
			+ "void $ENTRY_init() {\n" \
			+ "  if (&$ENTRY) register_dynamic_symbol((char *)\"$ENTRY\", (void *)$ENTRY);\n" \
			+ "}\n" \
			+ "struct $ENTRY_struct {\n" \
			+ "  $ENTRY_struct() {\n" \
			+ "    add_apple_embedded_platform_init_callback($ENTRY_init);\n" \
			+ "  }\n" \
			+ "};\n" \
			+ "$ENTRY_struct $ENTRY_struct_instance;\n\n"
	return code.replace("$ENTRY", entry)
