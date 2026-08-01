extends Node

## Sesion multijugador nativa de Godot. Vive como autoload para conservar el
## ENetMultiplayerPeer cuando todos cambian del lobby a la partida.

signal state_changed
signal players_changed
signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
signal connection_error(message: String)

enum Mode { OFFLINE, HOST, CLIENT }

const GAME_SCENE := "res://scenes/main.tscn"
const DEFAULT_PORT := 7000
const MAX_CLIENTS := 1 # Primer corte: host + un cliente.

var mode: Mode = Mode.OFFLINE
var player_name := "Jugador"
var match_seed := 0
var status := "Sin conexion"
var player_names: Dictionary = {}
var _peer: ENetMultiplayerPeer


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func host_game(display_name: String, port: int = DEFAULT_PORT) -> Error:
	disconnect_session()
	player_name = _clean_name(display_name)
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(port, MAX_CLIENTS)
	if err != OK:
		_peer = null
		status = "No se pudo abrir el puerto %d" % port
		connection_error.emit(status)
		state_changed.emit()
		return err
	multiplayer.multiplayer_peer = _peer
	mode = Mode.HOST
	player_names = {1: player_name}
	status = "Lobby creado en el puerto %d" % port
	state_changed.emit()
	players_changed.emit()
	return OK


func join_game(address: String, display_name: String, port: int = DEFAULT_PORT) -> Error:
	disconnect_session()
	player_name = _clean_name(display_name)
	var target := address.strip_edges()
	if target.is_empty():
		target = "127.0.0.1"
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(target, port)
	if err != OK:
		_peer = null
		status = "No se pudo iniciar la conexion"
		connection_error.emit(status)
		state_changed.emit()
		return err
	multiplayer.multiplayer_peer = _peer
	mode = Mode.CLIENT
	player_names.clear()
	status = "Conectando a %s:%d..." % [target, port]
	state_changed.emit()
	players_changed.emit()
	return OK


func begin_match() -> void:
	if mode != Mode.HOST or player_names.size() < 2:
		return
	match_seed = randi()
	_load_match.rpc(match_seed)


func disconnect_session() -> void:
	if _peer != null:
		_peer.close()
	_peer = null
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	mode = Mode.OFFLINE
	match_seed = 0
	player_names.clear()
	status = "Sin conexion"
	state_changed.emit()
	players_changed.emit()


func is_networked() -> bool:
	return mode != Mode.OFFLINE


func is_host() -> bool:
	return mode == Mode.HOST


func get_player_name(peer_id: int) -> String:
	return str(player_names.get(peer_id, "Jugador %d" % peer_id))


func _clean_name(value: String) -> String:
	var cleaned := value.strip_edges().left(18)
	return cleaned if not cleaned.is_empty() else "Jugador"


func _on_peer_connected(peer_id: int) -> void:
	if mode == Mode.HOST:
		player_names[peer_id] = "Conectando..."
		players_changed.emit()
	peer_joined.emit(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	player_names.erase(peer_id)
	if mode == Mode.HOST:
		_sync_players.rpc(player_names)
	players_changed.emit()
	peer_left.emit(peer_id)


func _on_connected_to_server() -> void:
	status = "Conectado. Esperando al host..."
	state_changed.emit()
	_register_player.rpc_id(1, player_name)


func _on_connection_failed() -> void:
	_fail_connection("No se pudo conectar con el host")


func _on_server_disconnected() -> void:
	_fail_connection("El host cerro la partida")


func _fail_connection(message: String) -> void:
	if _peer != null:
		_peer.close()
	_peer = null
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	mode = Mode.OFFLINE
	player_names.clear()
	status = message
	connection_error.emit(message)
	state_changed.emit()
	players_changed.emit()


@rpc("any_peer", "call_remote", "reliable")
func _register_player(display_name: String) -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	player_names[peer_id] = _clean_name(display_name)
	status = "Dos jugadores listos"
	_sync_players.rpc(player_names)
	state_changed.emit()
	players_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _sync_players(roster: Dictionary) -> void:
	player_names = roster.duplicate()
	players_changed.emit()


@rpc("authority", "call_local", "reliable")
func _load_match(seed_value: int) -> void:
	match_seed = seed_value
	status = "Partida en curso"
	state_changed.emit()
	get_tree().change_scene_to_file(GAME_SCENE)
