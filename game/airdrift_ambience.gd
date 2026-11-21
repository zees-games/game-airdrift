extends RefCounted

## What Airdrift's ambience is: the cvar defaults the client's director plays (`airdrift_ambient*`).

const PREFIX := "airdrift"
## A timer game: the layer is felt, not heard, so a landing stays the loudest thing.
const LEVEL := 0.15
const RATE := 0.4
const DEFAULT_MOOD := &"outdoor_night"

## By map id prefix (lower case); imported maps arrive by the hundred, so nothing is listed per map.
const PREFIX_MOODS := {
	"surf_": &"snow_wind", "bhop_g2g_stages": &"snow_wind",
	"kz_": &"cave_tunnel", "climb_": &"cave_tunnel", "xc_": &"cave_tunnel",
}


static func make_rules() -> GSAmbienceRules:
	var r := GSAmbienceRules.new()
	r.prefix = PREFIX
	r.volume = LEVEL
	r.frequency = RATE
	return r
