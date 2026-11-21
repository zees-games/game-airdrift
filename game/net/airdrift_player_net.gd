extends GSNetBehaviour

const AirdriftNetBridge := preload("airdrift_net_bridge.gd")
const AirdriftNetCommand := preload("airdrift_net_command.gd")
const AirdriftPlayer := preload("../airdrift_player.gd")
const AirdriftArsenal := preload("../airdrift_arsenal.gd")

## What a networked Airdrift player replicates: the movement state, and an
## administrator's two marks on the player — `blind` and `beacon`.
##
## The timer is not replicated per tick. A client runs its own [GSTimer] over its own
## copy of the zones and reaches the same answer a tick earlier than any packet could,
## which is the whole reason the timer is deterministic; the server sends run
## identities and finishes as reliable events instead. See [GSTimerNet].

var player: AirdriftPlayer = null
var bridge: AirdriftNetBridge = null

var net_position: Vector3 = Vector3.ZERO
var net_velocity: Vector3 = Vector3.ZERO
var net_yaw: float = 0.0
var net_pitch: float = 0.0
var net_crouch: float = 0.0
var net_flags: int = 0
var net_modifiers: int = 0

## The jump timers (coyote, jump buffer, cooldown), owner only, for the owner's rewind. Opt-in on dot-player-controller API 10; see its docs/networking.md.
var net_timers: int = 0

# --- An administrator's marks, from AirdriftModTools ---

## `AirdriftPlayer.blinded`. Owner only: see [method _register_net_vars].
var net_blind: bool = false

## `AirdriftPlayer.beacon`. Everybody's.
var net_beacon: bool = false

## `AirdriftPlayer.held_weapon` as `AirdriftArsenal.wire_of` numbers it; 0 is empty hands. Owner only.
var net_weapon: int = 0

## Retained, not cleared: a player whose packet was lost keeps moving in a straight
## line rather than stopping dead. The controller says the same of its own command.
var last_move: GSFpsCommand = GSFpsCommand.new()

## Whether the trigger was down on the last input applied.
##
## [b]NOT retained across a lost packet, unlike the movement.[/b] A player whose input
## went missing should keep running in the direction they were going — stopping dead is
## worse than overshooting — but should not keep firing: a held trigger that survives a
## dropped packet is a weapon that empties itself during a hiccup, and on a server with
## lag compensation it is a shot fired at a moment nobody chose.
var last_attack: bool = false
var last_state_tick: int = -1


func _register_net_vars() -> void:
	for spec in GSFpsNetSync.state_specs():
		var declaration := replicate(spec["property"], GSNetVar.Type[spec["type"]])
		if int(spec["bits"]) > 0:
			declaration.bits(int(spec["bits"]))
		if bool(spec["interpolated"]):
			declaration.interpolated()
		if spec["property"] == &"net_crouch":
			declaration.range_of(0.0, 1.0)

	# Owner-only jump timers, appended after the movement specs (declaration order is wire order).
	# Guarded: a shell without API 10 has no GSFpsNetSync.rewind_specs().
	if GSAddonApi.build_level("dot_player_controller") >= 10:
		for spec in GSFpsNetSync.rewind_specs():
			var _timers := replicate(spec["property"], GSNetVar.Type[spec["type"]]).bits(int(spec["bits"])).to_owner_only()

	# [b]Per-player state rather than an event, and that is what makes both of these
	# survive what an event does not.[/b] A client that joins after the admin typed
	# `beacon`, a snapshot lost on the way, a map change: each is a baseline the next
	# snapshot corrects, where an event sent once is simply missed. Two bits, and nothing
	# at all on a tick where neither changed.
	#
	# The blind goes to its owner alone. Nobody else's screen changes, and a player who
	# received it would know the moment somebody could not see — which on a server running
	# its deathmatch layer is the moment to go and find them.
	#
	# Appended after the movement specs, never among them: the order of declaration is
	# the order on the wire, and the movement's is GSFpsNetSync's to keep.
	replicate(&"net_blind", GSNetVar.Type.BOOL).to_owner_only()
	replicate(&"net_beacon", GSNetVar.Type.BOOL)

	# The weapon in hand, for the owner's ammunition counter. A client has no combat layer
	# to ask, and state rather than an event for the reason the blind is: a lost snapshot or
	# a late join is corrected by the next one. Owner only, because nobody else's screen
	# shows it; four bits, and nothing on a tick it did not change.
	replicate(&"net_weapon", GSNetVar.Type.UINT).bits(4).to_owner_only()


func _net_apply_input(input: GSNetInput, _tick: int) -> void:
	var command := input as AirdriftNetCommand
	if command != null:
		last_move = command.move
		last_attack = command.attack

		# The trigger reaches the combat layer here rather than in the bridge's tick,
		# because this is the one place that runs on a REPLAY as well as on a fresh
		# tick — the predictor calls it for every unacknowledged command. A trigger
		# read anywhere else would be a shot the replay could not reproduce.
		if bridge != null:
			bridge.note_attack(player, command.attack)


## On the authority the whole game ticks as one — every player moves, then every
## timer sees the positions the moves produced — so the first behaviour through
## drives the game and the rest find it done. On a predicting client there is one
## predicted player, and simulating it directly is the whole of what a client may
## compute.
func _net_simulate(tick: int, delta: float) -> void:
	if player == null:
		return

	if identity != null and identity.is_authoritative:
		if bridge != null:
			bridge.ensure_game_ticked(tick)
	else:
		player.controller.apply_command(last_move.duplicate_command())
		player.predicted_tick = tick
		player.controller.simulate_tick(tick, delta)
		player.replay_teleport(tick)
		if bridge != null:
			bridge.timers_after_predicted_move(tick)

	pull()


func pull() -> void:
	if player != null:
		GSFpsNetSync.pull(player.controller.state, self)
		net_blind = player.blinded
		net_beacon = player.beacon
		net_weapon = AirdriftArsenal.wire_of(player.held_weapon)

	# [b]No relevance to change for a beacon, unlike game-fatal-contact.[/b] Every player entity
	# here is `always_relevant` already (`AirdriftNetBridge._build_entity`), so a beaconed
	# runner reaches every client however far away they are — and switching relevance
	# with the flag, as FC does, would CUT every runner the moment their beacon
	# went off. `headless_net` asserts it stays on.


## The server's answer, adopted wholesale. On the owner it is the rewind half of
## reconciliation and the predictor replays every unacknowledged command on top.
func _net_state_applied(tick: int) -> void:
	if player == null:
		return
	last_state_tick = tick
	GSFpsNetSync.push(self, player.controller.state)
	player.blinded = net_blind
	player.beacon = net_beacon
	player.held_weapon = AirdriftArsenal.id_from_wire(net_weapon)
	# NOT the node, on a predicted entity: receive_snapshot calls this before the
	# predictor reconciles, and reconcile's first act is to read the node as "what
	# the client is showing". Moving it here makes the measured error the whole
	# replay distance and the correction rate reads as if every snapshot snapped.
	if identity == null or not identity.is_predicted():
		player.global_position = player.controller.state.position


## Every frame on a remote player. Without this the interpolator's work sits in a
## property nothing reads and the remote player moves in snapshot-sized steps.
func _net_interpolated(_tick: int) -> void:
	if player == null:
		return
	GSFpsNetSync.push(self, player.controller.state)
	player.global_position = player.controller.state.position
