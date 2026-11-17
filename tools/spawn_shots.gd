extends SceneTree

const AirdriftConfig := preload("../game/airdrift_config.gd")
const AirdriftGame := preload("../game/airdrift_game.gd")
const AirdriftCamera := preload("../game/airdrift_camera.gd")

## Third-person spawn frame on every map, to `screenshots/spawns/<map>.png`.
##
##   xvfb-run -a godot --path . --resolution 1280x720 --script tools/spawn_shots.gd -- [map ...]
##
## No maps named: every map in `maps/zones/`. One process, `change_map` between them. Not `--headless`
## (a null renderer saves empty frames). Run through `gpu.sh shot` for a real GPU.

const OUT_DIR := "res://screenshots/spawns"
const SETTLE := 40

var _game: AirdriftGame = null


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	DotFpsSampler.register_default_actions()
	var config := AirdriftConfig.new()
	config.auto_bhop = true
	config.initial_map = &""
	_game = AirdriftGame.new()
	_game.name = "Game"
	_game.config = config
	root.add_child(_game)
	_run.call_deferred()


func _maps() -> Array[String]:
	var wanted: Array[String] = []
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--"):
			wanted.append(a)
	if not wanted.is_empty():
		return wanted
	for f in DirAccess.get_files_at("res://maps/zones"):
		if f.ends_with(".json"):
			wanted.append(f.get_basename())
	wanted.sort()
	return wanted


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var failed := 0
	for id in _maps():
		var started: DotResult = await _game.change_map(StringName(id))
		if not started.ok:
			print("FAIL  %s: map did not load" % id)
			failed += 1
			continue
		_game.remove_player(&"local")
		var me := _game.add_player(&"local", "qa", true)
		me.sampler = null
		var _third := me.camera.set_mode(AirdriftCamera.Mode.THIRD_PERSON)
		for i in SETTLE:
			me.present(1.0 / 60.0)
			await process_frame
		await RenderingServer.frame_post_draw
		var err := root.get_texture().get_image().save_png("%s/%s.png" % [OUT_DIR, id])
		print("%s  %s  pos=%s" % ["ok  " if err == OK else "FAIL", id, me.controller.state.position])
		if err != OK:
			failed += 1
	quit(1 if failed > 0 else 0)
