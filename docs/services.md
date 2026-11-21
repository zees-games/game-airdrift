# Services: moderation, chat, voice, the vote, the browser, identity

`AirdriftServices` builds gs-chat, gs-voice and gs-moderation on a dedicated server; `AirdriftIdentity` joins gs-cloud, gs-auth, gs-user and gs-platform; `AirdriftVote` is gs-vote over the map catalogue; `AirdriftBrowser` is gs-browser's client half; `AirdriftQuery` is what a browser is told. The rule each was added under: **a player who came to run must not be stopped by anything added for a player who came to do something else.**

## An admin's live tools

gs-moderation's live tools are here (`AirdriftModTools`, built in `AirdriftServices`, commands on the module). **No admin tool can help a run**: the taint rules are in [timer.md](timer.md#what-taints-a-run).

- **Health, weapons and god mode exist only while `sv_deathmatch` is on**, so god, buddha, hp, slay, give and strip answer "not running its deathmatch" rather than being absent: whether they mean anything is a cvar, not a build.
- **Blind and beacon are two replicated flags** (`AirdriftPlayer.blinded`, `AirdriftPlayer.beacon`, in `AirdriftPlayerNet` after the movement specs). **`net_blind` is owner-only**: nobody else's screen changes, and an opponent on the deathmatch layer who could read it would know when to go and find somebody. `net_beacon` goes to everybody. State rather than an event, so a joiner, a lost snapshot and a map change are corrected by the next snapshot. `GSFxBeacon` (gs-fx, ping off: the game plays its own through gs-audio) is a ring and a once-a-second ripple sized to this game's 32-unit hull, and a column through walls the beaconed player's own camera does not draw.
- Three differences from game-fatal-contact's version, on purpose: **neither taints a run**; **nothing re-applies them on a respawn**, because a respawn here is `AirdriftGame.spawn_player`, a teleport of the same node, so the flags stay (this game never calls `GSModTools.respawned`, so adding them to `persist_on_respawn` would be a setting nothing reads); and **a beacon changes no relevance**. Every player entity is already `always_relevant` (`AirdriftNetBridge._build_entity`); FC's `always_relevant = beacon` here would CUT every runner the moment their beacon went off.

## Chat is the policy; gs-server stays the transport

`AirdriftServices` hooks `player_chat` and **cancels** it, routes the text through `GSChatRouter`, and hands each recipient's line back to gs-server's manager for the wire. Exactly one of the two delivers a line. On the client a line arrives on `GSClientLink.chat_received` and `AirdriftClientExtras.receive_line` feeds `GSChatClient`.

- **It hooks `player_command` as well.** gs-server's chat manager checks for a command prefix before it fires `player_chat`, and its prefixes are `["!", "/"]`, the same as `GSChatRules`', so without the hook no `!` line reaches the router: `!spec` once did nothing at all. A new `!` command must be handled by the router path or be a console command registered `.with_chat()`.
- **The `running` channel** is everybody mid-run: a `MEMBERS` channel whose rule ("their timer is going") only this game knows, which is why gs-chat asks rather than deciding. The team key falls back to it, because a timer server has no teams.
- **gs-moderation is built first, and the order is load-bearing.** It publishes `gs_mute_source` on `_ready` and both routers look that name up when they start; a router that started first enforces no gag for the life of the server.
- **`airdrift_map` carries `CHANGEMAP` and is reachable from chat.** The permission flag is what answers, not chat being disabled for the command: a chat block runs before the permission check and never asks who is typing, so it only ever stopped the operator who holds the flag. `sv_chat_commands 0` turns chat commands off server-wide, and `allow_chat_change = false` on the gs-map block turns off the map change alone.

## Voice

**Voice rides its own channel on the link.** A talk spurt is fifty frames a second per speaker relayed to every listener; on the state channel it would queue with the snapshots, and on a server where a run is counted in ticks, latency must not depend on whether anybody is talking. **The speaker id is stamped from the transport's sender, never read from the payload.** The two voice calls are declared `unreliable`: a lost frame is 20 ms a jitter buffer conceals, and a resent one arrives after its neighbours played. What that becomes on the wire is the transport's decision (UDP on ENet, reliable TCP on a browser's WebSocket); the game names no transport.

The default voice channel is **ALL**, the opposite of game-fatal-contact's, and both are right: an arena is a room, and a course is long and thin with half the server two hundred metres away.

## The vote

`AirdriftVote` is the ballot a records community runs: nominations with caps and seconding, an instant runoff (so a six-option vote is not won by a fifth of the server), a cooldown, and an **extend** option, because a player two stages into a run they have been learning for an hour should not lose the map to a clock.

- **One rock-the-vote.** `AirdriftVote.install_commands` puts `GSVoteCommands` on the module (`vote` keeps its name so `!vote 2` works); `airdrift_rtv` and a client's `Ask.RTV` (`AirdriftNetBridge.rtv_fn`) go to the ballot. The chat handler claims `!rtv` and `!vote` only when the vote failed to load. Without a vote, `rtv` is the map session's tally, which is then the only one.
- **`begin_on_apply` is off.** The map session's own `changed` is the one signal that says what is running (it fires for an admin's `airdrift_map` too); both firing means two play-history entries for one play.
- **The map session's clock does not end a map when there is a vote** (`AirdriftGame.rotation_ends_maps` off once the module has a ballot); otherwise a map voted to extend was ended on the old clock.
- **Every screen's time left is the vote's clock.** `AirdriftVote.advance` keeps a `GSVoteClockView` of what clients believe and emits `clock_due` only when it is stale (an extend, a new map, a clock stopped for a ballot), so a quiet map sends nothing; the module sends it as `CLOCK`, and a joiner is told in `_admit` (`AirdriftNetBridge.clock_fn`). `airdrift_status` reads it through `AirdriftGame.clock_fn = vote.clock_state` (`time_left_text()`: `m:ss`, `(stopped)`, or `no limit` in words, because a status line is read when somebody asks and a missing row reads as a diagnostic that forgot). A server with no vote keeps the session's.
- **The vote's cues reach the client** (`cue_due`, sent as `VOTE`), on voices the run does not use and below the timer's sounds. No countdown before a ballot: a runner is not in a fight.
- **The ballot is drawn by the client shell**: the module points the ballot feed's `ballot_fn` at `server.send_notice`, one copy per playing session with that voter as `you`, topic `map_ballot`; a click comes back as the same command a player could type. Standalone, chat carries the ballot.
- A timer server has no rounds and no leading score: `time_up` changes on time either way, and nothing calls `note_score`.

## The server browser, from the other end

`AirdriftQuery` contributes the map, tick rate, styles and world record; `AirdriftBrowser` is gs-browser's client half (list model, three protocols, filters, favourites, history), and `dedicated` has a real browser ask a real `GSServer` over a real UDP socket.

- **The map is not `entry.map`**: that is gs-server's `info.map`, the content id of the loaded game. A game's own section is under `rules["game"]` precisely so a field called `map` there cannot overwrite it.
- **JSON has one number type**: `tick_rate` comes back as a float; `game_number` is the accessor, and `wr` (a dictionary) has a third.
- **The list is a chat command** (`!servers`, or F3), because that is what this genre's fingers do and this client has a HUD rather than a screen stack. game-fatal-contact has the screen.

## Identity and platform

gs-platform's module holds each authenticated player in gs-server's PROFILE signon stage while the hub admits them, so a player is normally seated already resolved. Admission can still finish after the spawn (an optional player let in after `admission_timeout_sec`, or a session the module first hears of past the stage), so `AirdriftModule._avatar_for` falls through to `AirdriftIdentity.avatar_for`, which falls through to the stock document. gs-platform `docs/design.md` has the stage.

## Statistics and achievements

`AirdriftStats` declares every per-player number once; `AirdriftAwards` are achievements as rules over those ids; `AirdriftProgress` joins them to the runs. How they are counted is in [timer.md](timer.md#statistics-are-read-not-counted-a-second-time). `!stats` is the door to the derived figures.
