extends Node

const AirdriftConfig := preload("../game/airdrift_config.gd")
const AirdriftGame := preload("../game/airdrift_game.gd")
const RouteBot := preload("../game/airdrift_route_bot.gd")

## Server tick profile: the game on one map with N bots, driven tick by tick (external tick), each phase of
## AirdriftGame._simulate_tick timed in microseconds, and with `--script-top N` (Godot started with -d) the N GDScript
## functions with the most self time. `--phases 0` runs the plain tick_once instead (the A/B timing: `--ticks N`).
## Run: godot --headless --path . res://tools/tick_prof.tscn -- --map bhop_g2g_intro --bots 16 --ticks 3000 [--script-top 30]
## Prints TICKPROF lines (phase, mean and p99 us per tick) and one TICKTOTAL line (mean us per tick).
## `--ab N` alternates the route bots between native (dot-sim `route`) and script every N ticks (the rides are the same
## to the bit, so both halves time the same work) and prints a TICKAB line per round (native then script block: tick
## and bots-phase means) and a TICKABSUM line (the mean and spread of the per-round differences).

const TICK_RATE := 128

var _game: AirdriftGame
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
	var ab := int(_arg("ab", "0"))
	if not await _start(map_id, bots, warm):
		get_tree().quit(2)
		return
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
	var ab_rows: Array = []  # per block: [native, tick sum, bots sum, count]
	for i in range(ticks):
		_tick += 1
		if ab > 0:
			var native := (i / ab) % 2 == 0
			if i % ab == 0:
				RouteBot.native_route = native
				ab_rows.append([native, 0.0, 0.0, 0])
		var t0 := Time.get_ticks_usec()
		if phases:
			_phased(step, acc)
		else:
			_game.tick_once(_tick)
		totals.append(Time.get_ticks_usec() - t0)
		if ab > 0 and phases:
			var row: Array = ab_rows[-1]
			row[1] += totals[-1]
			row[2] += (acc["bots"] as Array)[-1]
			row[3] += 1
		if i % 32 == 0:
			await get_tree().physics_frame
	if phases:
		for n: String in names:
			var a := PackedFloat64Array(acc[n])
			print("TICKPROF phase=%s mean_us=%.1f p99_us=%.1f" % [n, _mean(a), _pct(a, 0.99)])
	print("TICKTOTAL map=%s bots=%d ticks=%d phases=%s mean_us=%.1f p50_us=%.1f p99_us=%.1f" % [
		map_id, bots, ticks, phases, _mean(totals), _pct(totals, 0.5), _pct(totals, 0.99)])
	if ab > 0 and phases:
		_ab_report(ab_rows)
	RouteBot.native_route = true
	if scripts != null:
		var rep := scripts.stop(script_top, ticks)
		for f: Dictionary in rep.get("functions", []):
			print("TICKFUNC self_us_per_tick=%.1f calls_per_tick=%.2f us_per_call=%.2f %s::%s:%d" % [
				f.self_ms * 1000.0, f.calls_per_frame, f.us_per_call, str(f.script).get_file(), f.function, f.line])
	_game.queue_free()
	for _i in range(3):
		await get_tree().process_frame
	get_tree().quit(0)


## Builds the game on [param map_id] with [param bots] bots, ticks it until the bots have planned their routes, then
## [param warm] more ticks. False when the map would not load.
func _start(map_id: StringName, bots: int, warm: int) -> bool:
	var cfg := AirdriftConfig.new()
	cfg.records_directory = ""
	cfg.map_seconds = 0.0
	cfg.initial_map = &"bhop_g2g_intro"
	_game = AirdriftGame.new()
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
			return false
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
	return true


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


## One TICKAB line per native+script pair of blocks, then the mean and standard deviation of the differences.
func _ab_report(rows: Array) -> void:
	var d_tick := PackedFloat64Array()
	var d_bots := PackedFloat64Array()
	var r := 0
	while r + 1 < rows.size():
		var n: Array = rows[r]
		var s: Array = rows[r + 1]
		r += 2
		if n[3] == 0 or s[3] == 0:
			continue
		var nt: float = n[1] / n[3]
		var st: float = s[1] / s[3]
		var nb: float = n[2] / n[3]
		var sb: float = s[2] / s[3]
		d_tick.append(st - nt)
		d_bots.append(sb - nb)
		print("TICKAB round=%d native_tick_us=%.1f script_tick_us=%.1f native_bots_us=%.1f script_bots_us=%.1f" % [
			d_tick.size(), nt, st, nb, sb])
	print("TICKABSUM rounds=%d saved_tick_us=%.1f sd=%.1f saved_bots_us=%.1f sd=%.1f" % [
		d_tick.size(), _mean(d_tick), _sd(d_tick), _mean(d_bots), _sd(d_bots)])


static func _sd(a: PackedFloat64Array) -> float:
	if a.size() < 2:
		return 0.0
	var m := _mean(a)
	var s := 0.0
	for v in a:
		s += (v - m) * (v - m)
	return sqrt(s / (a.size() - 1))


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
