extends Node3D

## El agujero / jugador. Se mueve por el plano XZ con teclado o arrastre,
## detecta objetos encima y los traga si son <= su tamaño. Crece por niveles:
## la XP acumulada desbloquea saltos escalonados de radio.

@export var move_speed: float = 8.0
@export var acceleration: float = 24.0    # unidades/s²: qué tan rápido alcanza move_speed
@export var radius: float = 1.0           # radio actual del agujero
@export var camera_zoom_speed: float = 3.0  # suavizado del alejamiento de cámara
@export var camera_zoom_factor: float = 0.15 # 1.0 = alejamiento proporcional al radio; menos = más cerca

# Progresión escalonada: radio por nivel y XP acumulada requerida.
@export var level_radii: Array[float] = [1.0, 1.5, 2.2, 3.2, 4.4, 5.8, 7.4, 9.2]
@export var level_xp_req: Array[int] = [0, 25, 70, 150, 300, 520, 820, 1200]

var xp := 0
var level := 0
var _drag_input: Vector2 = Vector2.ZERO    # input táctil/mouse acumulado
var _velocity: Vector2 = Vector2.ZERO      # velocidad actual en el plano XZ
var _base_radius: float
var _base_camera_offset: Vector3

@onready var visual: MeshInstance3D = $Visual
@onready var detection_area: Area3D = $DetectionArea
@onready var shape: CollisionShape3D = $DetectionArea/CollisionShape3D
@onready var camera: Camera3D = $Camera3D

signal swallowed(xp_gained: int, total_xp: int)
signal leveled_up(new_level: int)

func _ready() -> void:
	radius = level_radii[0]
	_base_radius = radius
	_base_camera_offset = camera.position
	_apply_radius()
	# La cámara es hija del agujero (lo sigue). La orientamos una vez hacia él.
	camera.look_at(global_position, Vector3.UP)

func _physics_process(delta: float) -> void:
	var dir := _get_move_direction()
	# Acelerar hacia la velocidad objetivo (también frena suave al soltar).
	_velocity = _velocity.move_toward(dir * move_speed, acceleration * delta)
	global_position += Vector3(_velocity.x, 0.0, _velocity.y) * delta
	_update_camera(delta)
	_check_swallow()

func _update_camera(delta: float) -> void:
	# El offset base escala con el radio, amortiguado para no alejarse tanto al final.
	var ratio := 1.0 + (radius / _base_radius - 1.0) * camera_zoom_factor
	var target := _base_camera_offset * ratio
	camera.position = camera.position.lerp(target, 1.0 - exp(-camera_zoom_speed * delta))

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
			# La XP NO se otorga acá: el objeto puede escaparse si el agujero
			# se corre. Se acredita vía señal "consumed" al llegar al fondo.
			area.set_meta("being_swallowed", true)
			area.call("be_swallowed", self)
		elif sw_size > radius and dist < radius * 1.1:
			area.call("wobble")  # feedback "todavía no podés"

func gain_xp(amount: int) -> void:
	xp += amount
	emit_signal("swallowed", amount, xp)
	# Subir todos los niveles que la XP alcance (por si un objeto grande salta 2).
	while level + 1 < level_xp_req.size() and xp >= level_xp_req[level + 1]:
		level += 1
		_animate_grow(level_radii[level])
		emit_signal("leveled_up", level)

func _animate_grow(target_r: float) -> void:
	# Crecimiento escalonado con overshoot (pop elástico).
	var t := create_tween()
	t.tween_method(_set_radius, radius, target_r, 0.5) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _set_radius(r: float) -> void:
	radius = r
	_apply_radius()

func _apply_radius() -> void:
	# Escalar el disco visual y el shape de detección.
	visual.scale = Vector3(radius, 1.0, radius)
	if shape.shape is CylinderShape3D:
		(shape.shape as CylinderShape3D).radius = radius
