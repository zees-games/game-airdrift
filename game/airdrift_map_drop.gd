extends RefCounted

## Maps handed to Airdrift outside the window: dropped on the executable, named by `--map-path=<path>`, and every window drop,
## through gs-map's GSMapDropIntake (API 30). The client answers each on the HUD ([method AirdriftGame.add_dropped_maps]);
## a path with no converted map is refused out loud. Solo only.
const CHANNEL := "g2g.map_drop"
## gs-map's API level with GSMapDropIntake. Older builds take no exe drop, nor config options out of the paths.
const NEEDS_LEVEL := 30
const INTAKE_SCRIPT := "res://addons/gs_map/core/gs_map_drop_intake.gd"
## Options gs-core reads whose next argument is their value (never read as a dropped path).
const VALUE_FLAGS := ["--config"]
## Airdrift's config prefixes ([method AirdriftConfig.cli_prefix] and the old one it still reads):
## `--airdrift-<key> <value>`.
const CONFIG_PREFIXES: PackedStringArray = ["--airdrift-", "--g2g-"]

const AirdriftConfig := preload("airdrift_config.gd")


## A GSMapDropIntake taking converted map folders and zips, not watching the window (the client's handler does, so a
## window drop and an executable drop say the same line). Null, with a warning, on gs-map older than API 30.
static func make() -> Node:
	if GSAddonApi.build_level("gs_map") < NEEDS_LEVEL or not ResourceLoader.exists(INTAKE_SCRIPT):
		GSLog.warn(CHANNEL, "maps dropped on the executable are off: this build's gs-map is older than API %d" % NEEDS_LEVEL)
		return null
	var intake: Node = load(INTAKE_SCRIPT).new()
	intake.name = "MapDrop"
	intake.set(&"watch_window", false)
	var flags: PackedStringArray = intake.get(&"value_flags")
	flags.append_array(PackedStringArray(VALUE_FLAGS))
	intake.set(&"value_flags", flags)
	var config := AirdriftConfig.new()
	intake.set(&"config_prefixes", CONFIG_PREFIXES)
	intake.set(&"option_takes_value", func(_prefix: String, stem: String) -> bool: return bool(intake.call(&"config_takes_value", config, stem)))
	intake.call(&"add_converted_maps")
	return intake


## The process's arguments, the engine's and the user's.
static func cmdline() -> PackedStringArray:
	var all := OS.get_cmdline_args()
	all.append_array(OS.get_cmdline_user_args())
	return all
