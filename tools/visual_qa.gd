extends DotGameVisualQaCapture

## g2gfast's visual QA capture (the loop is dot-game's docs/visual-qa.md). One item per stock person, recorded frame by frame
## at --fps in three views (f a rival's eye 2.5 m in front, t behind-right, o an opponent in front):
##   person_<letter>  one of the Kenney stock characters (the body and head parts AirdriftAvatars.stock draws) as the game's
##                    DotHumanoidFigure, idling, walking, running, crouching and jumping.
## Airdrift is third person and its weapons are hitscan with no held model, so there are no weapon items.
## The outside views and frame saving are dot-game's DotGameVisualQaViews, through DotGameVisualQaCapture.

const AirdriftAvatars := preload("../game/airdrift_avatars.gd")

const BODY_HEIGHT := 1.8
const CLIPS: PackedStringArray = ["idle", "walk", "run", "crouch", "jump"]
## Ground speed per clip (metres a second), about the game's walk and run.
const SPEED := {"idle": 0.0, "walk": 2.9, "run": 6.5, "crouch": 2.9, "jump": 2.9}
const SECONDS := {"idle": 2.0, "walk": 2.4, "run": 2.0, "crouch": 2.0, "jump": 1.6}
const LETTERS := "abcdefghijklmnopqr"

var _figure: DotHumanoidFigure = null
var _holder := Node3D.new()


func _items() -> PackedStringArray:
	var items := PackedStringArray()
	for i in LETTERS.length():
		items.append("person_" + LETTERS[i])
	return items


func _clips(_item: String) -> PackedStringArray:
	return CLIPS


func _seconds(_item: String, clip: String) -> float:
	return float(SECONDS.get(clip, 2.0))


func _warmup_frames(_item: String, _clip: String) -> int:
	return 4


func _build() -> void:
	build_stage()
	views.behind_offset = Vector3(1.6, 1.6, 3.2)
	views.behind_look_height = 1.0
	views.opponent_offset = Vector3(0.4, 1.6, -4.0)
	views.opponent_look_height = 1.3
	root.add_child(_holder)


func _stage(item: String, _clip: String) -> DotResult:
	for child in _holder.get_children():
		_holder.remove_child(child)
		child.free()
	var letter := item.trim_prefix("person_")
	var avatar := DotAvatar.make(AirdriftAvatars.SCHEMA_ID)
	avatar.set_part(AirdriftAvatars.SLOT_BODY, StringName("body_kenney_" + letter))
	avatar.set_part(AirdriftAvatars.SLOT_HEAD, StringName("head_kenney_" + letter))
	_figure = DotHumanoidFigure.new()
	_figure.name = "Figure"
	_holder.add_child(_figure)
	_figure.global_position = Vector3.ZERO
	_figure.build(AirdriftAvatars.look_of(avatar, StringName(item)), BODY_HEIGHT)
	return DotResult.success(item)


func _subject(_item: String) -> Node3D:
	return _figure


## The person stands at the origin facing -Z; the clips move it along -Z so the stage is walked, not skated on.
func _drive(_item: String, clip: String, t: float, _frame: int) -> void:
	var step := 1.0 / float(fps)
	var speed := float(SPEED.get(clip, 0.0))
	var airborne := false
	var vertical := 0.0
	_figure.global_position.y = 0.0
	if clip == "jump":
		# A 0.6 s hop at the start, again at 1.0 s.
		var phase := fmod(t, 1.0) / 0.6
		airborne = phase < 1.0
		vertical = 4.0 * (1.0 - 2.0 * phase) if airborne else 0.0
		_figure.global_position.y = 0.6 * phase * (1.0 - phase) if airborne else 0.0
	_figure.set_motion({"on_floor": not airborne, "vertical": vertical, "crouched": clip == "crouch",
		"sprinting": clip == "run", "aim": 0.0, "velocity": Vector3(0.0, 0.0, -speed)})
	_figure.global_position.z = -speed * t + speed * float(SECONDS.get(clip, 2.0)) * 0.5
	_figure.global_position.x = 0.0
	_figure.rotation = Vector3.ZERO
	_figure.animate(speed, step)


func _grounded(_item: String, clip: String, t: float) -> bool:
	return not (clip == "jump" and fmod(t, 1.0) < 0.6)


## A rival's eye 2.5 m in front, looking at the subject.
func _place_first_person(_item: String) -> void:
	first_person.global_position = _figure.global_position + Vector3(0.0, 1.6, -2.5)
	first_person.look_at(_figure.global_position + Vector3(0.0, BODY_HEIGHT * 0.5, 0.0))
