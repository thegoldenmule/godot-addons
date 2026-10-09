@tool
extends RefCounted

## Pure (editor-free, network-free) half of the itch.io target: slug/channel
## validation, export_presets.cfg → channel resolution, staging paths,
## export-template names, butler argv building, butler output parsing, the
## web-bundle size rules, and the itch.* preflight row evaluators.
##
## Everything here is static and side-effect free so tools/verify_build_kit.gd
## can pin it down headless; build_kit_service.gd owns the I/O (spawning
## butler, reading .env, downloading) and feeds the results back through the
## check_* evaluators, which return complete row dicts (same keys as
## Service._row) carrying the "walk you through it" guidance.
##
## Facts pinned from sources (see tools/verify_build_kit.gd for fixtures):
## - Godot template names: platform/web/export/export_plugin.h
##   (_get_template_name), editor_export_platform_pc + windows/linuxbsd
##   get_template_file_name, macos "macos.zip" (Godot 4.6-stable source).
## - butler: buildinfo VersionString "<tag>, built on …, ref <sha>" (tags are
##   "vX.Y.Z"); `status` renders a tablewriter table; API errors render as
##   "itch.io API error (<code>): <path>: <messages>" (go-itchio errors.go);
##   creds path from butler main.go defaultKeyPath().

const PLATFORM_CHANNELS := {
	"Web": "html5",
	"Windows Desktop": "windows",
	"macOS": "mac",
	"Linux": "linux",
	"Linux/X11": "linux",
}

## itch.io HTML5 ZIP limits (https://itch.io/docs/creators/html5).
const WEB_MAX_FILES := 1000
const WEB_MAX_FILE_BYTES := 209715200
const WEB_MAX_TOTAL_BYTES := 524288000

const API_KEYS_URL := "https://itch.io/user/settings/api-keys"
const NEW_GAME_URL := "https://itch.io/game/new"
const DASHBOARD_URL := "https://itch.io/dashboard"
const BUTLER_DOCS_URL := "https://itch.io/docs/butler/"
const BUTLER_INSTALL_URL := "https://itch.io/docs/butler/installing.html"
const BUTLER_LOGIN_URL := "https://itch.io/docs/butler/login.html"
const BROTH_BASE := "https://broth.itch.zone/butler"

const _CHANNEL_FALLBACK_EXT := {
	"Windows Desktop": ".exe",
	"Linux": ".x86_64",
	"Linux/X11": ".x86_64",
	"macOS": ".zip",
}


## Same keys as Service._row so the dock renders these unchanged.
static func row(id: String, label: String, status: String, detail := "", guidance := "", fixable := false, links: Array = []) -> Dictionary:
	return {"id": id, "label": label, "status": status, "detail": detail,
		"guidance": guidance, "fixable": fixable, "links": links}


# --- slugs / channels / URLs -------------------------------------------------

## itch user + game slugs: the subdomain and the page path segment.
static func valid_slug(s: String) -> bool:
	return _full_match("^[a-z0-9][a-z0-9_-]*$", s)


## Channel names: itch's convention is kebab-case; dots allowed for things
## like "windows-1.2". Platform tagging is by substring (win/linux/mac/osx/
## android) — HTML5 is never inferred and is tagged on the Edit game page.
static func valid_channel(s: String) -> bool:
	return _full_match("^[a-z0-9][a-z0-9._-]*$", s)


## Accepts the page URL in any of the forms people paste
## ("https://user.itch.io/game", "user.itch.io/game/", with query/fragment)
## or the butler-style "user/game". Returns {user, game} or {} if invalid.
static func parse_itch_url(text: String) -> Dictionary:
	var t := text.strip_edges()
	if t == "":
		return {}
	for sep in ["#", "?"]:
		var cut := t.find(sep)
		if cut >= 0:
			t = t.substr(0, cut)
	var lower := t.to_lower()
	for scheme in ["https://", "http://"]:
		if lower.begins_with(scheme):
			lower = lower.substr(scheme.length())
	var user := ""
	var game := ""
	var parts := lower.split("/", false)
	if parts.is_empty():
		return {}
	if parts[0].ends_with(".itch.io"):
		# URL form — the page is the first path segment (ignore /devlog etc.)
		user = parts[0].trim_suffix(".itch.io")
		if parts.size() < 2:
			return {}
		game = parts[1]
	else:
		# butler form — exactly user/game, no channel suffix
		if parts.size() != 2 or lower.contains(":"):
			return {}
		user = parts[0]
		game = parts[1]
	if not valid_slug(user) or not valid_slug(game):
		return {}
	return {"user": user, "game": game}


static func game_url(user: String, game: String) -> String:
	return "https://%s.itch.io/%s" % [user, game]


## The channel a Godot export platform pushes to by default; "" = itch can't
## host it through build_kit (iOS, Android, …).
static func default_channel(platform: String) -> String:
	return str(PLATFORM_CHANNELS.get(platform, ""))


# --- export presets → channels -----------------------------------------------

## Every preset in export_presets.cfg, in file order:
## [{section, name, platform, export_path, options}] — options is the whole
## [preset.N.options] section as a Dictionary.
static func list_presets(cfg_text: String) -> Array:
	var out: Array = []
	var cfg := ConfigFile.new()
	if cfg.parse(cfg_text) != OK:
		return out
	for section in cfg.get_sections():
		if not section.begins_with("preset.") or section.ends_with(".options"):
			continue
		var options := {}
		var opt := section + ".options"
		if cfg.has_section(opt):
			for key in cfg.get_section_keys(opt):
				options[key] = cfg.get_value(opt, key)
		out.append({
			"section": section,
			"name": str(cfg.get_value(section, "name", "")),
			"platform": str(cfg.get_value(section, "platform", "")),
			"export_path": str(cfg.get_value(section, "export_path", "")),
			"options": options,
		})
	return out


## Joins the committed itch.channels config onto the real presets.
## Empty config → auto-discover every itch-relevant preset (Web → html5, …);
## a second preset landing on the same default channel gets a suffix from its
## own name so discovery never produces a duplicate.
## Returns [{preset, platform, channel, enabled, options, export_path,
## problem}] — problem is "" when the entry is pushable.
static func resolve_channels(config_channels: Array, presets: Array) -> Array:
	var out: Array = []
	if config_channels.is_empty():
		var used := {}
		for p in presets:
			var platform := str(p.get("platform", ""))
			var channel := default_channel(platform)
			if channel == "":
				continue
			if used.has(channel):
				var suffixed := channel + "-" + _slugify(str(p.get("name", "")))
				var n := 2
				var candidate := suffixed
				while used.has(candidate):
					candidate = "%s-%d" % [suffixed, n]
					n += 1
				channel = candidate
			used[channel] = true
			out.append(_entry(p, platform, channel, true, ""))
		return out

	var by_name := {}
	for p in presets:
		var pname := str(p.get("name", ""))
		if not by_name.has(pname):
			by_name[pname] = p
	var seen := {}
	for c in config_channels:
		if not (c is Dictionary):
			continue
		var preset_name := str(c.get("preset", ""))
		var enabled := bool(c.get("enabled", true))
		var p: Dictionary = by_name.get(preset_name, {})
		var platform := str(p.get("platform", ""))
		var channel := str(c.get("channel", "")).strip_edges()
		if channel == "":
			channel = default_channel(platform)
		var problem := ""
		if p.is_empty():
			problem = "No export preset named '%s' (Project → Export)." % preset_name
		elif default_channel(platform) == "":
			problem = "Preset '%s' targets %s, which build_kit doesn't push to itch.io." % [preset_name, platform]
		elif not valid_channel(channel):
			problem = "Channel '%s' isn't valid — use lower-case letters, digits, '-', '_' or '.'." % channel
		elif enabled and seen.has(channel):
			problem = "Channel '%s' is used by more than one preset — each needs its own." % channel
		if enabled and channel != "":
			seen[channel] = true
		out.append(_entry(p, platform, channel, enabled, problem, preset_name))
	return out


static func _entry(p: Dictionary, platform: String, channel: String, enabled: bool, problem: String, preset_name := "") -> Dictionary:
	return {
		"preset": str(p.get("name", preset_name)),
		"platform": platform,
		"channel": channel,
		"enabled": enabled,
		"options": p.get("options", {}),
		"export_path": str(p.get("export_path", "")),
		"problem": problem,
	}


# --- staging paths -----------------------------------------------------------

## output_dir is committed config and its channel subdirs get deleted +
## recreated each build — so it must be a plain relative path that can't
## escape (or be) the project root.
static func safe_output_dir(output_dir: String) -> bool:
	var d := output_dir.strip_edges()
	if d == "" or d.contains("://") or d.begins_with("/") or d.begins_with("\\") or d.begins_with("~"):
		return false
	if d.length() >= 2 and d[1] == ":":
		return false  # Windows drive letter
	var kept := 0
	for part in d.replace("\\", "/").split("/", false):
		if part == "..":
			return false
		if part != ".":
			kept += 1
	return kept > 0


## {root, dir, out, logs}: root = <project>/<output_dir>, one dir per channel
## (that's what butler pushes), out = the file Godot exports into it.
## Web must be index.html (itch serves it); others keep the preset's own
## export filename, else <app>.exe / .x86_64 / .zip.
static func channel_paths(project_root: String, output_dir: String, channel: String, platform: String, preset_export_path: String, app_name: String) -> Dictionary:
	var root := project_root.path_join(output_dir).simplify_path()
	var dir := root.path_join(channel)
	var file := ""
	if platform == "Web":
		file = "index.html"
	else:
		file = preset_export_path.replace("\\", "/").get_file()
		if file == "":
			file = _clean_app_name(app_name) + str(_CHANNEL_FALLBACK_EXT.get(platform, ""))
	return {"root": root, "dir": dir, "out": dir.path_join(file), "logs": root.path_join("logs")}


# --- export templates --------------------------------------------------------

## Template files (names only, relative to the templates dir) the preset's
## release (or debug) export needs. A custom template on the preset means
## nothing is needed from the templates dir. Mirrors Godot 4's own lookup:
## web[_dlink][_nothreads]_<target>.zip, windows_<target>_<arch>.exe,
## linux_<target>.<arch>, macos.zip.
static func required_template_files(platform: String, options: Dictionary, release := true) -> PackedStringArray:
	var target := "release" if release else "debug"
	if str(options.get("custom_template/" + target, "")).strip_edges() != "":
		return PackedStringArray()
	match platform:
		"Web":
			var name := "web"
			if _opt_bool(options.get("variant/extensions_support", false)):
				name += "_dlink"
			if not _opt_bool(options.get("variant/thread_support", false)):
				name += "_nothreads"
			return PackedStringArray([name + "_" + target + ".zip"])
		"Windows Desktop":
			var arch := str(options.get("binary_format/architecture", "x86_64"))
			return PackedStringArray(["windows_%s_%s.exe" % [target, arch]])
		"Linux", "Linux/X11":
			var arch := str(options.get("binary_format/architecture", "x86_64"))
			return PackedStringArray(["linux_%s.%s" % [target, arch]])
		"macOS":
			return PackedStringArray(["macos.zip"])
	return PackedStringArray()


# --- butler argv / install ---------------------------------------------------

## The key never appears here — butler reads BUTLER_API_KEY from the env.
static func butler_push_args(butler: String, src: String, user: String, game: String, channel: String, userversion := "", dry_run := false, if_changed := true) -> PackedStringArray:
	var args := PackedStringArray([butler, "push", src, "%s/%s:%s" % [user, game, channel]])
	if userversion != "":
		# `=` form so a version starting with '-' can't parse as a flag
		args.append("--userversion=" + userversion)
	if if_changed:
		args.append("--if-changed")
	if dry_run:
		args.append("--dry-run")
	return args


static func butler_status_args(butler: String, user: String, game: String) -> PackedStringArray:
	return PackedStringArray([butler, "status", "%s/%s" % [user, game]])


## `butler login` as argv. butler only starts its browser sign-in when stdin is
## a terminal (mansion.IsTerminal), and an editor-spawned process has none, so
## on macOS/Linux it runs under `script`, which gives it a pseudo-terminal.
## Windows butler skips that check. `env -u` drops an inherited BUTLER_API_KEY:
## with one set, butler authenticates with it and never saves credentials.
static func butler_login_args(butler: String, os_name: String) -> PackedStringArray:
	match os_name:
		"Windows", "UWP":
			return PackedStringArray([butler, "login"])
		"macOS":
			return PackedStringArray(["env", "-u", "BUTLER_API_KEY", "script", "-q", "/dev/null", butler, "login"])
	# util-linux script: -c takes one shell string, -e passes the exit code through.
	var quoted := "'%s'" % butler.replace("'", "'\\''")
	return PackedStringArray(["env", "-u", "BUTLER_API_KEY", "script", "-qec", quoted + " login", "/dev/null"])


## broth channel for this OS/arch (OS.get_name(), Engine.get_architecture_name()).
## broth publishes darwin-amd64, darwin-arm64, linux-amd64, linux-arm64 and
## windows-amd64 only ("" = no prebuilt butler for this machine). Windows on
## ARM runs the amd64 build under emulation.
static func butler_broth_channel(os_name: String, arch: String) -> String:
	var a := arch.to_lower()
	var is_arm := a == "arm64" or a == "aarch64"
	var is_x64 := a == "x86_64" or a == "amd64"
	match os_name:
		"macOS":
			if is_arm:
				return "darwin-arm64"
			if is_x64:
				return "darwin-amd64"
		"Linux":
			if is_arm:
				return "linux-arm64"
			if is_x64:
				return "linux-amd64"
		"Windows":
			if is_x64 or is_arm:
				return "windows-amd64"
	return ""


## A zip with the butler executable (+ its bundled libs) at the root.
static func butler_download_url(broth_channel: String) -> String:
	if broth_channel == "":
		return ""
	return "%s/%s/LATEST/archive/default" % [BROTH_BASE, broth_channel]


static func butler_exe_name(os_name: String) -> String:
	return "butler.exe" if os_name == "Windows" else "butler"


## Where `butler login` saves its key (butler main.go defaultKeyPath):
## $HOME (falling back to %USERPROFILE%) + Library/Application Support/itch
## on macOS, .config/itch everywhere else. "" when neither var is set.
static func butler_creds_path(os_name: String, home: String, userprofile: String) -> String:
	var base := home if home != "" else userprofile
	if base == "":
		return ""
	if os_name == "macOS":
		return base.path_join("Library/Application Support/itch/butler_creds")
	return base.path_join(".config/itch/butler_creds")


# --- butler output parsing ---------------------------------------------------

## `butler version` prints "v15.32.0, built on Oct  9 2026 @ 13:02:37, ref
## <sha>" (dev builds: "head, no build date"). Returns "15.32.0" / "head" /
## "" when unrecognizable.
static func parse_butler_version(output: String) -> String:
	var re := RegEx.new()
	re.compile("(?m)^\\s*v?(\\d+\\.\\d+(?:\\.\\d+)*)\\b")
	var m := re.search(output)
	if m:
		return m.get_string(1)
	var head := RegEx.new()
	head.compile("(?m)^\\s*head\\b")
	if head.search(output):
		return "head"
	var loose := RegEx.new()
	loose.compile("\\bv(\\d+\\.\\d+\\.\\d+)\\b")
	m = loose.search(output)
	return m.get_string(1) if m else ""


## Best-effort parse of `butler status`'s table:
##   | CHANNEL |  UPLOAD  |   BUILD   | VERSION |
##   | html5   | #1234567 | √ #456789 | 1.0.0   |
## Pending-build continuation rows (blank channel cell) and the header are
## skipped. Returns [{channel, upload, build, version}].
static func parse_status(output: String) -> Array:
	var out: Array = []
	for raw in output.split("\n"):
		var line := raw.strip_edges()
		if not line.begins_with("|"):
			continue
		var cells := PackedStringArray()
		for c in line.trim_prefix("|").trim_suffix("|").split("|"):
			cells.append(c.strip_edges())
		if cells.is_empty() or cells[0] == "" or cells[0].to_upper() == "CHANNEL":
			continue
		out.append({
			"channel": cells[0],
			"upload": cells[1] if cells.size() > 1 else "",
			"build": cells[2] if cells.size() > 2 else "",
			"version": cells[3] if cells.size() > 3 else "",
		})
	return out


## Turns one `butler status user/game` run into the itch.auth + itch.target
## row states: {"auth": {status, detail, guidance}, "target": {…}}.
## Exit 0 proves both (the call is authenticated and lists the page's
## channels). On failure the output decides which row is at fault.
static func interpret_status(code: int, output: String) -> Dictionary:
	if code == 0:
		var channels := parse_status(output)
		var detail := "page found — no builds pushed yet"
		if not channels.is_empty():
			var names := PackedStringArray()
			for c in channels:
				names.append(str(c["channel"]))
			detail = "%d channel(s): %s" % [names.size(), ", ".join(names)]
		return {
			"auth": _state("ok", "authenticated"),
			"target": _state("ok", detail),
		}
	var low := output.to_lower()
	var unchecked := _state("warn", "not checked", "Sign in on the itch.io account row above first — itch.io only answers authenticated requests.")
	var auth_failed := {
		"auth": _state("fail", "rejected by itch.io", _AUTH_GUIDANCE),
		"target": unchecked,
	}
	# Explicit key messages first; then page errors (whose 4xx code must not
	# read as an auth failure); bare 401/403 last.
	if _has_any(low, _AUTH_SIGNS):
		return auth_failed
	if _has_any(low, _TARGET_SIGNS):
		return {
			"auth": _state("ok", "authenticated"),
			"target": _state("fail", "itch.io doesn't know this page",
				"butler status was refused for this user/game.\n1. Check the user is your itch.io subdomain (the 'user' in https://user.itch.io/game) and the game is the page's URL slug — not its title\n2. The page must already exist (butler never creates one) — ↗ Create new project; drafts are fine\n3. If both are right, the key may belong to a different account or have expired: generate a fresh API key (or re-run `butler login`)."),
		}
	if _has_any(low, _AUTH_HTTP_SIGNS):
		return auth_failed
	if _has_any(low, _NETWORK_SIGNS):
		var offline := _state("warn", "couldn't reach itch.io", "Network problem — check connectivity (or a firewall blocking butler) and press Refresh.")
		return {"auth": offline, "target": offline}
	if _has_any(low, _MISSING_SIGNS) or code == 127:
		var no_butler := _state("warn", "not checked", "butler isn't runnable — see the butler row.")
		return {"auth": no_butler, "target": no_butler}
	var tail := _last_line(output)
	var unknown := _state("warn", "butler status failed (exit %d)" % code,
		"Unrecognized butler output%s — run the 'itch status' button and read its log." % ((": " + tail) if tail != "" else ""))
	return {"auth": unknown, "target": unknown}


# Lower-cased signatures shared with interpret_status (classify.gd keeps its
# own copies — its patterns are case-sensitive literals).
const _AUTH_SIGNS := ["invalid key", "invalid api key", "no credentials", "please set butler_api_key"]
const _AUTH_HTTP_SIGNS := ["api error (401)", "api error (403)", "http 401", "http 403"]
const _TARGET_SIGNS := ["invalid target", "invalid game", "invalid spec:", "invalid user"]
const _NETWORK_SIGNS := ["no such host", "connection refused", "connection reset", "network is unreachable",
	"i/o timeout", "tls handshake timeout", "client.timeout exceeded", "server error: http 5", "timed out"]
const _MISSING_SIGNS := ["command not found", "is not recognized as", "no such file or directory: ", "butler: not found"]
const _AUTH_GUIDANCE := "itch.io rejected the API key.\n1. ↗ Open API keys → Generate new API key, copy it\n2. Paste it into the key field on the itch.io account row → Save (replaces BUTLER_API_KEY in .env — check it has no stray spaces)\n3. Or press Sign in with browser (runs `butler login`) and remove BUTLER_API_KEY from .env, which otherwise takes priority."


static func _state(status: String, detail: String, guidance := "") -> Dictionary:
	return {"status": status, "detail": detail, "guidance": guidance}


# --- web bundle --------------------------------------------------------------

## itch rejects an HTML5 zip without a root index.html, with more than 1000
## files, any file over 200 MB, or more than 500 MB in total. files:
## [{path, size}], paths relative to the channel dir. Returns one message per
## violation (empty = OK).
static func web_bundle_violations(files: Array) -> PackedStringArray:
	var out := PackedStringArray()
	var has_index := false
	var total := 0
	var too_big := PackedStringArray()
	for f in files:
		var path := str(f.get("path", "")).replace("\\", "/").trim_prefix("./")
		var size := int(f.get("size", 0))
		total += size
		if path == "index.html":
			has_index = true
		if size > WEB_MAX_FILE_BYTES:
			too_big.append("%s (%s)" % [path, _mb(size)])
	if not has_index:
		out.append("No index.html at the top of the bundle — itch.io serves index.html; Build Kit exports the Web preset as index.html, so the export likely failed.")
	if files.size() > WEB_MAX_FILES:
		out.append("%d files — itch.io allows at most %d in an HTML5 upload." % [files.size(), WEB_MAX_FILES])
	for b in too_big:
		out.append("%s is over itch.io's %s per-file limit." % [b, _mb(WEB_MAX_FILE_BYTES)])
	if total > WEB_MAX_TOTAL_BYTES:
		out.append("Bundle is %s — itch.io allows at most %s extracted." % [_mb(total), _mb(WEB_MAX_TOTAL_BYTES)])
	return out


# --- preflight row evaluators ------------------------------------------------

## probe = Exec.run([butler, "version"]) → {code, output}; butler_path "" =
## nothing found (managed, itch app, PATH).
static func check_butler(probe: Dictionary, butler_path: String, download_available: bool) -> Dictionary:
	var links := [{"label": "Installing butler", "url": BUTLER_INSTALL_URL}]
	var how := ("Press Fix — downloads butler (itch.io's official uploader) from broth.itch.zone into the editor's data folder; no PATH changes needed."
		if download_available else
		"No prebuilt butler for this OS/CPU — install it manually and put it on PATH.")
	if butler_path == "":
		return row("itch.butler", "butler (itch.io uploader)", "fail", "not found",
			"butler uploads builds to itch.io (only changed bytes go up on later pushes).\n1. " + how
				+ "\n2. Or install it yourself (↗ Installing butler) so `butler` is on PATH, then Refresh.",
			download_available, links)
	var code := int(probe.get("code", -1))
	if code != 0:
		return row("itch.butler", "butler (itch.io uploader)", "fail",
			"`butler version` failed (exit %d)" % code,
			"Found %s but it doesn't run (corrupt download, wrong CPU build, or quarantined).\n1. %s\n2. Or replace it manually (↗ Installing butler), then Refresh." % [butler_path, how],
			download_available, links)
	var version := parse_butler_version(str(probe.get("output", "")))
	var detail := butler_path if version == "" else "%s (%s)" % [version, butler_path]
	return row("itch.butler", "butler (itch.io uploader)", "ok", detail)


## key_source: "env" (process environment) | "dotenv" (.env) | "" (none).
## A key or a `butler login` creds file → busy until the async `butler
## status` verdict (interpret_status) lands via _set_row.
static func check_auth(key_source: String, has_creds_file: bool) -> Dictionary:
	var links := [{"label": "Open API keys", "url": API_KEYS_URL}, {"label": "About butler login", "url": BUTLER_LOGIN_URL}]
	match key_source:
		"env":
			return row("itch.auth", "itch.io account", "busy", "BUTLER_API_KEY (environment) — verifying…", "", false, links)
		"dotenv":
			return row("itch.auth", "itch.io account", "busy", "BUTLER_API_KEY (.env) — verifying…", "", false, links)
	if has_creds_file:
		return row("itch.auth", "itch.io account", "busy", "butler login credentials — verifying…", "", false, links)
	return row("itch.auth", "itch.io account", "warn", "not signed in",
		"Pushing needs you signed in to itch.io (export-only and dry runs don't). Either:\n1. Press Sign in with browser — runs `butler login`, which opens itch.io in your browser; approve butler there and the credentials are saved for every project on this machine\n2. Or ↗ Open API keys → Generate new API key, paste it below → Save — stored as BUTLER_API_KEY in this project's gitignored .env, never in build_kit.config.json or on a command line",
		false, links)


## user/game from the committed config. Valid → busy until `butler status`
## confirms the page exists.
static func check_target(user: String, game: String) -> Dictionary:
	var links := [{"label": "Create new project", "url": NEW_GAME_URL}, {"label": "Dashboard", "url": DASHBOARD_URL}]
	var how := "butler can't create game pages — make yours once on itch.io:\n1. ↗ Create new project → set a Title and Kind of project (HTML if you'll ship the Web build, else Downloadable); leaving it as a Draft is fine — drafts accept pushes\n2. Save, then copy the page URL (https://<you>.itch.io/<game>) and paste it below → Save."
	if user == "" and game == "":
		return row("itch.target", "itch.io game page", "fail", "not set", how, false, links)
	if not valid_slug(user) or not valid_slug(game):
		return row("itch.target", "itch.io game page", "fail", "'%s/%s' isn't a valid user/game" % [user, game],
			"The user is your itch.io subdomain and the game is the page's URL slug (lower-case letters, digits, '-', '_').\n" + how,
			false, links)
	var with_page := links.duplicate()
	with_page.push_front({"label": "Open page", "url": game_url(user, game)})
	return row("itch.target", "itch.io game page", "busy", "%s/%s — checking…" % [user, game], "", false, with_page)


## resolved = resolve_channels(...); configured = the config pins channels
## (else they were auto-discovered and Fix writes them down).
static func check_channels(resolved: Array, configured: bool) -> Dictionary:
	var enabled: Array = []
	var problems := PackedStringArray()
	for c in resolved:
		if not bool(c.get("enabled", true)):
			continue
		enabled.append(c)
		if str(c.get("problem", "")) != "":
			problems.append(str(c["problem"]))
	if resolved.is_empty():
		return row("itch.channels", "itch.io channels", "fail", "no Web/desktop presets",
			"Each itch.io channel is built from one export preset.\n1. Project → Export → Add… → Web, Windows Desktop, macOS or Linux\n2. Refresh — channels are picked up automatically (Web → html5, Windows → windows, macOS → mac, Linux → linux).")
	if not problems.is_empty():
		return row("itch.channels", "itch.io channels", "fail", "%d problem(s)" % problems.size(),
			"\n".join(problems) + "\nEdit itch.channels in build_kit.config.json ({\"preset\", \"channel\", \"enabled\"} per entry), then Refresh.")
	if enabled.is_empty():
		return row("itch.channels", "itch.io channels", "fail", "all disabled",
			"Every entry in itch.channels is \"enabled\": false — enable at least one in build_kit.config.json, then Refresh.")
	var summary := _channel_summary(enabled)
	if not configured:
		return row("itch.channels", "itch.io channels", "warn", "auto: " + summary,
			"Discovered from your export presets and used as-is. Press Fix to pin them in build_kit.config.json (committed) so channel names stay stable when presets change — then rename channels or set \"enabled\": false there.",
			true)
	return row("itch.channels", "itch.io channels", "ok", summary)


## missing = template file names (required_template_files) absent from the
## templates dir; version_label like "4.7.1.stable".
static func check_templates(missing: PackedStringArray, version_label: String, download_available: bool) -> Dictionary:
	if missing.is_empty():
		return row("itch.templates", "Export templates (itch)", "ok", version_label)
	var detail := "missing %s (%s)" % [", ".join(missing), version_label]
	if download_available:
		return row("itch.templates", "Export templates (itch)", "fail", detail,
			"1. Press Fix — downloads the official %s template pack (~1 GB, several minutes) and installs it." % version_label,
			true)
	return row("itch.templates", "Export templates (itch)", "fail", detail,
		"1. Editor → Manage Export Templates → Download and Install (no direct download for non-stable builds).")


## Threaded web exports need SharedArrayBuffer (cross-origin isolation),
## which is opt-in and fragile on itch.io.
static func check_web(resolved: Array) -> Dictionary:
	var webs := PackedStringArray()
	var threaded := PackedStringArray()
	for c in resolved:
		if not bool(c.get("enabled", true)) or str(c.get("platform", "")) != "Web":
			continue
		webs.append(str(c.get("preset", "")))
		if _opt_bool((c.get("options", {}) as Dictionary).get("variant/thread_support", false)):
			threaded.append(str(c.get("preset", "")))
	if webs.is_empty():
		return row("itch.web", "Web export threads", "ok", "no Web channel")
	if threaded.is_empty():
		return row("itch.web", "Web export threads", "ok", "single-threaded (plays everywhere)")
	return row("itch.web", "Web export threads", "warn", "thread support on (%s)" % ", ".join(threaded),
		"Threaded web builds need SharedArrayBuffer. itch.io only provides it if you tick 'SharedArrayBuffer support' in the page's Embed options — an experimental setting that breaks some browsers (notably Safari/iOS) and parts of the itch.io page.\n1. Press Fix — sets variant/thread_support=false on the Web preset (Godot's default; uses the nothreads template)\n2. Or keep threads and tick SharedArrayBuffer support on the Edit game page after the first push.",
		true)


static func check_version(version: String) -> Dictionary:
	if version.strip_edges() == "":
		return row("itch.version", "Build version", "warn", "not set",
			"Pushes go up without --userversion, so itch.io only shows build numbers.\n1. Enter a version below (e.g. 1.0.0) → Save — writes application/config/version to project.godot\n2. Every push then sends it as --userversion.")
	return row("itch.version", "Build version", "ok", version.strip_edges())


# --- helpers -----------------------------------------------------------------

static func _full_match(pattern: String, s: String) -> bool:
	var re := RegEx.new()
	re.compile(pattern)
	return re.search(s) != null


# Preset option values come back from ConfigFile typed, but tolerate strings.
static func _opt_bool(v: Variant) -> bool:
	if v is String:
		return (v as String).strip_edges().to_lower() == "true"
	if v == null:
		return false
	return bool(v)


static func _slugify(s: String) -> String:
	var out := ""
	for ch in s.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			out += ch
		elif not out.ends_with("-") and out != "":
			out += "-"
	out = out.trim_suffix("-")
	return out if out != "" else "preset"


static func _clean_app_name(name: String) -> String:
	var out := ""
	for ch in name.strip_edges().replace(" ", "_"):
		if (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch == "_" or ch == "-":
			out += ch
	return out if out != "" else "game"


static func _channel_summary(entries: Array) -> String:
	var parts := PackedStringArray()
	for c in entries:
		parts.append("%s ← %s" % [c.get("channel", ""), c.get("preset", "")])
	return ", ".join(parts)


static func _has_any(haystack: String, needles: Array) -> bool:
	for n in needles:
		if haystack.contains(n):
			return true
	return false


static func _last_line(text: String) -> String:
	var lines := text.strip_edges().split("\n", false)
	return lines[lines.size() - 1].strip_edges() if not lines.is_empty() else ""


static func _mb(bytes: int) -> String:
	return "%d MB" % int(round(bytes / 1048576.0))
