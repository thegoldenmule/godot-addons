extends SceneTree

## Headless verifier for RemoteConfigService — the Remote Config aggregation +
## config logic, exercised WITHOUT the editor:
##   godot --headless --path . --script res://tools/verify_remote_config_editor.gd
## Covers the pure surface (build_document order/skip, versions, validate's
## missing-file / missing-version / duplicate-key / empty-manifest cases) driven
## against a temp manifest, copy_publish_payload's validate gate, the path resolver,
## and the game-agnostic config seam (defaults, config-driven labels + version
## field, has_sync gating). The check_sync shell-out (a live external command) is
## NOT exercised here. Writes only to a temp dir.

const ServiceT := preload("res://addons/remote_config_editor/remote_config_service.gd")

var _ok := true


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var svc: Node = ServiceT.new()
	root.add_child(svc)

	var tmp := OS.get_cache_dir().path_join("rc_verify")
	DirAccess.make_dir_recursive_absolute(tmp)

	_test_path_resolver()
	_test_config_defaults(svc)
	_test_config_driven_surface(svc)
	_test_check_sync_seam(svc, tmp)
	_test_aggregation(svc, tmp)
	_test_validate_cases(svc, tmp)

	svc.queue_free()
	print("VERIFY remote_config_editor: %s" % ["PASS" if _ok else "FAIL"])
	quit(0 if _ok else 1)


# ── path resolver ───────────────────────────────────────────────────────────────


func _test_path_resolver() -> void:
	# res:// is globalized (becomes an absolute OS path, no scheme left).
	var res_abs: String = ServiceT._resolve("res://")
	_check("_resolve(res://) globalizes", res_abs == ProjectSettings.globalize_path("res://").simplify_path())
	_check("_resolve(res://) is absolute", res_abs.is_absolute_path() and not res_abs.begins_with("res://"))
	# A relative path joins onto the project dir.
	_check("_resolve(relative) joins onto project dir",
		ServiceT._resolve("a/b.json") == ProjectSettings.globalize_path("res://").path_join("a/b.json").simplify_path())
	# An already-absolute path is kept (simplified).
	_check("_resolve(absolute) kept", ServiceT._resolve("/tmp/x/../y.json") == "/tmp/y.json")
	# "res://.." resolves to the project's parent — the nested-repo layout.
	_check("_resolve(res://..) is parent of project",
		ServiceT._resolve("res://..") == ProjectSettings.globalize_path("res://").path_join("..").simplify_path())


# ── config seam ─────────────────────────────────────────────────────────────────


func _test_config_defaults(svc) -> void:
	# No config file exists in this distribution repo → pure defaults.
	var cfg: Dictionary = svc.load_config()
	_check("defaults: manifest empty", str(cfg.get("manifest", "x")) == "")
	_check("defaults: not configured", not svc.is_configured())
	_check("defaults: no sync", not svc.has_sync())
	_check("defaults: doc_version_field", str(cfg.get("doc_version_field", "")) == "app_config_version")
	_check("check_sync unconfigured → code -1", int(svc.check_sync().get("code", 0)) == -1)


func _test_config_driven_surface(svc) -> void:
	# Inject a config (as load_config would produce) and assert every label /
	# version field is driven by it — nothing hardcoded.
	svc.config = {
		"doc_version_field": "schema_rev",
		"document_label": "widget bundle",
		"publish_target": "the Acme dashboard",
		"sync": {"program": "node", "args": ["x.js"], "hint": "npm run verify"},
	}
	svc.manifest = {"schema_rev": "rev7", "entries": []}
	_check("app_config_version reads configured field", svc.app_config_version() == "rev7")
	_check("document_label config-driven", svc.document_label() == "widget bundle")
	_check("publish_target config-driven", svc.publish_target() == "the Acme dashboard")
	_check("has_sync true when program set", svc.has_sync())
	_check("sync_hint config-driven", svc.sync_hint() == "npm run verify")
	# An empty sync block disables the drift check.
	svc.config = {"sync": {}}
	_check("has_sync false when sync empty", not svc.has_sync())
	# A config-level error (e.g. content_dir unset) short-circuits validate() with one
	# clear message instead of leaking an absolute path into a file-not-found error.
	svc._config_error = "content_dir not set in res://remote_config_editor.config.json"
	_check("config error short-circuits validate", svc.validate() == [svc._config_error])
	svc._config_error = ""


# ── check_sync seam (real OS.execute, deterministic external command) ───────────


func _test_check_sync_seam(svc, tmp: String) -> void:
	# Drives the actual OS.execute path with stock Unix tools standing in for the
	# project's comparator — confirms the {root} substitution + the stdout JSON scan,
	# the two bits the refactor moved off hardcoded constants. Skipped where absent.
	# (The comparator emits its JSON on STDOUT, so — unlike an arg — the quotes
	# survive the shell OS.execute uses when capturing output; cat a temp file.)
	if not (FileAccess.file_exists("/bin/cat") and FileAccess.file_exists("/bin/echo")):
		return
	# 1. The results line is found + parsed (key/version surfaced; ok tracks exit 0).
	var results_file := tmp.path_join("sync_results.json")
	_write(results_file, '{"results":[{"key":"k","status":"match","committed_version":"7"}]}')
	svc.config = {"root": "res://", "sync": {"program": "/bin/cat", "args": [results_file]}}
	var r: Dictionary = svc.check_sync()
	var results: Array = r.get("results", [])
	_check("check_sync parses a results line", results.size() == 1 and str(results[0]["key"]) == "k")
	_check("check_sync ok on exit 0", bool(r.get("ok", false)) and int(r.get("code", -1)) == 0)
	# 2. {root} in an arg is replaced with the resolved root (echoed back verbatim).
	svc.config = {"root": "res://", "sync": {"program": "/bin/echo", "args": ["{root}"]}}
	_check("check_sync substitutes {root}", str(svc.check_sync().get("text", "")) == ServiceT._resolve("res://"))


# ── aggregation (pure, temp-dir driven) ─────────────────────────────────────────


func _test_aggregation(svc, tmp: String) -> void:
	# A clean two-entry manifest (beta deliberately at version 0).
	_write(tmp.path_join("manifest.json"), JSON.stringify({
		"app_config_version": "v1",
		"entries": [
			{"key": "alpha", "file": "alpha.json", "version_field": "v", "label": "Alpha"},
			{"key": "beta", "file": "beta.json", "version_field": "version", "label": "Beta"},
		]}, "  "))
	_write(tmp.path_join("alpha.json"), JSON.stringify({"v": 3, "x": 1}))
	_write(tmp.path_join("beta.json"), JSON.stringify({"version": 0, "y": 2}))
	# Reset config so app_config_version() reads the default "app_config_version" field.
	svc.config = svc.DEFAULTS.duplicate(true)
	svc.reload_from(tmp.path_join("manifest.json"), tmp, "content")

	var doc: Dictionary = svc.build_document()
	_check("build_document keys in manifest order", doc.keys() == ["alpha", "beta"])
	_check("build_document carries each blob", int(doc["alpha"]["x"]) == 1 and int(doc["beta"]["y"]) == 2)
	_check("app_config_version read", svc.app_config_version() == "v1")
	var vers: Array = svc.versions()
	_check("versions present + reads the per-entry field (incl version 0)",
		vers.size() == 2 and bool(vers[0]["present"]) and int(vers[0]["version"]) == 3 and int(vers[1]["version"]) == 0)
	_check("clean manifest validates []", svc.validate() == [])
	var cp: Dictionary = svc.copy_publish_payload()
	_check("copy_publish_payload ok on a clean set", cp.get("ok", false) and int(cp.get("count", 0)) == 2)

	# Numeric fidelity: the published text splices the RAW on-disk JSON, so integers
	# (incl. version 0) survive verbatim — NOT coerced to 1.0/0.0 like the parsed dict.
	var doc_text: String = svc.build_document_text()
	_check("payload preserves integers verbatim (no float coercion)",
		doc_text.contains('"v":3') and doc_text.contains('"version":0') and not doc_text.contains(".0"))
	_check("payload keys in manifest order + valid JSON",
		doc_text.find('"alpha"') < doc_text.find('"beta"')
		and JSON.parse_string(doc_text) != null)
	# A large 64-bit id past 2^53 must not lose precision (the parsed-dict path would).
	_write(tmp.path_join("alpha.json"), '{"v":3,"big_id":9007199254740993}')
	svc.reload_from(tmp.path_join("manifest.json"), tmp, "content")
	_check("payload preserves a >2^53 id without precision loss",
		svc.build_document_text().contains("9007199254740993"))


func _test_validate_cases(svc, tmp: String) -> void:
	# Missing version field.
	_write(tmp.path_join("manifest.json"), JSON.stringify({"app_config_version": "v1", "entries": [
		{"key": "alpha", "file": "alpha.json", "version_field": "nope", "label": "Alpha"}]}, "  "))
	svc.reload_from(tmp.path_join("manifest.json"), tmp, "content")
	_check("validate flags a missing version field",
		svc.validate().has("alpha: missing integer version field \"nope\""))

	# Missing content file — the message uses the human content label, not an abs path.
	_write(tmp.path_join("manifest.json"), JSON.stringify({"app_config_version": "v1", "entries": [
		{"key": "ghost", "file": "ghost.json", "version_field": "v", "label": "Ghost"}]}, "  "))
	svc.reload_from(tmp.path_join("manifest.json"), tmp, "content")
	_check("validate flags a missing content file (labeled path)",
		svc.validate().has("ghost: content file not found (content/ghost.json)"))
	_check("build_document skips a missing blob", svc.build_document().is_empty())

	# Duplicate key.
	_write(tmp.path_join("manifest.json"), JSON.stringify({"app_config_version": "v1", "entries": [
		{"key": "alpha", "file": "alpha.json", "version_field": "v", "label": "A"},
		{"key": "alpha", "file": "beta.json", "version_field": "version", "label": "B"}]}, "  "))
	svc.reload_from(tmp.path_join("manifest.json"), tmp, "content")
	_check("validate flags a duplicate key", svc.validate().has("alpha: duplicate key in manifest"))

	# Missing manifest hard-fails (no fallback list).
	svc.reload_from(tmp.path_join("does_not_exist.json"), tmp, "content")
	_check("missing manifest -> build_document is empty", svc.build_document().is_empty())
	_check("missing manifest -> validate reports it",
		svc.validate().size() == 1 and str(svc.validate()[0]).begins_with("manifest missing or has no entries"))
	_check("copy refuses an invalid document", not svc.copy_publish_payload().get("ok", true))


# ── helpers ─────────────────────────────────────────────────────────────────────


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _check(label: String, cond: bool) -> void:
	if not cond:
		_ok = false
		print("FAIL: %s" % label)
