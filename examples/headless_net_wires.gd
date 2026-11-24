extends GSGameCheckSuite

const AirdriftAvatars := preload("../game/airdrift_avatars.gd")
const AirdriftConfig := preload("../game/airdrift_config.gd")
const AirdriftEvents := preload("../game/net/airdrift_events.gd")
const AirdriftGame := preload("../game/airdrift_game.gd")
const AirdriftKillView := preload("../game/net/airdrift_killview.gd")
const AirdriftMovement := preload("../game/airdrift_movement.gd")
const AirdriftHullView := preload("../game/net/airdrift_hull_view.gd")
const AirdriftHunters := preload("../game/airdrift_hunters.gd")
const AirdriftNetBridge := preload("../game/net/airdrift_net_bridge.gd")
const AirdriftNetCommand := preload("../game/net/airdrift_net_command.gd")
const AirdriftPlayer := preload("../game/airdrift_player.gd")
const AirdriftUnits := preload("../game/airdrift_units.gd")
const AirdriftVote := preload("../game/airdrift_vote.gd")
const AirdriftHud := preload("../game/airdrift_hud.gd")
const AirdriftModTools := preload("../game/airdrift_mod_tools.gd")
const AirdriftPlayerNet := preload("../game/net/airdrift_player_net.gd")
const AirdriftRequest := preload("../game/net/airdrift_request.gd")
const AirdriftEvent := preload("../game/net/airdrift_event.gd")
const AirdriftMapCatalogue := preload("../game/airdrift_map_catalogue.gd")

const CLIENT_PEER := 2
const SESSION := 7
const INPUT_LEAD := 2
const SNAPSHOT_RATE := 32

var _entered := 0
var _completed := 0

var _server_game: AirdriftGame = null
var _client_game: AirdriftGame = null
var _server_net: GSNetManager = null
var _client_net: GSNetManager = null
var _server_bridge: AirdriftNetBridge = null
var _client_bridge: AirdriftNetBridge = null

var _to_client: Array[Dictionary] = []
var _to_server: Array[Dictionary] = []
var _drop_every: int = 0
var _snapshot_count: int = 0
var _tick: int = 0



## A kill and the end of a deathmatch round-trip: the killcam's inputs and the podium's rows.
func _test_end_of_match_wire() -> void:
	_section("a kill and a match's end over the link")
	var shot := AirdriftEvents.read_kill(GSNetReader.new(AirdriftEvents.write_kill(4097, 12, "deagle", true)))
	_check(bool(shot["ok"]) and int(shot["killer"]) == 4097 and int(shot["victim"]) == 12
			and shot["weapon"] == "deagle" and bool(shot["headshot"]),
		"a KILL round-trips: killer, victim, weapon and the head", str(shot))
	var fired := AirdriftEvents.read_shot(GSNetReader.new(AirdriftEvents.write_shot(7, "deagle", Vector3(1.5, -2.0, 3000.0))))
	_check(bool(fired["ok"]) and int(fired["shooter"]) == 7 and fired["weapon"] == "deagle"
			and (fired["at"] as Vector3).is_equal_approx(Vector3(1.5, -2.0, 3000.0)),
		"a SHOT round-trips: shooter, weapon and where", str(fired))
	var flat := PackedFloat32Array()
	flat.resize(GSKillViewRing.STRIDE * 600)
	var packed := GSKillViewClip.pack({"v": 1, "f": flat}, {"killer": "Ana", "weapon": "deagle"}, AirdriftKillView.BYTES)
	var unpacked := GSKillViewClip.unpack(packed)
	_check(packed.size() <= AirdriftKillView.BYTES and packed.size() <= AirdriftEvent.MAX_BODY and bool(unpacked["ok"])
			and unpacked["info"]["killer"] == "Ana",
		"a KILLVIEW clip is thinned to fit an event body and round-trips", str(packed.size()))
	_check(AirdriftEvent.fits() and AirdriftRequest.fits(), "KILLVIEW and RESPAWN fit the kind fields")
	var rules := GSKillViewRules.new()
	var names: Array = []
	var _made := rules.bind_cvars(func(n: String, _v: String, _d: String, _f: int) -> Variant:
		names.append(n)
		return null, GSConVar.FLAG_REPLICATED)
	_check("mp_killview" in names and not rules.enabled, "mp_killview is bound, and off by default", str(names.size()))
	var rows := [{"name": "Ana", "kills": 40, "deaths": 3}, {"name": "Bo", "kills": 12, "deaths": 20},
		{"name": "Cy", "kills": 0, "deaths": 9}, {"name": "Dee", "kills": 0, "deaths": 0}]
	var over := AirdriftEvents.read_match_end(GSNetReader.new(AirdriftEvents.write_match_end(7.0, rows)))
	_check(bool(over["ok"]) and is_equal_approx(float(over["killcam"]), 7.0) and over["rows"].size() == 3
			and over["rows"][0] == rows[0] and over["rows"][2] == rows[2],
		"a MATCH_END round-trips: the killcam's seconds and the podium's three rows", str(over))
	var none := AirdriftEvents.read_match_end(GSNetReader.new(AirdriftEvents.write_match_end(0.0, [])))
	_check(bool(none["ok"]) and none["rows"].is_empty() and float(none["killcam"]) == 0.0,
		"and an empty board reads as none")
	_done()


## A hit the server applied reaches the one who fired, and only as the server described it.
func _test_hit_wire() -> void:
	_section("a confirmed hit over the link")

	var round_trip := AirdriftEvents.read_hit(GSNetReader.new(
		AirdriftEvents.write_hit(4097, 33.5, Vector3(-9123.25, 412.5, 15000.0), true, false)))
	_check(bool(round_trip["ok"]) and int(round_trip["victim"]) == 4097
			and absf(float(round_trip["amount"]) - 33.5) < 0.1
			and (round_trip["point"] as Vector3).is_equal_approx(Vector3(-9123.25, 412.5, 15000.0))
			and bool(round_trip["killed"]) and not bool(round_trip["headshot"]),
		"a HIT round-trips: victim, amount, point and both flags", str(round_trip))

	var arrived: Array[Dictionary] = []
	var on_hit := func(victim: int, amount: float, point: Vector3, killed: bool, headshot: bool) -> void:
		arrived.append({"victim": victim, "amount": amount, "point": point, "killed": killed, "headshot": headshot})
	_client_bridge.hit_received.connect(on_hit)
	_server_bridge._on_hit_landed(&"u%d" % SESSION, 12, 20.0, Vector3(1.0, 2.0, 3.0), false, true)
	# A shooter with no peer (a bot) is told nothing, and nothing reaches this client for it.
	_server_bridge._on_hit_landed(&"u999999", 12, 20.0, Vector3.ZERO, false, false)
	_flush()
	_client_bridge.hit_received.disconnect(on_hit)

	_check(arrived.size() == 1 and int(arrived[0]["victim"]) == 12 and bool(arrived[0]["headshot"]),
		"the shooter's own hit reaches their client, and a peerless shooter's does not (%s)" % str(arrived))
	_done()


## A death and a return, to everybody: who, and how the body falls (the server's pick).
## Armed by dropping the fall from `write_death` (the reaction check fails) and by reading it
## unconditionally (the bare check fails: an older server's DEATH reads garbage).
func _test_death_wire() -> void:
	_section("a death and a return over the link")

	var fall := GSPlayerDeath.new()
	fall.reaction = GSPlayerDeathReactions.HEADSHOT_LAUNCH
	fall.roll_seed = 9001
	fall.damage = 62.0
	fall.direction = Vector3(1.0, 0.0, 0.0)
	fall.headshot = true
	var carried := AirdriftEvents.read_death(GSNetReader.new(AirdriftEvents.write_death(4097, fall)))
	var read: GSPlayerDeath = carried.get("death")
	_check(bool(carried["ok"]) and int(carried["player_id"]) == 4097 and read != null
			and read.reaction == fall.reaction and read.roll_seed == 9001 and read.headshot
			and read.direction.distance_to(Vector3(1.0, 0.0, 0.0)) < 0.05,
		"a DEATH round-trips: the victim and the server's fall", str(carried))
	var bare := AirdriftEvents.read_death(GSNetReader.new(AirdriftEvents.write_death(4097)))
	_check(bool(bare["ok"]) and int(bare["player_id"]) == 4097 and not bare.has("death"),
		"and one without a fall reads as the victim alone", str(bare))

	var deaths: Array = []
	var alive: Array = []
	var on_death := func(id: StringName, death: GSPlayerDeath) -> void:
		deaths.append([id, death])
	var on_alive := func(id: StringName) -> void:
		alive.append(id)
	_client_bridge.death_received.connect(on_death)
	_client_bridge.alive_received.connect(on_alive)
	var victim := _server_player()
	victim.death = fall
	_server_bridge.broadcast_death(victim.player_id)
	_flush()
	_server_bridge.broadcast_alive(victim.player_id)
	_flush()
	victim.death = null
	_client_bridge.death_received.disconnect(on_death)
	_client_bridge.alive_received.disconnect(on_alive)

	_check(deaths.size() == 1 and deaths[0][0] == victim.player_id,
		"the death reaches the client, keyed as the client keys the player", str(deaths))
	_check(deaths.size() == 1 and deaths[0][1] != null
			and (deaths[0][1] as GSPlayerDeath).reaction == GSPlayerDeathReactions.HEADSHOT_LAUNCH,
		"with the reaction the server picked, so every screen draws the same fall")
	_check(alive == [victim.player_id], "and so does the return", str(alive))
	_done()


## `sv_flashlight`, `sv_allow_thirdperson` and the chat commands the help screen lists.
## Armed by sending the flags from the client's config instead of the server's (the live checks fail)
## and by letting `write_rules` truncate (the oversize check fails: a cut JSON document parses to nothing).
func _test_rules_wire() -> void:
	_section("what a client may do on its own screen, over the link")

	var round_trip := AirdriftEvents.read_rules(GSNetReader.new(AirdriftEvents.write_rules({
		"flashlight": false, "thirdperson": true, "commands": [["r", "Back to the start"], ["wr", "Fastest"]],
	})))
	_check(
		bool(round_trip["ok"]) and not bool(round_trip["flashlight"]) and bool(round_trip["thirdperson"])
			and (round_trip["commands"] as Array).size() == 2
			and str(round_trip["commands"][1][0]) == "wr",
		"a RULES body round-trips: both flags and the command list in order"
	)

	var many: Array = []
	for i in range(1500):
		many.append(["command_%04d" % i, "a description long enough to fill the body quickly %d" % i])
	var big := AirdriftEvents.read_rules(GSNetReader.new(AirdriftEvents.write_rules({
		"flashlight": false, "thirdperson": false, "commands": many,
	})))
	_check(
		bool(big["ok"]) and not bool(big["flashlight"]) and not bool(big["thirdperson"])
			and (big["commands"] as Array).size() > 0 and (big["commands"] as Array).size() < many.size(),
		"a list too long for the cap is shortened, never cut: the flags survive (%d of %d commands)" % [
			(big["commands"] as Array).size() if bool(big["ok"]) else 0, many.size()
		]
	)

	var junk := GSNetWriter.new()
	junk.write_string("{not json", AirdriftEvents.RULES_BYTES)
	_check(
		not bool(AirdriftEvents.read_rules(GSNetReader.new(junk.to_bytes()))["ok"]),
		"a body that is not a JSON object is refused rather than half-read"
	)

	var arrived: Array[Dictionary] = []
	var on_rules := func(r: Dictionary) -> void: arrived.append(r)
	_client_bridge.rules_received.connect(on_rules)
	var listed := func() -> Array: return [["r", "Back to the start"], ["spec", "Watch somebody"]]
	_server_bridge.commands_fn = listed

	_server_game.config.flashlight = false
	_server_bridge.broadcast_rules()
	_flush()
	_check(
		arrived.size() == 1 and not bool(arrived[0]["flashlight"]),
		"sv_flashlight 0 on the server reaches the client"
	)
	_check(
		arrived.size() == 1 and (arrived[0]["commands"] as Array).size() == 2
			and str(arrived[0]["commands"][1][0]) == "spec",
		"with the server's own command list, not one the client keeps"
	)

	_server_game.config.flashlight = true
	_server_game.config.allow_thirdperson = false
	_server_bridge.broadcast_rules()
	_flush()
	_check(
		arrived.size() == 2 and bool(arrived[1]["flashlight"]) and not bool(arrived[1]["thirdperson"]),
		"and so does turning it back on, and sv_allow_thirdperson 0"
	)

	_server_game.config.allow_thirdperson = true
	_server_bridge.commands_fn = Callable()
	_client_bridge.rules_received.disconnect(on_rules)
	_done()


func _test_voice_wire() -> void:
	_section("voice over the link")

	var relayed: Array[Dictionary] = []
	var heard: Array[PackedByteArray] = []

	_server_bridge.voice_relay_fn = func(speaker: int, bytes: PackedByteArray) -> void:
		relayed.append({"speaker": speaker, "bytes": bytes})
		# Straight back out, which is what GSVoiceRouter does once it has decided
		# who hears it. The router itself is checked on a real server in `dedicated`.
		_server_bridge.link.send_voice(CLIENT_PEER, bytes)

	_client_bridge.voice_in_fn = func(bytes: PackedByteArray) -> void:
		heard.append(bytes)

	var frame := PackedByteArray([9, 8, 7, 6, 5, 4, 3, 2])
	_client_bridge.link.send_voice_frame(frame)
	_flush()

	_check(relayed.size() == 1, "a captured frame reaches the server")

	if not relayed.is_empty():
		# The speaker is stamped from the transport, never read out of the payload: a client that
		# named its own speaker id could put words in anybody's mouth.
		_check(
			int(relayed[0]["speaker"]) == CLIENT_PEER,
			"stamped with the peer the transport reported",
			str(relayed[0]["speaker"])
		)
		_check(
			(relayed[0]["bytes"] as PackedByteArray) == frame,
			"and the bytes are unchanged"
		)

	_flush()
	_check(heard.size() == 1, "and the relay reaches a listener")

	# Never a broadcast. `send(bytes, 0)` is how this family last delivered a private
	# message to every client at once, and a voice packet sent to peer 0 would be
	# exactly that bug with audio in it.
	var before := _server_bridge.link.voice_sent
	_server_bridge.link.send_voice(0, frame)
	_check(
		_server_bridge.link.voice_sent == before,
		"and a voice frame addressed to peer 0 is refused rather than broadcast"
	)

	# The client's own voice reaches the server. Armed: a GSVoiceManager with no send_fn captures
	# and counts frames that go nowhere while every check above, which hands the link bytes, passes.
	relayed.clear()
	var extras_script := preload("../game/airdrift_client_extras.gd")
	var extras: Node = extras_script.new()
	extras.name = "VoiceExtras"
	add_child(extras)
	var attached: GSResult = extras.call(&"attach", _client_bridge, _client_game)
	var voice: GSVoiceManager = extras.get(&"voice")
	_check(attached.ok and voice != null, "the client's chat and voice attach to its bridge")
	if voice != null:
		var mic := GSVoiceSourceBuffer.new()
		mic.sample_rate = voice.config.sample_rate
		mic.write(GSVoiceSourceBuffer.tone(440.0, 0.2, mic.sample_rate, 0.4))
		voice.source = mic
		_check(not voice.is_capturing(), "no microphone is open before the talk key")
		extras.call(&"set_talking", true)
		for _i in range(4):
			await get_tree().process_frame
		_flush()
		_check(voice.frames_sent > 0 and relayed.size() == voice.frames_sent,
			"holding it sends the player's speech to the server (%d sent, %d relayed)" % [voice.frames_sent, relayed.size()])
		extras.call(&"set_talking", false)
	extras.queue_free()
	await get_tree().process_frame
	_done()


func _section(name: String) -> void:
	pass

func _done() -> void:
	pass

func _flush() -> void:
	pass

func _server_player() -> AirdriftPlayer:
	return null
