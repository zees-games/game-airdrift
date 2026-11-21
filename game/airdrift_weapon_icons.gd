extends RefCounted

## The deathmatch weapons' pictures: weapon id to sprite tag; the rest is gs-ui's [GSWeaponIconStyle].

const TAGS := {
	&"deagle": &"pistol", &"knife": &"knife",
}

## The one instance the HUD and the console share.
static var shared: GSWeaponIconStyle = _make()


static func _make() -> GSWeaponIconStyle:
	var s := GSWeaponIconStyle.new()
	s.tags = TAGS
	return s
