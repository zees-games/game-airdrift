extends RefCounted

const AirdriftHullView := preload("airdrift_hull_view.gd")
const AirdriftNetCommand := preload("airdrift_net_command.gd")

## Where every other player stood on a mover's screen, for [GSPlayerHullRewind] (`mp_solidplayers_unlag`). One rule on both ends:
## a command names how far behind its tick the sender drew the others (`view_lag_q`) and the snapshot pair (`view_back`, `view_span`);
## server (per-tick ring of wire-snapped feet) and client (interpolator samples) answer alike. A null answer leaves the hull; misses are logged.

const CHANNEL := "airdrift.hullview"

## A jump over this many metres between two samples is a teleport (a pit, a respawn), not movement: the hull stays where it is rather than sliding across the map.
const TELEPORT_CUT := 10.0

## Misses between two warnings.
const WARN_EVERY := 256

var rewind := GSPlayerHullRewind.new()

## Ticks the ring keeps per player. Set from `net.config.max_rewind_sec` and the tick rate, plus the bracket's slack; 0 keeps nothing (every answer is a miss).
var capacity: int = 0

## Answers by kind, for a test and a profile: `ring` (server), `interp` (client), `miss` (a tick not held), `teleport`, `none` (no view sent).
var counts: Dictionary = {"ring": 0, "interp": 0, "miss": 0, "teleport": 0, "none": 0}

var _game: Object = null
var _bridge: Object = null
var _is_server := false
var _feet: Dictionary = {}
var _wire_var: Object = null


func _init(game: Object, bridge: Object, is_server: bool) -> void:
	_game = game
	_bridge = bridge
	_is_server = is_server
	rewind.feet_fn = feet_for
	rewind.snap_fn = _snap


static func session_of(id: Variant) -> int:
	return String(id).trim_prefix("u").to_int()


## Runs [param work] for [param mover]'s step at [param tick] with the other hulls where the mover's last command said they were drawn.
func around(mover: Variant, tick: int, work: Callable) -> Variant:
	return rewind.around(_game.body_rules, mover, _game.hull_bodies, tick, work)



## Records every player's feet (wire-snapped) at [param tick], after the tick's moves. Server only.
func record(tick: int, positions: Dictionary) -> void:
	if capacity <= 0:
		return
	for id: Variant in positions:
		var by_tick: Dictionary = _feet.get_or_add(id, {})
		by_tick[tick] = _snap(positions[id])
		by_tick.erase(tick - capacity)
	# A player who left keeps nothing.
	if _feet.size() > positions.size():
		for id: Variant in _feet.keys():
			if not positions.has(id):
				_feet.erase(id)


## Feet of [param id] at exactly [param tick], or null.
func ring_at(id: Variant, tick: int) -> Variant:
	var by_tick: Dictionary = _feet.get(id, {})
	return by_tick.get(tick)


## [param id]'s feet blended between the samples at [param older] and [param newer] at [param render]; null when either is not held or they are a teleport apart.
func ring_between(id: Variant, older: int, newer: int, render: float) -> Variant:
	var a: Variant = ring_at(id, older)
	var b: Variant = ring_at(id, newer)
	if a == null or b == null:
		return _miss()
	if (a as Vector3).distance_to(b) > TELEPORT_CUT:
		return _teleported()
	var alpha := 0.0 if newer <= older else clampf((render - float(older)) / float(newer - older), 0.0, 1.0)
	counts["ring"] += 1
	return (a as Vector3).lerp(b, alpha)


## [param id]'s feet at [param render] with no bracket named: the two ticks around it.
func ring_near(id: Variant, render: float) -> Variant:
	var low := floori(render)
	return ring_between(id, low, low + 1 if float(low) < render else low, render)


func _miss() -> Variant:
	counts["miss"] += 1
	if int(counts["miss"]) % WARN_EVERY == 1:
		GSLog.warn(CHANNEL, "a hull rewind asked for a tick the ring does not hold; the hull stays where it is", {"misses": counts["miss"], "capacity": capacity})
	return null


func _teleported() -> Variant:
	counts["teleport"] += 1
	return null



## `(mover, other, tick) -> Vector3 or null` for [member rewind]: [param other]'s feet on [param mover]'s screen for its step at [param tick].
func feet_for(mover: Variant, other: Variant, tick: int) -> Variant:
	var behaviour: Object = _bridge.call(&"behaviour_for", session_of(mover))
	if behaviour == null or int(behaviour.get(&"last_view_q")) < 0:
		counts["none"] += 1
		return null
	var view := resolve(int(behaviour.get(&"last_view_q")), int(behaviour.get(&"last_view_tick")), int(behaviour.get(&"last_view_back")), int(behaviour.get(&"last_view_span")), tick)
	var render: float = view[0]
	var older: int = view[1]
	var span: int = view[2]
	if _is_server:
		return ring_between(other, older, older + span, render) if older >= 0 else ring_near(other, render)
	var theirs: Object = _bridge.call(&"behaviour_for", session_of(other))
	var net: Object = _bridge.get(&"net")
	if theirs == null or theirs.get(&"identity") == null or net == null or net.get(&"interpolator") == null:
		return null
	var id: int = (theirs.get(&"identity") as Object).get(&"net_id")
	var answer: Variant
	if older >= 0:
		answer = net.interpolator.value_between(id, &"net_position", older, older + span, render, TELEPORT_CUT)
	else:
		answer = net.interpolator.value_at(id, &"net_position", render, TELEPORT_CUT)
	counts["interp" if answer != null else "miss"] += 1
	return answer


## `[render, older, span]` for a step at [param tick] from the last command heard: [param command_tick] is the tick it was for. A command repeated over a lost packet keeps its lag, and the pair it named is stepped on by [param span] until it brackets the render tick, as the client's would have been.
## older is -1 for no bracket.
static func resolve(lag_q: int, command_tick: int, back: int, span: int, tick: int) -> Array:
	var render := float(tick) - float(lag_q) * 0.25
	var older := -1
	if back >= 0 and command_tick >= 0:
		older = command_tick - back
		if span > 0 and render > float(older + span):
			older += int((render - float(older)) / float(span)) * span
			if float(older) > render:
				older -= span
	return [render, older, span]


## Sets the lag and bracket on [param command] for [param tick] as this client draws the others now. Leaves none when the interpolator is not running yet.
func fill(command: AirdriftNetCommand, tick: int) -> void:
	command.view_lag_q = -1
	command.view_back = -1
	command.view_span = 0
	var net: Object = _bridge.get(&"net")
	if net == null or net.get(&"interpolator") == null or not net.clock.is_synced():
		return
	var drawn: float = float(net.clock.received_tick()) + clampf(net.clock.render_alpha(), -1.0, 2.0) + net.clock.receive_slip() - net.interpolator.delay_ticks()
	var q := clampi(roundi((float(tick) - drawn) * 4.0), 0, AirdriftNetCommand.MAX_VIEW_LAG_Q)
	command.view_lag_q = q
	var pair: Vector2i = net.interpolator.bracket_at(float(tick) - float(q) * 0.25)
	if pair.x >= 0 and tick - pair.x < (1 << AirdriftNetCommand.VIEW_BACK_BITS) and pair.y - pair.x < (1 << AirdriftNetCommand.VIEW_SPAN_BITS):
		command.view_back = tick - pair.x
		command.view_span = pair.y - pair.x


func _snap(feet: Vector3) -> Vector3:
	if _wire_var == null and _game != null and _bridge != null:
		for id: Variant in _game.players:
			var behaviour: Object = _bridge.call(&"behaviour_for", session_of(id))
			if behaviour != null:
				_wire_var = behaviour.call(&"find_var", &"net_position")
				if _wire_var != null:
					break
	return _wire_var.wire_value(feet) if _wire_var != null else feet
