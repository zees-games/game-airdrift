extends Node

## The static half of AirdriftCombat: the weapon table, the default kit, the hitbox layout and the id parse.
## No class_name; scripts keep using AirdriftCombat.

const AirdriftArsenal := preload("airdrift_arsenal.gd")


## The two weapons everybody starts with.
static func _give_default(arsenal: GSWeaponArsenal) -> void:
	arsenal.clear()
	arsenal.give(AirdriftArsenal.ITEM_KNIFE)
	arsenal.give(AirdriftArsenal.ITEM_DEAGLE)
	hold(arsenal, 2)


## Holds [param slot] at once. `select` refuses while the arsenal is disabled, which would leave a
## player (a bot presses no slot key) on the first weapon given, the knife.
static func hold(arsenal: GSWeaponArsenal, slot: int, tick: int = 0) -> void:
	if arsenal.has_method("equip") and arsenal.equip(slot):
		return
	var _selected := arsenal.select(slot, tick)


## The shared weapon table, built and validated once for the whole process.
static var _shared_catalogue: GSWeaponCatalogue = null


static func catalogue() -> GSWeaponCatalogue:
	if _shared_catalogue == null:
		_shared_catalogue = AirdriftArsenal.weapon_catalogue()
		var res := _shared_catalogue.validate()
		if not res.ok:
			push_error(res.error.message)
		_shared_catalogue.warm_scripts()
	return _shared_catalogue


static func _add_hitboxes(set_node: GSHitboxSet) -> void:
	var head := GSHitbox.new()
	head.name = "Head"
	head.group = GSHitGroup.HEAD
	head.shape = GSHitbox.Shape.SPHERE
	head.radius = 0.15
	head.position = Vector3(0.0, 1.62, 0.0)
	# Higher than the chest's, so the surface the two share resolves to the head every
	# time rather than about half the time.
	head.precedence = 10
	set_node.add_child(head)

	var chest := GSHitbox.new()
	chest.name = "Chest"
	chest.group = GSHitGroup.CHEST
	chest.shape = GSHitbox.Shape.CAPSULE
	chest.radius = 0.30
	chest.height = 1.05
	chest.position = Vector3(0.0, 0.98, 0.0)
	set_node.add_child(chest)

	var legs := GSHitbox.new()
	legs.name = "Legs"
	legs.group = GSHitGroup.LEG
	legs.shape = GSHitbox.Shape.CAPSULE
	legs.radius = 0.24
	legs.height = 0.9
	legs.position = Vector3(0.0, 0.45, 0.0)
	set_node.add_child(legs)


## The account number inside a player id. `u123` becomes 123.
## Not an entity id: a loadout's filename and the session lookup want this number.
static func userid_of(player_id: StringName) -> int:
	var text := String(player_id)
	return text.substr(1).to_int() if text.begins_with("u") else text.to_int()
