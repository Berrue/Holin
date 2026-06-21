extends Node3D

## El agujero / jugador. Se mueve por el plano XZ con teclado o arrastre,
## detecta objetos encima y los traga si son <= su tamaño, creciendo.

@export var move_speed: float = 8.0
@export var radius: float = 1.0           # radio actual del agujero
@export var growth_per_unit: float = 0.05 # cuánto crece el radio por unidad de masa

var mass: float = 0.0
var _drag_input: Vector2 = Vector2.ZERO    # input táctil/mouse acumulado

@onready var visual: MeshInstance3D = $Visual
@onready var detection_area: Area3D = $DetectionArea
@onready var shape: CollisionShape3D = $DetectionArea/CollisionShape3D
@onready var camera: Camera3D = $Camera3D

signal swallowed(amount: float, total_mass: float)

func _ready() -> void:
	_apply_radius()
	# La cámara es hija del agujero (lo sigue). La orientamos una vez hacia él.
	camera.look_at(global_position, Vector3.UP)

func _physics_process(delta: float) -> void:
	var dir := _get_move_direction()
	# Mover en el plano XZ.
	global_position += Vector3(dir.x, 0.0, dir.y) * move_speed * delta
	_check_swallow()

func _get_move_direction() -> Vector2:
	# Teclado (desktop) + input táctil/mouse (arrastre).
	var kb := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if kb != Vector2.ZERO:
		return kb
	if _drag_input != Vector2.ZERO:
		return _drag_input.normalized()
	return Vector2.ZERO

func _input(event: InputEvent) -> void:
	# Arrastrar dedo (móvil) o mouse (desktop) define la dirección.
	if event is InputEventScreenDrag:
		_drag_input = event.relative
	elif event is InputEventScreenTouch and not event.pressed:
		_drag_input = Vector2.ZERO
	elif event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_drag_input = event.relative
	elif event is InputEventMouseButton and not event.pressed:
		_drag_input = Vector2.ZERO

func _check_swallow() -> void:
	for area in detection_area.get_overlapping_areas():
		if not area.is_in_group("swallowable"):
			continue
		if area.has_meta("being_swallowed"):
			continue
		var sw_size: float = area.get("swallow_size")
		# Distancia horizontal centro-agujero <-> centro-objeto.
		var hpos := Vector2(global_position.x, global_position.z)
		var opos := Vector2(area.global_position.x, area.global_position.z)
		var dist := hpos.distance_to(opos)
		if sw_size <= radius and dist < radius * 0.9:
			area.set_meta("being_swallowed", true)
			area.call("be_swallowed", global_position)
			_grow(sw_size)
		elif sw_size > radius and dist < radius * 1.1:
			area.call("wobble")  # feedback "todavía no podés"

func _grow(amount: float) -> void:
	mass += amount
	radius += amount * growth_per_unit
	_apply_radius()
	emit_signal("swallowed", amount, mass)

func _apply_radius() -> void:
	# Escalar el disco visual y el shape de detección.
	visual.scale = Vector3(radius, 1.0, radius)
	if shape.shape is CylinderShape3D:
		(shape.shape as CylinderShape3D).radius = radius
