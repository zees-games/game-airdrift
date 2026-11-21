extends Node

const AirdriftPaths := preload("airdrift_paths.gd")

const AirdriftArsenal := preload("airdrift_arsenal.gd")
const AirdriftCombat := preload("airdrift_combat.gd")
const AirdriftEffects := preload("airdrift_effects.gd")
const AirdriftGame := preload("airdrift_game.gd")
const AirdriftPlayer := preload("airdrift_player.gd")
const AirdriftStats := preload("airdrift_stats.gd")
const AirdriftUnits := preload("airdrift_units.gd")

## Hunters on the course: gs-npc, gs-npc-ai and gs-npc-ai-director.
##
## [b]The idea is one this genre already has under other names[/b] — bhop zombies, the
## chase in a hunted map — and it works here for a reason worth stating: a hunter
## cannot catch a runner who is running well. The fastest one does 8 m/s and a bhop
## player on a good line does forty. What a hunter punishes is stopping, which is the
## same thing the timer punishes, made visible.
##
## [b]There is no navigation graph, and that is the design rather than a shortcut.[/b]
## A timer map is a critical path — start pad, stage lines, end zone — and
## [GSNpcDirectorFlow] is exactly "the map's own critical path" as a thing you can
## sample. So the flow is built from the map's zones, the director spawns ahead along
## it, and hunters patrol it; the pathfinding a graph would give is spent on a map
## whose route is already known. [method GSNpcBrain.steer_toward] falls back to
## steering straight at a goal when there is no path, and gs-npc documents that as a
## decision rather than an oversight.
##
## [codeblock]
## var hunters := AirdriftHunters.new()
## hunters.game = game
## add_child(hunters)
## hunters.setup()
## hunters.enabled = true
## [/codeblock]
##
## Server-authoritative and unpredicted, for gs-props' reason twice over: a brain runs
## a behaviour tree against a blackboard with lifetimes on it, which is not something
## two machines reproduce from the same inputs.

const CHANNEL := "g2g.hunters"

## The registry name a brain reaches this through. See `airdrift_hunter_brain.gd`.
const SERVICE := &"airdrift_hunters"

const STALKER := &"g2g_stalker"
const SPRINTER := &"g2g_sprinter"

const FACTION := &"hunter"

static var BRAIN_PATH := AirdriftPaths.rebase("res://game/airdrift_hunter_brain.gd")

## A hunter died. Carries the player id that killed it, or empty.
signal hunter_killed(npc: GSNpcInstance, killer: StringName)

signal wave_spawned(at: Vector3, count: int)

@export_group("Pacing")

## Whether anything is spawned at all. `sv_hunters` sets it.
@export var enabled: bool = false

var game: AirdriftGame = null

var spawner: GSNpcSpawner = null

## The hunters' squad and what they can hear. On the spawner as metadata, so gs-npc-ai's
## brain finds both; see [method note_fire] for what makes the noise.
var squads: GSNpcAiSquads = GSNpcAiSquads.new()
var sounds: GSNpcAiSounds = GSNpcAiSounds.new()

## How far a shot is heard by a hunter of alertness 1, in metres. Two stages of a course:
## a deathmatch gunfight brings the hunters nearby and not the whole map.
const GUNFIRE_RADIUS := 28.0
var director: GSNpcDirector = null
var senses: GSNpcSenses = null

## The map's route, as something a position can be measured along.
var flow: GSNpcDirectorFlow = null

var _world: Node3D = null
var _candidates: Array = []
var _registered: bool = false


func _exit_tree() -> void:
	if _registered:
		GSRegistry.unregister_instance(SERVICE, self)
		_registered = false


func setup() -> GSResult:
	if game == null:
		return GSResult.fail(GSError.CODE_STATE, "Hunters need a game.")

	_world = Node3D.new()
	_world.name = "Hunters"
	add_child(_world)

	senses = GSNpcSenses.new()
	senses.switch_ratio = 0.55
	senses.commitment_grace = 4.0
	# On. This game's world IS a physics space — its players collide against one — so
	# a line-of-sight test is a real question here, unlike in game-fatal-contact where it
	# would answer "clear" for every pair. It is also what stops a hunter committing
	# to somebody two stages away through a wall.
	senses.line_of_sight_enabled = true

	spawner = GSNpcSpawner.new()
	spawner.name = "Npcs"
	spawner.catalogue = catalogue()
	spawner.limits = limits()
	spawner.authoritative = game.authoritative
	spawner.world_ref = GSNodeRef.of_path(NodePath("../Hunters"))
	# Before add_child: `GSNpcSpawner._ready` makes its own senses when it finds
	# none, so assigning afterwards leaves this one built, configured and read by
	# nobody — with the spawner running on defaults that look identical until a hunter
	# refuses to give up on somebody behind a wall.
	spawner.senses = senses
	# Before the first spawn, so no hunter thinks a tick at the wrong skill.
	if game != null and game.npc_skill != null:
		game.npc_skill.attach(spawner)
	squads.attach(spawner)
	sounds.attach(spawner)
	add_child(spawner)

	spawner.died.connect(_on_died)

	director = GSNpcDirector.new()
	director.name = "Director"
	director.spawner = spawner
	director.rules = _rules()
	director.population = [STALKER, SPRINTER]
	director.enabled = enabled
	add_child(director)

	director.wave_spawned.connect(
		func(at: Vector3, count: int) -> void: wave_spawned.emit(at, count)
	)

	game.map_ready.connect(_on_map_ready)

	if game.maps != null and game.maps.current != null:
		_on_map_ready(game.maps.current)

	GSRegistry.register(SERVICE, self)
	_registered = true

	return GSResult.success(self)


## Builds the route and the spawn points from the map's own zones.
##
## [b]Start, then every stage in order, then the end.[/b] That is the route a player
## takes and there is no second description of it: `bhop_g2g_stages` derives its
## geometry and its zones from one walk of the course, so a flow built from the zones
## is a flow built from the geometry.
func rebuild_route() -> int:
	if game == null or game.timers == null or game.timers.zones == null:
		return 0

	var zones := game.timers.zones
	var points := PackedVector3Array()

	var start := zones.first_of_kind(GSTimerZone.Kind.START, GSTimerTrack.MAIN)

	if start != null:
		points.append(start.centre())

	for number in range(1, zones.stage_count(GSTimerTrack.MAIN) + 1):
		var stage := zones.stage_zone(GSTimerTrack.MAIN, number)

		if stage != null:
			points.append(stage.centre())

	var end := zones.first_of_kind(GSTimerZone.Kind.END, GSTimerTrack.MAIN)

	if end != null:
		points.append(end.centre())

	if points.size() < 2:
		GSLog.info(CHANNEL, "this map has no route to hunt along", {
			"points": points.size()
		})
		return 0

	flow = GSNpcDirectorFlow.new()
	flow.set_route(points)

	director.flow = flow
	director.spawn_points = points

	GSLog.info(CHANNEL, "the hunt route was built from the map's zones", {
		"points": points.size(), "length": "%.0f m" % flow.length()
	})

	return points.size()


## A point along the course, for a hunter with nothing to chase.
##
## Called by the brain through [GSRegistry], never by name — a brain loaded from a
## path cannot be handed a reference.
func patrol_point(fraction: float) -> Vector3:
	if flow == null or not flow.has_route():
		return Vector3.ZERO

	return flow.position_at(clampf(fraction, 0.0, 1.0))


static func catalogue() -> GSNpcCatalogue:
	var out := GSNpcCatalogue.new()
	out.meta = {"game": "airdrift"}  # legacy id: saved-data/wire name kept so existing data and published packs keep working

	for def in [_stalker(), _sprinter()]:
		var added := out.add(def)

		if not added.ok:
			GSLog.warn(CHANNEL, "a hunter could not be catalogued", {
				"npc": String(def.id), "why": added.error.message
			})

	return out


static func _stalker() -> GSNpcDef:
	var def := GSNpcDef.make(STALKER, AirdriftPaths.rebase("res://npcs/airdrift_stalker.tscn"))
	def.display_name = "Stalker"
	def.category = &"hunter"
	def.faction = FACTION
	def.brain_script_path = BRAIN_PATH
	def.weight = GSNpcDef.Weight.NORMAL
	def.cost = 1
	def.max_health = 120.0
	def.move_speed = 5.0
	def.sight_range = 40.0
	def.sight_half_angle_deg = 75.0
	def.hearing_range = 20.0
	def.require_line_of_sight = true
	def.meta = {"damage": 25.0, "reach": 2.0, "attack_interval": 1.4, "squad": "hunters", "attackers": 2}
	return def


static func _sprinter() -> GSNpcDef:
	var def := GSNpcDef.make(SPRINTER, AirdriftPaths.rebase("res://npcs/airdrift_sprinter.tscn"))
	def.display_name = "Sprinter"
	def.category = &"hunter"
	def.faction = FACTION
	def.brain_script_path = BRAIN_PATH
	def.weight = GSNpcDef.Weight.LIGHT
	def.cost = 2
	def.max_health = 60.0
	# Fast for a hunter and slow for a runner. The fastest thing here does 8 m/s; a
	# bhop player on a good line does forty. A sprinter catches somebody who fell.
	def.move_speed = 8.0
	def.sight_range = 60.0
	def.sight_half_angle_deg = 100.0
	def.hearing_range = 30.0
	def.require_line_of_sight = false
	def.meta = {"damage": 12.0, "reach": 1.8, "attack_interval": 0.7, "squad": "hunters", "attackers": 2}
	return def


static func limits() -> GSNpcLimits:
	var out := GSNpcLimits.new()

	# Few. A course is narrow and a wall of hunters is a wall, which is a different
	# game and a worse one — the interesting number is "enough that stopping is
	# expensive", not "enough that moving is impossible".
	out.world_budget = 16
	out.per_kind_cap = 10
	out.spawn_interval = 0.4
	out.burst_cap = 3

	# Generous, because a course is long: a hunter a hundred metres behind the field
	# is one that has been left behind rather than one that wandered off.
	out.reclaim_distance = 140.0
	out.reclaim_grace = 10.0
	out.clean_up_on_leave = true

	out.sense_period_ticks = 4
	out.sense_candidate_cap = 24

	# Off. There is no navigation graph here — the route is a flow, not a mesh — so a
	# navigable-spawn requirement would refuse every spawn on the map.
	out.require_navigable_spawn = false
	out.spawn_snap_radius = 0.0

	return out


func _rules() -> GSNpcDirectorRules:
	var rules := GSNpcDirectorRules.new()

	rules.peak_per_player = 4.0
	rules.build_up_per_player = 2.0
	rules.relax_per_player = 0.5
	rules.absolute_cap = 14

	rules.peak_stress = 0.7
	rules.sustain_seconds = 6.0
	rules.fade_seconds = 8.0
	rules.relax_seconds = 25.0

	# [b]The distances are a course's, not a room's.[/b] `spawn_ahead` is what puts a
	# hunter where a runner is going rather than where they were, and on a linear map
	# that is the whole of the placement — a hunter spawned behind the field is a
	# hunter nobody ever meets.
	rules.spawn_min_distance = 25.0
	rules.spawn_max_distance = 120.0
	rules.spawn_ahead = 60.0
	rules.behind_fraction = 0.15
	rules.spawn_out_of_sight = true

	rules.spawn_burst = 2
	rules.spawn_interval = 1.0
	rules.reclaim_interval = 3.0

	rules.stress_per_damage = 1.4
	rules.stress_threat_radius = 10.0

	return rules


# --- The tick --------------------------------------------------------------

func tick(delta: float) -> void:
	if spawner == null or game == null:
		return

	_rebuild_candidates()
	spawner.set_candidates(_candidates)
	spawner.tick(delta)
	squads.prune()

	if director == null:
		return

	director.enabled = enabled

	for id in game.players.keys():
		if id == AirdriftGame.GHOST_ID:
			continue

		var player: AirdriftPlayer = game.players[id]

		if player == null or player.controller == null:
			continue

		# Health as a fraction, which is what gs-npc-ai-director's stress model
		# wants — a game that had to report damage would have to remember to from
		# every damage path it has, and the one it forgets is the one that matters.
		director.report_player(id, player.controller.state.position, _health_of(id))

	director.tick(delta)


## How hurt a player is, or whole when nothing is tracking that.
##
## A timer server without deathmatch has no health at all, and a director handed 0.0
## for everybody would read the whole server as about to die — which is the top of its
## build-up curve, for ever.
func _health_of(player_id: StringName) -> float:
	if game.combat == null:
		return 1.0

	var health: GSHealth = game.combat.health_of(player_id)

	if health == null:
		return 1.0

	return clampf(health.health / maxf(health.max_health, 1.0), 0.0, 1.0)


## A player fired. Every hunter in earshot hears it and knows who: a hunter that was
## patrolling comes to look. Called by [AirdriftCombat] for every tick a weapon produced a shot.
func note_fire(player_id: Variant, origin: Vector3) -> void:
	if spawner == null:
		return

	sounds.emit(
		GSNpcAiSounds.Kind.COMBAT, origin, GUNFIRE_RADIUS, spawner.now(), 0.5,
		StringName(str(player_id))
	)


func _rebuild_candidates() -> void:
	_candidates.clear()

	for id in game.players.keys():
		if id == AirdriftGame.GHOST_ID:
			continue

		var player: AirdriftPlayer = game.players[id]

		if player == null or player.controller == null:
			continue

		var state := player.controller.state

		# Loudness as a radius, which is the number this game already has — and on a
		# movement server it is the most legible one there is: a player at 3000 u/s is
		# heard across the map and one standing on the start pad is not heard at all.
		var speed := AirdriftUnits.to_units(state.horizontal_speed())
		var loudness := clampf(speed / 250.0, 0.0, 6.0) * 12.0

		_candidates.append(GSNpcSenses.Candidate.new(
			id, state.position + Vector3(0.0, 0.9, 0.0), &"player", loudness
		))


# --- Combat ----------------------------------------------------------------

## A hunter hitting a runner. Called by the brain through [GSRegistry].
##
## [b]Through gs-combat when there is one, and nowhere otherwise.[/b] A timer server
## with deathmatch off has no health on anybody, and a hunter that could hurt a player
## the server is not tracking would be doing damage nothing could heal, display or
## respawn away.
func hunter_attack(npc: GSNpcInstance, victim: StringName, amount: float) -> void:
	if game == null or game.combat == null or npc == null or not npc.is_alive():
		return

	var health: GSHealth = game.combat.health_of(victim)

	if health == null or not health.alive:
		return

	var type: GSDamageType = game.combat.manager.damage_type(AirdriftArsenal.DAMAGE_WORLD)

	if type == null:
		return

	# Attacker 0, which gs-combat reads as the world. A hunter is not on the
	# scoreboard and crediting one would put a row there keyed on an id no player has
	# — the bug game-fatal-contact shipped from the other end.
	# Asked of the table rather than computed from the name. The two were the same
	# number until entity ids stopped being derived from player ids; a swipe that
	# computed one would now be damaging an entity that does not exist, silently,
	# because gs-combat has nothing registered under it and simply does nothing.
	var damage := GSDamage.make(0, game.combat.entity_for(victim), amount, type)
	damage.weapon_id = npc.def.id if npc.def != null else &"hunter"
	# [b]The tick, or the swipe is refused for ever after a respawn.[/b] GSHealth compares it
	# with the spawn protection's last tick, and a damage left on tick 0 is inside every
	# window: a runner who had died once (or been placed at a round start) could not be hurt
	# by a hunter again. The effects layer and the admin's slay always stamped it.
	damage.tick = game.current_tick()
	# Away from the hunter, so a runner it kills falls the way the swipe pushed them
	# ([method AirdriftCombat.decide_death]); world damage has no attacker to measure from.
	var target: AirdriftPlayer = game.players.get(victim)
	if target != null and target.controller != null:
		damage.direction = target.controller.state.position - npc.position()
	game.combat.manager.apply_damage(damage)

	# And the part that makes being chased cost something other than health.
	#
	# [b]Refused on a ranked run unless the server has said otherwise[/b], and tainting
	# it when it is allowed — see [AirdriftEffects]. A hunter that could quietly halve a
	# runner's speed would be handing them a style they did not choose, and a time set
	# under one is not comparable with anything.
	if game.effects != null:
		var slowed := game.effects.apply(AirdriftEffects.MAULED, victim, &"")

		if not slowed.ok:
			GSLog.debug(CHANNEL, "the swipe did not slow", {
				"player": String(victim), "why": slowed.error.message
			})


func _on_died(npc: GSNpcInstance, by: StringName) -> void:
	var killer := StringName("")

	if game != null and game.combat != null:
		killer = game.combat.player_id_for(String(by).to_int())

	hunter_killed.emit(npc, killer)

	if killer != &"" and game != null and game.progress != null:
		game.progress.record(killer, AirdriftStats.HUNTERS_KILLED)


func _on_map_ready(_map: GSMapDef) -> void:
	# Every hunter belonged to the map that was just replaced. Their nodes are
	# children of this node rather than of the world, so nothing freed them — and a
	# hunter standing where a wall now is, patrolling a route that no longer exists,
	# is worse than no hunters at all.
	if spawner != null:
		spawner.clear_all(GSNpcSpawner.REASON_CLEANUP)

	var points := rebuild_route()

	if points <= 0 and enabled:
		GSLog.info(CHANNEL, "the hunt is off on this map", {
			"why": "it has no route to hunt along"
		})


# --- Admin -----------------------------------------------------------------

func spawn_one(npc_id: StringName, at: Vector3) -> GSNpcInstance:
	return spawner.spawn(npc_id, at) if spawner != null else null


## Hunters stop seeing through a cloud of [param radius] for [param seconds] (hearing passes); gs-npc API 6.
## No Airdrift item makes smoke yet: this is the hook a smoke source calls.
func block_sight(at: Vector3, radius: float, seconds: float) -> int:
	if senses == null or GSAddonApi.build_level("gs_npc") < 6:
		return 0

	return senses.add_sight_blocker(at + Vector3.UP, radius, seconds)


## Blinds every hunter within [param radius] of a flash at [param at] that has line of sight to it; returns how many.
func flash(at: Vector3, radius: float, seconds: float) -> int:
	if spawner == null or senses == null or GSAddonApi.build_level("gs_npc") < 6:
		return 0

	var space := _world.get_world_3d().direct_space_state if _world != null and _world.is_inside_tree() else null
	var blinded := 0

	for npc in spawner.all_npcs():
		var eye := npc.position() + Vector3.UP * (npc.def.eye_height if npc.def != null else 1.5)

		if not npc.is_alive() or eye.distance_to(at) > radius:
			continue

		if space != null:
			var q := PhysicsRayQueryParameters3D.create(at, eye, senses.occlusion_mask)

			if not space.intersect_ray(q).is_empty():
				continue

		npc.blind_for(senses.now, seconds)
		blinded += 1

	return blinded


func clear() -> int:
	return spawner.clear_all(GSNpcSpawner.REASON_ADMIN) if spawner != null else 0


func count() -> int:
	return spawner.world_count() if spawner != null else 0


func describe() -> Dictionary:
	return {
		"enabled": enabled,
		"hunters": count(),
		"route": flow.describe() if flow != null else {},
		"director": director.describe() if director != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("hunters      %s  %d on the map" % [
		"on" if enabled else "off", count()
	])

	if director != null:
		out.append_array(director.describe_lines())

	return out
