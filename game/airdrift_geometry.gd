extends RefCounted

const AirdriftLighting := preload("airdrift_lighting.gd")
const AirdriftTextures := preload("airdrift_textures.gd")
const AirdriftUnits := preload("airdrift_units.gd")

## Prototype-textured collision geometry in code, in genre units.
##
## [b]Every argument is in genre units[/b] and converted here, so a map file reads
## like a brush list: a 64-unit-tall block is [code]64[/code], not
## [code]1.2192[/code]. A surf ramp built as "128 wide at 60°" is a ramp a mapper
## who has built one before can read.
##
## Deliberately duplicated from game-playlot rather than shared: the family rule
## is that games copy what they need, because a shared helper is a dependency and
## these two games will diverge.

# THESE ARE ROLES NOW, not colours, and they keep the old names because every map in
# this repository and any anybody else has written passes one of them to `box()`.
#
# The change is what happens to them: they used to become a flat `albedo_color` and
# they now select a prototype-textured material through `AirdriftTextures`. A map file did
# not change and does not have to — which is the point of having had one seam for this
# rather than a colour per box. A map that really wants a flat colour still passes a
# `Color`; `box()` takes either.
const COLOUR_FLOOR := AirdriftTextures.Role.FLOOR
const COLOUR_RAMP := AirdriftTextures.Role.RAMP
const COLOUR_START := AirdriftTextures.Role.START
const COLOUR_END := AirdriftTextures.Role.END
const COLOUR_PLATFORM := AirdriftTextures.Role.PLATFORM
const COLOUR_BONUS := AirdriftTextures.Role.BONUS

## The same six, under the names a new map should be written against.
const ROLE_FLOOR := AirdriftTextures.Role.FLOOR
const ROLE_RAMP := AirdriftTextures.Role.RAMP
const ROLE_START := AirdriftTextures.Role.START
const ROLE_END := AirdriftTextures.Role.END
const ROLE_PLATFORM := AirdriftTextures.Role.PLATFORM
const ROLE_BONUS := AirdriftTextures.Role.BONUS


## A static box. [param at] is its centre and [param size] its extent, both in units.
static func box(
	parent: Node3D,
	at: Vector3,
	size: Vector3,
	surface: Variant = ROLE_FLOOR,
	basis: Basis = Basis.IDENTITY
) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.transform = Transform3D(basis, AirdriftUnits.vector_to_metres(at))

	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = AirdriftUnits.vector_to_metres(size)
	shape.shape = box_shape
	body.add_child(shape)

	var mesh := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = box_shape.size
	mesh.mesh = box_mesh

	mesh.material_override = material_for(surface)

	body.add_child(mesh)
	parent.add_child(body)

	return body


## A ramp: a slab tilted [param angle_degrees] about [param axis].
static func ramp(
	parent: Node3D,
	at: Vector3,
	size: Vector3,
	angle_degrees: float,
	axis: Vector3 = Vector3.FORWARD,
	surface: Variant = ROLE_RAMP
) -> StaticBody3D:
	return box(
		parent, at, size, surface, Basis(axis.normalized(), deg_to_rad(angle_degrees))
	)


## The material for a surface, which is either a [enum AirdriftTextures.Role] or a [Color].
##
## [b]Both, because the roles were `Color` constants until the maps got textures.[/b]
## Every map file in this repository passes `AirdriftGeometry.COLOUR_*` and so does any map
## anybody wrote against the old signature; those constants are role ids now and go
## down the first branch. A `Color` still means what it always did — a flat, untextured
## surface — which is what a trigger volume or a skybox brush wants, and is the only
## thing that made this worth accepting two types for.
static func material_for(surface: Variant) -> StandardMaterial3D:
	if surface is Color:
		var flat := StandardMaterial3D.new()
		flat.albedo_color = surface
		flat.roughness = 0.92
		flat.metallic = 0.0
		return flat

	return AirdriftTextures.material_for(surface as AirdriftTextures.Role)


## The hand-built maps' sun, sky and air: [constant AirdriftLighting.DAYLIGHT], a dot-lighting
## document like an imported map's, through the same rig. See [method AirdriftLighting.builtin].
static func sun(parent: Node3D) -> DirectionalLight3D:
	return AirdriftLighting.builtin(parent)
