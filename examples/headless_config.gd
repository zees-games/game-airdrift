extends GSGameCheckSuite

## AirdriftConfig through GSGameConfigBinder: fields, cvars, the deathmatch rules reading them, strict refusal, the diff.
## Run: godot --headless --path . res://examples/headless_config.tscn

const AirdriftArsenal := preload("../game/airdrift_arsenal.gd")
const AirdriftConfig := preload("../game/airdrift_config.gd")
const AirdriftGame := preload("../game/airdrift_game.gd")
const AirdriftMapMechanics := preload("../game/airdrift_map_mechanics.gd")
const AirdriftUnits := preload("../game/airdrift_units.gd")
const AirdriftZoneEditor := preload("../game/airdrift_zone_editor.gd")
## One directory per suite process (the probe child is handed its parent's): user:// is shared by
## every copy of this project on a box, and two suites at once wrote and deleted each other's cfg files.
const ROOT_ARG := "--cfgroot="
var ROOT := _root()
const GAME := "game-airdrift"
const CHECKS := 41
const SECTIONS := 4

var _entered := 0
var _completed := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.FATAL)
	_run.call_deferred()


func _root() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(ROOT_ARG):
			return a.substr(ROOT_ARG.length())
	return "user://airdrift_cfgtest_%d" % OS.get_process_id()


func _run() -> void:
	if OS.get_cmdline_user_args().has("--probe"):
		_probe()
		return
	print("Airdrift: config binder")
	_section("fields, cvars and rules")
	var config := AirdriftConfig.new()
	var binder := AirdriftConfig.make_binder(config)
	binder.strict = true
	_check(GSAddonConfig.game_names("game-airdrift") == PackedStringArray(["game-g2gfast", "game-airdrift"]), "the binder registers game-g2gfast as game-airdrift's former id", str(GSAddonConfig.game_names("game-airdrift")))  # legacy id
	_check(binder.load_layers().ok, "defaults load")
	_check(binder.diff().is_empty(), "no diff at the code defaults")
	_check(binder.schema().size() >= 55, "every exported field is in the schema")
	var console := GSConsole.new()
	add_child(console)
	binder.bind_cvars(console.cvar, GSConVar.FLAG_ARCHIVE, console.has_name)
	_check(console.get_int("airdrift_score_limit") == 40 and console.get_int("airdrift_max_players") == 64, "cvars start at the defaults")
	console.set_cvar("airdrift_max_players", "300")
	_check(config.max_players == 300, "max_players is not capped at the old 128")
	console.set_cvar("airdrift_max_players", "64")
	var cap_src := FileAccess.get_file_as_string("res://game/airdrift_module.gd") + FileAccess.get_file_as_string("res://game/airdrift_client.gd")
	_check(not cap_src.contains("max_entities_per_snapshot = 64"), "no 64-entity snapshot cap on server or client")
	console.set_cvar("airdrift_respawn_delay", "4")
	_check(config.respawn_delay == 4.0 and binder.source_of("respawn_delay") == "cvar", "a cvar writes the field")
	var rules := AirdriftArsenal.match_rules(config.score_limit, config.respawn_delay, config.spawn_protection)
	_check(rules.respawn_delay_sec == 4.0 and rules.spawn_protection_sec == 2.0, "the match rules read the config")
	_check(AirdriftArsenal.match_rules().respawn_delay_sec == 1.0, "and keep the old defaults without it")
	var mechanics := AirdriftMapMechanics.new()
	_check(mechanics.lethal_damage == config.lethal_damage, "the map mechanics start at the configured lethal damage")
	_check(binder.diff_yaml().contains("respawn_delay: 4"), "the diff names the edit")
	config.max_velocity = 10.0
	_check(not config.validate().ok, "validate refuses a max_velocity below max_speed")
	config.max_velocity = 3500.0
	_check(config.zone_editor_max_number == 99 and config.zone_editor_max_height == 2048.0
		and config.zone_mark_max_height == 4096.0, "the zone limits default to the old caps")
	_check(config.validate().ok, "the defaults validate")
	config.zone_editor_max_number = -1
	_check(not config.validate().ok, "a negative stage limit is refused, not clamped")
	config.zone_editor_max_number = 99
	config.zone_editor_max_height = -16.0
	_check(not config.validate().ok, "a negative height limit is refused, not clamped")
	config.zone_editor_max_height = 2048.0
	var at_cap := AirdriftZoneEditor.step_limited(99.0, 1.0, 99.0, "stage number")
	_check(not at_cap.ok and at_cap.value == 99.0 and at_cap.message.contains("limit"), "past the limit the step fails loudly and keeps the value")
	_check(AirdriftZoneEditor.step_limited(98.0, 1.0, 99.0, "stage number").value == 99.0, "up to the limit it steps")
	_check(AirdriftZoneEditor.step_limited(99.0, 1.0, 0.0, "stage number").value == 100.0, "0 is unlimited: stage 100")
	_check(AirdriftZoneEditor.step_limited(2048.0, 16.0, 0.0, "zone height").value == 2064.0, "0 is unlimited: height past 2048")
	_check(binder.schema()[0]["description"].length() > 5, "doc comments reach the schema")
	_check(binder.write_schema(ROOT + "_schema_check.json").ok, "write_schema works")
	var timer_config := AirdriftGame.make_timer_config(config, 64, true)
	_check(is_equal_approx(timer_config.hull_extent, 0.6096) and is_equal_approx(timer_config.hull_extent, AirdriftUnits.to_metres(AirdriftUnits.PLAYER_WIDTH)), "the timer config carries the 32-unit hull (0.61 m) for the thin-zone warning", str(timer_config.hull_extent))
	var fall := AirdriftGame.make_fall_rules()
	var _made := fall.bind_cvars(console.cvar, GSConVar.FLAG_NOTIFY)
	_check(console.get_int("sv_falldamage") == 0 and not fall.enabled, "fall damage is off in this game by default")
	_check(fall.damage_for(60.0) == 0.0, "a 60 m/s landing costs nothing while it is off")
	console.set_cvar("sv_falldamage", "1")
	_check(fall.enabled and fall.damage_for(60.0) > 0.0, "the cvar is the only way on (and it works)")
	var manager := GSCombatManager.new()
	var ff_rules := GSDamageRules.new()
	ff_rules.friendly_fire = config.friendly_fire
	manager.rules = ff_rules
	var _ff := manager.bind_cvars(console.cvar, GSConVar.FLAG_NOTIFY | GSConVar.FLAG_REPLICATED)
	_check(console.get_int("mp_friendlyfire") == 1, "mp_friendlyfire starts at the game's rule (on)")
	console.set_cvar("mp_friendlyfire", "0")
	_check(not ff_rules.friendly_fire, "the cvar drives the damage rules")
	manager.free()
	_done()
	_section("layers")
	_layers()
	_done()
	_section("shipped templates")
	_templates(binder)
	_done()
	_check_workbench(binder)
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


## The workbench lists every key of the binder's schema across its profile files.
func _check_workbench(binder: GSGameConfigBinder) -> void:
	_section("workbench")
	var wb := GSGameWorkbench.new()
	wb.panel_mode = 1
	wb.config = {"enabled": false}
	for set: GSProfileSet in binder.profile_sets():
		wb.add_set(set, set.rel_path)
	add_child(wb)
	_check(wb.start().ok, "the workbench starts")
	binder.attach(wb.api.runtime)
	var listed := PackedStringArray()
	for kind: String in wb.api.kinds():
		var got: GSResult = wb.api.handle(GSGameWorkbench.LOCAL_ACTOR, {"op": "get", "kind": kind, "id": binder.profile_id})
		if got.ok:
			listed.append_array(PackedStringArray((got.value as Dictionary).get("values", {}).keys()))
	var missing := PackedStringArray()
	for e: Dictionary in binder.schema():
		if not listed.has(e["key"]):
			missing.append(e["key"])
	_check(missing.is_empty() and binder.profile_sets().size() == 4, "the workbench lists every key over 4 files: " + ",".join(missing))
	wb.free()
	_done()


## Child process: loads the layers strictly over the test root and prints what the live config holds.
func _probe() -> void:
	var config := AirdriftConfig.new()
	var binder := AirdriftConfig.make_binder(config)
	binder.strict = true
	binder.roots = PackedStringArray([ProjectSettings.globalize_path(ROOT)])
	var loaded := binder.load_layers()
	var console := GSConsole.new()
	add_child(console)
	binder.bind_cvars(console.cvar, GSConVar.FLAG_ARCHIVE, console.has_name)
	print("PROBE ok=%s grav=%s grav_src=%s score=%s score_src=%s cvar=%s delay=%s delay_src=%s" % [
		loaded.ok, config.gravity, binder.source_of("gravity"), config.score_limit, binder.source_of("score_limit"),
		console.find_cvar("airdrift_score_limit").get_string(), config.respawn_delay, binder.source_of("respawn_delay")])
	get_tree().quit(0)


func _write(rel: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ROOT.path_join(rel).get_base_dir())
	var f := FileAccess.open(ROOT.path_join(rel), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _child(arg := "--airdrift-respawn-delay=3.0") -> String:
	var out: Array = []
	OS.execute(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"),
		"res://examples/headless_config.tscn", "--", "--probe", ROOT_ARG + ROOT, arg], out, true)
	return "".join(PackedStringArray(out))


## A value set in a cfg file, the environment and argv each reaches the live config, and later layers win.
func _layers() -> void:
	_write("game/%s/config_movement/game.yml" % GAME, "gravity: 650.0\n")
	_write("game/%s/config_modes/game.yml" % GAME, "score_limit: 10\n")
	OS.set_environment("AIRDRIFT_SCORE_LIMIT", "25")
	var text := _child()
	_check(text.contains("PROBE ok=true"), "the layers load strictly in a fresh process: " + text.right(300))
	_check(text.contains("grav=650") and text.contains("grav_src=yml"), "a cfg file reaches the live config")
	_check(text.contains("score=25") and text.contains("score_src=env") and text.contains("cvar=25"), "the environment beats a file and reaches the cvar")
	_check(text.contains("delay=3") and text.contains("delay_src=argv"), "argv alone reaches the config")
	# The old prefixes (AirdriftConfig.LEGACY_*) are still read, and the new ones win over them.
	OS.set_environment(AirdriftConfig.LEGACY_ENV_PREFIX + "SCORE_LIMIT", "40")
	text = _child()
	_check(text.contains("score=25") and text.contains("score_src=env"), "the new environment prefix beats the old one")
	OS.unset_environment("AIRDRIFT_SCORE_LIMIT")
	text = _child(AirdriftConfig.LEGACY_CLI_PREFIX + "respawn-delay=4.0")
	_check(text.contains("PROBE ok=true") and text.contains("score=40") and text.contains("score_src=env"),
		"the old environment prefix alone still reaches the config: " + text.right(300))
	_check(text.contains("delay=4") and text.contains("delay_src=argv"), "the old argument prefix still reaches the config")
	OS.unset_environment(AirdriftConfig.LEGACY_ENV_PREFIX + "SCORE_LIMIT")
	_write("game/%s/config_modes/game.yml" % GAME, "gravity: 650.0\n")
	_check(_child().contains("PROBE ok=false"), "strict: a key in the wrong file is refused")
	for f in ["config_movement", "config_modes"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(ROOT.path_join("game/%s/%s/game.yml" % [GAME, f])))


## The shipped cfg files hold every key, in step with AirdriftConfig.
func _templates(binder: GSGameConfigBinder) -> void:
	var files := binder.template_files()
	_check(files.size() == 4, "four shipped cfg files: %d" % files.size())
	var stale := PackedStringArray()
	for path: String in files:
		if not FileAccess.file_exists("res://" + path) or FileAccess.get_file_as_string("res://" + path) != files[path]:
			stale.append(path)
	_check(stale.is_empty(), "the shipped files match the config (run addons/gs_game/qa/gs_game_cfg_templates.gd): " + ",".join(stale))


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("== %s" % title)


func _done() -> void:
	_completed += 1
