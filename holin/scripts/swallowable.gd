extends Area3D

## Objeto que el agujero puede tragar. Raíz Area3D para que el agujero
## lo detecte por solapamiento, sin física pesada.

@export var swallow_size: float = 1.0

func _ready() -> void:
	add_to_group("swallowable")

func be_swallowed(hole_center: Vector3) -> void:
	# Animación de succión: caer hacia el centro + bajar + encoger + rotar.
	var tween := create_tween().set_parallel(true)
	var target := Vector3(hole_center.x, hole_center.y - 1.5, hole_center.z)
	tween.tween_property(self, "global_position", target, 0.35).set_ease(Tween.EASE_IN)
	tween.tween_property(self, "scale", Vector3.ZERO, 0.35).set_ease(Tween.EASE_IN)
	tween.tween_property(self, "rotation", rotation + Vector3(0, TAU, 0), 0.35)
	tween.chain().tween_callback(queue_free)

func wobble() -> void:
	# Pequeño feedback de "todavía no entrás".
	if has_meta("wobbling"):
		return
	set_meta("wobbling", true)
	var base := position
	var t := create_tween()
	t.tween_property(self, "position", base + Vector3(0.05, 0, 0), 0.04)
	t.tween_property(self, "position", base - Vector3(0.05, 0, 0), 0.04)
	t.tween_property(self, "position", base, 0.04)
	t.tween_callback(func(): remove_meta("wobbling"))
