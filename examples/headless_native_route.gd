extends GSGameCheckSuite

const AirdriftConfig := preload("../game/airdrift_config.gd")
const AirdriftGame := preload("../game/airdrift_game.gd")
const RouteBot := preload("../game/airdrift_route_bot.gd")

## dot-sim's route bots (`GSSimRouteBots`, every route bot of a tick in one native call) held to
## `AirdriftRouteBot.command` in script, to the bit. [codeblock] godot --headless --path . res://examples/headless_native_route.tscn [/codeblock]
## Per map, the same seeded lobby of route bots is ridden three times from a fresh game: all script
## (`native_route` off), native, and native under `route_verify` (each bot's tick re-run in script
## on the same state, its command and its whole state compared). The script and native rides
## must leave every bot at the same position and velocity on every tick, and verify must find no
## difference. Only the bots' commands are produced here: the motor, hit registration and lag
## compensation are the game's as before. With no dot-sim `route` it says the native half was
## skipped and passes; `GS_SIM_REQUIRE_NATIVE=1` fails instead.

const MAPS: Array[StringName] = [&"bhop_g2g_intro", &"surf_g2g_intro"]
const BOTS := 12
const TICKS := 1600
const SEED := 4711

var _entered := 0
var _completed := 0
var _routed := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("Airdrift — native route bots parity")
	var was := RouteBot.native_route
	var was_verify := RouteBot.route_verify
	if not GSSim.has(&"route"):
		print("SKIP: dot-sim's route module is not loaded: the native half is skipped")
		if (OS.get_environment("GS_SIM_REQUIRE_NATIVE") if OS.has_environment("GS_SIM_REQUIRE_NATIVE") else OS.get_environment("DOT_SIM_REQUIRE_NATIVE")) == "1":
			_check(false, "the library is loaded (GS_SIM_REQUIRE_NATIVE=1)")
		_report_sections(0, 0, 0)
		return
	for id in MAPS:
		await _map_runs(id)
	RouteBot.native_route = was
	RouteBot.route_verify = was_verify
	_check(_routed > 0, "at least one map rode on a route (%d)" % _routed)
	_report_sections(_entered, _completed, MAPS.size())


func _map_runs(id: StringName) -> void:
	_entered += 1
	print("")
	print("== %s" % id)
	var a := await _ride(id, false, false)
	if a.is_empty():
		_check(false, "%s: the game booted on the map" % id)
		return
	if a["mode"] != &"route":
		print("  rides in %s mode, not route: nothing native to compare" % a["mode"])
		_completed += 1
		return
	_routed += 1
	_check(a["native"] == 0, "%s script: stayed out of the library" % id)
	_check(a["moved"] > 1.0, "%s script: the bots rode (farthest %.1f m)" % [id, a["moved"]])
	var b := await _ride(id, true, false)
	_check(b["native"] >= BOTS * (TICKS / 2), "%s native: the bots were driven in the library (%d bot ticks)" % [id, b["native"]])
	var first := -1
	var ticks: Array = a["ticks"]
	for i in range(ticks.size()):
		if i >= b["ticks"].size() or ticks[i] != b["ticks"][i]:
			first = i
			break
	_check(first < 0, "%s native: every bot's position and velocity matched the script's on all %d ticks" % [id, ticks.size()],
		"first difference on tick %d" % first)
	var c := await _ride(id, true, true)
	_check(c["checked"] >= BOTS * (TICKS / 2) and c["mismatches"] == 0,
		"%s verify: %d native bot ticks re-run in script, %d differed" % [id, c["checked"], c["mismatches"]])
	_completed += 1


## One ride from a fresh game: per tick, every bot's position and velocity packed into one array.
func _ride(id: StringName, native: bool, verify: bool) -> Dictionary:
	RouteBot.native_route = native
	RouteBot.route_verify = verify
	RouteBot.native_driven = 0
	RouteBot.verify_checked = 0
	RouteBot.verify_mismatches = 0
	seed(SEED)
	var cfg := AirdriftConfig.new()
	cfg.records_directory = ""
	cfg.map_seconds = 0.0
	cfg.initial_map = id
	var game := AirdriftGame.new()
	game.config = cfg
	game.external_tick = true
	add_child(game)
	for _i in range(120):
		await get_tree().process_frame
		if game.maps != null and game.maps.current != null:
			break
	if game.maps == null or game.maps.current == null:
		game.queue_free()
		return {}
	if game.maps.current.id != id:
		var changed: GSResult = await game.change_map(id)
		if not changed.ok:
			game.queue_free()
			return {}
	for i in range(BOTS):
		game.bots.call("add_bot", "bot%d" % (i + 1))
	for _i in range(40):
		await get_tree().process_frame
	var tick := 0
	while game.bots.get("_planning") and tick < 60000:
		tick += 1
		game.tick_once(tick)
		if tick % 32 == 0:
			await get_tree().physics_frame
	var out := {"mode": game.bots.get("mode"), "ticks": [], "moved": 0.0}
	var ids: Array = game.bots.get("ids")
	var start := Vector3.INF
	for t in range(TICKS):
		tick += 1
		game.tick_once(tick)
		var row := PackedVector3Array()
		for bot_id: StringName in ids:
			var player: Node = game.players.get(bot_id)
			if player == null:
				continue
			var state: GSFpsState = player.get("controller").state
			var at := state.position
			row.append(at)
			row.append(state.velocity)
			if start == Vector3.INF:
				start = at
			out["moved"] = maxf(out["moved"], at.distance_to(start))
		out["ticks"].append(row)
		if t % 32 == 0:
			await get_tree().physics_frame
	out["native"] = RouteBot.native_driven
	out["checked"] = RouteBot.verify_checked
	out["mismatches"] = RouteBot.verify_mismatches
	print("  %-8s %s: %d ticks, farthest %.1f m, %d native bot ticks, %d verified, %d differed" % [
		("verify" if verify else ("native" if native else "script")), id, TICKS, out["moved"], out["native"],
		out["checked"], out["mismatches"]])
	remove_child(game)
	game.free()
	for _i in range(4):
		await get_tree().process_frame
	return out
