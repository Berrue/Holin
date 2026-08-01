extends SceneTree

## Probe de integracion: se ejecuta en dos procesos con --probe-host / --probe-client.

const TIMEOUT := 30.0

var role := ""
var session: Node
var elapsed := 0.0
var session_started := false
var local_position_applied := false
var game_elapsed := 0.0
var validated := false


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--probe-host":
			role = "host"
		elif arg == "--probe-client":
			role = "client"
	if role.is_empty():
		printerr("NETWORK_PROBE_FAIL missing role")
		quit(2)


func _process(delta: float) -> bool:
	elapsed += delta
	if elapsed >= TIMEOUT:
		printerr("NETWORK_PROBE_FAIL timeout role=%s" % role)
		quit(3)
		return true
	if session == null:
		session = root.get_node_or_null("NetworkSession")
		if session == null:
			return false
	if not session_started:
		session_started = true
		if role == "host":
			var err: Error = session.host_game("Probe Host")
			if err != OK:
				printerr("NETWORK_PROBE_FAIL host error=%d" % err)
				quit(4)
		else:
			var err: Error = session.join_game("127.0.0.1", "Probe Client")
			if err != OK:
				printerr("NETWORK_PROBE_FAIL client error=%d" % err)
				quit(5)
		return false
	if role == "host" and session.player_names.size() == 2 and current_scene == null:
		session.begin_match()
	if current_scene == null or current_scene.name != "Main":
		return false
	game_elapsed += delta
	if not local_position_applied:
		local_position_applied = true
		var local_x := -10.0 if role == "host" else 10.0
		current_scene.get_node("Hole").global_position = Vector3(local_x, 0.0, 32.0)
	if validated:
		if game_elapsed >= 6.0:
			session.disconnect_session()
			quit(0)
			return true
		return false
	if game_elapsed < 3.0:
		return false
	var remotes := current_scene.get_node("RemotePlayers")
	if remotes.get_child_count() != 1:
		printerr("NETWORK_PROBE_FAIL role=%s remote_count=%d" % [role, remotes.get_child_count()])
		quit(6)
		return true
	var remote := remotes.get_child(0)
	var expected_x := 10.0 if role == "host" else -10.0
	if absf(remote.target_position.x - expected_x) > 0.75:
		printerr("NETWORK_PROBE_FAIL role=%s remote_x=%.2f expected=%.2f" % [
			role, remote.target_position.x, expected_x])
		quit(7)
		return true
	print("NETWORK_PROBE_OK role=%s local_peer=%d remote_count=1 remote_x=%.2f roster=%d" % [
		role, session.multiplayer.get_unique_id(), remote.target_position.x, session.player_names.size()])
	validated = true
	return false
