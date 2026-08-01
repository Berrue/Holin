extends Node

## Repone el trafico que desaparece durante la partida.
## Los intervalos y topes se editan desde el Inspector del nodo TrafficSpawner.

signal car_spawn_requested
signal npc_spawn_requested

@export_category("Autos")
@export var spawn_cars := true
@export_range(0.1, 60.0, 0.1, "suffix:s") var car_spawn_interval := 4.0
@export_range(0, 512, 1) var max_cars := 72

@export_category("NPCs")
@export var spawn_npcs := true
@export_range(0.1, 60.0, 0.1, "suffix:s") var npc_spawn_interval := 2.0
@export_range(0, 512, 1) var max_npcs := 128

var _car_time := 0.0
var _npc_time := 0.0


func _process(delta: float) -> void:
	if spawn_cars:
		_car_time += delta
		if _car_time >= car_spawn_interval:
			_car_time = fmod(_car_time, car_spawn_interval)
			if get_tree().get_node_count_in_group(&"car") < max_cars:
				car_spawn_requested.emit()
	else:
		_car_time = 0.0

	if spawn_npcs:
		_npc_time += delta
		if _npc_time >= npc_spawn_interval:
			_npc_time = fmod(_npc_time, npc_spawn_interval)
			if get_tree().get_node_count_in_group(&"pedestrian") < max_npcs:
				npc_spawn_requested.emit()
	else:
		_npc_time = 0.0
