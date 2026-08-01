extends Node3D

## Representacion visual (sin fisica ni input) de otro peer.

@onready var visual: Node3D = $Visual
@onready var rim: MeshInstance3D = $Visual/Rim
@onready var name_label: Label3D = $Name

var peer_id := 0
var target_position := Vector3.ZERO
var target_radius := 1.0
var remote_score := 0
var remote_level := 0
var display_name := "Jugador"


func _ready() -> void:
	global_position = target_position
	name_label.text = display_name
	var material := rim.material_override.duplicate() as StandardMaterial3D
	var hue := fmod(float(peer_id) * 0.173, 1.0)
	var color := Color.from_hsv(hue, 0.68, 1.0)
	material.albedo_color = color
	material.emission = color
	rim.material_override = material


func setup(id: int, display_name: String, start_position: Vector3) -> void:
	peer_id = id
	target_position = start_position
	self.display_name = display_name


func push_state(pos: Vector3, radius: float, score: int, level: int) -> void:
	target_position = pos
	target_radius = clampf(radius, 0.8, 12.0)
	remote_score = maxi(score, 0)
	remote_level = maxi(level, 0)
	name_label.text = "%s  Nv.%d  %d pts" % [
		NetworkSession.get_player_name(peer_id), remote_level + 1, remote_score]


func _process(delta: float) -> void:
	var position_weight := 1.0 - exp(-18.0 * delta)
	global_position = global_position.lerp(target_position, position_weight)
	var radius_weight := 1.0 - exp(-8.0 * delta)
	var next_radius := lerpf(visual.scale.x, target_radius, radius_weight)
	visual.scale = Vector3(next_radius, 1.0, next_radius)
