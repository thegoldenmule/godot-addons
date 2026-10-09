@tool
extends RefCounted

## The decision halves of the one-command iOS release (cli/release_ios.gd):
## argument parsing, build-number selection, the config write, the commit
## message, git commit/push (through an injected runner, so the verifier can
## mock it), cleanup selection and redaction. Everything here is static and
## does no network I/O, so tools/verify_build_kit.gd exercises it headless.

const CONFIG_FILE := "build_kit.config.json"
const DEFAULT_TIMEOUT_MIN := 30

const USAGE := """Usage: addons/build_kit/cli/release_ios.sh [--project <dir>] [--no-upload] [--no-commit] [--no-push] [--timeout <minutes>]

One command for an iOS TestFlight release: pick the build number (config vs App
Store Connect), export, archive, sign, verify entitlements, upload, wait for
processing, then commit + push the next build_number in build_kit.config.json.

  --project <dir>    directory holding project.godot (default: the project this addon lives in)
  --no-upload        stop after the verified local .ipa (no ASC, no commit, no push)
  --no-commit        upload, but leave build_kit.config.json uncommitted (implies --no-push)
  --no-push          commit locally, don't push
  --timeout <min>    how long to wait for App Store Connect processing (default 30)
  -h, --help         this text"""


# ── Arguments ─────────────────────────────────────────────────────────────────

## Returns {ok, error, help, project, upload, commit, push, timeout_min}.
## --no-upload implies no commit/push (nothing was uploaded, so there is no
## build number to record); --no-commit implies --no-push.
static func parse_args(args: PackedStringArray) -> Dictionary:
	var out := {"ok": true, "error": "", "help": false, "project": "", "upload": true,
		"commit": true, "push": true, "timeout_min": DEFAULT_TIMEOUT_MIN}
	var i := 0
	while i < args.size():
		var a := args[i]
		var value := ""
		var has_inline := false
		if a.begins_with("--") and a.contains("="):
			value = a.substr(a.find("=") + 1)
			a = a.substr(0, a.find("="))
			has_inline = true
		match a:
			"-h", "--help":
				out["help"] = true
			"--no-upload":
				out["upload"] = false
			"--no-commit":
				out["commit"] = false
			"--no-push":
				out["push"] = false
			"--project", "--timeout":
				if not has_inline:
					if i + 1 >= args.size() or args[i + 1].begins_with("--"):
						return _arg_error("%s needs a value" % a)
					i += 1
					value = args[i]
				if value.strip_edges() == "":
					return _arg_error("%s needs a value" % a)
				if a == "--project":
					out["project"] = value
				elif not value.is_valid_int() or int(value) <= 0:
					return _arg_error("--timeout takes a positive number of minutes, got '%s'" % value)
				else:
					out["timeout_min"] = int(value)
			_:
				return _arg_error("unknown argument '%s'" % args[i])
		if has_inline and a in ["-h", "--help", "--no-upload", "--no-commit", "--no-push"]:
			return _arg_error("%s takes no value" % a)
		i += 1
	if not out["upload"]:
		out["commit"] = false
	if not out["commit"]:
		out["push"] = false
	return out


static func _arg_error(msg: String) -> Dictionary:
	return {"ok": false, "error": msg, "help": false}


# ── Build number ──────────────────────────────────────────────────────────────

## max(config, highest on App Store Connect + 1): a build that was uploaded but
## whose bump never got committed can't be reused, and the config never goes
## backwards. highest_on_asc <= 0 means "none uploaded for this version".
static func pick_build_number(config_number: int, highest_on_asc: int) -> int:
	return maxi(maxi(config_number, 1), highest_on_asc + 1)


## Highest all-digit build number in an asc_helper builds list (0 = none).
static func highest_build(builds: Array) -> int:
	var best := 0
	for b in builds:
		var v := str(b.get("version", "")) if b is Dictionary else ""
		if v.is_valid_int():
			best = maxi(best, int(v))
	return best


## processingState of build `build_number` in an asc_helper builds list, ""
## while App Store Connect doesn't list it yet.
static func build_state(builds: Array, build_number: int) -> String:
	for b in builds:
		if b is Dictionary and str(b.get("version", "")) == str(build_number):
			return str(b.get("state", ""))
	return ""


## What a processingState means for the poll: "done" (VALID), "failed"
## (FAILED/INVALID) or "wait" (PROCESSING, not listed yet, anything new).
static func state_verdict(state: String) -> String:
	match state:
		"VALID":
			return "done"
		"FAILED", "INVALID":
			return "failed"
	return "wait"


# ── Config write ──────────────────────────────────────────────────────────────

## build_kit.config.json text with ios.build_number = n and nothing else
## changed. A lone `"build_number": <int>` is rewritten in place so the file's
## own formatting survives; otherwise the parsed file (only its own keys, no
## defaults merged in) is re-serialised. "" when `text` isn't a JSON object.
static func set_build_number_text(text: String, n: int) -> String:
	if text.strip_edges() == "":
		return JSON.stringify({"ios": {"build_number": n}}, "\t") + "\n"
	var json := JSON.new()  # not JSON.parse_string: that logs an engine error on bad input
	if json.parse(text) != OK or not json.data is Dictionary:
		return ""
	var parsed: Dictionary = json.data
	var want := parsed.duplicate(true)
	if not want.get("ios") is Dictionary:
		want["ios"] = {}
	want["ios"]["build_number"] = n
	var re := RegEx.create_from_string("(\"build_number\"\\s*:\\s*)-?[0-9]+(\\.[0-9]+)?")
	var hits := re.search_all(text)
	if hits.size() == 1:
		var m: RegExMatch = hits[0]
		var edited := text.substr(0, m.get_end(1)) + str(n) + text.substr(m.get_end())
		var check: Variant = JSON.parse_string(edited)
		if check is Dictionary and _same_json(check, want):
			return edited
	return JSON.stringify(want, "\t") + "\n"


static func _same_json(a: Variant, b: Variant) -> bool:
	# JSON numbers parse as floats; compare through one canonical form.
	return JSON.stringify(JSON.parse_string(JSON.stringify(a)), "", true) \
		== JSON.stringify(JSON.parse_string(JSON.stringify(b)), "", true)


## Write ios.build_number = n into the config at `path`. Returns {ok, error}.
static func write_build_number(path: String, n: int) -> Dictionary:
	var text := ""
	if FileAccess.file_exists(path):
		var r := FileAccess.open(path, FileAccess.READ)
		if r == null:
			return {"ok": false, "error": "cannot read %s" % path}
		text = r.get_as_text()
		r.close()
	var out := set_build_number_text(text, n)
	if out == "":
		return {"ok": false, "error": "%s is not a JSON object" % path}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": "cannot write %s" % path}
	f.store_string(out)
	f.close()
	return {"ok": true, "error": ""}


# ── Git ───────────────────────────────────────────────────────────────────────

## No trailers on purpose: some repos reject Co-Authored-By and friends.
static func commit_message(version: String, build: int, next_build: int) -> String:
	return "build: iOS %s (%d) uploaded to TestFlight; next build_number %d" % [version, build, next_build]


## `git` is a Callable(args: PackedStringArray) -> {code: int, output: String}
## run in the project dir. Checked BEFORE building, so a release never uploads
## something it then can't record: a work tree, nothing staged, the config not
## locally modified, and (when pushing) an attached branch with an upstream it
## isn't ahead of — so the push carries only the release commit.
## Returns {ok, error, branch, remote, merge}.
static func git_preflight(git: Callable, push: bool, config_rel := CONFIG_FILE) -> Dictionary:
	var r: Dictionary = git.call(PackedStringArray(["rev-parse", "--is-inside-work-tree"]))
	if int(r["code"]) != 0 or str(r["output"]).strip_edges() != "true":
		return {"ok": false, "error": "not inside a git work tree (use --no-commit)"}
	r = git.call(PackedStringArray(["diff", "--cached", "--name-only"]))
	if int(r["code"]) != 0:
		return {"ok": false, "error": "git diff --cached failed: " + str(r["output"]).strip_edges()}
	var staged := str(r["output"]).strip_edges()
	if staged != "":
		return {"ok": false, "error": "other changes are staged (%s); unstage them or use --no-commit" % ", ".join(staged.split("\n"))}
	r = git.call(PackedStringArray(["status", "--porcelain", "--", config_rel]))
	var st := str(r["output"]).strip_edges()
	if int(r["code"]) == 0 and st != "" and not st.begins_with("??"):
		return {"ok": false, "error": "%s has uncommitted changes; commit or revert them first" % config_rel}
	var out := {"ok": true, "error": "", "branch": "", "remote": "", "merge": ""}
	if not push:
		return out
	r = git.call(PackedStringArray(["symbolic-ref", "--quiet", "--short", "HEAD"]))
	var branch := str(r["output"]).strip_edges()
	if int(r["code"]) != 0 or branch == "":
		return {"ok": false, "error": "HEAD is detached; check out a branch or use --no-push"}
	var remote := str(git.call(PackedStringArray(["config", "--get", "branch.%s.remote" % branch]))["output"]).strip_edges()
	var merge := str(git.call(PackedStringArray(["config", "--get", "branch.%s.merge" % branch]))["output"]).strip_edges()
	if remote == "" or merge == "" or remote == ".":
		return {"ok": false, "error": "branch %s has no upstream; set one (git push -u) or use --no-push" % branch}
	r = git.call(PackedStringArray(["rev-list", "--count", "@{u}..HEAD"]))
	if int(r["code"]) == 0 and int(str(r["output"]).strip_edges()) > 0:
		return {"ok": false, "error": "%s is %s commit(s) ahead of its upstream; push them first or use --no-push" % [
			branch, str(r["output"]).strip_edges()]}
	out["branch"] = branch
	out["remote"] = remote
	out["merge"] = merge
	return out


## git add ONLY the config, commit it, and (optionally) push to the branch's
## upstream. A rejected push gets one fetch + rebase of just the release
## commit (git rebase --onto @{u} HEAD~1) and one retry; never a force push.
## `upstream` is git_preflight's result. Returns {ok, error, sha, pushed, rebased}.
static func git_commit_and_push(git: Callable, message: String, push: bool, upstream: Dictionary,
		config_rel := CONFIG_FILE) -> Dictionary:
	var out := {"ok": false, "error": "", "sha": "", "pushed": false, "rebased": false}
	var r: Dictionary = git.call(PackedStringArray(["diff", "--cached", "--name-only"]))
	var staged := str(r["output"]).strip_edges()
	if int(r["code"]) != 0 or staged != "":
		out["error"] = "refusing to commit: other changes are staged (%s)" % ", ".join(staged.split("\n"))
		return out
	r = git.call(PackedStringArray(["add", "--", config_rel]))
	if int(r["code"]) != 0:
		out["error"] = "git add failed: " + str(r["output"]).strip_edges()
		return out
	r = git.call(PackedStringArray(["diff", "--cached", "--name-only"]))
	var now_staged := str(r["output"]).strip_edges().split("\n", false)
	if now_staged.size() != 1:
		git.call(PackedStringArray(["reset", "-q", "--", config_rel]))
		out["error"] = "refusing to commit: expected only %s staged, found [%s]" % [config_rel, ", ".join(now_staged)]
		return out
	r = git.call(PackedStringArray(["commit", "-q", "-m", message, "--", config_rel]))
	if int(r["code"]) != 0:
		out["error"] = "git commit failed: " + str(r["output"]).strip_edges()
		return out
	out["sha"] = str(git.call(PackedStringArray(["rev-parse", "HEAD"]))["output"]).strip_edges()
	if not push:
		out["ok"] = true
		return out
	var remote := str(upstream.get("remote", ""))
	var dest := "HEAD:" + str(upstream.get("merge", ""))
	r = git.call(PackedStringArray(["push", remote, dest]))
	if int(r["code"]) == 0:
		out["ok"] = true
		out["pushed"] = true
		return out
	if not is_push_rejection(str(r["output"])):
		out["error"] = "git push failed: " + _last_lines(str(r["output"]))
		return out
	r = git.call(PackedStringArray(["fetch", "-q", remote]))
	if int(r["code"]) != 0:
		out["error"] = "push rejected and git fetch failed: " + _last_lines(str(r["output"]))
		return out
	r = git.call(PackedStringArray(["rebase", "-q", "--autostash", "--onto", "@{u}", "HEAD~1"]))
	if int(r["code"]) != 0:
		git.call(PackedStringArray(["rebase", "--abort"]))
		out["error"] = "push rejected and rebasing the release commit onto %s failed (left unpushed at %s): %s" % [
			remote, out["sha"], _last_lines(str(r["output"]))]
		return out
	out["rebased"] = true
	out["sha"] = str(git.call(PackedStringArray(["rev-parse", "HEAD"]))["output"]).strip_edges()
	r = git.call(PackedStringArray(["push", remote, dest]))
	if int(r["code"]) != 0:
		out["error"] = "push rejected again after rebase (commit %s is local only): %s" % [
			out["sha"], _last_lines(str(r["output"]))]
		return out
	out["ok"] = true
	out["pushed"] = true
	return out


static func is_push_rejection(output: String) -> bool:
	return output.contains("[rejected]") or output.contains("non-fast-forward") \
		or output.contains("fetch first") or output.contains("Updates were rejected")


static func _last_lines(text: String, n := 3) -> String:
	var lines := text.strip_edges().split("\n", false)
	return " | ".join(lines.slice(maxi(0, lines.size() - n)))


# ── Cleanup + output ──────────────────────────────────────────────────────────

## Entries of the build dir to delete after a run: everything that appeared
## during the run plus the pipeline's known outputs, never logs/ (and never
## the .ipa when `keep` names it). Refuses ([]) a dir holding project.godot or
## .git — an export_path at the project root must not cost the project files.
static func cleanup_entries(before: Array, after: Array, known: Array, keep: Array) -> Array:
	if after.has("project.godot") or after.has(".git"):
		return []
	var out: Array = []
	for name in after:
		if name == "logs" or keep.has(name):
			continue
		if not before.has(name) or known.has(name):
			out.append(name)
	out.sort()
	return out


## Every credential value blanked out of `text` (key id, issuer id, key path).
static func redact(text: String, secrets: Array) -> String:
	for s in secrets:
		var v := str(s)
		if v.length() >= 4:
			text = text.replace(v, "<redacted>")
	return text


static func summary_line(ok: bool, version: String, build: String, asc_state: String,
		entitlements: String, commit: String) -> String:
	return "release_ios: %s  version=%s build=%s asc=%s entitlements=%s commit=%s" % [
		"OK" if ok else "FAILED", version if version != "" else "?", build, asc_state, entitlements, commit]
