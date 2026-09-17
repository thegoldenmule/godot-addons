@tool
extends RefCounted

## Maps raw pipeline output (Godot export, xcodebuild archive/upload, adb
## install) to a human diagnosis + the exact next action. This is the "walk
## you through it" half of the tool: every known failure signature observed
## in real runs gets a title and step-by-step guidance instead of a wall of
## log output.
##
## Rules are ordered most-specific-first; classify() returns the first match
## whose `platforms` includes the caller's platform ("ios"/"android"; absent
## `platforms` = both — most rules are platform-neutral or the platform is
## implied by the failure signature itself). `context` may carry bundle_id /
## team_id, spliced into the guidance text.


static func rules() -> Array:
	return [
		{
			"id": "no_dist_cert",
			"patterns": ["No signing certificate \"iOS Distribution\"", "No signing certificate \"Apple Distribution\""],
			"title": "No distribution certificate in the keychain",
			"guidance": "1. Xcode → Settings → Accounts → select team {team_id}\n2. Manage Certificates… → ＋ (bottom-left) → Apple Distribution\n3. Press the build button again.",
			"links": [{"label": "Open Xcode", "url": "/Applications/Xcode.app"}],
			"platforms": ["ios"],
		},
		{
			"id": "missing_app_record",
			"patterns": ["DistributionAppRecordProviderError.missingApp", "Error Downloading App Information"],
			"title": "No App Store Connect app record for this bundle id",
			"guidance": "App creation is not in Apple's public API — this is a one-time manual step (~2 min):\n1. Open App Store Connect → My Apps → ＋ → New App\n2. Platform: iOS. Name: must be unique across the App Store.\n3. Bundle ID: pick {bundle_id} from the dropdown (already registered — signing did that).\n4. SKU: any internal id. Then press the build button again.",
			"links": [{"label": "Open My Apps", "url": "https://appstoreconnect.apple.com/apps"}],
			"platforms": ["ios"],
		},
		{
			"id": "signing_conflict",
			"patterns": ["conflicting provisioning settings"],
			"title": "Automatic signing conflicts with a pinned signing identity",
			"guidance": "The generated Xcode project pins a code-sign identity that fights automatic signing. Build Kit normally overrides this with CODE_SIGN_STYLE=Automatic + CODE_SIGN_IDENTITY=\"Apple Development\" — if you are seeing this, the override was bypassed; re-run the build from the Build Kit panel.",
			"platforms": ["ios"],
		},
		{
			"id": "not_signed_in",
			"patterns": ["No Accounts", "Your session has expired", "No Apple ID", "requires a development team", "Signing for \"", "No signing certificate"],
			"title": "No usable Apple account / team for signing",
			"guidance": "Either sign into Xcode (Xcode → Settings → Accounts → ＋, then select team {team_id}) or drop an App Store Connect API key (.p8) on the preflight row — it saves ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH to your gitignored .env, works headless, and never expires like a login session.",
			"links": [{"label": "Create API key", "url": "https://appstoreconnect.apple.com/access/integrations/api"}],
			"platforms": ["ios"],
		},
		{
			"id": "cloud_signing_permission",
			"patterns": ["Cloud signing permission error"],
			"title": "The API key can't manage signing (role too low)",
			"guidance": "1. ↗ Open Integrations → find key {key_id} — its role must be App Manager (Developer keys can't cloud-sign)\n2. Roles can't be edited: revoke it, create a new key with role App Manager, drop the new .p8 on this panel\n3. Or simply stay signed into Xcode — a login session is used automatically when available.",
			"links": [{"label": "Open Integrations", "url": "https://appstoreconnect.apple.com/access/integrations/api"}],
			"platforms": ["ios"],
		},
		{
			"id": "profile_missing_cert",
			"patterns": ["doesn't include signing certificate"],
			"title": "The managed profile predates your certificate",
			"guidance": "1. Press the build button again — with working auth the managed profile regenerates to include the certificate\n2. If it repeats, the auth in use can't regenerate it: see the 'auth:' line at the top of the log (an API key must be role App Manager).",
			"platforms": ["ios"],
		},
		{
			"id": "no_profiles",
			"patterns": ["No profiles for", "Provisioning profile", "profile doesn't match"],
			"title": "Provisioning profile problem",
			"guidance": "1. Press the build button again (automatic signing regenerates profiles)\n2. If it repeats: ↗ Open Identifiers — {bundle_id} must be listed under team {team_id}\n3. If the app uses push/iCloud/etc., enable that capability on the App ID there first.",
			"links": [{"label": "Open Identifiers", "url": "https://developer.apple.com/account/resources/identifiers/list"}],
			"platforms": ["ios"],
		},
		{
			"id": "export_config_errors",
			"patterns": ["due to configuration errors"],
			"title": "Godot rejected the export configuration",
			"guidance": "Godot hides the specific reasons in headless runs (often an empty list, as above).\n1. Press Refresh in Preflight — the known causes (ETC2/ASTC imports off, incomplete preset) appear there with a Fix\n2. Still failing: open Project → Export in the editor — the dialog shows the actual errors.",
		},
		{
			"id": "no_export_templates",
			"patterns": ["No export template", "export templates"],
			"title": "Godot export failed",
			"guidance": "Check the export templates are installed for this exact Godot version (the preflight templates row has a Fix), and that the export preset exists. The full Godot output is in the log above.",
		},
		{
			"id": "asc_auth",
			"patterns": ["Failed to authenticate", "authentication credentials", "NOT_AUTHORIZED", "401"],
			"title": "App Store Connect authentication failed",
			"guidance": "The configured API key was rejected. Re-check ASC_KEY_ID, ASC_ISSUER_ID and that ASC_KEY_PATH points at the downloaded .p8 in your .env (App Store Connect → Users and Access → Integrations). The key needs the App Manager (or Developer) role.",
			"links": [{"label": "Open Integrations", "url": "https://appstoreconnect.apple.com/access/integrations/api"}],
			"platforms": ["ios"],
		},
		{
			"id": "network",
			"patterns": ["Communication with Apple failed", "The network connection was lost", "timed out"],
			"title": "Network problem talking to Apple",
			"guidance": "Transient — check connectivity and retry the build.",
			"platforms": ["ios"],
		},
		{
			"id": "upload_failed",
			"patterns": ["error: exportArchive", "** EXPORT FAILED **"],
			"title": "Archive export/upload failed",
			"guidance": "xcodebuild rejected the export. The detailed reason is in the .xcdistributionlogs bundle whose path appears in the log above (IDEDistribution.standard.log names the failing step).",
			"platforms": ["ios"],
		},
		{
			"id": "archive_failed",
			"patterns": ["** ARCHIVE FAILED **"],
			"title": "xcodebuild archive failed",
			"guidance": "See the compiler/signing errors in the log above; the last 'error:' line is the actual cause.",
			"platforms": ["ios"],
		},
		{
			"id": "install_update_incompatible",
			"patterns": ["INSTALL_FAILED_UPDATE_INCOMPATIBLE"],
			"title": "Installed build was signed with a different key",
			"guidance": "1. adb uninstall the existing app from the device\n2. Press the build button again.",
			"platforms": ["android"],
		},
		{
			"id": "apksigner_missing",
			"patterns": ["'apksigner' could not be found", "'apksigner' returned with error", "'apksigner' verification of APK failed", "All 'apksigner' tools located in Android SDK 'build-tools' directory failed"],
			"title": "APK is unsigned — apksigner missing from the SDK",
			"guidance": "See the Android SDK preflight row — apksigner ships in the SDK's build-tools directory.",
			"platforms": ["android"],
		},
		{
			"id": "device_unauthorized",
			"patterns": ["device unauthorized", "unauthorized"],
			"title": "Device hasn't accepted the debugging prompt",
			"guidance": "On the device, accept the \"Allow USB debugging\" RSA fingerprint prompt, then press the build button again.",
			"platforms": ["android"],
		},
		{
			"id": "no_devices",
			"patterns": ["no devices/emulators found"],
			"title": "No Android device connected",
			"guidance": "Plug in a device with USB debugging enabled, or start an emulator, then press the build button again.",
			"platforms": ["android"],
		},
		{
			"id": "install_insufficient_storage",
			"patterns": ["INSTALL_FAILED_INSUFFICIENT_STORAGE"],
			"title": "Not enough storage on the device",
			"guidance": "Free up space on the device, then press the build button again.",
			"platforms": ["android"],
		},
		{
			"id": "install_version_downgrade",
			"patterns": ["INSTALL_FAILED_VERSION_DOWNGRADE"],
			"title": "Installed build is newer than this export",
			"guidance": "adb uninstall the existing app from the device, then press the build button again.",
			"platforms": ["android"],
		},
		{
			"id": "android_sdk_missing",
			"patterns": ["A valid Android SDK path is required in Editor Settings."],
			"title": "Android SDK not configured",
			"guidance": "See the Android SDK preflight row (it has a Fix when an SDK is found at the conventional install location).",
			"platforms": ["android"],
		},
		{
			"id": "android_jdk_missing",
			"patterns": ["A valid Java SDK path is required in Editor Settings."],
			"title": "Java SDK not configured",
			"guidance": "See the Java SDK preflight row (it has a Fix when a JDK is found via JAVA_HOME or Android Studio's bundled runtime).",
			"platforms": ["android"],
		},
	]


## Returns {id, title, guidance, links} — falls back to a generic entry when
## nothing matches, so callers always get something presentable. `links` is an
## Array of {label, url} the dock renders as open-in-browser buttons.
static func classify(log_text: String, context: Dictionary = {}, platform := "") -> Dictionary:
	for rule in rules():
		var platforms: Array = rule.get("platforms", [])
		if not platforms.is_empty() and not platforms.has(platform):
			continue
		for p in rule["patterns"]:
			if log_text.contains(p):
				return {
					"id": rule["id"],
					"title": rule["title"],
					"guidance": _fill(rule["guidance"], context),
					"links": rule.get("links", []),
				}
	return {
		"id": "unknown",
		"title": "Build step failed",
		"guidance": "No known failure signature matched — read the tail of the log above for the first 'error:' line.",
		"links": [],
	}


static func _fill(text: String, context: Dictionary) -> String:
	var out := text
	for key in context:
		out = out.replace("{%s}" % key, str(context[key]))
	return out
