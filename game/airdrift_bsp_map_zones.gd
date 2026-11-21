extends "airdrift_map.gd"

## The zone half of AirdriftBspMap: the payload keys and kind names a manifest writes, and the timer zones read from it. No class_name; scripts keep using AirdriftBspMap.

## The key in a stage zone's [member GSTimerZone.payload] that makes it a split with no restart, holding the reason. A map's zone file sets it (`restart: false` and
## `restart_why`) for a stage line the mapper drew across open air -- surf_greensway's stage 2 is a gate across a canyon, and the only spot under it is a fail plane.
## `AirdriftGame.request_stage` refuses `!s<n>` there and `restart_stage` goes back a stage.
const NO_RESTART := "no_restart"

## Payload key on a RESPAWN zone that carries its own destination: the map's
## `trigger_teleport` sends a player there and the run goes on, the way Source does. A
## pit without it (an old manifest, a teleport aimed at nothing) still means the spawn.
const SENDS_TO := "sends_to"

## Payload key on a TELEPORT zone the map fires as the run ends (manifest `finish`):
## it sends past the end, often back to the start, so it is no door into a stage.
const FINISH_DOOR := "finish_door"

## Zone kinds by the name the manifest writes, which is [enum GSTimerZone.Kind]'s. [b]Names on the wire, not numbers.[/b] A manifest is read by a build that may be
## older or newer than the one that wrote it -- `user://maps` outlives an update -- and a number would silently become a different kind the day anything is inserted
## into that enum. dot-timer keeps the numbering compatible with the community timers' for exactly this reason, and a name costs nothing to be safe as well.
const KINDS := {
	"START": GSTimerZone.Kind.START, "END": GSTimerZone.Kind.END,
	"RESPAWN": GSTimerZone.Kind.RESPAWN, "STOP": GSTimerZone.Kind.STOP,
	"SLAY": GSTimerZone.Kind.SLAY, "FREESTYLE": GSTimerZone.Kind.FREESTYLE,
	"SPEED_LIMIT": GSTimerZone.Kind.SPEED_LIMIT, "TELEPORT": GSTimerZone.Kind.TELEPORT,
	"SPAWN": GSTimerZone.Kind.SPAWN, "EASY_BHOP": GSTimerZone.Kind.EASY_BHOP,
	"SLIDE": GSTimerZone.Kind.SLIDE, "AIR_ACCELERATE": GSTimerZone.Kind.AIR_ACCELERATE,
	"STAGE": GSTimerZone.Kind.STAGE, "GRAVITY": GSTimerZone.Kind.GRAVITY,
	"PUSH": GSTimerZone.Kind.PUSH, "NO_JUMP": GSTimerZone.Kind.NO_JUMP,
	"AUTO_HOP": GSTimerZone.Kind.AUTO_HOP, "CHECKPOINT": GSTimerZone.Kind.CHECKPOINT,
	"CUSTOM": GSTimerZone.Kind.CUSTOM,
}

var manifest: Dictionary = {}


static func _vec(a: Variant) -> Vector3:
	var arr: Array = a as Array
	if arr == null or arr.size() < 3:
		return Vector3.ZERO
	return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))


## Zones: everything the manifest worked out about this map. [b]The importer decides what a zone is; this only reads.[/b] Which volume is the finish line is a judgement about a map somebody played, and it is made once -- in `tools/bsp_import.py` against the entity lump, and in `maps/zones/<id>.json`
## where a map does not label itself. Making it again here would be a second copy of the answer, and this family has counted what two copies of one list cost it. A manifest with no `zones` is one written before there were any: it gets the spawn and the pit, which is what it carried and all it can support. `user://maps` is full
## of those the moment anybody downloads a map, and refusing them would take away maps that work.
func timer_zones() -> GSTimerZoneSet:
	var zones := GSTimerZoneSet.new()
	zones.map_id = StringName(str(manifest.get("id", "imported")))
	zones.meta["tier"] = tier
	zones.meta["source"] = manifest.get("source", "")
	zones.meta["imported"] = true
	zones.meta["track_names"] = manifest.get("track_names", {})

	var listed: Array = manifest.get("zones", [])
	if listed.is_empty():
		return _legacy_zones(zones)

	for entry: Variant in listed:
		var zone := _zone_from(entry as Dictionary)
		if zone != null:
			zones.add(zone)
	return zones


## One zone from its manifest entry, or null if the kind is not one we know. An unknown kind is skipped rather than defaulted. [enum GSTimerZone.Kind] starts
## at START, so a `kind` this build has never heard of would otherwise become a second start line -- and a track with two of those is a track [GSTimerZoneSet] refuses
## whole, over a zone nobody asked for.
func _zone_from(entry: Dictionary) -> GSTimerZone:
	var name := str(entry.get("kind", ""))
	if not KINDS.has(name):
		GSLog.warn("g2g.maps", "an imported map has a zone kind this build does not know",
			{"map": manifest.get("id", "?"), "kind": name})
		return null

	var kind: GSTimerZone.Kind = KINDS[name]
	var track := int(entry.get("track", GSTimerTrack.MAIN))
	var zone: GSTimerZone

	if entry.has("min") and entry.has("max"):
		zone = zone_box(kind, track, _vec(entry["min"]), _vec(entry["max"]))
	else:
		zone = GSTimerZone.make(kind, track)

	zone.number = float(entry.get("number", 0.0))
	if entry.has("destination"):
		zone.destination = AirdriftUnits.vector_to_metres(_vec(entry["destination"]))
		zone.destination_yaw = float(entry.get("destination_yaw", 0.0))
		if kind == GSTimerZone.Kind.RESPAWN:
			zone.payload[SENDS_TO] = true
	if entry.get("finish", false):
		zone.payload[FINISH_DOOR] = true
	zone.comment = str(entry.get("comment", ""))
	# A stage with nowhere to stand is a split only; see `AirdriftGame.request_stage`.
	if entry.get("restart", true) == false:
		zone.payload[NO_RESTART] = str(entry.get("restart_why", ""))
	return zone


## The zones a manifest written before `zones` existed can still supply.
func _legacy_zones(zones: GSTimerZoneSet) -> GSTimerZoneSet:
	var spawn: Dictionary = manifest.get("spawn", {})
	zones.add(zone_spawn(GSTimerTrack.MAIN, _vec(spawn.get("origin", [0, 64, 0])),
		float(spawn.get("yaw", 0.0))))

	for v: Variant in manifest.get("respawn_volumes", []):
		var vol: Dictionary = v
		zones.add(zone_box(GSTimerZone.Kind.RESPAWN, GSTimerTrack.MAIN,
			_vec(vol.get("min")), _vec(vol.get("max"))))
	return zones
