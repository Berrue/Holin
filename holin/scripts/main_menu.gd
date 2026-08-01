extends Control

## Menu principal y lobby minimo para una partida ENet host + cliente.

const GAME_SCENE := "res://scenes/main.tscn"

@onready var name_edit: LineEdit = $Center/VBox/NameEdit
@onready var address_edit: LineEdit = $Center/VBox/AddressEdit
@onready var offline_button: Button = $Center/VBox/OfflineButton
@onready var host_button: Button = $Center/VBox/NetworkRow/HostButton
@onready var join_button: Button = $Center/VBox/NetworkRow/JoinButton
@onready var start_button: Button = $Center/VBox/StartButton
@onready var cancel_button: Button = $Center/VBox/CancelButton
@onready var status_label: Label = $Center/VBox/Status
@onready var players_label: Label = $Center/VBox/Players


func _ready() -> void:
	offline_button.pressed.connect(_on_offline)
	host_button.pressed.connect(_on_host)
	join_button.pressed.connect(_on_join)
	start_button.pressed.connect(_on_start)
	cancel_button.pressed.connect(_on_cancel)
	NetworkSession.state_changed.connect(_refresh)
	NetworkSession.players_changed.connect(_refresh)
	NetworkSession.connection_error.connect(_on_connection_error)
	_refresh()


func _on_offline() -> void:
	NetworkSession.disconnect_session()
	get_tree().change_scene_to_file(GAME_SCENE)


func _on_host() -> void:
	NetworkSession.host_game(name_edit.text)
	_refresh()


func _on_join() -> void:
	NetworkSession.join_game(address_edit.text, name_edit.text)
	_refresh()


func _on_start() -> void:
	NetworkSession.begin_match()


func _on_cancel() -> void:
	NetworkSession.disconnect_session()
	_refresh()


func _on_connection_error(message: String) -> void:
	status_label.text = message


func _refresh() -> void:
	var active := NetworkSession.is_networked()
	var host := NetworkSession.is_host()
	name_edit.editable = not active
	address_edit.editable = not active
	offline_button.disabled = active
	host_button.disabled = active
	join_button.disabled = active
	cancel_button.visible = active
	start_button.visible = host
	start_button.disabled = NetworkSession.player_names.size() < 2
	status_label.text = NetworkSession.status
	players_label.visible = active
	if active:
		var names: Array[String] = []
		for peer_id in NetworkSession.player_names:
			names.append(NetworkSession.get_player_name(int(peer_id)))
		players_label.text = "Jugadores (%d/2): %s" % [names.size(), ", ".join(names)]
