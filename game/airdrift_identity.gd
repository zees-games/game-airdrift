extends GSPlatformIdentity

const AirdriftAvatars := preload("airdrift_avatars.gd")

## Content, profiles, avatars and admission: gs-platform's [GSPlatformIdentity], over
## this game's avatar schema.
##
## [b]This game already had the avatar half and not the rest.[/b] `AirdriftAvatars` has
## described a schema and six stock parts since it was written, `AirdriftModule._avatar_for`
## has duck-typed its way to a platform module that nothing was loading, and
## `AirdriftRig.dress` has drawn whatever it was handed. What was missing is the thing that
## produces an avatar that is not a stock one, and that is now the shared chain.
##
## [b]The schema is the rig's, not a second one.[/b] `AirdriftRig.dress` conforms every
## document to it, so a manager validating against a different schema would accept
## avatars the rig then silently rewrote.


func _init() -> void:
	avatar_schema = AirdriftAvatars.schema()
	stock_avatar_fn = AirdriftAvatars.stock_avatar
	avatar_translate_fn = AirdriftAvatars.from_site
