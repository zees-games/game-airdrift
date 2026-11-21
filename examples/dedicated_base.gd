extends GSGameCheckSuite

const AirdriftArsenal := preload("../game/airdrift_arsenal.gd")
const AirdriftAvatars := preload("../game/airdrift_avatars.gd")
const AirdriftMovementNames := preload("../game/airdrift_movement_names.gd")
const AirdriftBrowser := preload("../game/airdrift_browser.gd")
const AirdriftCamera := preload("../game/airdrift_camera.gd")
const AirdriftCombat := preload("../game/airdrift_combat.gd")
const AirdriftConfig := preload("../game/airdrift_config.gd")
const AirdriftGame := preload("../game/airdrift_game.gd")
const AirdriftIdentity := preload("../game/airdrift_identity.gd")
const AirdriftPlayer := preload("../game/airdrift_player.gd")
const AirdriftProps := preload("../game/airdrift_props.gd")
const AirdriftServices := preload("../game/airdrift_services.gd")
const AirdriftUnits := preload("../game/airdrift_units.gd")
const AirdriftVote := preload("../game/airdrift_vote.gd")
const ExitProbe := preload("dedicated_exit_probe.gd")
const DedicatedWorld := preload("dedicated_world.gd")
const Accounts := preload("dedicated_accounts.gd")

## A real GSServer running Airdrift: the movement cvars, and sv_autobunnyhopping in
## particular, reaching every player live.
##
## [codeblock]
## godot --headless --path . res://examples/dedicated.tscn
## [/codeblock]

## Sections entered against sections that ran to their last line, and the total number of
## checks — the second being the one the first cannot be. A runtime error inside a section
## aborts that function; the section counter sees it, and the checks it never reached are
## what the total sees when the section had already announced itself. See
## docs/testing.md: this suite had neither until 2026-09-24.
const SECTIONS := 24
const CHECKS := 289

## Everything this run writes, and it is deleted on the way in and on the way out.
##
## [b]A suite that writes to `user://` is a suite whose result depends on the last run.[/b]
## This one wrote the real punishment store, the server's ban and admin files and its audit
## log at their defaults, so every run appended to all of them: 290 punishments in the store
## a real server enforces, and a gag against the same test uid every time. docs/testing.md
## has the two suites that began failing on an unchanged tree over exactly this.
const SERVER_DIR := "user://airdrift_dedicated"

var _entered := 0
var _completed := 0
## The app's URL segment on the website, which is this game's code name.
##
## Unique and lowercase because the site already made it so. Display only — a
## listing prints it to say which game this is, and nothing treats it as proof.
const APP_URL := "airdrift"

var server: GSServer = null
var query_host: GSQueryHost = null
var game: AirdriftGame = null


var _stats_errors: PackedStringArray = []



func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _run_command(line: String) -> PackedStringArray:
	var captured: Array[String] = []
	var template := GSCmdContext.console("", PackedStringArray())
	template.reply_sink = func(text: String) -> void: captured.append(text)
	server.console.execute(line, template)
	return PackedStringArray(captured)


func _said(lines: PackedStringArray, text: String) -> bool:
	for line in lines:
		if line.to_lower().contains(text.to_lower()):
			return true
	return false


func _physics(frames: int) -> void:
	for _i in range(frames):
		await get_tree().physics_frame


## A finished copy of [param run], for asking `can_record` without finishing the real one.

## [method _run_command] for a coroutine handler: the live tools record each action on a
## punishment store, which may be remote, so the reply can land a frame late.
func _run_command_later(line: String) -> PackedStringArray:
	var captured: Array[String] = []
	var template := GSCmdContext.console("", PackedStringArray())
	template.reply_sink = func(text: String) -> void: captured.append(text)
	server.console.execute(line, template)
	await get_tree().process_frame
	await get_tree().process_frame
	return PackedStringArray(captured)
