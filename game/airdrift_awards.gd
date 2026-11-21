extends RefCounted

const AirdriftStats := preload("airdrift_stats.gd")

## What a player earns on a timer server, as a document rather than as code.
##
## Every rule reads an id from [AirdriftStats] and nothing else. dot-achievements never
## hears about a run, a ramp or a strafe — it hears that a number moved.
##
## [b]One stat may be read with only one merge rule across the catalogue[/b], and
## dot-achievements refuses one that breaks it at validate rather than at the first
## reading: one number cannot be both a running total and a personal best. So
## [constant AirdriftStats.BEST_TIME] is always LOWEST, [constant AirdriftStats.TOP_SPEED] is
## always HIGHEST, and everything else is SUM. The helpers are the only reason that
## cannot be got wrong one entry at a time.
##
## [b]The one worth reading twice is `sub_thirty`.[/b] "Finish a map in under thirty
## seconds" is a LOWEST stat with an AT_MOST rule — and dot-achievements' own note says
## what that means for a player who has never been recorded: a missing stat reads as
## zero, and "at most 30" is satisfied by zero. It is guarded by a second rule
## requiring a finished run, because the alternative is every new player unlocking it
## for having done nothing.

# No `CHANNEL`: this is a declaration read at setup, with no runtime of its own to
# report -- `AirdriftProgress` logs what happens to the numbers and the awards.

const CAT_TIMER := &"timer"
const CAT_MOVEMENT := &"movement"
const CAT_SERVER := &"server"
const CAT_COMBAT := &"combat"


static func catalogue() -> GSAchievementCatalogue:
	var out: Array[GSAchievement] = []
	_add_timer(out)
	_add_movement(out)
	_add_server_and_combat(out)
	return GSAchievementCatalogue.of(out)


static func _add_timer(out: Array[GSAchievement]) -> void:
	out.append(_sum(
		&"g2g.first_finish", "Made It", AirdriftStats.RUNS_FINISHED, 1,
		"Finish a course.", CAT_TIMER, 5, &"g2g.finisher", 1
	))
	out.append(_sum(
		&"g2g.hundred_finishes", "Regular", AirdriftStats.RUNS_FINISHED, 100,
		"A hundred finished runs.", CAT_TIMER, 25, &"g2g.finisher", 2
	))
	out.append(_sum(
		&"g2g.thousand_finishes", "Fixture", AirdriftStats.RUNS_FINISHED, 1000,
		"A thousand finished runs.", CAT_TIMER, 100, &"g2g.finisher", 3
	))

	# --- Records ----------------------------------------------------------
	out.append(_sum(
		&"g2g.first_pb", "Personal Best", AirdriftStats.RECORDS_SET, 1,
		"Beat your own time.", CAT_TIMER, 10
	))
	out.append(_sum(
		&"g2g.first_wr", "Top of the Board", AirdriftStats.WORLD_RECORDS, 1,
		"Take a server record.", CAT_TIMER, 40, &"g2g.record_holder", 1
	))
	out.append(_sum(
		&"g2g.ten_wr", "Record Holder", AirdriftStats.WORLD_RECORDS, 10,
		"Hold ten server records.", CAT_TIMER, 90, &"g2g.record_holder", 2
	))

	# A LOWEST stat with AT_MOST is met by a never-recorded player (missing reads as
	# zero); the second rule makes it mean what it says. See the class note.
	var quick: Array[GSAchievementRule] = [
		GSAchievementRule.make(
			AirdriftStats.BEST_TIME, 30.0,
			GSAchievementRule.Op.AT_MOST, GSAchievementRule.Merge.LOWEST
		),
		GSAchievementRule.make(AirdriftStats.RUNS_FINISHED, 1.0),
	]
	var sub_thirty := GSAchievement.make(&"g2g.sub_thirty", "Under Thirty", quick)
	sub_thirty.description = "Finish a course in under thirty seconds."
	sub_thirty.category = CAT_TIMER
	sub_thirty.points = 30
	out.append(sub_thirty)


static func _add_movement(out: Array[GSAchievement]) -> void:
	out.append(_sum(
		&"g2g.ten_thousand_jumps", "Springs", AirdriftStats.JUMPS, 10000,
		"Ten thousand jumps.", CAT_MOVEMENT, 25
	))

	# Perfect jumps (landed and left on one tick) are a different claim from many jumps.
	out.append(_sum(
		&"g2g.perfect_thousand", "Frame Perfect", AirdriftStats.PERFECT_JUMPS, 5000,
		"Five thousand perfect jumps.", CAT_MOVEMENT, 60
	))

	out.append(_best(
		&"g2g.fast_mover", "Terminal", AirdriftStats.TOP_SPEED, 2000,
		"Reach 2000 u/s.", CAT_MOVEMENT, 40, &"g2g.speed", 1
	))
	out.append(_best(
		&"g2g.very_fast_mover", "Escape Velocity", AirdriftStats.TOP_SPEED, 3500,
		"Reach 3500 u/s.", CAT_MOVEMENT, 90, &"g2g.speed", 2
	))

	out.append(_sum(
		&"g2g.marathon", "Marathon", AirdriftStats.DISTANCE, 42195,
		"Travel a marathon.", CAT_MOVEMENT, 50
	))


static func _add_server_and_combat(out: Array[GSAchievement]) -> void:
	out.append(_sum(
		&"g2g.tourist", "Tourist", AirdriftStats.MAPS_PLAYED, 25,
		"Play twenty-five maps.", CAT_SERVER, 20
	))
	out.append(_sum(
		&"g2g.resident", "Resident", AirdriftStats.PLAYTIME_SEC, 86400,
		"Twenty-four hours on the server.", CAT_SERVER, 60
	))

	out.append(_sum(
		&"g2g.duellist", "Duellist", AirdriftStats.KILLS, 100,
		"A hundred kills in deathmatch.", CAT_COMBAT, 25
	))
	out.append(_sum(
		&"g2g.hunted", "Hunted", AirdriftStats.HUNTERS_KILLED, 50,
		"Put down fifty hunters.", CAT_COMBAT, 30
	))


static func _sum(
	id: StringName, display: String, stat: StringName, threshold: float,
	description: String, category: StringName, points: int,
	series: StringName = &"", tier: int = 0
) -> GSAchievement:
	return _entry(
		id, display, stat, threshold, GSAchievementRule.Merge.SUM,
		description, category, points, series, tier
	)


static func _best(
	id: StringName, display: String, stat: StringName, threshold: float,
	description: String, category: StringName, points: int,
	series: StringName = &"", tier: int = 0
) -> GSAchievement:
	return _entry(
		id, display, stat, threshold, GSAchievementRule.Merge.HIGHEST,
		description, category, points, series, tier
	)


static func _entry(
	id: StringName, display: String, stat: StringName, threshold: float,
	merge: GSAchievementRule.Merge, description: String, category: StringName,
	points: int, series: StringName, tier: int
) -> GSAchievement:
	var rules: Array[GSAchievementRule] = [
		GSAchievementRule.make(stat, threshold, GSAchievementRule.Op.AT_LEAST, merge)
	]
	var out := GSAchievement.make(id, display, rules)
	out.description = description
	out.category = category
	out.points = points
	out.series = series
	out.tier = tier
	return out
