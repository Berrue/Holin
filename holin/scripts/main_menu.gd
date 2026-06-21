extends Control

## Menú principal: título + botón Jugar que entra a la partida.

const GAME_SCENE := "res://scenes/main.tscn"

@onready var play_button: Button = $Center/VBox/PlayButton

func _ready() -> void:
	play_button.pressed.connect(_on_play)

func _on_play() -> void:
	get_tree().change_scene_to_file(GAME_SCENE)
