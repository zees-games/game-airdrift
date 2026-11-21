extends GSGameCheckSuite

## The shared state of [code]headless_client.gd[/code] (the client, the section counters and
## the preloads) and its solo-session sections: Leave, the course list and the map collection.

const AirdriftClient := preload("../game/airdrift_client.gd")
const AirdriftGame := preload("../game/airdrift_game.gd")
const AirdriftEvents := preload("../game/net/airdrift_events.gd")
const AirdriftNetBridge := preload("../game/net/airdrift_net_bridge.gd")
const AirdriftPlayer := preload("../game/airdrift_player.gd")
const AirdriftHud := preload("../game/airdrift_hud.gd")
const AirdriftSoloMaps := preload("../game/airdrift_solo_maps.gd")
const AirdriftRig := preload("../game/airdrift_rig.gd")
const AirdriftClientKillView := preload("../game/airdrift_client_killview.gd")

var _entered := 0
var _completed := 0
var _client: AirdriftClient = null


## Stands in for the browser shell's solo session: a node under `gs_solo` with `leave()`.
class FakeSolo extends Node:
	var left := 0
	var start_map: StringName = &""

	func leave() -> void:
		left += 1


## Inside the shell's solo session Leave goes back to the shell's menu and M offers every
## course the stock list names; outside it nothing changes.
func _test_solo_in_the_shell() -> void:
	_section("solo in the browser shell: Leave and the course list")
	var before_label := _client.menu_leave_label()
	_check(_client.game.offered_maps.is_empty() and AirdriftSoloMaps.session() == null,
		"outside a solo session nothing is offered on M", str(_client.game.offered_maps.size()))

	var solo := FakeSolo.new()
	add_child(solo)
	GSRegistry.register(AirdriftSoloMaps.SERVICE, solo)
	_check(_client.menu_leave_label() == "Back to menu", "in a solo session Leave reads Back to menu",
		_client.menu_leave_label())
	_client._leave()
	_check(solo.left == 1, "Leave in a solo session asks the shell to leave once", str(solo.left))

	var first := _client.game.config.initial_map
	solo.start_map = &"bhop_not_stock"
	_client._offer_solo_maps()
	_check(_client.game.config.initial_map == &"bhop_not_stock" and "bhop_not_stock" in _client.game.offered_maps,
		"a solo session's start map is the first course and on M", str(_client.game.config.initial_map))
	solo.start_map = &"../escape"
	_client.game.config.initial_map = first
	_client._offer_solo_maps()
	_check(_client.game.config.initial_map == first, "a start map that is not a course id is ignored")
	solo.start_map = &""
	_client._offer_solo_maps()
	# A checkout with the maps linked holds every stock course, so add one nothing holds.
	var ghost := PackedStringArray(AirdriftSoloMaps.IDS)
	ghost.append("zz_unfetched_course")
	_client.game.offered_maps = ghost
	var rows: Array = _client.game.map_rows()
	var offered := PackedStringArray()
	for row: Dictionary in rows:
		if bool(row.get("download", false)):
			offered.append(str(row["id"]))
	# Linked imported maps are already held and need no download, so count what is missing.
	var missing := PackedStringArray()
	for id in AirdriftSoloMaps.IDS:
		if not _client.game.maps.catalogue.has(StringName(id)):
			missing.append(id)
	missing.append("zz_unfetched_course")
	# map_rows() sorts by id; with no maps linked (CI) every id is missing, so match the order.
	missing.sort()
	_check(offered == missing and "zz_unfetched_course" in offered and AirdriftSoloMaps.IDS.size() == 26,
		"M offers every stock course the catalogue lacks", "%d offered, %d missing" % [offered.size(), missing.size()])
	var held := 0
	for row: Dictionary in rows:
		if str(row["id"]) in AirdriftSoloMaps.IDS:
			held += 1
	_check(held == AirdriftSoloMaps.IDS.size(), "and every stock course is on the list, held or not", "%d" % held)
	_check(_client.game.config.map_content_id(&"surf_kitsune") == "gamemann/surf_kitsune",
		"a pick is fetched under the stock owner", _client.game.config.map_content_id(&"surf_kitsune"))
	var shown: Array = AirdriftGame.menu_rows(rows)
	var tagged := 0
	for row: Dictionary in shown:
		if "downloads when chosen" in (row["tags"] as Array):
			tagged += 1
	_check(tagged == offered.size(), "the menu says an unfetched course downloads when chosen")

	_check_stock_course_list()

	GSRegistry.unregister(AirdriftSoloMaps.SERVICE)
	solo.queue_free()
	_client.game.offered_maps = PackedStringArray()
	_client.game.config.map_content_owner = ""
	_check(_client.menu_leave_label() == before_label, "after the session ends Leave reads as before", _client.menu_leave_label())
	_check(_client.game.map_rows().size() == rows.size() - offered.size(), "and the extra courses are gone from M")
	_done()


## The solo course list matches gs-server-deploy's stock content.yml, when that checkout is beside this one.
func _check_stock_course_list() -> void:
	# The list in gs-server-deploy's stock configuration, when that checkout is beside this one.
	var stock := FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://").path_join("../gs-server-deploy/cfg.example/content.yml"))
	if stock == "":
		_check(true, "(gs-server-deploy is not beside this checkout: drift not checked)")
	else:
		var block := stock.split("  game-airdrift:")[1].split("\n  mg-")[0].split("\n  game-")[0]
		var re := RegEx.new()
		re.compile("-\\s+gamemann/([a-z0-9_]+)\\s*$")
		var named := PackedStringArray()
		for line in block.split("\n"):
			var hit := re.search(line)
			if hit != null:
				named.append(hit.get_string(1))
		var a := Array(named)
		var b := Array(AirdriftSoloMaps.IDS)
		a.sort()
		b.sort()
		_check(a == b, "the list is the stock content.yml's Airdrift list", "%d vs %d" % [a.size(), b.size()])


## Stands in for gs-cloud's client: one origin, nothing fetched.
class FakeCloud extends Node:
	func resolved_http_base_urls() -> PackedStringArray:
		return PackedStringArray(["https://origin.test/content/"])

	func ensure(_id: StringName, _version: String = "") -> GSResult:
		return GSResult.fail(GSError.CODE_HTTP, "not in this suite")


## The fake origin's answers by URL; anything else is a 404.
var _origin: Dictionary = {}


func _fake_get_json(url: String) -> GSResult:
	await get_tree().process_frame
	if _origin.has(url):
		return GSResult.success(_origin[url])
	var err := GSResult.fail(GSError.CODE_HTTP, "404 for %s" % url)
	return err


## In a solo session M lists the airdrift-maps collection the origin publishes, not only the
## stock 26: every pack it names, minus held maps, foreign owners, bad names and packs it 404s.
func _test_the_collection_fills_m() -> void:
	_section("solo in the browser shell: M lists the published map collection")
	var game = _client.game
	var held_id := String(game.maps.catalogue.available()[0].id)
	var base := "https://origin.test/content"
	var col := "%s/gamemann/airdrift-maps/collection.json" % base
	_origin = {
		col: {"format": 1, "id": "gamemann/airdrift-maps", "version": "1.2.10", "packs": [
			"gamemann/zz_new_course", "gamemann/zz_lost_course", "someone/zz_foreign",
			"gamemann/../escape", "gamemann/" + held_id, "gamemann/zz_new_course"]},
		"%s/gamemann/zz_new_course/latest.json" % base: {"version": "1.2.10"},
		"%s/gamemann/zz_stock_course/latest.json" % base: {"version": "1.2.6"},
	}
	var old_cloud: Object = GSRegistry.get_service(game.map_content_service)
	var cloud := FakeCloud.new()
	add_child(cloud)
	GSRegistry.register(game.map_content_service, cloud)
	game.json_fetch_fn = _fake_get_json

	var res: GSResult = await game.offer_collection("gamemann/airdrift-maps",
		PackedStringArray(["zz_stock_course", "zz_new_course", held_id]))
	_check(res.ok and game.offered_maps == PackedStringArray(["zz_new_course", "zz_stock_course"]),
		"M offers each published course it lacks, stock ones too, once, and hides a pack the origin 404s",
		str(game.offered_maps))
	_check(str(game._offered_versions.get(&"zz_new_course", "")) == "1.2.10",
		"and a pick fetches the version latest.json names", str(game._offered_versions))
	var tagged := PackedStringArray()
	for row: Dictionary in AirdriftGame.menu_rows(game.map_rows()):
		if "downloads when chosen" in (row["tags"] as Array):
			tagged.append(str(row["id"]))
	_check(tagged == PackedStringArray(["zz_new_course", "zz_stock_course"]), "the menu says it downloads when chosen", str(tagged))

	var picked: GSResult = await game.ensure_map_content(&"zz_new_course")
	_check(not picked.ok and not game.offered_maps.has("zz_new_course"),
		"a course the origin then refuses leaves M", str(game.offered_maps))

	game.offered_maps = PackedStringArray(AirdriftSoloMaps.IDS)
	_origin = {col: {"format": 9, "id": "gamemann/airdrift-maps", "packs": []}}
	res = await game.offer_collection("gamemann/airdrift-maps")
	_check(not res.ok and game.offered_maps == PackedStringArray(AirdriftSoloMaps.IDS),
		"an unreadable collection keeps the stock list", str(game.offered_maps.size()))
	_origin = {}
	res = await game.offer_collection("gamemann/airdrift-maps")
	_check(not res.ok and game.offered_maps.size() == AirdriftSoloMaps.IDS.size(),
		"and so does an origin that serves none", res.error.message if not res.ok else "ok")

	game.json_fetch_fn = Callable()
	game.offered_maps = PackedStringArray()
	game._offered_versions.clear()
	GSRegistry.unregister(game.map_content_service)
	if old_cloud != null:
		GSRegistry.register(game.map_content_service, old_cloud)
	cloud.queue_free()
	_done()


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- " + title)


func _done() -> void:
	_completed += 1
