extends SceneTree

const AirdriftClient := preload("../game/airdrift_client.gd")

## Frames for the README from the real offline client: `tools/readme_shots.sh run|surf <map> [seconds]` (a strafing auto-bhop
## run, from the start or a ramp), `start|style|maps|board <map>` (start zone, Gameplay page, map list, scoreboard).
## The driver alternates A and D while turning the same way, so jumps, strafes and sync are measured from real movement.

const OUT_DIR := "res://screenshots"
const TURN_DEG_PER_SEC := 95.0
const SWITCH_SECS := 0.32

var _client: AirdriftClient = null
var _kind := "run"
var _seconds := 6.0
var _loaded := 0
var _t := 0.0
var _last_usec := 0
var _next_shot := 1.0
var _shots := 0
var _dir := 1.0
var _flip := SWITCH_SECS
var _stage := 0
var _wait := 0
var _entry := Vector3.ZERO


func _initialize() -> void:
	GSLog.set_level(GSLog.Level.WARN)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var args := OS.get_cmdline_user_args()
	_kind = args[0] if args.size() > 0 else "run"
	if args.size() > 1 and args[1] != "":
		OS.set_environment("AIRDRIFT_INITIAL_MAP", args[1])
	if args.size() > 2:
		_seconds = float(args[2])
	_client = (load("res://game/airdrift.tscn") as PackedScene).instantiate() as AirdriftClient
	_client.force_offline = true
	root.add_child(_client)
	_last_usec = Time.get_ticks_usec()
	process_frame.connect(_on_frame)
	print("[readme] renderer: ", RenderingServer.get_video_adapter_name(), " / ", RenderingServer.get_rendering_device().get_device_name() if RenderingServer.get_rendering_device() != null else "none")


# Driven from process_frame (not _process): a capture tool, not game code,
# and the frame-hazard gate scans only _process roots.
func _on_frame() -> void:
	var now := Time.get_ticks_usec()
	var delta := float(now - _last_usec) / 1000000.0
	_last_usec = now
	if _step(delta):
		quit()


func _step(delta: float) -> bool:
	if _client.player == null or _client.game == null or _client.game.maps.current == null:
		return false
	if _loaded < 90:
		_loaded += 1
		if _loaded == 1:
			_client.presentation.settings.local_store = GSSettingsStoreMemory.new()
			_client.presentation.settings.load_now()
			_client.presentation.apply_all()
		return false
	if _wait > 0:
		_wait -= 1
		return false
	match _kind:
		"run", "surf":
			return _drive(delta)
		"start":
			return _still_start()
		"style":
			return _still_menu()
		"maps":
			return _still_maps()
		"board":
			return _still_board()
	push_error("unknown scenario " + _kind)
	return true


func _drive(delta: float) -> bool:
	var sampler = _client.player.sampler
	if _stage == 0:
		_stage = 1
		var args := OS.get_cmdline_user_args()
		if _kind == "surf" and args.size() > 6:
			var at := Vector3(float(args[3]), float(args[4]), float(args[5]))
			_client.player.teleport(at, float(args[6]))
			if sampler != null:
				sampler.yaw = float(args[6])
			if args.size() > 7:
				var spd := float(args[7])
				var yaw := deg_to_rad(float(args[6]))
				_client.player.controller.state.velocity = Vector3(-sin(yaw), 0, -cos(yaw)) * spd
		_wait = 10
		return false
	_t += delta
	_flip -= delta
	if _flip <= 0.0:
		_flip = SWITCH_SECS
		_dir = -_dir
	if sampler != null:
		sampler.yaw += _dir * TURN_DEG_PER_SEC * delta
	_press("gs_fps_left", _dir > 0.0)
	_press("gs_fps_right", _dir < 0.0)
	_press("gs_fps_jump", true)
	if _t >= _next_shot:
		_next_shot += 0.5
		_capture("readme_%s_%s_%02d" % [_kind, _client.game.maps.current.id, _shots])
		_shots += 1
	if _t >= _seconds:
		_release()
		quit(0)
		return true
	return false


func _release() -> void:
	for a in ["gs_fps_left", "gs_fps_right", "gs_fps_jump"]:
		Input.action_release(a)


func _press(action: String, down: bool) -> void:
	if down:
		Input.action_press(action)
	else:
		Input.action_release(action)


func _still_start() -> bool:
	# Four looks from the spawn (every 90 degrees), so the one that shows the zone can be chosen.
	var sampler = _client.player.sampler
	if _stage == 0:
		_yaw0 = sampler.yaw if sampler != null else 0.0
		_stage = 1
	if _stage == 1:
		if sampler != null:
			sampler.yaw = _yaw0 + 90.0 * float(_look)
			sampler.pitch = -12.0
		_stage = 2
		_wait = 30
		return false
	_capture("readme_start_%s_%d" % [_client.game.maps.current.id, _look])
	_look += 1
	_stage = 1
	if _look >= 4:
		quit(0)
		return true
	return false


var _yaw0 := 0.0
var _look := 0


func _still_menu() -> bool:
	if _stage == 0:
		_stage = 1
		_client.open_menu(&"gameplay")
		_wait = 20
		return false
	if _stage == 1:
		_stage = 2
		for node in _client.menu.screen.find_children("*", "OptionButton", true, false):
			(node as OptionButton).show_popup()
			break
		_wait = 20
		return false
	_capture("readme_style_%s" % _client.game.maps.current.id)
	quit(0)
	return true


func _still_maps() -> bool:
	if _stage == 0:
		_stage = 1
		_client.open_map_list()
		_client.menu.picker.turn(-1)
		_wait = 20
		return false
	_capture("readme_maps_%s" % _client.game.maps.current.id)
	quit(0)
	return true


func _still_board() -> bool:
	if _stage == 0:
		_stage = 1
		_client.menu.scoreboard.source = func() -> Dictionary:
			return {"server": {"name": "Airdrift", "game": "airdrift", "map": _client.game.maps.current.id, "players": 6, "max": 24},
				"header": {"": "Time left 23:41"}, "you": 3,
				"players": [
					{"id": 1, "name": "Ada", "style": "Normal", "best": 72.418, "rank": 1, "of": 41, "seconds": 3912, "ping": 24},
					{"id": 2, "name": "Bea", "style": "Sideways", "best": 95.002, "rank": 3, "of": 12, "seconds": 1260, "ping": 61},
					{"id": 3, "name": "Cy", "style": "Normal", "best": 80.115, "rank": 6, "of": 41, "seconds": 432, "ping": 38},
					{"id": 4, "name": "Dot", "style": "Backwards", "best": -1.0, "rank": 0, "seconds": 75, "ping": 142},
					{"id": 5, "name": "Eli", "style": "Low gravity", "best": 88.731, "rank": 14, "of": 41, "seconds": 2207, "ping": 215},
					{"id": 6, "name": "Fin", "style": "Prebhop", "best": -1.0, "rank": 0, "seconds": 18, "ping": 40},
				]}
		_client.menu.scoreboard.open()
		_wait = 20
		return false
	_capture("readme_board_%s" % _client.game.maps.current.id)
	quit(0)
	return true


func _capture(name: String) -> void:
	var image := root.get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, name]
	if image.save_png(path) != OK:
		push_error("could not write " + path)
		return
	print("[readme] %s  %dx%d" % [path, image.get_width(), image.get_height()])
