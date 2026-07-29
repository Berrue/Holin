extends Node3D

## El agujero / jugador. Se mueve por el plano XZ con teclado o arrastre y crece
## por niveles: la XP acumulada desbloquea saltos escalonados de radio.
##
## No "traga" objetos a mano: lo que hace es llevar consigo el SUELO. El nodo
## Ground es una malla anillo (de radius hacia afuera) con las paredes del pozo
## colgando hacia abajo, y viaja pegado al agujero. Entonces cualquier objeto
## dinámico que quede sobre la boca simplemente se queda sin piso y se cae solo,
## con la física real decidiendo si se vuelca, si engancha en el borde o si se
## traba contra otro objeto. Lo mismo hace el shader del piso, que descarta los
## fragmentos de adentro del radio para que se vea el pozo.

# Tipo por preload en vez de class_name: la caché de clases globales vive en
# .godot/ (ignorada por git) y sin ella el proyecto no arranca fuera del editor.
const SwallowableRef = preload("res://scripts/swallowable.gd")

@export var move_speed: float = 8.0
@export var acceleration: float = 24.0    # unidades/s²: qué tan rápido alcanza move_speed
@export var radius: float = 1.0           # radio actual del agujero
@export var camera_zoom_speed: float = 3.0  # suavizado del alejamiento de cámara
@export var camera_zoom_factor: float = 0.15 # 1.0 = alejamiento proporcional al radio; menos = más cerca

# Progresión escalonada: radio por nivel y XP acumulada requerida.
@export var level_radii: Array[float] = [1.0, 1.5, 2.2, 3.2, 4.4, 5.8, 7.4, 9.2]
@export var level_xp_req: Array[int] = [0, 25, 70, 150, 300, 520, 820, 1200]

const SHAFT_DEPTH := 9.0        # alto de las paredes del pozo (debe coincidir con el shader)
const SHAFT_TAPER := 0.78       # el pozo se afina hacia el fondo (idem malla visual)
const GROUND_OUTER := 160.0     # radio del anillo de suelo: tapa todo el mapa desde donde esté
const GROUND_SEGMENTS := 40
const SHAPE_EPSILON := 0.05     # cuánto tiene que cambiar el radio para rehacer la colisión
const WAKE_FACTOR := 2.3        # radio de "despertar" objetos, en radios de agujero
const WAKE_EXTRA := 1.8
const FIT_MARGIN := 1.02        # tolerancia de tamaño para dejar suelto un objeto

var xp := 0
var level := 0
var _drag_input: Vector2 = Vector2.ZERO    # input táctil/mouse acumulado
var _velocity: Vector2 = Vector2.ZERO      # velocidad actual en el plano XZ
var _base_radius: float
var _base_camera_offset: Vector3
var _shape_radius := -1.0                  # radio con el que se generó la malla de colisión

@onready var visual: Node3D = $Visual
@onready var rim: MeshInstance3D = $Rim
@onready var detection_area: Area3D = $DetectionArea
@onready var shape: CollisionShape3D = $DetectionArea/CollisionShape3D
@onready var ground_shape: CollisionShape3D = $Ground/CollisionShape3D
@onready var camera: Camera3D = $Camera3D

signal swallowed(xp_gained: int, total_xp: int)
signal leveled_up(new_level: int)

func _ready() -> void:
	radius = level_radii[0]
	_base_radius = radius
	_base_camera_offset = camera.position
	_apply_radius()
	_publish_hole_uniforms()
	# La cámara es hija del agujero (lo sigue). La orientamos una vez hacia él.
	camera.look_at(global_position, Vector3.UP)

func _physics_process(delta: float) -> void:
	var dir := _get_move_direction()
	# Acelerar hacia la velocidad objetivo (también frena suave al soltar).
	_velocity = _velocity.move_toward(dir * move_speed, acceleration * delta)
	global_position += Vector3(_velocity.x, 0.0, _velocity.y) * delta
	_publish_hole_uniforms()
	_update_camera(delta)
	_check_swallow()

func _publish_hole_uniforms() -> void:
	# El piso recorta su propio agujero en el shader: necesita saber dónde está.
	RenderingServer.global_shader_parameter_set(&"hole_position", global_position)
	RenderingServer.global_shader_parameter_set(&"hole_radius", radius)

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
	# Teclas de debug: 1 achica un nivel, 2 agranda un nivel.
	if event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_1:
				debug_step_level(-1)
				return
			KEY_2:
				debug_step_level(1)
				return
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
	# Acá no se traga nada: sólo se avisa. Lo que entra por tamaño se suelta como
	# cuerpo dinámico y la física resuelve el resto; lo que no entra, tiembla.
	for body in detection_area.get_overlapping_bodies():
		var obj := body as SwallowableRef
		if obj == null:
			continue
		var sw := obj.swallow_size
		var dist := Vector2(global_position.x - obj.global_position.x,
			global_position.z - obj.global_position.z).length()
		if sw <= radius * FIT_MARGIN:
			obj.hole_nearby(self, dist)
		elif dist < radius + sw * 0.5:
			obj.wobble()  # feedback "todavía no podés"

func debug_step_level(step: int) -> void:
	# Salta de nivel a mano, para probar sin tener que comerse media ciudad.
	# Mueve también la XP al piso del nivel nuevo: si no, al achicar quedaría
	# XP de sobra y el próximo bocado volvería a subir de nivel al instante.
	var target := clampi(level + step, 0, level_radii.size() - 1)
	if target == level:
		return
	level = target
	xp = level_xp_req[level]
	_animate_grow(level_radii[level])
	emit_signal("leveled_up", level)

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
	visual.scale = Vector3(radius, 1.0, radius)
	rim.scale = Vector3(radius, 0.6 + radius * 0.3, radius)
	if shape.shape is CylinderShape3D:
		(shape.shape as CylinderShape3D).radius = radius * WAKE_FACTOR + WAKE_EXTRA
	# La boca física se rehace sólo cuando el radio cambió lo suficiente: durante
	# el tween de crecimiento no hace falta regenerar la malla en cada frame.
	if absf(radius - _shape_radius) > SHAPE_EPSILON:
		_rebuild_ground_shape()

func _rebuild_ground_shape() -> void:
	# Anillo de piso (de radius a GROUND_OUTER) + pared cónica del pozo colgando
	# hacia abajo, todo en una sola malla de colisión que viaja con el agujero.
	_shape_radius = radius
	var faces := PackedVector3Array()
	var bottom_r := radius * SHAFT_TAPER
	var down := Vector3(0.0, SHAFT_DEPTH, 0.0)
	for i in GROUND_SEGMENTS:
		var a0 := TAU * float(i) / float(GROUND_SEGMENTS)
		var a1 := TAU * float(i + 1) / float(GROUND_SEGMENTS)
		var c0 := Vector3(cos(a0), 0.0, sin(a0))
		var c1 := Vector3(cos(a1), 0.0, sin(a1))
		var in0 := c0 * radius
		var in1 := c1 * radius
		var out0 := c0 * GROUND_OUTER
		var out1 := c1 * GROUND_OUTER
		var bot0 := c0 * bottom_r - down
		var bot1 := c1 * bottom_r - down
		faces.append_array([in0, out1, out0, in0, in1, out1])   # piso, normal hacia arriba
		faces.append_array([in0, bot0, bot1, in0, bot1, in1])   # pared, normal hacia adentro
	var sh := ConcavePolygonShape3D.new()
	sh.backface_collision = true  # que nada se escape por el lado equivocado
	sh.set_faces(faces)
	ground_shape.shape = sh
