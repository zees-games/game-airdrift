extends GSNetInput

const AirdriftNetCommand := preload("airdrift_net_command.gd")

## One tick of a player's intent, on the wire: a [GSFpsCommand], and the trigger.
##
## [b]The only thing a client may send about itself.[/b] Clients send inputs, never
## state — a client that could send a position could send any position, and gs-net's
## whole security model rests on the distinction. The style, the track and the practice
## keys are requests, not inputs: they change what the simulation IS rather than what
## it does this tick, so they go reliably and rarely through [AirdriftRequest].
##
## [b]The trigger is here rather than in a request, and that is the whole reason this
## class grew a second field.[/b] A shot happens on a tick and has to be replayed with
## the movement of that tick — prediction rewinds and re-simulates, and a trigger that
## arrived reliably-and-separately would be replayed against a different tick's
## position every time. It is one bit; the aim it is fired along is already here, in
## the movement command's own yaw and pitch.
##
## [b]It is a bit and not a [GSWeaponCommand].[/b] gs-combat's command carries a slot
## request, a reload, an alternate fire and a zoom, and this game has two weapons with
## no magazine between them — so all but one of those fields would be a field nothing
## reads, quantised and sent sixty-four times a second per player. `AirdriftCombat` builds
## the full command on the server from this bit and the movement's angles, which is the
## same place it would have had to correct a client's aim anyway.

var move: GSFpsCommand = GSFpsCommand.new()

## Whether the attack button is down this tick.
##
## Meaningless on a server with `sv_deathmatch` off, and still sent: one bit per input
## packet is nothing, and a wire whose shape depends on a cvar is a wire two ends can
## disagree about the moment an operator changes it mid-session.
var attack: bool = false

## Bits of [member view_lag_q]: quarter ticks, so 1023 ticks, past any `max_rewind_sec` a server allows.
const VIEW_LAG_BITS := 12
const MAX_VIEW_LAG_Q := (1 << VIEW_LAG_BITS) - 1
## Bits of [member view_back] and [member view_span]. A view the pair does not fit is sent with no bracket (the lag alone), never clamped.
const VIEW_BACK_BITS := 10
const VIEW_SPAN_BITS := 6

## How far behind this command's tick the sender drew every other player, in quarter ticks; -1 sends none (`mp_solidplayers_unlag` off, a client not synced yet).
## The server rewinds the other players' hulls to `tick - view_lag_q / 4` for this tick's move ([GSPlayerHullRewind]); a command with none moves against the present.
var view_lag_q: int = -1

## The snapshot bracket the sender drew between: `tick - view_back` is the older snapshot tick and `+ view_span` the newer, so both ends blend the same two samples. -1: no bracket named.
var view_back: int = -1
var view_span: int = 0


func _write(writer: GSNetWriter) -> void:
	move.write(writer)
	writer.write_bool(attack)
	# Appended after the trigger, as every addition to this wire is. One bit when there is no view.
	var lagged := view_lag_q >= 0
	writer.write_bool(lagged)
	if lagged:
		writer.write_uint(clampi(view_lag_q, 0, MAX_VIEW_LAG_Q), VIEW_LAG_BITS)
		var bracketed := view_back >= 0
		writer.write_bool(bracketed)
		if bracketed:
			writer.write_uint(clampi(view_back, 0, (1 << VIEW_BACK_BITS) - 1), VIEW_BACK_BITS)
			writer.write_uint(clampi(view_span, 0, (1 << VIEW_SPAN_BITS) - 1), VIEW_SPAN_BITS)


func _read(reader: GSNetReader) -> void:
	move = GSFpsCommand.new()
	move.read(reader)
	attack = reader.read_bool()
	view_lag_q = -1
	view_back = -1
	view_span = 0
	if reader.read_bool():
		view_lag_q = reader.read_uint(VIEW_LAG_BITS)
		if reader.read_bool():
			view_back = reader.read_uint(VIEW_BACK_BITS)
			view_span = reader.read_uint(VIEW_SPAN_BITS)


## Not optional. Quantisation bounds each field; it cannot bound the relationship
## between them, and a move vector of (1, 1) is 41% more speed than anybody else.
func _sanitise() -> void:
	move.sanitise()
	view_lag_q = clampi(view_lag_q, -1, MAX_VIEW_LAG_Q)
	view_back = clampi(view_back, -1, (1 << VIEW_BACK_BITS) - 1)
	view_span = clampi(view_span, 0, (1 << VIEW_SPAN_BITS) - 1)


## A silent player lets go: the default neutralises `move`, the held trigger is released here.
func _neutralise() -> void:
	super()
	attack = false
	view_lag_q = -1
	view_back = -1
	view_span = 0


func _equals(other: GSNetInput) -> bool:
	var them := other as AirdriftNetCommand
	return them != null and attack == them.attack and move.equals(them.move) and view_lag_q == them.view_lag_q \
			and view_back == them.view_back and view_span == them.view_span
