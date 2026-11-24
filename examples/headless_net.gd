extends "headless_net_views.gd"

## game-airdrift's netcode, end to end, in one process.
##
## A server game and a client game, each with its own [GSNetManager] and [AirdriftNetBridge], with a
## lossy loopback where the socket would be. This proves the bridge, not gs-net.
##
## [b]The client's tick lead is hand-stamped[/b] (INPUT_LEAD): a command for tick N
## has to be in the server's hands before it simulates N, and with no clock to
## synchronise against the harness does the arithmetic itself.


## What the client's engine is pretending to run at, and deliberately not the
## server's. See the note in [method _build].
const CLIENT_ENGINE_TICK_RATE := 60

const CHECKS := 286

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose. The CHECKS
## total above is the other half — see docs/testing.md.
const SECTIONS := 38


func _ready() -> void:
	GSLog.set_level(GSLog.Level.WARN)
	_run.call_deferred()


func _run() -> void:
	print("game-airdrift: netcode")
	print("")
	_test_command_wire()
	_test_neutralise()
	_test_movement_wire()
	_test_hello_wire()
	if await _build():
		await _test_handshake()
		await _test_prediction()
		await _test_prediction_hopping()
		await _test_timer()
		await _test_finish()
		# The order does not matter. The walk ends at z=-0.97 m before and after
		# these sections, with one server player, so extra hulls at the pad (solid players) do not
		# block it; both orders give the same pit and finish results.
		await _test_pit_respawn_predicted()
		await _test_pit_zone_predicted()
		_test_movement_change()
		_test_style_and_track()
		_test_avatar()
		await _test_lossy()
		await _test_map_change()
		await _test_map_by_vote()
		await _test_map_delivered()
		await _test_map_owned()
		await _test_map_disk_stamped()
		await _test_map_republished()
		await _test_map_straggler()
		await _test_map_refused()
		_test_ghost()
		await _test_solid_players()
		await _test_voice_wire()
		_test_vote_wire()
		_test_clock_wire()
		_test_rules_wire()
		_test_hit_wire()
		_test_end_of_match_wire()
		_test_death_wire()
		_test_blind_and_beacon()
		_test_hunters_reach_the_client()
		_test_spectating_reaches_the_client()
		_test_leave()
	_test_the_remote_workbench()
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _test_command_wire() -> void:
	_section("a command survives the wire")
	var packet := AirdriftNetCommand.new()
	packet.tick = 77
	packet.delta = 1.0 / 128.0
	packet.move.move = Vector2(-1.0, 0.5)
	packet.move.yaw = 45.0
	packet.move.pitch = -20.0
	packet.move.set_button(GSFpsCommand.BUTTON_JUMP, true)
	packet.move.set_button(GSFpsCommand.BUTTON_CROUCH, true)

	var writer := GSNetWriter.new()
	packet.write(writer)
	var back := AirdriftNetCommand.new()
	back.read(GSNetReader.new(writer.to_bytes()))

	_check(back.tick == 77, "tick")
	_check(back.move.move.distance_to(packet.move.move) < 0.01, "move axes", str(back.move.move))
	_check(absf(back.move.yaw - 45.0) < 0.2 and absf(back.move.pitch + 20.0) < 0.5, "view angles", "%s %s" % [back.move.yaw, back.move.pitch])
	_check(back.move.is_pressed(GSFpsCommand.BUTTON_JUMP) and back.move.is_pressed(GSFpsCommand.BUTTON_CROUCH), "buttons")
	# Quantised once is quantised for good: a second trip must change nothing.
	var again := GSNetWriter.new()
	back.write(again)
	var twice := AirdriftNetCommand.new()
	twice.read(GSNetReader.new(again.to_bytes()))
	_check(twice.equals(back), "and is stable under a second trip, which is what input compression rests on")
	_done()


func _test_neutralise() -> void:
	_section("a silent player's command lets go")
	var command := AirdriftNetCommand.new()
	command.attack = true
	command.move.move = Vector2(0.0, 1.0)
	command.move.yaw = 40.0
	command.move.set_button(GSFpsCommand.BUTTON_JUMP, true)
	command._neutralise()
	_check(not command.attack and command.move.move == Vector2.ZERO and command.move.buttons == 0,
		"attack, move and buttons are cleared")
	_check(is_equal_approx(command.move.yaw, 40.0), "and the view is kept")
	_done()


func _test_movement_wire() -> void:
	_section("the movement configuration travels")
	var config := AirdriftConfig.new()
	config.air_accelerate = 1000.0
	config.gravity = 600.0
	config.auto_bhop = false

	var reader := GSNetReader.new(AirdriftEvents.write_movement(config))
	var received := AirdriftConfig.new()
	var fingerprint := AirdriftEvents.read_movement(reader, received)

	_check(received.air_accelerate == 1000.0 and received.gravity == 600.0, "cvars arrive")
	_check(received.auto_bhop == false, "and the autobhop switch")
	_check(AirdriftMovement.tunables_for(received).fingerprint() == fingerprint,
		"and the receiver derives the same tunables the sender fingerprinted")
	_check(AirdriftMovement.tunables_for(config).fingerprint() == fingerprint, "which are the sender's")
	_done()


func _test_hello_wire() -> void:
	_section("hello")
	var config := AirdriftConfig.new()
	var reader := GSNetReader.new(AirdriftEvents.write_hello(128, 7, 2, 4096, config))
	var hello := AirdriftEvents.read_hello(reader)
	_check(bool(hello["ok"]), "parses")
	_check(int(hello["tick_rate"]) == 128 and int(hello["player_id"]) == 7 and int(hello["peer_id"]) == 2, "with ids")
	# No map. It carried one, and the client changed to it by id out of its own build —
	# the ad-hoc half of what gs-map's protocol now does. The map arrives as an announce.
	_check(int(hello["server_tick"]) == 4096 and not hello.has("map_id"), "the tick, and no map: the protocol's announce carries that")

	# The protocol's own messages, through the game's codec both ways.
	var map := GSMapDef.new()
	map.id = &"surf_g2g_intro"
	map.scene_path = "res://maps/surf_g2g_intro.tscn"
	map.tier = 4
	var announce := AirdriftEvents.read_map_message(GSNetReader.new(
		AirdriftEvents.write_map_message(GSMapMessage.announce(map))))
	var back := GSMapDef.from_dictionary(announce.get("map", {}))
	_check(GSMapMessage.kind_of(announce) == GSMapMessage.KIND_ANNOUNCE and back.id == map.id
		and back.tier == 4 and back.version == map.version and back.is_local(),
		"a map announce survives the wire, tier and all", str(announce))
	var huge := GSMapMessage.announce(map)
	(huge["map"] as Dictionary)["description"] = "x".repeat(AirdriftEvents.MAP_MESSAGE_BYTES)
	_check(AirdriftEvents.write_map_message(huge).is_empty(),
		"one too big to send is refused whole rather than cut into JSON nobody can parse")
	var garbage := GSNetWriter.new()
	garbage.write_string("{not json", AirdriftEvents.MAP_REPLY_BYTES)
	_check(AirdriftEvents.read_map_message(GSNetReader.new(garbage.to_bytes()), AirdriftEvents.MAP_REPLY_BYTES).is_empty(),
		"and a reply that is not a JSON object reads as nothing, which gs-map ignores")
	# A kind goes out in a fixed field the writer masks without a word, so one past it aliases a
	# smaller kind: game-zombie-zone sent HURT and AMMO as HELLO and MAP that way. The track has
	# no field limit: gs-timer's escape carries any number, checked just below.
	_check(AirdriftEvent.fits(), "every event kind fits the event's kind field",
		"%d kinds in %d bits" % [AirdriftEvents.Kind.size(), AirdriftEvent.KIND_BITS])
	_check(AirdriftRequest.fits(), "every request kind fits the request's kind field",
		"%d kinds in %d bits" % [AirdriftEvents.Ask.size(), AirdriftRequest.KIND_BITS])
	for joined_track in [0, 8, 14, 15, 40, 100000]:
		var join_bytes := AirdriftEvents.write_join(1, 2, 3, "a", null, 0, joined_track)
		var join_back := AirdriftEvents.read_join(GSNetReader.new(join_bytes))
		_check(int(join_back["track"]) == joined_track,
			"JOIN carries track %d unchanged (got %s)" % [joined_track, join_back["track"]])
	_done()


# --- Bringing both halves up ---------------------------------------------------

func _build() -> bool:
	_section("bringing both halves up")

	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)
	var client_side := Node.new()
	client_side.name = "ClientSide"
	add_child(client_side)

	_server_game = _make_game(true, &"server", server_side)
	_client_game = _make_game(false, &"client", client_side)

	for _i in range(120):
		await get_tree().process_frame
		if _server_game.maps.current != null and _client_game.maps.current != null:
			break

	_check(_server_game.maps.current != null and _client_game.maps.current != null, "both games load the map")
	_check(_server_game.tick_rate == _client_game.tick_rate, "at one tick rate, because one process has one engine rate")

	# [b]And that is exactly why this suite could not see the tick rate bug.[/b] Both
	# halves read `Engine.physics_ticks_per_second`, so they agreed no matter what the
	# wire carried — while a real client is a separate process whose rate is its own
	# project's export and has nothing to do with the server's `sv_tickrate`. The
	# client shell in gs-server-deploy never sets one at all and runs at 60.
	#
	# So put the client on a rate the server is not on, the way a host project would,
	# and let HELLO be what corrects it. Every check after this one is then running
	# against a client that had to adopt rather than one that happened to match.
	_check(
		_client_game.set_tick_rate(CLIENT_ENGINE_TICK_RATE),
		"the client is put on %d, as a host project with its own export would be" % CLIENT_ENGINE_TICK_RATE
	)
	_check(
		_client_game.tick_rate != _server_game.tick_rate,
		"so the two now disagree", "%d vs %d" % [_client_game.tick_rate, _server_game.tick_rate]
	)

	# [b]The ENGINE too, or the check below passes for the wrong reason.[/b] Both halves
	# share one process and this project exports 128, so an assertion that the engine
	# ends up on the server's rate would hold whether or not anything ever set it — the
	# same "agrees versus was never asked to disagree" trap that let the original tick
	# rate bug live here. The browser shell genuinely runs at 60, so put the engine
	# there and make HELLO be what moves it.
	Engine.physics_ticks_per_second = CLIENT_ENGINE_TICK_RATE
	# And the engine's default step cap, which is what a shell that sets none runs with:
	# HELLO must be what raises it (see the slow-frame check below).
	Engine.max_physics_steps_per_frame = 8
	_check(
		Engine.physics_ticks_per_second != _server_game.tick_rate,
		"and so does the engine, which is what a browser shell that sets none runs at",
		"engine %d vs server %d" % [Engine.physics_ticks_per_second, _server_game.tick_rate]
	)

	_server_net = _make_manager(true, &"server", 1, server_side, _server_game.tick_rate)
	_client_net = _make_manager(false, &"client", CLIENT_PEER, client_side, _client_game.tick_rate)
	# This harness stamps every command itself (`_tick + INPUT_LEAD`), not from the client's
	# clock, so the client must not ask for gs-net's input-lead report: steered by reports
	# about commands it never stamped, the clock runs away from them (only gs-net's cap
	# holds it). By the constant map, so this parses against a gs-net from before the report.
	var lead_bit := int((GSNetMessageRegistry as Script).get_script_constant_map().get("FEATURE_INPUT_LEAD", 0))
	_client_net.messages.features &= ~lead_bit

	_server_bridge = AirdriftNetBridge.new()
	_server_bridge.name = "Bridge"
	server_side.add_child(_server_bridge)
	_client_bridge = AirdriftNetBridge.new()
	_client_bridge.name = "Bridge"
	client_side.add_child(_client_bridge)

	# The link mirrors a node named "Server" on both ends: the manager is one.
	var attached := _server_bridge.attach(_server_game, _server_net, _server_net)
	_check(attached.ok, "the server bridge attaches", str(attached.error) if not attached.ok else "")
	var client_attached := _client_bridge.attach(_client_game, _client_net, _client_net)
	_check(client_attached.ok, "the client bridge attaches", str(client_attached.error) if not client_attached.ok else "")

	var wrong := AirdriftNetBridge.new()
	add_child(wrong)
	var refused := wrong.attach(_client_game, _server_net, self)
	_check(not refused.ok and refused.error.code == GSError.CODE_STATE, "a client game on a server manager is refused")
	wrong.queue_free()

	_server_net.messages.seal()
	_client_net.messages.seal()
	_check(_server_net.messages.schema_hash() == _client_net.messages.schema_hash(), "both ends agree on the message schema")

	_server_bridge.link.loopback = _on_server_send
	_client_bridge.link.loopback = _on_client_send
	# What a real client wires to GSClientLink.ping_ms(). Without it the clock
	# believes the link is instant and every command arrives a flight time late.
	_client_bridge.rtt_source = func() -> float:
		return 40.0

	# start() announced the client's schema before the loopback existed, so it went nowhere
	# and the server kept the pre-list snapshot format. Announce again now it can arrive;
	# it is delivered with the rest of _to_server once the loop runs.
	_client_net.announce_schema(1)

	_check(_server_game.external_tick, "the server game hands its tick to the bridge")
	_check(_client_game.external_tick, "and so does the client's, which predicts and interpolates instead")

	_done()
	return attached.ok and client_attached.ok


func _test_handshake() -> void:
	_section("a client joins")

	var hellos := []
	# [b]Whether the local player exists at the moment HELLO says who you are.[/b] It does
	# not — `_apply_join` is what calls `game.add_player` — and a client that resolved its
	# own player on `hello_received` therefore held null for the whole session. AirdriftClient
	# did exactly that, and the symptom was the entire keyboard and mouse dead on a client
	# whose HUD, movement and camera all worked: everything below its `player == null`
	# guard is mouse look and the keybinds, while movement is polled from the InputMap and
	# never touches it.
	#
	# Captured in the handler rather than checked afterwards, because by the time the
	# exchange returns JOIN has been applied and the answer is yes either way.
	var local_at_hello := []
	var added_locally: Array[StringName] = []
	_client_game.player_added.connect(func(p: AirdriftPlayer) -> void: added_locally.append(p.player_id))
	_client_bridge.hello_received.connect(func(id: int) -> void:
		hellos.append(id)
		local_at_hello.append(_client_game.players.has(StringName("u%d" % id)))
	)

	# The READY first, as over ENet with loss: a client is PLAYING by its own reckoning once it has
	# sent `loaded`, on another channel, so its READY can reach the server before its seat. The
	# server sends nothing on it, keeps it, and answers it when the seat comes; a bridge that
	# dropped it never told this client anything.
	_client_bridge.ask_ready()
	_exchange()
	_check(not _server_net.peers().has(CLIENT_PEER) and _client_player() == null and hellos.is_empty(),
		"a READY before the seat admits nothing yet")

	var loaded: Array[String] = []
	_client_bridge.map_loaded.connect(func(m: GSMapDef) -> void: loaded.append(String(m.id)))
	var standings := []
	_client_bridge.standing_received.connect(func(id: int, _standing: Dictionary) -> void: standings.append(id))

	var added := _server_bridge.add_player(CLIENT_PEER, SESSION, "Ada")
	_check(added.ok, "the server adds the player", str(added.error) if not added.ok else "")
	_check(_server_player() != null and not _server_player().samples_input, "as a remote player on the server")
	_exchange()

	_check(_server_net.peers().has(CLIENT_PEER), "asking admits them")
	# The client's announce reached the server, so snapshots to it carry the unchanged list.
	# By the constant map, so this parses against a gs-net from before the feature.
	var runs_bit := int((GSNetMessageRegistry as Script).get_script_constant_map().get("FEATURE_UNCHANGED_RUNS", 0))
	_check(runs_bit == 0 or _server_net.messages.peer_supports(CLIENT_PEER, runs_bit),
		"the server knows its client reads the unchanged list")
	_check(hellos == [SESSION], "and the client is told who it is", str(hellos))
	_check(_client_bridge.local_player_id == SESSION, "which the bridge remembers")
	# The join's spawn works the standing out inside `game.add_player`, before the peer is
	# mapped, so with a store that answers from memory it went to nobody: a reconnecting
	# record holder's timer showed no best and no record while Tab showed both.
	_check(standings.has(SESSION), "and is sent its standing, which the join worked out before it had a peer",
		str(standings))
	_handshake_stage_ref()
	await _handshake_tick_rate(local_at_hello)
	await _handshake_map(loaded, added_locally)
	_done()


## A splits comparison survives the wire and reaches the owner.
func _handshake_stage_ref() -> void:
	var reference_in: Array[Dictionary] = []
	_client_bridge.stage_reference_received.connect(func(id: int, ref: Dictionary) -> void:
		if id == SESSION:
			reference_in.append(ref)
	)
	var sent := {
		"map": "bhop_x", "track": 0, "style": &"normal", "stages": 3,
		"pb": {"splits": {1: 10.25, "2": 21.5}, "total": 33.125},
		"wr": {"splits": {1: 9.0, 2: 20.0, 3: 29.5}, "total": 31.75},
		"bests": {1: 9.5, 3: 11.0, 4: 12.0},
	}
	var wire := AirdriftEvents.read_stage_ref(GSNetReader.new(AirdriftEvents.write_stage_ref(SESSION, sent)))
	_check(bool(wire["ok"]) and int(wire["stages"]) == 3 and is_equal_approx(float(wire["pb"]["total"]), 33.125)
		and wire["pb"]["splits"].size() == 2 and is_equal_approx(float(wire["wr"]["splits"][3]), 29.5)
		and wire["bests"].size() == 3 and not wire["bests"].has(2),
		"a splits comparison survives the wire, absent splits staying absent", str(wire))
	_check(wire["map"] == "bhop_x", "carrying the map it was worked out for", str(wire.get("map")))
	# A message from before the map id was added ends after the bests: refused whole.
	var short := AirdriftEvents.write_stage_ref(SESSION, sent)
	short = short.slice(0, short.size() - 1 - "bhop_x".length())
	var old_wire := AirdriftEvents.read_stage_ref(GSNetReader.new(short))
	_check(not bool(old_wire["ok"]), "and one without a map id is refused, not guessed at", str(old_wire.get("ok")))
	_server_game.stage_reference_changed.emit(AirdriftNetBridge._player_key(SESSION), sent)
	_exchange()
	_check(reference_in.size() == 1 and reference_in[0]["style"] == "normal"
		and is_equal_approx(float(reference_in[0]["wr"]["total"]), 31.75),
		"and the server sends the owner their comparison when it changes", str(reference_in))
	_check(reference_in.size() == 1 and reference_in[0]["map"] == "bhop_x", "map id included", str(reference_in))
	_check(AirdriftEvent.fits(), "and the new message kind still fits the kind field")


## HELLO moves the client game, timers, clock and engine to the server's tick rate.
func _handshake_tick_rate(local_at_hello: Array) -> void:
	# Game, net config and the clock's setup() copy all have to move.
	_check(
		_client_game.tick_rate == _server_game.tick_rate,
		"and the client adopts the server's tick rate from HELLO",
		"%d vs %d" % [_client_game.tick_rate, _server_game.tick_rate]
	)
	_check(
		_client_game.timers.tick_rate == _server_game.tick_rate,
		"its timers with it, or every run time is wrong by the ratio",
		"%d vs %d" % [_client_game.timers.tick_rate, _server_game.tick_rate]
	)
	_check(
		_client_net.clock.tick_rate == _server_game.tick_rate
			and _client_net.config.tick_rate == _server_game.tick_rate,
		"and so does the netcode clock, which is a copy taken at setup()",
		"clock %d, config %d" % [_client_net.clock.tick_rate, _client_net.config.tick_rate]
	)
	# [b]And the ENGINE's, which is the half that decides whether it looks smooth.[/b]
	# The three rates above make the simulation correct; this one makes it drawable.
	# `AirdriftClient._physics_process` asks the clock how many ticks a frame is worth, so a
	# client on a 60 Hz engine against a 128-tick server simulated the right number of
	# ticks — in bursts of two and three. Nothing renders between ticks, so the camera
	# advanced 74 mm on six frames out of seven and 112 mm on the seventh: a 47% change
	# in apparent speed, eight times a second. Interpolation cannot fix it on its own,
	# because a fraction through a PHYSICS frame is only a fraction through a tick while
	# the two rates agree. `examples/jitter_probe.tscn` measures all four combinations.
	_check(
		Engine.physics_ticks_per_second == _server_game.tick_rate,
		"and the ENGINE, so one physics frame is one tick and a renderer can interpolate",
		"engine %d vs server %d" % [Engine.physics_ticks_per_second, _server_game.tick_rate]
	)
	# [b]And every tick of a slow frame.[/b] The engine runs at most
	# `max_physics_steps_per_frame` steps a frame and drops the rest; the default 8 is
	# 62.5 ms at 128, so a client under 16 frames a second (a browser's first visit) ran
	# fewer ticks than the server, every command it sent was late, and the server never
	# moved the player off the spawn pad. Measured through real slow frames, because a
	# setting that is written and not obeyed is this family's most repeated bug. Armed:
	# without `_keep_up_through_slow_frames` both fail (8 steps; about 53 ticks a second).
	var wanted_steps := ceili(AirdriftNetBridge.SLOW_FRAME_SECONDS * float(_server_game.tick_rate))
	_check(
		Engine.max_physics_steps_per_frame >= wanted_steps,
		"HELLO lets the engine run a quarter second of ticks in one frame",
		"%d steps a frame, %d wanted" % [Engine.max_physics_steps_per_frame, wanted_steps]
	)
	await get_tree().process_frame
	var physics_before := Engine.get_physics_frames()
	var wall_before := Time.get_ticks_usec()
	for _i in range(6):
		OS.delay_msec(150)
		await get_tree().process_frame
	var ran := Engine.get_physics_frames() - physics_before
	var owed := float(Time.get_ticks_usec() - wall_before) / 1000000.0 * float(Engine.physics_ticks_per_second)
	_check(
		float(ran) >= 0.85 * owed,
		"through 150 ms frames the engine still runs every tick the server does",
		"%d physics steps for %.0f ticks of wall time" % [ran, owed]
	)
	_check(
		local_at_hello == [false],
		"the local player does NOT exist yet when HELLO names it — JOIN is what creates it",
		str(local_at_hello)
	)


## The joiner is told the map, mirrors itself as the local player and is predicted.
func _handshake_map(loaded: Array[String], added_locally: Array[StringName]) -> void:
	var announced := _client_bridge.map_client.announced
	_check(announced != null and announced.id == _server_game.maps.current.id,
		"the joiner is announced the map the server is on",
		String(announced.id) if announced != null else "nothing announced")
	_exchange()
	for _i in range(10):
		if not loaded.is_empty():
			break
		await get_tree().process_frame
		_flush()
	_check(loaded == [String(_server_game.maps.current.id)],
		"and told to load it once it said it had it", str(loaded))
	_check(_server_bridge.map_host.peers.has(CLIENT_PEER), "and follows every change from now on")
	_check(
		added_locally.has(StringName("u%d" % SESSION)),
		"so `player_added` is the hook a client has to follow, and it fires for the local one",
		str(added_locally)
	)
	_check(_client_player() != null and _client_player().samples_input, "the client mirrors itself as the local player")
	_check(_client_player() != null and _client_player().sampler == null, "which the bridge drives rather than the devices")
	_check(_client_game.tunables.fingerprint() == _server_game.tunables.fingerprint(), "with the server's movement")
	_check(_client_player() != null and _client_player().timer != null and not _client_player().timer.authoritative,
		"and a timer that mirrors rather than decides")

	var mine := _client_bridge.behaviour_for(SESSION)
	_check(mine != null and mine.identity != null and mine.identity.is_predicted(), "the local player is predicted")
	_check(mine != null and mine.identity.net_id == _server_bridge.behaviour_for(SESSION).identity.net_id,
		"under the server's entity id")


func _test_prediction_hopping() -> void:
	_section("prediction converges while hopping and turning in the start zone")
	var server := _server_player()
	var client := _client_player()
	_server_game.spawn_player(server.player_id)
	_steps(4)
	_flush()
	for i in range(600):
		var c := GSFpsCommand.new()
		c.move = Vector2(1.0 if (i / 40) % 2 == 0 else -1.0, 1.0)
		c.yaw = float(i) * 0.7
		c.set_button(GSFpsCommand.BUTTON_JUMP, true)
		_step(c)
		if i % 4 == 0:
			_flush()
	_flush()
	_check(client.global_position.distance_to(server.global_position) < 0.5, "the client ends where the server has it",
		"%.3f m apart" % client.global_position.distance_to(server.global_position))
	_check(_client_net.predictor.correction_rate() < 0.1, "with almost no corrections", "%.3f" % _client_net.predictor.correction_rate())
	await get_tree().process_frame
	_done()


## nightly 1546: the client ignored a lethal hurt volume and the server's respawn reached it a
## round trip later as a 5 m correction. It now predicts the respawn at the map's start.
func _test_pit_respawn_predicted() -> void:
	_section("a pit's respawn is predicted, not corrected")
	var server := _server_player()
	var client := _client_player()
	_server_game.spawn_player(server.player_id)
	_steps(8)
	_steps(60, _forward())
	var pit := server.global_position
	_server_game.spawn_player(server.player_id)
	_steps(30)
	var box := {"box": AABB(pit - Vector3(1.0, 1.0, 1.0), Vector3(2.0, 2.0, 2.0)), "damage": 1000.0}
	_server_game.mechanics.hurt.append(box)
	_client_game.mechanics.hurt.append(box.duplicate())
	var hits := {"server": 0, "client": 0}
	var on_server := func(event: int, _index: int) -> void:
		if event == AirdriftPlayer.AirdriftMapMechanics.Event.HURT:
			hits["server"] += 1
	var on_client := func(event: int, _index: int) -> void:
		if event == AirdriftPlayer.AirdriftMapMechanics.Event.HURT:
			hits["client"] += 1
	server.map_event.connect(on_server)
	client.map_event.connect(on_client)
	_client_net.predictor.set("_worst_error", 0.0)
	_steps(100, _forward())
	_flush()
	server.map_event.disconnect(on_server)
	client.map_event.disconnect(on_client)
	_server_game.mechanics.hurt.pop_back()
	_client_game.mechanics.hurt.pop_back()
	var worst: float = _client_net.predictor.get("_worst_error")
	_check(int(hits["server"]) >= 1, "the server's player runs into the pit", "%d hits" % hits["server"])
	_check(int(hits["client"]) >= 1, "and the client's prediction does too", "%d hits" % hits["client"])
	_check(worst < 0.5, "the respawn needs no large correction", "%.3f m" % worst)
	_check(client.global_position.distance_to(server.global_position) < 0.5, "and the client ends where the server has it",
		"%.3f m apart" % client.global_position.distance_to(server.global_position))
	_server_game.spawn_player(server.player_id)
	_steps(30)
	await get_tree().process_frame
	_done()


## nightly 1546: a RESPAWN zone (the intro maps' pit) on the client teleported only after the predictor had
## remembered the tick, so every pit was a 5 m correction in netchaos.
func _test_pit_zone_predicted() -> void:
	_section("a pit zone's respawn is predicted, not corrected")
	var server := _server_player()
	var client := _client_player()
	_server_game.spawn_player(server.player_id)
	_steps(8)
	_steps(60, _forward())
	var pit := server.global_position
	_server_game.spawn_player(server.player_id)
	_steps(30)
	var added: Array[GSTimerZone] = []
	for game: AirdriftGame in [_server_game, _client_game]:
		var zone := GSTimerZone.make(GSTimerZone.Kind.RESPAWN, GSTimerTrack.MAIN).set_box(
			pit - Vector3(1.0, 1.0, 1.0), pit + Vector3(1.0, 1.0, 1.0))
		game.timers.zones.add(zone)
		game.timers.set_zones(game.timers.zones)
		added.append(zone)
	var hits := {"server": 0, "client": 0}
	var on_server := func(_id: StringName, zone: GSTimerZone) -> void:
		if zone == added[0]:
			hits["server"] += 1
	var on_client := func(_id: StringName, zone: GSTimerZone) -> void:
		if zone == added[1]:
			hits["client"] += 1
	_server_game.timers.effect_requested.connect(on_server)
	_client_game.timers.effect_requested.connect(on_client)
	_client_net.predictor.set("_worst_error", 0.0)
	_steps(100, _forward())
	_flush()
	_server_game.timers.effect_requested.disconnect(on_server)
	_client_game.timers.effect_requested.disconnect(on_client)
	for i in range(2):
		var game: AirdriftGame = [_server_game, _client_game][i]
		game.timers.zones.remove_id(added[i].id)
		game.timers.set_zones(game.timers.zones)
	var worst: float = _client_net.predictor.get("_worst_error")
	_check(int(hits["server"]) >= 1, "the server's player falls into the pit zone", "%d hits" % hits["server"])
	_check(int(hits["client"]) >= 1, "and the client's timer sees it too", "%d hits" % hits["client"])
	_check(worst < 0.5, "the zone's respawn needs no large correction", "%.3f m" % worst)
	_check(client.global_position.distance_to(server.global_position) < 0.5, "and the client ends where the server has it",
		"%.3f m apart" % client.global_position.distance_to(server.global_position))
	_server_game.spawn_player(server.player_id)
	_steps(30)
	await get_tree().process_frame
	_done()


func _test_prediction() -> void:
	_section("prediction converges")
	var server := _server_player()
	var client := _client_player()
	_server_game.spawn_player(server.player_id)
	_steps(4)
	_flush()

	var forward := _forward()
	_steps(96, forward)

	_check(AirdriftUnits.to_units(server.speed()) > 200.0, "the server player moves on the client's input", AirdriftUnits.format_speed(server.speed()))
	_check(client.global_position.distance_to(server.global_position) < 0.5, "and the client shows it where the server has it",
		"%.3f m apart" % client.global_position.distance_to(server.global_position))
	var rate := _client_net.predictor.correction_rate()
	_check(rate < 0.1, "with almost no corrections", "%.3f" % rate)
	_check(absf(_client_net.stats.rtt_percentile(0.5) - 40.0) < 0.01, "and the clock has been told how long the link is",
		"%.1f ms" % _client_net.stats.rtt_percentile(0.5))
	await get_tree().process_frame
	_done()


func _test_timer() -> void:
	_section("the timer replicates")
	var server := _server_player()
	var client := _client_player()
	_server_game.spawn_player(server.player_id)
	_steps(2)

	_check(server.timer.in_zone(GSTimerZone.Kind.START), "the server player spawns on the start pad")

	var hold := _forward()
	hold.set_button(GSFpsCommand.BUTTON_JUMP, true)
	_steps(120, _forward())
	_steps(120, hold)

	_check(server.timer.run.is_running(), "the server's run starts when its player hops off the pad",
		"in start: %s, %s" % [server.timer.in_zone(GSTimerZone.Kind.START), AirdriftUnits.format_speed(server.speed())])
	_check(client.timer.run.is_running(), "and the client's mirror is running too")
	_check(client.timer.run.style_id == server.timer.run.style_id, "in the same style")
	var drift := absf(client.timer.run.time() - server.timer.run.time())
	_check(drift < 0.05, "reading the same time", "%.3f s apart" % drift)
	await get_tree().process_frame
	_done()


func _test_finish() -> void:
	_section("a finish reaches the client")
	var server := _server_player()
	var finishes := []
	var notices := []
	_client_bridge.finish_received.connect(func(id: int, time: float, rank: int) -> void: finishes.append([id, time, rank]))
	_client_bridge.notice_received.connect(func(_id: int, text: String) -> void: notices.append(text))

	# A fresh run walked off the pad on the ground, so its length is known: the
	# hopping run above may have fallen at a gap and been respawned since.
	_server_game.spawn_player(server.player_id)
	_steps(2)
	_steps(260, _forward())
	_check(server.timer.run.is_running(), "a walked run is going", str(server.timer.describe()))
	var before := server.timer.run.time()

	var end := _server_game.timers.zones.first_of_kind(GSTimerZone.Kind.END, 0)
	server.controller.state.position = end.centre() + Vector3.UP * 0.3
	server.controller.state.velocity = Vector3(0.0, 0.0, -3.0)
	_steps(6, _forward())
	for _i in range(4):
		await get_tree().process_frame
	_flush()

	var who := _server_game.timers.player(server.player_id)
	var filed := who.last_finished if who != null else null
	_check(finishes.size() == 1, "once", str(finishes))
	_check(finishes.size() == 1 and finishes[0][0] == SESSION and float(finishes[0][1]) >= before,
		"with a time", "%s before=%.3f notices=%s" % [finishes, before, notices])
	_check(finishes.size() == 1 and filed != null and absf(float(finishes[0][1]) - filed.time()) < 0.0001,
		"which is the server's own to the sub-tick fraction",
		"%s vs %s" % [finishes[0][1] if finishes.size() == 1 else "none", filed.time() if filed else "none"])
	_check(finishes.size() == 1 and (int(finishes[0][2]) >= 1 or not notices.is_empty()),
		"ranked, or told why not", str(notices))
	_check(not _client_player().timer.run.is_running(), "and the client's mirror stops")
	_done()


func _test_movement_change() -> void:
	_section("changing the movement under a live client")
	_server_game.config.air_accelerate = 150.0
	_server_game.apply_movement()
	_flush()
	_check(_client_game.config.air_accelerate == 150.0, "the cvar reaches the client")
	_check(_client_game.tunables.fingerprint() == _server_game.tunables.fingerprint(), "and both derive the same tunables")
	_steps(2)
	_done()


func _test_style_and_track() -> void:
	_section("asking for a style and a track")
	_client_bridge.ask_style(&"sideways")
	_exchange()
	_check(_server_player().timer_style != null and _server_player().timer_style.id == &"sideways", "the server switches",
		str(_server_player().timer_style.id) if _server_player().timer_style else "")
	_check(_client_player().timer_style != null and _client_player().timer_style.id == &"sideways", "and tells the client")

	_client_bridge.ask_track(GSTimerTrack.BONUS_FIRST)
	_exchange()
	_check(_server_player().timer.track == GSTimerTrack.BONUS_FIRST, "a bonus track, on the server")
	_check(_client_player().timer.track == GSTimerTrack.BONUS_FIRST, "and on the client")

	_client_bridge.ask_track(1 << GSTimerTrack.WIDE_BITS)
	_exchange()
	_check(_server_player().timer.track == GSTimerTrack.BONUS_FIRST, "an invalid track is ignored")

	_client_bridge.ask_style(&"normal")
	_client_bridge.ask_track(GSTimerTrack.MAIN)
	_exchange()
	_done()


func _test_avatar() -> void:
	_section("an avatar published by the client")
	var avatar := AirdriftAvatars.stock_avatar(&"someone-else")
	var before := _server_player().rig.avatar.to_dict() if _server_player().rig.avatar != null else {}
	_client_bridge.publish_avatar(avatar)
	_exchange()
	var after := _server_player().rig.avatar.to_dict() if _server_player().rig.avatar != null else {}
	_check(after != before or avatar.to_dict() == before, "reaches the server's rig")
	_check(_client_player().rig.avatar != null and _client_player().rig.avatar.to_dict() == after, "and comes back to the client")
	_done()


func _test_lossy() -> void:
	_section("losing every third snapshot")
	_server_game.spawn_player(_server_player().player_id)
	_steps(4)
	_drop_every = 3
	_steps(128, _forward())
	_drop_every = 0
	var apart := _client_player().global_position.distance_to(_server_player().global_position)
	_check(apart < 0.5, "the client still shows the server's position", "%.3f m" % apart)
	_check(_client_net.predictor.correction_rate() < 0.15, "and prediction still converges", "%.3f" % _client_net.predictor.correction_rate())
	await get_tree().process_frame
	_done()


