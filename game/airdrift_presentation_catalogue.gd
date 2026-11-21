extends Node

## The sound recipes and effects catalogue of AirdriftPresentation, with the ids they name.
## No class_name; scripts keep using AirdriftPresentation.

const AirdriftPaths := preload("airdrift_paths.gd")
const AirdriftVote := preload("airdrift_vote.gd")

## The ping an administrator's beacon makes. See [method sound_catalogue].
const BEACON_SOUND := &"beacon"

## The flashlight's switch. See [method sound_catalogue].
const FLASHLIGHT_SOUND := &"flashlight"

static var FX_DIR := AirdriftPaths.rebase("res://scenes/fx")


## Which synthesised voice stands in for each id until real audio is dropped into SOUND_DIR.
## Sound is part of this game's input loop, so the jump and landing are the shortest voices,
## and `land` is an impact, not a thud with a tail that would smear the rhythm.
static func sound_recipes() -> Dictionary:
	return {
		&"land": GSAudioSynth.Voice.IMPACT,
		&"jump": GSAudioSynth.Voice.STEP,
		&"timer_start": GSAudioSynth.Voice.BLIP,
		&"timer_split": GSAudioSynth.Voice.CLICK,
		&"timer_finish": GSAudioSynth.Voice.PICKUP,
		&"personal_best": GSAudioSynth.Voice.SPAWN,
		&"teleport": GSAudioSynth.Voice.DENY,
		# The one voice the run also uses: BLIP is the only pure tone, and a beacon is located by ear.
		# Positional on the SFX bus, where the start is flat on UI.
		BEACON_SOUND: GSAudioSynth.Voice.BLIP,
		# A switch, which is what a click is; the pitch keeps it from reading as a split.
		FLASHLIGHT_SOUND: GSAudioSynth.Voice.CLICK,
		# Only voices the run does not use, so a ballot never sounds like a split or a jump.
		AirdriftVote.CUE_START: GSAudioSynth.Voice.SHOT_TIGHT,
		AirdriftVote.CUE_END: GSAudioSynth.Voice.DIE,
		AirdriftVote.CUE_WARNING: GSAudioSynth.Voice.BOOM,
		AirdriftVote.CUE_COUNT: GSAudioSynth.Voice.SHOT,
		# Stand-ins only for a build without gs-player-char's files.
		GSPlayerDeathReactions.SOUND_THUD: GSAudioSynth.Voice.IMPACT,
		GSPlayerDeathReactions.SOUND_FACE_PLANT: GSAudioSynth.Voice.IMPACT,
		GSPlayerDeathReactions.SOUND_SLUMP: GSAudioSynth.Voice.STEP,
		GSPlayerDeathReactions.SOUND_WHOOSH: GSAudioSynth.Voice.SPAWN,
	}


static func fx_catalogue() -> GSFxCatalogue:
	var c := GSFxCatalogue.new()

	var start := GSFxDef.new()
	start.id = &"start_gate"
	start.scene_path = "%s/start_gate.tscn" % FX_DIR
	start.lifetime_ms = 600
	start.cost = 2
	start.priority = 80
	start.max_distance = 0.0
	c.add(start)

	var finish := GSFxDef.new()
	finish.id = &"finish_gate"
	finish.scene_path = "%s/finish_gate.tscn" % FX_DIR
	finish.lifetime_ms = 1200
	finish.cost = 4
	finish.priority = 90
	finish.max_distance = 0.0
	c.add(finish)

	# A tint on a personal best, off by default like everything else.
	var best := GSFxDef.new()
	best.id = &"personal_best"
	best.kind = GSFxDef.Kind.SCREEN
	best.flash_peak = 0.18
	best.flash_colour = Color(0.45, 1.0, 0.55)
	best.flash_decay_ms = 500
	c.add(best)

	var land := GSFxDef.new()
	land.id = &"land_shake"
	land.kind = GSFxDef.Kind.SHAKE
	land.shake_trauma = 0.18
	c.add(land)

	return c
