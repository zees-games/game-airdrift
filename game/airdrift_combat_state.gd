extends "airdrift_combat_kit.gd"

## The state half of AirdriftCombat: the game, the managers, each player's kit, and the lookups
## between player ids and combat entity ids. No class_name; scripts keep using AirdriftCombat.

const AirdriftGame := preload("airdrift_game.gd")
const AirdriftPlayer := preload("airdrift_player.gd")
const AirdriftStats := preload("airdrift_stats.gd")

var game: AirdriftGame = null

## The dot-combat manager.
## Named `manager` rather than `combat` because this node is what a game calls
## `combat`, and `game.manager.combat` is a line nobody should have to read twice.
var manager: GSCombatManager = null
var loadouts: GSLoadoutManager = null
var match_node: GSMatch = null

## player id -> the components this layer hung off their node.
var _kit: Dictionary = {}

## The weapon definitions by id, for the death reaction a weapon asks for. Built on first use.
var _weapon_defs: Dictionary = {}


## The combat entity id for a player, or 0 when they have no kit. Two id spaces meet here: this game keys players by [StringName] and dot-combat and
## dot-effects both key by int. A caller that hashed the name instead would produce a number that is stable, plausible and not the one the health, the hitboxes and the
## kill feed use — which is why [GSEntityTable] stores the key rather than deriving it.
func entity_for(player_id: StringName) -> int:
	return game.entities.id_for_key(player_id) if game != null else 0


## The other direction: one dictionary read in the table's reverse index, not a scan of every kit (this runs once per kill, respawn and hunter swipe).
## [b]Not `"u%d" % entity`.[/b] That would be a second spelling of one serialisation.
func player_id_for(entity_id: int) -> StringName:
	return game.entities.key_for_id(entity_id) if game != null else &""


func _kit_for_entity(entity_id: int) -> Dictionary:
	var id := player_id_for(entity_id)
	return _kit.get(id, {}) if id != &"" else {}


func _player_for(entity_id: int) -> AirdriftPlayer:
	var id := player_id_for(entity_id)
	return game.players.get(id) if id != &"" else null


func health_of(player_id: StringName) -> GSHealth:
	var kit: Dictionary = _kit.get(player_id, {})
	return kit.get("health") if not kit.is_empty() else null
