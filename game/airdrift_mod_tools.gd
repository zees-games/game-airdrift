extends RefCounted

const AirdriftGame := preload("airdrift_game.gd")
const AirdriftPlayer := preload("airdrift_player.gd")

## What dot-moderation's live tools mean on a timer server.
##
## [b]A time is the product here, so the first rule is that no admin tool can help one.[/b]
## Noclip abandons the run in progress the moment it is turned on, and `AirdriftPlayer` taints
## any run made while a noclip, a speed step or a gravity step is on them — so it finishes,
## is shown, and is never filed. A teleport already ends a run (`AirdriftPlayer.teleport`); a
## respawn is a teleport to the start. Freeze does neither: it can only cost a runner time.
##
## Health exists only while the deathmatch is on (`sv_deathmatch`, `AirdriftCombat`), so god,
## buddha, hp, slay, give and strip answer "not on this server" when it is off rather than
## being absent — whether they mean anything is a cvar, not a build.
##
## Blind and beacon are the two that are about a SCREEN rather than a body, and each is one
## flag on [AirdriftPlayer] that `AirdriftPlayerNet` replicates — the blind to its owner alone, the
## beacon to everybody — and that the client draws: `AirdriftHud` blacks the owner's screen out,
## `GSFxBeacon` rings the runner on every screen and pings. Neither taints a run: a blind
## can only cost a runner time, like a freeze, and a beacon changes nothing they can feel.
## Both outlive a respawn without anything re-applying them, because a respawn here is a
## teleport of the same player rather than a new body.

## Ids are the session userid as a string; this game's player key is `u<userid>`.
static func key_of(id: StringName) -> StringName:
	return StringName("u%s" % String(id))


static func handlers(game: AirdriftGame) -> Dictionary:
	return {
		GSModTools.ACTION_NOCLIP: func(id: StringName, args: Dictionary) -> GSResult:
			var p := _player(game, id)
			if p == null:
				return _absent(id)
			var on := bool(args["on"])
			if on and p.timer != null:
				p.timer.stop(&"noclip")
			return GSFpsAdminModifiers.set_noclip(p.controller, on),

		GSModTools.ACTION_FREEZE: func(id: StringName, args: Dictionary) -> GSResult:
			var p := _player(game, id)
			return _absent(id) if p == null else GSFpsAdminModifiers.set_frozen(p.controller, bool(args["on"])),

		GSModTools.ACTION_SPEED: func(id: StringName, args: Dictionary) -> GSResult:
			var p := _player(game, id)
			return _absent(id) if p == null else GSFpsAdminModifiers.set_speed(p.controller, float(args["scale"])),

		GSModTools.ACTION_GRAVITY: func(id: StringName, args: Dictionary) -> GSResult:
			var p := _player(game, id)
			return _absent(id) if p == null else GSFpsAdminModifiers.set_gravity(p.controller, float(args["scale"])),

		GSModTools.ACTION_RESPAWN: func(id: StringName, _args: Dictionary) -> GSResult:
			if _player(game, id) == null:
				return _absent(id)
			game.spawn_player(key_of(id))
			return GSResult.success(null),

		GSModTools.ACTION_RENAME: func(id: StringName, args: Dictionary) -> GSResult:
			var p := _player(game, id)
			if p == null:
				return _absent(id)
			p.display_name = str(args["name"]).strip_edges().substr(0, 32)
			return GSResult.success(p.display_name),

		GSModTools.ACTION_GOD: func(id: StringName, args: Dictionary) -> GSResult:
			var health := _health(game, id)
			if health == null:
				return _no_health()
			health.invulnerable = bool(args["on"])
			return GSResult.success(health.invulnerable),

		GSModTools.ACTION_BUDDHA: func(id: StringName, args: Dictionary) -> GSResult:
			var health := _health(game, id)
			if health == null:
				return _no_health()
			health.cannot_die = bool(args["on"])
			return GSResult.success(health.cannot_die),

		GSModTools.ACTION_HEALTH: func(id: StringName, args: Dictionary) -> GSResult:
			var health := _health(game, id)
			if health == null:
				return _no_health()
			if not health.alive:
				return GSResult.fail(GSError.CODE_STATE, "They are dead.")
			health.health = minf(float(args["value"]), 2000.0)
			return GSResult.success(health.health),

		GSModTools.ACTION_SLAY: func(id: StringName, _args: Dictionary) -> GSResult:
			return _hurt(game, id, -1.0),

		GSModTools.ACTION_SLAP: func(id: StringName, args: Dictionary) -> GSResult:
			return _hurt(game, id, float(args.get("damage", 0.0))),

		GSModTools.ACTION_GIVE: func(id: StringName, args: Dictionary) -> GSResult:
			var arsenal: GSWeaponArsenal = game.combat.arsenal_of(key_of(id)) if game.combat != null else null
			if arsenal == null:
				return _no_health()
			# A weapon an admin handed over can shove its holder (a rocket, a knockback
			# gun): assisted, like a slap.
			var runner := _player(game, id)
			if runner != null and runner.timer != null:
				runner.timer.taint()
			return arsenal.give(StringName(str(args["item"]).strip_edges().to_lower())),

		GSModTools.ACTION_STRIP: func(id: StringName, _args: Dictionary) -> GSResult:
			var arsenal: GSWeaponArsenal = game.combat.arsenal_of(key_of(id)) if game.combat != null else null
			if arsenal == null:
				return _no_health()
			arsenal.clear()
			return GSResult.success(null),

		GSModTools.ACTION_BLIND: func(id: StringName, args: Dictionary) -> GSResult:
			var p := _player(game, id)
			if p == null:
				return _absent(id)
			# The screen and nothing else. A blinded runner still moves and their timer
			# still counts; an admin who wants them to stop as well has freeze, and one
			# verb that did both would be a verb nobody could use for only the first.
			p.blinded = bool(args["on"])
			return GSResult.success(p.blinded),

		GSModTools.ACTION_BEACON: func(id: StringName, args: Dictionary) -> GSResult:
			var p := _player(game, id)
			if p == null:
				return _absent(id)
			p.beacon = bool(args["on"])
			return GSResult.success(p.beacon),
	}


static func unsupported() -> Dictionary:
	return {
		GSModTools.ACTION_BURN: "there is no fire on a course",
	}


static func position_of(game: AirdriftGame, id: StringName) -> Variant:
	var p := _player(game, id)
	return p.controller.state.position if p != null else null


## Through `AirdriftPlayer.teleport`, which ends the run: an admin moving somebody is a player
## leaving the route.
static func teleport(game: AirdriftGame, id: StringName, to: Variant) -> void:
	var p := _player(game, id)
	if p != null and to is Vector3:
		p.teleport(to as Vector3, p.controller.state.yaw)


static func _player(game: AirdriftGame, id: StringName) -> AirdriftPlayer:
	return game.players.get(key_of(id)) if game != null else null


static func _health(game: AirdriftGame, id: StringName) -> GSHealth:
	return game.combat.health_of(key_of(id)) if game != null and game.combat != null else null


static func _hurt(game: AirdriftGame, id: StringName, amount: float) -> GSResult:
	var p := _player(game, id)

	if p == null:
		return _absent(id)

	# A slap is a shove first; it works with or without the deathmatch, because a shove
	# is movement and every server has that.
	if amount >= 0.0:
		p.controller.state.velocity += Vector3(3.0, 5.0, 3.0)
		p.controller.state.mode = GSFpsState.Mode.AIR
		# A shove is speed nobody earned, in a direction the slapper knows: an admin's
		# help, which a record must not carry. `slap @me` was the cheapest boost there is.
		if p.timer != null:
			p.timer.taint()

	if amount == 0.0:
		return GSResult.success(null)

	var health := _health(game, id)

	if health == null:
		return _no_health()

	if not health.alive:
		return GSResult.fail(GSError.CODE_STATE, "They are already dead.")

	var was_god := health.invulnerable
	var was_buddha := health.cannot_die

	if amount < 0.0:
		health.invulnerable = false
		health.cannot_die = false
		health.invulnerable_until_tick = -1

	var damage := GSDamage.make(
		0, game.combat.entity_for(key_of(id)),
		health.health + 1000.0 if amount < 0.0 else amount, null
	)
	damage.weapon_id = &"slay" if amount < 0.0 else &"slap"
	damage.tick = game.current_tick()
	game.combat.manager.apply_damage(damage)

	health.invulnerable = was_god
	health.cannot_die = was_buddha

	if amount < 0.0 and not damage.lethal:
		return GSResult.fail(GSError.CODE_STATE, "The slay was refused: %s" % damage.refusal)

	return GSResult.success(null)


static func _absent(id: StringName) -> GSResult:
	return GSResult.fail(GSError.CODE_STATE, "Player %s is not on the map." % String(id))


static func _no_health() -> GSResult:
	return GSResult.fail(
		GSError.CODE_UNSUPPORTED,
		"This server is not running its deathmatch, so nobody has health or weapons.",
		"sv_deathmatch 1"
	)
