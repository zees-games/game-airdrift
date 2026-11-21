extends SceneTree

## The third-person camera (AirdriftCamera's boom, dot-core's GSCameraBoom) flown round the walls
## of the start map, armed; `mp_forceview` and the older `sv_allow_thirdperson` through the
## camera's own path; with a display, both views of the real player.
##
##   godot --headless --path . --script tools/camera_check.gd          # the checks
##   xvfb-run -a godot --path . --resolution 1280x720 --script tools/camera_check.gd   # and frames

const AirdriftCamera := preload("../game/airdrift_camera.gd")
const AirdriftConfig := preload("../game/airdrift_config.gd")
const AirdriftGame := preload("../game/airdrift_game.gd")
const AirdriftPlayer := preload("../game/airdrift_player.gd")

var _game: AirdriftGame = null
var _failed := false


func _initialize() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	GSFpsSampler.register_default_actions()
	var config := AirdriftConfig.new()
	config.auto_bhop = true
	_game = AirdriftGame.new()
	_game.name = "Game"
	_game.config = config
	root.add_child(_game)
	_run.call_deferred()


func _run() -> void:
	while _game.maps == null or _game.maps.current == null:
		await process_frame
	var me := _game.add_player(&"local", "gamemann", true)
	me.sampler = null
	for i in 6:
		await physics_frame

	var camera: AirdriftCamera = me.camera
	var offset := Vector3(0.0, camera.third_person_height, camera.third_person_distance)
	var pivots := GSCameraCheck.pivots_near_walls(root.get_world_3d(), AABB(Vector3(-200, -60, -200), Vector3(400, 160, 400)), 1, 1.6, 4.0, 3.0, 40)
	var got := {}
	for pivot in pivots:
		got = GSCameraCheck.add(got, GSCameraCheck.fly(root.get_world_3d(), GSCameraCheck.orbit_path(pivot), offset, 1))
	_check(not got.is_empty() and GSCameraCheck.passed(got), "third person round %d places by the walls: %s" % [pivots.size(), GSCameraCheck.summary(got) if not got.is_empty() else "no places"])

	_check(camera.toggle() and camera.is_third_person(), "the view key goes to third person")
	_game.view_rules.force_view = GSPlayerViewRules.FIRST_ONLY
	_check(not camera.is_third_person() and not camera.toggle(), "mp_forceview 1: back in first person, and the key refuses")
	_game.view_rules.force_view = GSPlayerViewRules.THIRD_ONLY
	_check(camera.is_third_person() and not camera.toggle(), "mp_forceview 2: held in third person")
	_game.view_rules.force_view = GSPlayerViewRules.ANY
	_check(not _game.config.allow_thirdperson == false, "and the config's switch follows the rule")

	if DisplayServer.get_name() != "headless":
		DirAccess.make_dir_recursive_absolute("screenshots/cameras")
		var _first := camera.set_mode(AirdriftCamera.Mode.FIRST_PERSON)
		await _shot(me, "airdrift_view_first")
		var _third := camera.set_mode(AirdriftCamera.Mode.THIRD_PERSON)
		await _shot(me, "airdrift_view_third")

	print("all passed" if not _failed else "FAILED")
	quit(1 if _failed else 0)


func _shot(me: AirdriftPlayer, file: String) -> void:
	for i in 10:
		me.present(1.0 / 60.0)
		await process_frame
	await RenderingServer.frame_post_draw
	var path := "screenshots/cameras/%s.png" % file
	var _saved := root.get_texture().get_image().save_png(path)
	print("  wrote %s" % path)


func _check(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failed = true
