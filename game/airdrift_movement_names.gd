extends RefCounted

## The shared movement cvar names (gs-player-controller's `GSFpsTunables`, bound by gs-game's `bind_movement_cvars`) over [AirdriftConfig], which stays the one source of truth.
##
## Only the names that differ are here: `sv_gravity`, `sv_accelerate` and the other eight are spelled alike in both sets, so Airdrift's own cvar already answers to them. The table is documented in docs/movement.md.

## Shared name -> {field: the AirdriftConfig field, Airdrift: the cvar that has always driven it}.
const RENAMES := {
	"sv_runspeed": {"field": "max_speed", "airdrift": "sv_maxspeed"},
	"sv_airwishspeed": {"field": "air_wish_cap", "airdrift": "sv_airwishcap"},
	"sv_autohop": {"field": "auto_bhop", "airdrift": "sv_autobunnyhopping"},
}

## Shared names with no Airdrift meaning, left unbound. `sv_maxspeed` is the shared wish-speed ceiling, and Airdrift's `sv_maxspeed` is the run speed: they are different quantities, so it must never be forwarded.
const UNBOUND := ["sv_maxspeed", "sv_jumpheight", "sv_bhopcap", "sv_movement_profile"]

const AirdriftConfig := preload("airdrift_config.gd")

var game: Node = null
## Called with the AirdriftConfig field after this adapter changed it, so the module refreshes the Airdrift cvar.
var changed_fn: Callable = Callable()


func _init(p_game: Node = null) -> void:
	game = p_game


## The renamed cvars in the shared spec shape, at the config's current values.
func cvar_specs() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for shared: String in RENAMES:
		var field: String = RENAMES[shared]["field"]
		var current: Variant = game.config.get(field)
		out.append({
			"name": shared, "value": (1.0 if current else 0.0) if current is bool else snappedf(float(current), 0.0001),
			"member": field, "description": "Same as %s." % RENAMES[shared]["airdrift"],
		})
	return out


## Writes the field behind [param cvar_name] through AirdriftConfig.validate on a copy first. False for an unknown name, a non-number or a refused value; a value already held is a no-op, so mirrored cvars do not apply twice.
func set_cvar(cvar_name: String, value: String) -> bool:
	if not RENAMES.has(cvar_name) or not value.strip_edges().is_valid_float():
		return false
	var field: String = RENAMES[cvar_name]["field"]
	var current: Variant = game.config.get(field)
	var number := value.strip_edges().to_float()
	var wanted: Variant = (number != 0.0) if current is bool else number
	if current == wanted:
		return true
	var trial := game.config.clone() as AirdriftConfig
	trial.set(field, wanted)
	if not trial.validate().ok:
		if changed_fn.is_valid():
			changed_fn.call(field)
		return false
	game.config.set(field, wanted)
	game.apply_movement()
	if changed_fn.is_valid():
		changed_fn.call(field)
	return true


## The shared name for a AirdriftConfig field, or "".
static func shared_name_for(field: String) -> String:
	for shared: String in RENAMES:
		if RENAMES[shared]["field"] == field:
			return shared
	return ""
