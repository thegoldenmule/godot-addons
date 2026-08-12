@tool
extends RefCounted

## Maps raw pipeline output (Godot export, xcodebuild archive/upload) to a
## human diagnosis + the exact next action. This is the "walk you through it"
## half of the tool: every known failure signature observed in real runs gets a
## title and step-by-step guidance instead of a wall of xcodebuild log.
##
## Rules are ordered most-specific-first; classify() returns the first match.
## `context` may carry bundle_id / team_id, spliced into the guidance text.


static func rules() -> Array:
	return [
		{
			"id": "no_dist_cert",
			"patterns": ["No signing certificate \"iOS Distribution\"", "No signing certificate \"Apple Distribution\""],
			"title": "No distribution certificate in the keychain",
			"guidance": "1. Xcode → Settings → Accounts → select team {team_id}\n2. Manage Certificates… → ＋ (bottom-left) → Apple Distribution\n3. Press the build button again.",
			"links": [{"label": "Open Xcode", "url": "/Applications/Xcode.app"}],
		},
		{
			"id": "missing_app_record",
			"patterns": ["DistributionAppRecordProviderError.missingApp", "Error Downloading App Information"],
			"title": "No App Store Connect app record for this bundle id",
			"guidance": "App creation is not in Apple's public API — this is a one-time manual step (~2 min):\n1. Open App Store Connect → My Apps → ＋ → New App\n2. Platform: iOS. Name: must be unique across the App Store.\n3. Bundle ID: pick {bundle_id} from the dropdown (already registered — signing did that).\n4. SKU: any internal id. Then press the build button again.",
			"links": [{"label": "Open My Apps", "url": "https://appstoreconnect.apple.com/apps"}],
		},
		{
			"id": "signing_conflict",
			"patterns": ["conflicting provisioning settings"],
			"title": "Automatic signing conflicts with a pinned signing identity",
			"guidance": "The generated Xcode project pins a code-sign identity that fights automatic signing. Build Kit normally overrides this with CODE_SIGN_STYLE=Automatic + CODE_SIGN_IDENTITY=\"Apple Development\" — if you are seeing this, the override was bypassed; re-run the build from the Build Kit panel.",
		},
		{
			"id": "not_signed_in",
			"patterns": ["No Accounts", "Your session has expired", "No Apple ID", "requires a development team", "Signing for \"", "No signing certificate"],
			"title": "No usable Apple account / team for signing",
			"guidance": "Either sign into Xcode (Xcode → Settings → Accounts → ＋, then select team {team_id}) or configure an App Store Connect API key in build_kit.config.json (asc_key_id / asc_issuer_id / asc_key_path) — the API key also works headless and never expires like a login session.",
			"links": [{"label": "Create API key", "url": "https://appstoreconnect.apple.com/access/integrations/api"}],
		},
		{
			"id": "cloud_signing_permission",
			"patterns": ["Cloud signing permission error"],
			"title": "The API key can't manage signing (role too low)",
			"guidance": "1. ↗ Open Integrations → find key {key_id} — its role must be App Manager (Developer keys can't cloud-sign)\n2. Roles can't be edited: revoke it, create a new key with role App Manager, drop the new .p8 on this panel\n3. Or simply stay signed into Xcode — a login session is used automatically when available.",
			"links": [{"label": "Open Integrations", "url": "https://appstoreconnect.apple.com/access/integrations/api"}],
		},
		{
			"id": "profile_missing_cert",
			"patterns": ["doesn't include signing certificate"],
			"title": "The managed profile predates your certificate",
			"guidance": "1. Press the build button again — with working auth the managed profile regenerates to include the certificate\n2. If it repeats, the auth in use can't regenerate it: see the 'auth:' line at the top of the log (an API key must be role App Manager).",
		},
		{
			"id": "no_profiles",
			"patterns": ["No profiles for", "Provisioning profile", "profile doesn't match"],
			"title": "Provisioning profile problem",
			"guidance": "1. Press the build button again (automatic signing regenerates profiles)\n2. If it repeats: ↗ Open Identifiers — {bundle_id} must be listed under team {team_id}\n3. If the app uses push/iCloud/etc., enable that capability on the App ID there first.",
			"links": [{"label": "Open Identifiers", "url": "https://developer.apple.com/account/resources/identifiers/list"}],
		},
		{
			"id": "no_export_templates",
			"patterns": ["No export template", "Cannot export project", "export templates"],
			"title": "Godot export failed",
			"guidance": "Check the iOS export templates are installed for this exact Godot version (Editor → Manage Export Templates), and that the iOS preset exists in Project → Export. The full Godot output is in the log above.",
		},
		{
			"id": "asc_auth",
			"patterns": ["Failed to authenticate", "authentication credentials", "NOT_AUTHORIZED", "401"],
			"title": "App Store Connect authentication failed",
			"guidance": "The configured API key was rejected. Re-check asc_key_id, asc_issuer_id and that asc_key_path points at the downloaded .p8 (App Store Connect → Users and Access → Integrations). The key needs the App Manager (or Developer) role.",
			"links": [{"label": "Open Integrations", "url": "https://appstoreconnect.apple.com/access/integrations/api"}],
		},
		{
			"id": "network",
			"patterns": ["Communication with Apple failed", "The network connection was lost", "timed out"],
			"title": "Network problem talking to Apple",
			"guidance": "Transient — check connectivity and retry the build.",
		},
		{
			"id": "upload_failed",
			"patterns": ["error: exportArchive", "** EXPORT FAILED **"],
			"title": "Archive export/upload failed",
			"guidance": "xcodebuild rejected the export. The detailed reason is in the .xcdistributionlogs bundle whose path appears in the log above (IDEDistribution.standard.log names the failing step).",
		},
		{
			"id": "archive_failed",
			"patterns": ["** ARCHIVE FAILED **"],
			"title": "xcodebuild archive failed",
			"guidance": "See the compiler/signing errors in the log above; the last 'error:' line is the actual cause.",
		},
	]


## Returns {id, title, guidance, links} — falls back to a generic entry when
## nothing matches, so callers always get something presentable. `links` is an
## Array of {label, url} the dock renders as open-in-browser buttons.
static func classify(log_text: String, context: Dictionary = {}) -> Dictionary:
	for rule in rules():
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
