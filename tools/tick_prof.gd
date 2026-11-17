extends Node

const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")

## Server tick profile: the game on one map with N bots, driven tick by tick (external tick), each phase of
## G2GGame._simulate_tick timed in microseconds, and with `--script-top N` (Godot started with -d) the N GDScript
## functions with the most self time. `--phases 0` runs the plain tick_once instead (the A/B timing: `--ticks N`).
## Run: godot --headless --path . res://tools/tick_prof.tscn -- --map bhop_g2g_intro --bots 16 --ticks 3000 [--script-top 30]
## Prints TICKPROF lines (phase, mean and p99 us per tick) and one TICKTOTAL line (mean us per tick).

const TICK_RATE := 128

var _game: G2GGame
var _tick := 0


func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--" + name)
	if at >= 0 and at + 1 < args.size():
		return args[at + 1]
	return fallback


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	var map_id := StringName(_arg("map", "bhop_g2g_intro"))
	var bots := int(_arg("bots", "16"))
	var ticks := int(_arg("ticks", "3000"))
	var warm := int(_arg("warm", "600"))
	var phases := _arg("phases", "1") == "1"
	var script_top := int(_arg("script-top", "0"))
	var cfg := G2GConfig.new()
	cfg.records_directory = ""
	cfg.map_seconds = 0.0
	cfg.initial_map = &"bhop_g2g_intro"
	_game = G2GGame.new()
	_game.config = cfg
	_game.external_tick = true
	add_child(_game)
	for _i in range(120):
		await get_tree().process_frame
		if _game.maps != null and _game.maps.current != null:
			break
	if map_id != _game.maps.current.id:
		var changed: DotResult = await _game.change_map(map_id)
		if not changed.ok:
			printerr("TICKPROF map failed: ", changed.error.message)
			get_tree().quit(2)
			return
	for i in range(bots):
		_game.bots.call("add_bot", "bot%d" % (i + 1))
	for _i in range(40):
		await get_tree().process_frame
	var planned := 0
	while _game.bots.get("_planning") and planned < 60000:
		_tick += 1
		_game.tick_once(_tick)
		planned += 1
		if planned % 32 == 0:
			await get_tree().physics_frame
	for i in range(warm):
		_tick += 1
		_game.tick_once(_tick)
		if i % 32 == 0:
			await get_tree().physics_frame
	var scripts: DotProfilerScripts = null
	if script_top > 0:
		scripts = DotProfilerScripts.new()
		var started := scripts.start()
		if not started.ok:
			printerr("TICKPROF ", started.error.message)
			scripts = null
	var names := ["maps", "bots", "players", "progress", "combat", "hunters", "props", "effects", "spectate", "timers", "stack"]
	var acc := {}
	for n: String in names:
		acc[n] = []
	var totals := PackedFloat64Array()
	var step := 1.0 / float(TICK_RATE)
	for i in range(ticks):
		_tick += 1
		var t0 := Time.get_ticks_usec()
		if phases:
			_phased(step, acc)
		else:
			_game.tick_once(_tick)
		totals.append(Time.get_ticks_usec() - t0)
		if i % 32 == 0:
			await get_tree().physics_frame
	if phases:
		for n: String in names:
			var a := PackedFloat64Array(acc[n])
			print("TICKPROF phase=%s mean_us=%.1f p99_us=%.1f" % [n, _mean(a), _pct(a, 0.99)])
	print("TICKTOTAL map=%s bots=%d ticks=%d phases=%s mean_us=%.1f p50_us=%.1f p99_us=%.1f" % [
		map_id, bots, ticks, phases, _mean(totals), _pct(totals, 0.5), _pct(totals, 0.99)])
	if scripts != null:
		var rep := scripts.stop(script_top, ticks)
		for f: Dictionary in rep.get("functions", []):
			print("TICKFUNC self_us_per_tick=%.1f calls_per_tick=%.2f us_per_call=%.2f %s::%s:%d" % [
				f.self_ms * 1000.0, f.calls_per_frame, f.us_per_call, str(f.script).get_file(), f.function, f.line])
	_game.queue_free()
	for _i in range(3):
		await get_tree().process_frame
	get_tree().quit(0)


func _phased(step: float, acc: Dictionary) -> void:
	var g := _game
	var t := Time.get_ticks_usec()
	g.maps.advance(step)
	t = _lap(acc, "maps", t)
	if g.bots != null:
		g.bots.call("drive", step)
	t = _lap(acc, "bots", t)
	for id in g.players:
		g.players[id].simulate(_tick, step)
	t = _lap(acc, "players", t)
	if g.progress != null:
		g.progress.sample(step)
	t = _lap(acc, "progress", t)
	if g.combat != null:
		g.combat.tick(step)
		g.weapon_layer.tick(step)
	t = _lap(acc, "combat", t)
	if g.hunters != null:
		g.hunters.tick(step)
	t = _lap(acc, "hunters", t)
	if g.props != null:
		g.props.tick(step)
	t = _lap(acc, "props", t)
	if g.effects != null:
		g.effects.tick(step)
	t = _lap(acc, "effects", t)
	if g.spectate != null:
		g.spectate.tick(step)
	t = _lap(acc, "spectate", t)
	g._feed_timers()
	t = _lap(acc, "timers", t)
	if g.player_stack != null:
		g.player_stack.tick(_tick)
	_lap(acc, "stack", t)


func _lap(acc: Dictionary, name: String, since: int) -> int:
	var now := Time.get_ticks_usec()
	(acc[name] as Array).append(now - since)
	return now


static func _mean(a: PackedFloat64Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += v
	return s / a.size()


static func _pct(a: PackedFloat64Array, p: float) -> float:
	if a.is_empty():
		return 0.0
	var b := a.duplicate()
	b.sort()
	return b[mini(int(b.size() * p), b.size() - 1)]
