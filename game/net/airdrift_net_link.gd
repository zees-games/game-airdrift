extends GSGameNetLink

const AirdriftNetLink := preload("airdrift_net_link.gd")

## This game's link: the shared skeleton in [GSGameNetLink] (snapshot, event, input and request
## calls, the counters, the loopback seam, the perf network table) plus what is its own: voice with
## a separate client-to-server frame call, whose server-to-client receiver takes no sender.
##
## Godot refuses an RPC unless both ends declare the same set of `@rpc` methods and routes it by
## node path. One script on both ends makes the set identical by construction; the node is named
## [constant NODE_NAME] on both, under a parent named the same ([GSServer] and [GSClientLink],
## both `Server`).
##
## Voice rides [constant GSGameNetLink.CHANNEL_VOICE], apart from the snapshots, so a talk spurt
## never delays movement on a server where a run is counted in ticks. The calls are declared
## `unreliable`; what that becomes on the wire (UDP on a desktop, TCP in a browser) is the
## transport's decision, and this file names neither.

const CHANNEL := "g2g.link"

## The node name both ends must use. It is the routing, so it is a constant.
const NODE_NAME := &"G2G"


func _init() -> void:
	channel = CHANNEL


## Builds the link; the caller places it (see [GSGameLink.attach]).
static func attached_to(_parent: Node, p_bridge: Node, server: bool) -> AirdriftNetLink:
	var link := AirdriftNetLink.new()
	link.bridge = p_bridge
	link.is_server = server
	return link


## One encoded voice frame, server to one listener.
##
## [b]Never a broadcast.[/b] [GSVoiceRouter] decides who hears a speaker, and a `send(bytes, 0)`
## convention here would quietly deliver a proximity packet to the whole server.
func send_voice(peer_id: int, payload: PackedByteArray) -> void:
	if peer_id <= 0 or not _live():
		return

	voice_sent += 1
	_cost(&"voice", 1, payload)

	if loopback.is_valid():
		loopback.call(&"voice", peer_id, payload)
	else:
		_net_voice.rpc_id(peer_id, payload)


## One captured voice frame, client to server.
func send_voice_frame(payload: PackedByteArray) -> void:
	if not _live():
		return

	voice_sent += 1
	_cost(&"voice", 1, payload)

	if loopback.is_valid():
		loopback.call(&"voice_frame", 1, payload)
	else:
		_net_voice_frame.rpc_id(1, payload)


## A relayed voice frame. Unreliable: a lost frame is 20 ms of silence a jitter buffer conceals.
@rpc("authority", "unreliable", "call_remote", CHANNEL_VOICE)
func _net_voice(payload: PackedByteArray) -> void:
	voice_received += 1
	_cost(&"voice", 0, payload)

	if bridge != null:
		bridge.receive_voice(payload)


## A client's captured audio. The speaker is stamped by the server from the transport's sender,
## never read out of the payload.
@rpc("any_peer", "unreliable", "call_remote", CHANNEL_VOICE)
func _net_voice_frame(payload: PackedByteArray) -> void:
	voice_received += 1
	_cost(&"voice", 0, payload)

	if bridge != null:
		bridge.receive_voice_frame(multiplayer.get_remote_sender_id(), payload)


## The voice kinds this game routes itself; every other kind goes through [method GSGameNetLink.deliver].
func deliver(method: StringName, from_peer_id: int, payload: PackedByteArray) -> void:
	match method:
		&"voice":
			if bridge != null:
				voice_received += 1
				_cost(&"voice", 0, payload)
				bridge.receive_voice(payload)
		&"voice_frame":
			if bridge != null:
				voice_received += 1
				_cost(&"voice", 0, payload)
				bridge.receive_voice_frame(from_peer_id, payload)
		_:
			super.deliver(method, from_peer_id, payload)
