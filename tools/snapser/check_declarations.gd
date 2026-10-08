extends SceneTree

## Cross-check a game's snapser_kit.config.json "declared" section (and its
## leaderboards / cloud-save blob) against its snapser/snapend-manifest.json.
## Run through check_declarations.sh, or directly:
##
##   godot --headless --path <godot-addons> --script res://tools/snapser/check_declarations.gd \
##       -- --config=/abs/game/snapser_kit.config.json --manifest=/abs/snapser/snapend-manifest.json
##
## Exit 0 = consistent, 1 = problems (listed), 2 = bad arguments. Offline: reads
## two files, no network. Games can run the same check in their own headless
## tests: SnapKitConfig.from_dict(cfg).declaration_problems(manifest).


func _initialize() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			args[a.substr(2, a.find("=") - 2)] = a.substr(a.find("=") + 1)
	var cfg_raw: Variant = _read(str(args.get("config", "")))
	var man: Variant = _read(str(args.get("manifest", "")))
	if not (cfg_raw is Dictionary) or not (man is Dictionary):
		print("check_declarations: --config=<snapser_kit.config.json> and --manifest=<snapend-manifest.json> must both be readable JSON objects")
		quit(2)
		return
	var cfg := SnapKitConfig.from_dict(cfg_raw)
	var on_server := SnapKitConfig.manifest_names(man)
	for kind in SnapKitConfig.DECLARED_KINDS:
		print("  %-7s config: %s" % [kind, str(cfg.declared.get(kind, "(not declared — unchecked)"))])
		print("  %-7s server: %s" % ["", str(on_server[kind])])
	var problems := cfg.declaration_problems(man)
	for p in problems:
		print("  PROBLEM " + p)
	print("check_declarations: %s" % ("OK" if problems.is_empty() else "%d problem(s)" % problems.size()))
	quit(0 if problems.is_empty() else 1)


func _read(path: String) -> Variant:
	if path == "" or not FileAccess.file_exists(path):
		return null
	return SnapKitJson.parse(FileAccess.get_file_as_string(path))
