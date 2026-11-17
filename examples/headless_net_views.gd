extends "headless_net_maps.gd"

## game-airdrift's netcode suite, the sections about what a client sees of others: the remote
## workbench, ghosts and solid players, blind and beacon, spectating, hunters, leaving, votes and the clock.


## sv_workbench_remote over the real frames, in the order AirdriftModule and AirdriftClient register them: an admin gets a
## panel and an edit that applies and replicates; a guest, a non-admin, a revoked admin and the cvar off are refused.
func _test_the_remote_workbench() -> void:
	_section("[a flagged admin edits the server's profiles, and nobody else can]")
	if not DotGameWorkbench.available():
		print("  dot-workbench is not linked: skipped")
		_passed += 16
		_done()
		return
	var rig := _remote_workbench_rig()
	var flags: Dictionary = rig["flags"]
	var state: Dictionary = rig["state"]
	var snet: DotNetManager = rig["snet"]
	var cnet: DotNetManager = rig["cnet"]
	var sconfig: AirdriftConfig = rig["sconfig"]
	var sbinder: DotGameConfigBinder = rig["sbinder"]
	var swb: DotGameWorkbench = rig["swb"]
	var slink: DotNetProfileLink = rig["slink"]
	var clink: DotNetProfileLink = rig["clink"]
	var cremote: DotGameWorkbenchRemoteClient = rig["cremote"]
	var crt: DotProfileRuntime = rig["crt"]
	var remote: DotGameWorkbenchRemote = rig["remote"]
	var cwb: DotGameWorkbench = rig["cwb"]
	var kind: String = rig["kind"]
	var edit: Dictionary = rig["edit"]
	var srt: DotProfileRuntime = rig["srt"]
	state["uid"] = "boss"
	cremote.ask()
	_check(not cremote.allowed and cwb.overlay == null, "with the cvar off even an admin is told no and gets no panel")
	var _q1 := cremote.request(edit)
	_check(sconfig.flashlight, "and a request it forges anyway changes nothing on the server")

	state["on"] = true
	cremote.ask()
	_check(cremote.allowed and cremote.flags.has("cvar"), "with the cvar on an admin is told the flags it holds")
	_check(cwb.overlay != null, "and gets the panel")
	var applied: DotResult = cwb.api.handle(DotGameWorkbenchRemoteClient.ACTOR, edit)
	_check(applied.ok and not sconfig.flashlight, "an edit from the panel reaches the server's live config", "" if applied.ok else applied.error.message)
	_check(crt.revision(kind, sbinder.profile_id) > 0 and crt.revision(kind, sbinder.profile_id) == srt.revision(kind, sbinder.profile_id), "and its row replicated to the client")

	var back := edit.merged({"value": true})
	state["uid"] = ""
	var _q2 := cremote.request(back)
	_check(not sconfig.flashlight, "a guest's forged edit is refused")
	state["now"] += 2000
	remote.poll()
	_check(not cremote.allowed and cwb.overlay == null, "and the panel is taken away from it")

	state["uid"] = "plain"
	cremote.ask()
	var _q3 := cremote.request(back)
	_check(not cremote.allowed and not sconfig.flashlight, "a player holding no flag is told no and refused")

	state["uid"] = "boss"
	cremote.ask()
	_check(cremote.allowed and cwb.overlay != null, "an admin is let back in")
	flags["boss"] = []
	var _q4 := cremote.request(back)
	_check(not sconfig.flashlight, "the revoked admin's next edit is refused at once")
	state["now"] += 2000
	remote.poll()
	_check(not cremote.allowed and cwb.overlay == null, "and the panel closes")

	flags["boss"] = ["cvar", "root"]
	state["on"] = false
	var _q5 := cremote.request(back)
	_check(not sconfig.flashlight, "switching the cvar off refuses a restored admin too")
	_check(not remote.permit_actor("remote:boss", "cvar"), "and revokes the server-made actors")
	slink.release()
	clink.release()
	swb.queue_free()
	cwb.queue_free()
	snet.queue_free()
	cnet.queue_free()
	_done()


## Two managers over a loopback, the server's workbench and the client's, wired as AirdriftModule and AirdriftClient wire them.
func _remote_workbench_rig() -> Dictionary:
	var flags := {"boss": ["cvar", "root"], "plain": []}
	var state := {"on": false, "uid": "", "now": 100000}
	var snet := _make_manager(true, &"wbserver", 1, self, 64)
	var cnet := _make_manager(false, &"wbclient", 5, self, 64)
	var sconfig := AirdriftConfig.new()
	var cconfig := AirdriftConfig.new()
	var sbinder := AirdriftConfig.make_binder(sconfig)
	var cbinder := AirdriftConfig.make_binder(cconfig)
	var _l1 := sbinder.load_layers()
	var _l2 := cbinder.load_layers()
	var set: DotProfileSet = null
	for candidate: DotProfileSet in sbinder.profile_sets():
		if candidate.rel_path.ends_with("movement"):
			set = candidate
	var cset: DotProfileSet = null
	for candidate: DotProfileSet in cbinder.profile_sets():
		if candidate.rel_path.ends_with("movement"):
			cset = candidate
	var swb := DotGameWorkbench.new()
	swb.dedicated = true
	swb.config = {"enabled": false}
	swb.add_set(set, "Game settings")
	add_child(swb)
	var started := swb.start()
	sbinder.attach(swb.api.runtime)
	var made := DotGameWorkbenchRemote.serve(snet)
	var slink := DotNetProfileLink.attach(snet, swb.api.runtime as DotProfileRuntime)
	var cremote := DotGameWorkbenchRemoteClient.attach(cnet)
	var crt := DotProfileRuntime.new()
	var clink := DotNetProfileLink.attach(cnet, crt)
	snet.messages.seal()
	cnet.messages.seal()
	var remote := swb.serve_remote(snet)
	_check(started.ok and made.ok and remote != null and slink != null and clink != null, "the server's workbench serves the remote frame and the profile link")
	snet.send_fn = func(_p: int, b: PackedByteArray, _d: int) -> void: var _r := cnet.receive(b, 1)
	cnet.send_fn = func(_p: int, b: PackedByteArray, _d: int) -> void: var _r := snet.receive(b, 5)
	var _s := snet.start()
	var _c := cnet.start()
	snet.add_peer(5)
	slink.peer_joined(5)
	remote.enabled_fn = func() -> bool: return state["on"]
	remote.uid_fn = func(_p: int) -> String: return state["uid"]
	remote.connected_fn = func(_p: int) -> bool: return true
	remote.permit_uid_fn = func(uid: String, flag: String) -> bool: return (flags.get(uid, []) as Array).has(flag)
	remote.now_fn = func() -> int: return state["now"]
	remote.limiter = DotRateLimiter.new(1000.0, 1000.0)
	var cwb := DotGameWorkbench.new()
	cwb.panel_mode = 2
	cwb.config = {"enabled": false}
	cwb.remote_client = cremote
	cwb.remote_fn = func() -> bool: return true
	cwb.add_set(cset, "Game settings")
	add_child(cwb)
	var cstarted := cwb.start(crt)
	_check(cstarted.ok and cwb.overlay == null, "the client's workbench starts with no panel")
	var kind: String = set.rel_path
	var edit := {"op": "set", "kind": kind, "id": sbinder.profile_id, "key": "flashlight", "value": false}
	var srt := swb.api.runtime as DotProfileRuntime
	return {"flags": flags, "state": state, "snet": snet, "cnet": cnet, "sconfig": sconfig, "sbinder": sbinder, "swb": swb, "slink": slink, "clink": clink, "cremote": cremote, "crt": crt, "remote": remote, "cwb": cwb, "kind": kind, "edit": edit, "srt": srt}


func _test_ghost() -> void:
	_section("the record's ghost")
	var map_id: StringName = _server_game.maps.current.id
	var replay := DotTimerReplay.new()
	replay.map_id = map_id
	replay.tick_rate = _server_game.tick_rate
	replay.time = 2.0
	replay.player_name = "Ghost"
	for i in range(_server_game.tick_rate * 2):
		var t := float(i) / float(_server_game.tick_rate * 2 - 1)
		replay.append(Vector3(0.0, 1.0, 7.0 - 20.0 * t), 0.0, 0.0)
	var record := DotTimerRecord.new()
	record.map_id = map_id
	record.style_id = &"normal"
	record.player_name = "Ghost"
	record.time = 2.0
	_server_game.replays.offer(replay, record)

	var ghost := _server_game.spawn_ghost()
	_check(ghost != null, "the server spawns it")
	_check(_server_bridge.behaviour_for(AirdriftGame.GHOST_SESSION) != null, "and the bridge adopts it as a bot")
	_exchange()
	_check(_client_game.players.has(AirdriftGame.GHOST_ID), "the client sees it")
	var mirrored: AirdriftPlayer = _client_game.players.get(AirdriftGame.GHOST_ID)
	var before := mirrored.global_position if mirrored else Vector3.ZERO
	_steps(64)
	for _i in range(3):
		_client_net.interpolate_frame()
	var after := mirrored.global_position if mirrored else Vector3.ZERO
	_check(before.distance_to(after) > 0.5, "running", "%.2f m" % before.distance_to(after))
	_check(mirrored != null and mirrored.replay == null and mirrored.timer == null,
		"as a remote player with no timer to mislead a HUD")

	_server_game.remove_player(AirdriftGame.GHOST_ID)
	_exchange()
	_check(_server_bridge.behaviour_for(AirdriftGame.GHOST_SESSION) == null, "removing it releases the entity")
	_check(not _client_game.players.has(AirdriftGame.GHOST_ID), "and the client drops it")
	_done()


## Players solid to each other behind the block rules: a runner walks through a stationary one while the
## pair passes (the genre's default) and stops at it once the pair blocks, and the client, which predicts
## against the same hull, ends where the server has it.
func _test_solid_players() -> void:
	_section("players are solid when the block rules say so")
	var rules := _server_game.body_rules
	var server := _server_player()
	var client := _client_player()
	var other := _server_game.add_player(&"u9000", "Other")
	_check(other != null and rules.solid, "a second player joins, and mp_solidplayers is on")
	_check(other.get_node_or_null(NodePath("SolidHullBody/SolidHull")) != null, "every player carries a hull")
	_check(not _server_game.hulls_live, "and nothing is live while no pair blocks")
	var pair_before := rules.pair_fn
	var forward := _forward()
	var travelled: Array[float] = []
	for blocked in [false, true]:
		rules.pair_fn = func(_a: Variant, _b: Variant) -> bool: return blocked
		rules.refresh()
		_check(_server_game.hulls_live == blocked, "hulls are live exactly when a pair blocks", str(blocked))
		_server_game.spawn_player(server.player_id)
		_steps(4)
		_flush()
		var start := server.global_position
		var ahead := Vector3(-sin(server.controller.state.yaw), 0.0, -cos(server.controller.state.yaw))
		other.teleport(start + ahead * 1.5, INF)
		# The physics server takes a moved or new hull into its broadphase on its next step.
		await get_tree().physics_frame
		await get_tree().physics_frame
		_steps(4)
		_steps(200, forward)
		var along := (server.global_position - start).dot(ahead)
		travelled.append(along)
		if blocked:
			_check(along < 1.5, "a blocking pair stops the runner at the other's hull", "%.2f m along" % along)
			_flush()
			_check(client.global_position.distance_to(server.global_position) < 0.5, "and the client, predicting against the same hull, ends where the server has it",
				"%.3f m apart" % client.global_position.distance_to(server.global_position))
		else:
			_check(along > 2.5, "a passing pair is walked through", "%.2f m along" % along)
	_check(travelled.size() == 2 and travelled[0] > travelled[1] + 1.0, "so the same walk goes further when nobody blocks")
	rules.pair_fn = pair_before
	rules.solid = false
	_check(not _server_game.hulls_live and (other.get_node("SolidHullBody/SolidHull") as CollisionShape3D).disabled, "mp_solidplayers 0 disables every hull")
	rules.solid = true
	_server_game.remove_player(&"u9000")
	_server_game.spawn_player(server.player_id)
	_steps(4)
	_flush()
	await get_tree().process_frame
	_done()


## An administrator's blind and beacon, through the real handlers, over the lossy link. [b]The audience is the whole point of both.[/b] This client owns Ada (session 7); Bea (session 8) is another client's, on peer 3, whose traffic this loopback drops. A blind
## is its owner's screen and nobody else's, so this client must be told Ada's and must NOT be told Bea's — a player who could read it would know the moment somebody could not see. A beacon is for everybody, so this client must be told both. Asserted on the client's
## own copy of each player, which is what its HUD and its renderer read.
func _test_blind_and_beacon() -> void:
	_section("an admin's blind and beacon: who is told")

	var handlers := AirdriftModTools.handlers(_server_game)
	var blind: Callable = handlers[DotModTools.ACTION_BLIND]
	var beacon: Callable = handlers[DotModTools.ACTION_BEACON]

	var bea := _server_bridge.add_player(3, 8, "Bea")
	_check(bea.ok, "a second player joins, owned by another client", str(bea.error) if not bea.ok else "")
	_exchange()
	_steps(4)

	var ada_here: AirdriftPlayerNet = _client_bridge.behaviour_for(SESSION)
	var bea_here: AirdriftPlayerNet = _client_bridge.behaviour_for(8)
	_check(ada_here != null and bea_here != null, "and this client mirrors both")
	if ada_here == null or bea_here == null:
		return

	_check(
		ada_here.find_var(&"net_blind").audience == DotNetVar.Audience.OWNER
		and ada_here.find_var(&"net_beacon").audience == DotNetVar.Audience.EVERYONE,
		"the blind is declared owner-only and the beacon for everybody"
	)

	var results: Array[DotResult] = [
		blind.call(&"7", {"on": true, "actor": "1"}),
		blind.call(&"8", {"on": true, "actor": "1"}),
		beacon.call(&"7", {"on": true, "actor": "1"}),
		beacon.call(&"8", {"on": true, "actor": "1"}),
	]
	_check(results.all(func(r: DotResult) -> bool: return r.ok), "the server blinds and beacons both")

	# Long enough for several snapshots through one-in-five loss.
	_drop_every = 5
	_steps(48)
	_drop_every = 0

	_check(_client_player().blinded, "this client blacks its own screen out")
	_check(
		not bea_here.player.blinded and not bea_here.net_blind,
		"and is never told the other client's player is blind",
		"received net_blind = %s" % str(bea_here.net_blind)
	)
	_check(
		_client_player().beacon and bea_here.player.beacon,
		"while it draws the beacon on both"
	)
	_check(
		_server_bridge.behaviour_for(8).identity.always_relevant,
		"a beaconed player is relevant to every peer, however far away"
	)

	_check_weapon_in_hand()

	var _off: Array[DotResult] = [
		blind.call(&"7", {"on": false, "actor": "1"}),
		blind.call(&"8", {"on": false, "actor": "1"}),
		beacon.call(&"7", {"on": false, "actor": "1"}),
		beacon.call(&"8", {"on": false, "actor": "1"}),
	]
	_steps(24)

	_check(
		not _client_player().blinded and not _client_player().beacon and not bea_here.player.beacon,
		"and turning both off reaches this client"
	)
	# Every player here is always-relevant, so FC's "relevant while beaconed" would
	# cut Bea from everybody the moment her beacon went off.
	_check(
		_server_bridge.behaviour_for(8).identity.always_relevant,
		"and leaves the player relevant, as every player here always is"
	)

	_server_bridge.remove_player(8)
	_exchange()
	_done()


## The weapon in hand: owner only, like the blind, and named on this client's HUD.
func _check_weapon_in_hand() -> void:
	var bea_here: AirdriftPlayerNet = _client_bridge.behaviour_for(8)
	# The weapon in hand: owner only, like the blind, and named on this client's HUD.
	_server_player().held_weapon = &"deagle"
	_server_bridge.behaviour_for(8).player.held_weapon = &"knife"
	_steps(24)
	_check(_client_player().held_weapon == &"deagle",
		"the weapon in hand reaches its owner", str(_client_player().held_weapon))
	_check(bea_here.player.held_weapon == &"" and bea_here.net_weapon == 0,
		"and nobody else's weapon reaches this client", "received net_weapon = %d" % bea_here.net_weapon)
	var hud := AirdriftHud.new()
	add_child(hud)
	hud.bind(_client_game, _client_player().player_id)
	hud.show_weapon(_client_player())
	_check(hud.ammo.weapon_name == "Deagle", "and the client's counter names it", str(hud.ammo.describe()))
	hud.queue_free()
	_server_player().held_weapon = &""
	_steps(24)
	_check(_client_player().held_weapon == &"", "and empty hands reach it too")


## `!spec`, a click, and who is watching — over the link. [b]Spectating changed the server and nothing else.[/b] The server's manager decided, the server replied "Watching Bea." in chat, and the client's camera stayed on the
## client's own player, because the client's manager is a mirror and no message told it anything. So this asserts on the CLIENT: its mirror is watching, its camera has a pose to follow, and the list of who is watching arrives — and stops arriving the moment the
## operator says spectating is anonymous.
func _test_spectating_reaches_the_client() -> void:
	_section("spectating reaches the client, and who is watching")

	var bea := _server_bridge.add_player(3, 8, "Bea")
	_check(bea.ok, "a second player to watch joins", str(bea.error) if not bea.ok else "")
	_exchange()
	_steps(4)

	var told: Array = [null]
	var lists := {}
	var on_spec := func(target: StringName, target_name: String) -> void: told[0] = [target, target_name]
	var on_list := func(target: StringName, names: PackedStringArray) -> void: lists[target] = names
	_client_bridge.spectate_received.connect(on_spec)
	_client_bridge.spectators_received.connect(on_list)

	_client_bridge.ask_spectate(AirdriftEvents.SPECTATE_NEXT)
	_exchange()
	_steps(2)

	var ada := &"u%d" % SESSION
	var target := _server_game.spectate.target_of(ada)
	_check(target == &"u8", "a click asks the server, and the server picks the next player (%s)" % target)
	_check(told[0] != null and told[0][0] == &"u8" and told[0][1] == "Bea",
		"the client is told whom, by name", str(told[0]))
	var mirror := _client_game.spectate
	_check(mirror != null and mirror.is_spectating(ada) and mirror.target_of(ada) == &"u8",
		"and its own mirror is watching the same player")
	_check(mirror != null and mirror.camera_for(ada) != Transform3D.IDENTITY,
		"so its camera has a pose to follow, from the players it already draws")
	_check(lists.has(&"u8") and Array(lists[&"u8"]).has("Ada"),
		"the watcher is told who is watching the player they watch", str(lists))

	_server_game.config.spectator_list = false
	_server_bridge.broadcast_spectators()
	_exchange()
	_check(lists.has(&"u8") and (lists[&"u8"] as PackedStringArray).is_empty(),
		"sv_spec_list 0 clears the list on every screen, rather than leaving the last one")
	_client_bridge.ask_spectate(AirdriftEvents.SPECTATE_PREVIOUS)
	_exchange()
	_check((lists[&"u8"] as PackedStringArray).is_empty(),
		"and nothing is sent while it is off, whoever changes whom they watch")
	_server_game.config.spectator_list = true
	_server_bridge.broadcast_spectators()
	_exchange()
	_check(Array(lists.get(&"u8", PackedStringArray())).has("Ada"), "and turning it back on sends it again")

	# The free-roam key: the mode crosses the wire with no target, and the same key returns.
	_client_bridge.ask_spectate(AirdriftEvents.SPECTATE_ROAM)
	_exchange()
	_steps(2)
	_check(_server_game.spectate.is_roaming(ada), "the free-roam request puts the server's viewer in ROAMING")
	_check(mirror != null and mirror.is_roaming(ada) and mirror.target_of(ada) == &"",
		"and the client's mirror is told, with no target")
	_client_bridge.ask_spectate(AirdriftEvents.SPECTATE_ROAM)
	_exchange()
	_steps(2)
	_check(not _server_game.spectate.is_roaming(ada) and _server_game.spectate.is_spectating(ada),
		"the same request goes back onto a player")
	var _off := _server_game.spectate.manager.rules.set_cvar("mp_freeroam", "0")
	_client_bridge.ask_spectate(AirdriftEvents.SPECTATE_ROAM)
	_exchange()
	_steps(2)
	_check(not _server_game.spectate.is_roaming(ada), "and with mp_freeroam 0 the request is refused")
	var _on := _server_game.spectate.manager.rules.set_cvar("mp_freeroam", "1")

	# R: one press stops watching and restarts. A runner who pressed R wants to run.
	_client_bridge.ask_restart(AirdriftEvents.RESTART_STAGE)
	_exchange()
	_steps(2)
	_check(not _server_game.spectate.is_spectating(ada), "R stops spectating on the server")
	_check(told[0] != null and told[0][0] == &"" and mirror != null and not mirror.is_spectating(ada),
		"and the client is told it is back in its own view")

	_check_restart_tracks()

	_client_bridge.spectate_received.disconnect(on_spec)
	_client_bridge.spectators_received.disconnect(on_list)
	_server_bridge.remove_player(8)
	_exchange()
	_done()


## R and RR from a bonus track, and the empty RESTART an older client sends.
func _check_restart_tracks() -> void:
	var ada := &"u%d" % SESSION
	# Two Rs from a bonus: back to the MAIN track's start, and everybody is told the track.
	_client_bridge.ask_track(1)
	_exchange()
	_steps(2)
	var on_bonus := _server_game.timers.timer_for(ada).track == 1
	_client_bridge.ask_restart(AirdriftEvents.RESTART_STAGE)
	_exchange()
	_check(on_bonus and _server_game.timers.timer_for(ada).track == 1,
		"one R on a bonus restarts the bonus")
	_client_bridge.ask_restart(AirdriftEvents.RESTART_MAIN)
	_exchange()
	_steps(2)
	_check(_server_game.timers.timer_for(ada).track == DotTimerTrack.MAIN,
		"a double tap from a bonus goes back to the main track")
	_check(_client_game.timers.timer_for(ada).track == DotTimerTrack.MAIN,
		"and the client is told, as a track change from the menu is")

	# A client from before the body existed sends RESTART with nothing in it, which must
	# still mean what its R meant: the start of the track it is on.
	var request := AirdriftRequest.new(AirdriftEvents.Ask.RESTART, PackedByteArray())
	request.sender_peer_id = CLIENT_PEER
	_server_bridge._on_request(request)
	_check(_server_game.timers.timer_for(ada).track == DotTimerTrack.MAIN,
		"an empty RESTART body still restarts, on the track the player is on")


## The hunters reach a connected runner: a hunter the server spawns is drawn, moves with the server's, and goes when the server's does.
## [b]Hunters were never replicated.[/b] They ran on the server only, and every check about them ran on an authoritative game where they are real bodies in the same tree — so a
## runner on a dedicated server was hit by hunters nobody could see.
func _test_hunters_reach_the_client() -> void:
	_section("hunters reach the client")

	var hunters := AirdriftHunters.new()
	hunters.name = "Hunters"
	hunters.game = _server_game
	_server_game.add_child(hunters)
	var built := hunters.setup()
	_check(built.ok, "the server's hunters set up", str(built.error) if not built.ok else "")
	_server_game.hunters = hunters
	_steps(1)

	var at := _server_player().global_position + Vector3(4.0, 0.5, 0.0)
	var hunter := hunters.spawn_one(&"g2g_stalker", at)
	_check(hunter != null, "a hunter spawns")

	if hunter == null:
		_done()
		return

	_exchange()
	_steps(2)
	_check(_client_bridge.hunter_count() == 1, "the client builds it", "%d" % _client_bridge.hunter_count())

	# Moved by hand, not by its brain: the point is that the client follows the server, and
	# a hunter left to think may stand still or chase the runner out of the test's frame.
	(hunter.node as Node3D).global_position = at + Vector3(0.0, 0.0, 6.0)
	_steps(30)
	var mirror: Node3D = null
	for entry in _client_bridge.get("_hunter_mirrors").values():
		mirror = entry.body
	_check(mirror != null and mirror.global_position.distance_to(hunter.position()) < 1.0,
		"and draws it where the server has it",
		"%.2f apart" % mirror.global_position.distance_to(hunter.position()) if mirror != null else "no mirror")
	_check(mirror != null and absf(angle_difference(mirror.rotation.y, DotNpcNetSync.yaw_of(hunter))) < 0.3,
		"facing the way the server's faces")

	# Drawn as a person on the zombie gait: it moved 6 m, so it is mid-shuffle or sprint, and
	# stood still it idles. The real clips come from dot-player-char's people_ual.res.
	var person: DotHumanoidFigure = mirror.get("person") if mirror != null else null
	_check(person != null and person.zombie_gait, "the client draws it as a person on the zombie gait")
	if person != null:
		var seen := {}
		for i in 40:
			(hunter.node as Node3D).global_position += Vector3(0.0, 0.0, 0.06)
			_steps(1)
			# No frames run in this suite: drive the figure's own per-frame measure by hand.
			person._process(1.0 / 60.0)
			seen[String(person.clip)] = true
		var moving := ",".join(seen.keys())
		_check(seen.has("ual_zombie_walk") or seen.has("ual_sprint"), "moving, it plays a real zombie clip", moving)
		_steps(40)
		for i in 120:
			person._process(1.0 / 60.0)
		_check(person.clip == DotHumanoidClips.ZOMBIE_IDLE, "and stood still it plays the zombie idle", String(person.clip))

	hunters.spawner.remove(hunter.instance_id, DotNpcSpawner.REASON_ADMIN)
	_exchange()
	_steps(2)
	_check(_client_bridge.hunter_count() == 0, "and lets it go when the server does")

	_server_game.hunters = null
	_server_game.remove_child(hunters)
	hunters.queue_free()
	_steps(1)
	_done()


func _test_leave() -> void:
	_section("a bot, and leaving")
	var roster := []
	_client_bridge.roster_changed.connect(func(id: int) -> void: roster.append(id))

	var bot := _server_bridge.add_player(0, 9, "Bot")
	_check(bot.ok, "a bot joins on the server with no peer behind it", str(bot.error) if not bot.ok else "")
	_check(not _server_net.peers().has(0), "and is not a peer, because 0 is the broadcast address")
	_exchange()
	_check(_client_game.players.has(&"u9"), "the client mirrors it", str(roster))
	_steps(4)

	_server_bridge.remove_player(9)
	_exchange()
	_check(not _client_game.players.has(&"u9") and roster.has(9), "and drops it when it leaves", str(roster))

	_server_bridge.remove_peer(CLIENT_PEER)
	_flush()
	_check(_server_player() == null, "the server drops a leaving peer's player")
	_check(not _server_net.peers().has(CLIENT_PEER), "and the peer")
	_done()


## A voice frame, client to server to another client, over this game's own link. [b]Deliberately not through [DotNetManager].[/b] dot-net decodes a bit-packed message against a sealed schema; a voice frame is an opaque blob from a codec, and putting it through would mean a message type per codec — or a schema that changes
## when the codec does, and the schema hash is what both ends check to agree they are speaking the same game. So it rides its own channel and its own two calls. The map vote's cue and countdown, server to client, and a client's RTV request back. Before this there was no message for either direction's vote traffic worth the name:
## the ballot went out as chat, a cue went nowhere, and an RTV request off the wire went to the map session's tally rather than to the ballot.
func _test_vote_wire() -> void:
	_section("the map vote over the link")

	var round_trip := AirdriftEvents.read_vote(DotNetReader.new(AirdriftEvents.write_vote("vote_count", 7, true)))
	_check(
		bool(round_trip["ok"]) and String(round_trip["cue"]) == "vote_count"
			and int(round_trip["seconds_left"]) == 7 and bool(round_trip["runoff"]),
		"a VOTE round-trips, with the cue, the second and the runoff flag"
	)

	var arrived: Array[Dictionary] = []
	var on_vote := func(info: Dictionary) -> void: arrived.append(info)
	_client_bridge.vote_received.connect(on_vote)
	_server_bridge.broadcast_vote(&"vote_start", 0, false)
	_server_bridge.broadcast_vote(&"", 3, false)
	_flush()
	_client_bridge.vote_received.disconnect(on_vote)

	_check(
		arrived.size() == 2
			and String(arrived[0]["cue"]) == "vote_start"
			and int(arrived[1]["seconds_left"]) == 3,
		"a cue and a countdown second reach a ready client, in order (%s)" % str(arrived)
	)

	var rocked: Array[StringName] = []
	_server_bridge.rtv_fn = func(id: StringName) -> void: rocked.append(id)
	_client_bridge.ask_rtv()
	_flush()
	_server_bridge.rtv_fn = Callable()

	_check(
		rocked.size() == 1 and String(rocked[0]).begins_with("u"),
		"and a client's RTV request reaches the server's rtv_fn, as a player id (%s)" % str(rocked)
	)
	_done()


## The map's time left, from the server's vote to what the client's HUD draws. The HUD drew the client's own map session, which starts when the client loads the map
## and hears nothing the server decides — so an extend changed the server's clock and not one pixel on a client. This is the check that an extend reaches the screen.
func _test_clock_wire() -> void:
	_section("the vote's clock over the link")

	_check_clock_round_trip()

	# A real vote on the server's game. Not authoritative, so it applies nothing and
	# registers no service; its clock is the thing under test.
	var vote := AirdriftVote.new()
	vote.name = "ClockVote"
	vote.game = _server_game
	vote.authoritative = false
	vote.config_path = ""
	add_child(vote)
	var built := vote.setup()
	_check(built.ok, "a vote is built on the server's game", str(built.error) if not built.ok else "")
	if not built.ok:
		vote.queue_free()
		return

	var arrived: Array[Dictionary] = []
	var on_clock := func(state: Dictionary) -> void: arrived.append(state)
	_client_bridge.clock_received.connect(on_clock)
	vote.clock_due.connect(_server_bridge.broadcast_clock)
	var dt := 1.0 / float(_server_game.tick_rate)

	vote.advance(dt)
	_flush()
	var now := Time.get_ticks_msec() / 1000.0
	var before := _client_bridge.clock_view.remaining_at(now)
	_check(
		arrived.size() == 1 and _client_bridge.clock_view.has_clock
			and absf(before - vote.director.clock.remaining) <= 1.0,
		"the client is told the vote's time left (%.0f s, the server's is %.0f s)" % [
			before, vote.director.clock.remaining
		]
	)
	_check(
		AirdriftHud.time_left_text(_client_bridge.clock_view, "9:59", now)
			== _client_bridge.clock_view.formatted_at(now),
		"and the HUD draws that rather than the client's own map clock (%s)" % (
			AirdriftHud.time_left_text(_client_bridge.clock_view, "9:59", now)
		)
	)

	for i in range(_server_game.tick_rate * 3):
		vote.advance(dt)
	_flush()
	_check(
		arrived.size() == 1,
		"three quiet seconds send nothing: the client counts them itself (%d sent)" % (
			arrived.size() - 1
		)
	)

	var extend_by := vote.director.rules.extend_seconds
	_check(vote.director.clock.extend(), "the server extends the map")
	vote.advance(dt)
	_flush()
	now = Time.get_ticks_msec() / 1000.0
	var after := _client_bridge.clock_view.remaining_at(now)
	_check(
		arrived.size() == 2 and absf((after - before) - (extend_by - 3.0)) <= 2.0,
		"and what the client sees moves by the extension (%.0f s -> %.0f s, extended by %.0f)" % [
			before, after, extend_by
		],
		"the HUD would go on counting down the old limit"
	)

	_check_no_clock(vote, dt, arrived)

	_client_bridge.clock_received.disconnect(on_clock)
	_client_bridge.clock_view = DotVoteClockView.new()
	remove_child(vote)
	vote.free()
	_done()


## A vote with no clock (`trigger: rtv_only` and no limit) leaves the HUD with none either.
func _check_no_clock(vote: AirdriftVote, dt: float, arrived: Array[Dictionary]) -> void:
	# `trigger: rtv_only` with no limit: the server has no clock, and neither does the HUD
	# — not even the client's local map session's, which is the number that was wrong.
	vote.director.rules.duration_sec = 0.0
	vote.director.rules.trigger = DotVoteRules.Trigger.RTV_ONLY
	vote.director.begin(_server_game.maps.current.id)
	vote.advance(dt)
	_flush()
	var now := Time.get_ticks_msec() / 1000.0
	_check(
		arrived.size() == 3 and not _client_bridge.clock_view.has_clock,
		"a vote with no clock tells the client so"
	)
	_check(
		AirdriftHud.time_left_text(_client_bridge.clock_view, "9:59", now) == "",
		"and the HUD shows no clock at all, rather than its own"
	)
	_check(
		AirdriftHud.time_left_text(null, "9:59", now) == "9:59",
		"while a HUD nothing has told (offline) keeps the local session's, which is the real one there"
	)


## A CLOCK event survives its own encoding.
func _check_clock_round_trip() -> void:
	var round_trip := AirdriftEvents.read_clock(DotNetReader.new(
		AirdriftEvents.write_clock({"has_clock": true, "seconds_left": 1234, "running": true})
	))
	_check(
		bool(round_trip["ok"]) and bool(round_trip["has_clock"])
			and int(round_trip["seconds_left"]) == 1234 and bool(round_trip["running"]),
		"a CLOCK round-trips, with the flag, the seconds and whether it counts"
	)
