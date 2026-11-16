extends DotGameCheckSuite

## Maps handed to Airdrift through dot-map's DotMapDropIntake (G2GMapDrop, API 26): dragged onto the window, dropped on
## the executable or named by `--map-path=`, all through the one intake and the one HUD line. A path that holds no
## converted map is refused out loud with what the game takes. Folder/zip copying itself: headless_local_maps.
## [codeblock] ./game.sh test headless_mapdrop [/codeblock]

const G2GClient := preload("../game/g2g_client.gd")
const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GMapCatalogue := preload("../game/g2g_map_catalogue.gd")
const G2GMapDrop := preload("../game/g2g_map_drop.gd")

const FIXTURE_DIR := "res://examples/local_maps"
## Built outside the maps roots, then dropped.
const SOURCE := "user://zz_headless_mapdrop_src"
## The local map a game starts on (a game has to start on one).
const START := "zz_mapdrop_start"
const START_FOLDER := "user://maps/zz_mapdrop_start"
## The map dropped.
const MAP := "zz_mapdrop_drop"
const DROPPED := "user://maps/zz_mapdrop_drop"
const SECTIONS := 3

var _game: G2GGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	if DotAddonApi.build_level("dot_map") < G2GMapDrop.NEEDS_LEVEL:
		print("-- skipped: dot-map API %d < %d (no DotMapDropIntake)" % [DotAddonApi.build_level("dot_map"), G2GMapDrop.NEEDS_LEVEL])
		_report_sections(0, 0, 0)
		return
	var entered := 0
	var finished := 0
	_clean()
	entered += 1
	_test_args()
	finished += 1
	entered += 1
	if await _start_game():
		_test_window()
		finished += 1
		entered += 1
		_test_cmdline()
		finished += 1
	if _game != null:
		_game.queue_free()
		await get_tree().process_frame
	_clean()
	G2GMapCatalogue.list_local = false
	_report_sections(entered, finished, SECTIONS)


func _test_args() -> void:
	print("-- the command line: config options are not drops, --map-path and bare paths are")
	var folder := ProjectSettings.globalize_path(SOURCE.path_join("args"))
	DirAccess.make_dir_recursive_absolute(folder)
	var kept := G2GMapDrop.drop_args(PackedStringArray(["--g2g-records_directory", folder, "--dot_net.port", folder,
		"--g2g-auto_bhop", folder, "--g2g-no_such_key", folder, "--g2g-map_seconds=5", "--headless"]))
	_check(kept == PackedStringArray([folder, folder, "--headless"]),
		"a --g2g-<key> and --<addon>.<key> value is no drop; a --g2g-<bool> switch and an unknown key take none", str(kept))
	var intake := G2GMapDrop.make()
	if not _check(intake != null, "dot-map 26 makes the shared intake"):
		return
	_check(not bool(intake.get(&"watch_window")), "it leaves the window to the client (one HUD line for every drop)")
	_check((intake.call(&"accepted_kinds") as PackedStringArray).size() == 1, "it takes converted maps")
	var paths := G2GMapDrop.paths_in(intake, PackedStringArray(["--path", folder, "--config", folder, "--map-path=" + folder]))
	_check(paths == PackedStringArray([folder]), "--map-path= is a drop; --path and --config values are not", str(paths))
	paths = G2GMapDrop.paths_in(intake, PackedStringArray([folder, "--g2g-records_directory", folder]))
	_check(paths == PackedStringArray([folder]), "a bare path is a drop (the executable's drop)", str(paths))
	paths = G2GMapDrop.paths_in(intake, PackedStringArray(["--map-path=/no/such/zz_mapdrop_drop"]))
	_check(paths == PackedStringArray(["/no/such/zz_mapdrop_drop"]), "a --map-path that does not exist is kept, to be refused", str(paths))
	paths = G2GMapDrop.paths_in(intake, PackedStringArray(["--headless", "res://examples/headless_mapdrop.tscn"]))
	_check(paths.is_empty(), "no path on a plain start", str(paths))
	intake.free()


func _start_game() -> bool:
	G2GMapCatalogue.list_local = true
	_pack_as(START_FOLDER, START)
	var config := G2GConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = StringName(START + DotMapLocalMaps.ID_SUFFIX)
	_game = G2GGame.new()
	_game.config = config
	add_child(_game)
	for _i in range(240):
		await get_tree().process_frame
		if _game.maps != null and _game.maps.current != null:
			break
	if not _check(_game.maps != null and _game.maps.current != null, "a solo game is up on a local map"):
		return false
	_game.map_drop = G2GMapDrop.make()
	_game.add_child(_game.map_drop)
	return _check(_game.map_drop != null, "with the intake every drop goes through")


func _test_window() -> void:
	print("-- a window drop goes through the intake: a deep download, a depth limit, junk, a missing path")
	var intake := _game.map_drop
	var id := StringName(MAP + DotMapLocalMaps.ID_SUFFIX)
	var deep := SOURCE.path_join("deep")
	_pack_as(deep.path_join("a/b/c").path_join(MAP).path_join("convert"), MAP)
	var said := _game.add_dropped_maps(_global(deep))
	_check(said.contains("not a map this game can load (it takes "), "a map deeper than search_depth (3) is refused with what the game takes", said)
	_check(not _game.maps.catalogue.has(id), "and not listed")
	intake.set(&"search_depth", 0)
	said = _game.add_dropped_maps(_global(deep))
	_check(said.begins_with("Added ") and said.contains(DotMapLocalMaps.TAG), "search_depth 0 is no limit: found five folders down", said)
	_check(_game.maps.catalogue.has(id), "M lists it without a restart")
	_check(DirAccess.dir_exists_absolute(DROPPED), "copied into user://maps under its own folder")
	var result: Dictionary = intake.get(&"last_result")
	_check(str(result.get("source", "")) == "window" and (result.get("added", []) as Array).size() == 1,
		"the intake's result says where it came from and what it added", str(result))
	intake.set(&"search_depth", 3)
	_wipe(DROPPED)
	var _change := _game.rescan_maps()

	var junk := SOURCE.path_join("notes.txt")
	_write(junk, "not a map")
	var refused := int(intake.get(&"refused_total"))
	var before: int = _game.maps.catalogue.size()
	said = _game.add_dropped_maps(_global(junk))
	_check(said.begins_with("Not a map: notes.txt: not a map this game can load"), "junk is refused out loud", said)
	_check(int(intake.get(&"refused_total")) == refused + 1, "and counted as refused")
	_check(_game.maps.catalogue.size() == before and not FileAccess.file_exists("user://maps/notes.txt"), "and adds nothing")
	said = _game.add_dropped_maps(PackedStringArray(["/no/such/zz_mapdrop_drop"]))
	_check(said.contains("zz_mapdrop_drop: not found"), "a path that does not exist is said", said)


func _test_cmdline() -> void:
	print("-- dropped on the executable / --map-path: added and said like a window drop")
	var client := G2GClient.new()
	client.game = _game
	var id := StringName(MAP + DotMapLocalMaps.ID_SUFFIX)
	var folder := SOURCE.path_join("exe").path_join(MAP)
	_pack_as(folder, MAP)
	var said := client._take_cmdline_drops(PackedStringArray(["--headless", "--map-path=" + ProjectSettings.globalize_path(folder)]))
	_check(said.begins_with("Added ") and said.contains(DotMapLocalMaps.TAG), "a --map-path map is added and said", said)
	_check(_game.maps.catalogue.has(id), "M lists it")
	_check(str((_game.map_drop.get(&"last_result") as Dictionary).get("source", "")) == "command line",
		"the intake knows it came from the command line")
	_wipe(DROPPED)
	var _change := _game.rescan_maps()
	said = client._take_cmdline_drops(PackedStringArray(["--headless", "res://examples/headless_mapdrop.tscn"]))
	_check(said == "", "a start with no path adds nothing", said)
	said = client._take_cmdline_drops(PackedStringArray([ProjectSettings.globalize_path(SOURCE.path_join("notes.txt"))]))
	_check(said.contains("not a map this game can load"), "a file dropped on the executable that is no map is refused", said)
	client.game = null
	client.free()


func _pack_as(dir: String, map_name: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	_write(dir.path_join(map_name + ".json"),
		FileAccess.get_file_as_string(FIXTURE_DIR.path_join("fixture.json")).replace("\"fixture.bin\"", "\"%s.bin\"" % map_name))
	var _copied := DirAccess.copy_absolute(FIXTURE_DIR.path_join("fixture.bin"), dir.path_join(map_name + ".bin"))


func _global(path: String) -> PackedStringArray:
	return PackedStringArray([ProjectSettings.globalize_path(path)])


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _clean() -> void:
	_wipe(SOURCE)
	_wipe(START_FOLDER)
	_wipe(DROPPED)


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	for n in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(n))
	DirAccess.remove_absolute(dir)
