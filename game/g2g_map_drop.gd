extends RefCounted

## Maps handed to Airdrift outside the window: dropped on the executable (a path on the command line) or named by
## `--map-path=<path>`, and every window drop too, through dot-map's DotMapDropIntake (API 26) with its converted-map
## acceptor. The client answers each drop on the HUD ([method G2GGame.add_dropped_maps]); a path that holds no converted
## map is refused out loud with what the game takes. Solo only, as the window drop always was.

const CHANNEL := "g2g.map_drop"
## dot-map's API level with DotMapDropIntake. Older builds keep the window drop (dot-map API 24) and take no exe drop.
const NEEDS_LEVEL := 26
const INTAKE_SCRIPT := "res://addons/dot_map/core/dot_map_drop_intake.gd"
## Options dot-core reads whose next argument is their value (never read as a dropped path).
const VALUE_FLAGS := ["--config"]
## Airdrift's config prefix ([method G2GConfig.cli_prefix]): `--g2g-<key> <value>`.
const CONFIG_PREFIX := "--g2g-"

const G2GConfig := preload("g2g_config.gd")


## A DotMapDropIntake taking converted map folders and zips, not watching the window (the client's handler does, so a
## window drop and an executable drop say the same line). Null, with a warning, on dot-map older than API 26.
static func make() -> Node:
	if DotAddonApi.build_level("dot_map") < NEEDS_LEVEL or not ResourceLoader.exists(INTAKE_SCRIPT):
		DotLog.warn(CHANNEL, "maps dropped on the executable are off: this build's dot-map is older than API %d" % NEEDS_LEVEL)
		return null
	var intake: Node = load(INTAKE_SCRIPT).new()
	intake.name = "MapDrop"
	intake.set(&"watch_window", false)
	var flags: PackedStringArray = intake.get(&"value_flags")
	flags.append_array(PackedStringArray(VALUE_FLAGS))
	intake.set(&"value_flags", flags)
	intake.call(&"add_converted_maps")
	return intake


## The process's arguments, the engine's and the user's.
static func cmdline() -> PackedStringArray:
	var all := OS.get_cmdline_args()
	all.append_array(OS.get_cmdline_user_args())
	return all


## The dropped paths in [param args] (DotMapDropIntake.paths_in_args, with Airdrift's config options taken out first):
## every path that exists, every `--map-path` value, and every absolute path that does not exist (said as not found).
static func paths_in(intake: Node, args: PackedStringArray) -> PackedStringArray:
	var found: Dictionary = intake.call(&"paths_in_args", drop_args(args), intake.get(&"value_flags"), intake.get(&"path_flag"))
	var paths: PackedStringArray = found["paths"]
	paths.append_array(found["missing"] as PackedStringArray)
	return paths


## [param args] without the config options and their values: `--g2g-<key> <value>` and `--<addon>.<key> <value>`; a
## value that happens to be a folder is not a dropped map. A bare `--g2g-<bool key>` is a switch, as in
## [method DotConfig.apply_cli]: the argument after it is not its value, nor after an unknown key.
static func drop_args(args: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	var config := G2GConfig.new()
	var i := 0
	while i < args.size():
		var a := args[i]
		i += 1
		if a.begins_with(CONFIG_PREFIX) or (a.begins_with("--") and a.get_slice("=", 0).contains(".")):
			var takes_value := not a.contains("=") and i < args.size() and not args[i].begins_with("--")
			if takes_value and a.begins_with(CONFIG_PREFIX):
				var key := config.call(&"_match_key", a.trim_prefix(CONFIG_PREFIX), config.config_keys()) as String
				takes_value = key != "" and typeof(config.get(key)) != TYPE_BOOL
			if takes_value:
				i += 1
			continue
		out.append(a)
	return out
