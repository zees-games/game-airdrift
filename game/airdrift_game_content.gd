extends Node3D

## The first layer of AirdriftGame: the map-content delivery (fetch a missing map through gs-cloud) and the
## state it reads. No class_name; scripts keep using AirdriftGame.

const AirdriftConfig := preload("airdrift_config.gd")
const AirdriftMapCatalogue := preload("airdrift_map_catalogue.gd")
const AirdriftSoloMaps := preload("airdrift_solo_maps.gd")

const CHANNEL := "g2g"

## The map catalogue was re-read from the disk. Carries `added`, `removed`, `total`.
signal maps_rescanned(change: Dictionary)

@export var config: AirdriftConfig = null

## The gs-cloud client to fetch a missing map through, by registry name; optional.
## A build that ships its maps (a server from source, every suite) never reaches it.
## Empty or unregistered is not an error: the build plays only the maps it has.
@export var map_content_service: StringName = &"gs_cloud_client"

## Content ids already fetched and registered, so a rotation that comes back round does
## not ask gs-cloud again. gs-cloud is itself idempotent; this saves the await.
var _map_content_seen: Dictionary = {}

## Maps the game's descriptor names in `maps:`, pinned by the server's installer:
## map id -> [content id, version]. See [method _adopt_descriptor_maps].
var _pinned_maps: Dictionary = {}

## Whether [method fetch_content_maps] is already sweeping the configured set.
var _fetching_content_maps: bool = false

## Map ids offered on M although this build has not fetched them: choosing one downloads it
## (see [method ensure_map_content]). A solo game in the shell sets it ([method offer_collection]);
## empty everywhere else, so desktop and servers list what they hold.
var offered_maps: PackedStringArray = PackedStringArray()

## The newest version of an offered map, by id, as [method offer_collection] read it.
var _offered_versions: Dictionary = {}

## GET-as-JSON override for a suite: `func(url: String) -> GSResult`. Unset is a real [GSHttp].
var json_fetch_fn: Callable = Callable()

var maps: GSMapSession = null


## Make sure the map [param id] is loadable, fetching it through gs-cloud if not.
## The map id IS the content id (the publisher's `dist/<id>/` layout), so no registry maps one to the other.
## Succeeds and does nothing if the catalogue has it, there is no cloud client, or it is built in.
func ensure_map_content(id: StringName) -> GSResult:
	if id == &"":
		return GSResult.fail(GSError.CODE_INVALID, "No map id.")

	if maps != null and maps.catalogue != null and maps.catalogue.has(id):
		return GSResult.success(null)

	if _map_content_seen.has(id):
		return GSResult.success(null)

	var cloud: Object = GSRegistry.get_service(map_content_service)

	if cloud == null or not cloud.has_method("ensure"):
		# Not a warning: `change_to` refuses the id next, naming the map, which reads better.
		return GSResult.success(null)

	GSLog.info(CHANNEL, "fetching a map this build does not have", {"map": String(id)})

	# The installer-pinned version when the descriptor names the map, else the origin's latest.
	var pinned: Array = _pinned_maps.get(id, [])
	var got: Variant

	if not pinned.is_empty():
		got = await cloud.call("ensure", StringName(pinned[0]), pinned[1])
	else:
		# `ensure` with no version means 0.0.0, answered by a manifest a publish never
		# updates (a solo game got a weeks-old map), so ask the origin for the newest.
		var content_id := config.map_content_id(id)
		var newest := str(_offered_versions.get(id, ""))
		if newest == "":
			newest = await _latest_map_version(cloud, content_id)
		got = await cloud.call("ensure", StringName(content_id), newest)

	if not (got is GSResult):
		return GSResult.fail(
			GSError.CODE_INTERNAL,
			"The content client answered with something else."
		)

	var res: GSResult = got

	if not res.ok:
		# An offered course the origin will not serve leaves M rather than failing every pick.
		var transient := res.error.code in [GSError.CODE_NETWORK, GSError.CODE_TIMEOUT]
		if offered_maps.has(String(id)) and not transient:
			offered_maps.remove_at(offered_maps.find(String(id)))
		return res.wrap("could not fetch the map %s" % id)

	# `ensure` returns the entry scene path or the mount prefix; the catalogue wants the directory.
	var where := str(res.value)
	var dir := where.get_base_dir() if where.ends_with(".json") else where
	var map := AirdriftMapCatalogue.at_directory(id, dir)

	if map == null:
		return GSResult.fail(
			GSError.CODE_INVALID,
			"%s was fetched but does not look like a map." % id
		)

	_mark_delivered(map, dir)

	var added := maps.catalogue.add(map)

	if not added.ok:
		return added

	_map_content_seen[id] = true
	GSLog.info(CHANNEL, "a map was added from delivered content", {
		"map": String(id), "version": map.content_version, "dir": dir
	})
	return GSResult.success(null)


## The version the origin's `latest.json` names for [param content_id], or "" when no base
## answers, which is the old unversioned lookup.
func _latest_map_version(cloud: Object, content_id: String) -> String:
	if not cloud.has_method("resolved_http_base_urls"):
		return ""

	var version := ""

	for base in cloud.call("resolved_http_base_urls"):
		var url := "%s/%s/latest.json" % [str(base).rstrip("/"), content_id]
		var res: GSResult = await _get_json(url)

		if res.ok and res.value is Dictionary:
			version = str((res.value as Dictionary).get("version", ""))
			if version != "" and not version.contains("/") and not version.contains(".."):
				break
			version = ""

	GSLog.debug(CHANNEL, "newest published map version", {"content": content_id, "version": version})
	return version


## Offers on M every map of [param collection] (`owner/name`) the origin publishes in its `collection.json`, minus packs whose `latest.json` it does not serve (a pack the collection
## names but the store lost). [param also] (the stock list) joins it, since the stock courses are published packs a collection need not name. Keeps [member offered_maps] as it was when no base answers.
func offer_collection(collection: String, also: PackedStringArray = PackedStringArray()) -> GSResult:
	var cloud: Object = GSRegistry.get_service(map_content_service)
	if cloud == null or not cloud.has_method("resolved_http_base_urls"):
		return GSResult.fail(GSError.CODE_UNSUPPORTED, "No content client to read %s from." % collection)
	var owner := collection.get_slice("/", 0)
	var bases: Variant = cloud.call("resolved_http_base_urls")
	var listed := PackedStringArray()
	var last: GSResult = GSResult.fail(GSError.CODE_UNSUPPORTED, "The content client has no origin.")
	for base in bases:
		last = await _get_json("%s/%s/collection.json" % [str(base).rstrip("/"), collection])
		if last.ok:
			last = AirdriftSoloMaps.collection_maps(last.value, collection, owner)
		if last.ok:
			listed = last.value
			break
	if not last.ok:
		GSLog.warn(CHANNEL, "the map collection could not be read; M keeps the stock list",
			{"collection": collection, "why": last.error.message})
		return last

	var held := func(id: String) -> bool: return maps != null and maps.catalogue != null and maps.catalogue.has(StringName(id))
	var wanted := PackedStringArray()
	for id in also:
		if not listed.has(id):
			listed.append(id)
	for id in listed:
		if not held.call(id):
			wanted.append(id)
	offered_maps = wanted.duplicate()
	var dropped := PackedStringArray()
	for id in wanted:
		var version := await _latest_map_version(cloud, "%s/%s" % [owner, id])
		if version == "":
			dropped.append(id)
			if offered_maps.has(id):
				offered_maps.remove_at(offered_maps.find(id))
		else:
			_offered_versions[StringName(id)] = version
	GSLog.info(CHANNEL, "the map collection is offered on M", {"collection": collection,
		"listed": listed.size(), "offered": offered_maps.size(), "unpublished": dropped})
	return GSResult.success(offered_maps)


func _get_json(url: String) -> GSResult:
	if json_fetch_fn.is_valid():
		return await json_fetch_fn.call(url)
	var http := GSHttp.new()
	http.name = "MapContentHttp"
	add_child(http)
	var res: GSResult = await http.get_json(url)
	http.queue_free()
	return res


## Names the content id and version of a map that came out of a gs-cloud mount, so a client can be sent it.
## Both come off the mount path `res://gs_cloud/<content_id>/<version>`, not a second record that could disagree.
func _mark_delivered(map: GSMapDef, dir: String) -> void:
	# Read off the path, not rebuilt from the owner cvar, so changing it mid-session
	# does not re-announce the map under another owner.
	# A map pack published before the dot_ to gs_ rename still mounts under res://dot_cloud/
	# (the root is baked into its manifest), so accept any `<x>_cloud` root.
	var base := dir.rstrip("/")
	if not base.begins_with("res://"):
		return                            # a directory on disk, not a mount
	var rest := base.substr("res://".length())
	var slash := rest.find("/")
	if slash <= 0 or not rest.substr(0, slash).ends_with("_cloud"):
		return
	rest = rest.substr(slash + 1)
	var cut := rest.rfind("/")
	if cut <= 0:
		return
	var content := rest.substr(0, cut)
	var version := rest.substr(cut + 1)
	if version.is_empty() or (content != String(map.id) and not content.ends_with("/" + String(map.id))):
		return
	map.content_id = StringName(content)
	map.content_version = version


## Fetch every id in [member AirdriftConfig.content_maps] into the catalogue, in the background.
## Deliberately not awaited: the download is up to 66 MB and must not block the server boot.
## One id at a time (they share a link); re-entrant calls are dropped.
func fetch_content_maps() -> void:
	if _fetching_content_maps or config == null or config.content_maps.is_empty():
		return

	_fetching_content_maps = true

	# One frame first: descriptor cvars apply in file order, and the owner cvar must land
	# before the sweep starts or every map is fetched from the unowned path.
	if is_inside_tree():
		await get_tree().process_frame

	var wanted := config.content_maps
	var added: Array[StringName] = []
	var failed := 0

	GSLog.info(CHANNEL, "fetching the configured map set", {"maps": wanted.size()})

	for raw in wanted:
		var id := StringName(raw.strip_edges())
		if id == &"":
			continue
		if maps != null and maps.catalogue != null and maps.catalogue.has(id):
			continue

		var res: GSResult = await ensure_map_content(id)

		# ok is not "arrived" (no content client succeeds silently): the catalogue says.
		if not res.ok:
			failed += 1
			GSLog.warn(CHANNEL, "a configured map could not be fetched",
				{"map": String(id), "why": res.error.message})
		elif maps != null and maps.catalogue != null and maps.catalogue.has(id):
			added.append(id)

	_fetching_content_maps = false

	var total := maps.catalogue.size() if maps != null and maps.catalogue != null else 0
	GSLog.info(CHANNEL, "the configured map set is in", {
		"added": added.size(), "failed": failed, "catalogue": total,
	})

	# The same signal a disk rescan emits: downstream, the set of loadable maps changed.
	var removed: Array[StringName] = []
	maps_rescanned.emit({"added": added, "removed": removed, "total": total})
