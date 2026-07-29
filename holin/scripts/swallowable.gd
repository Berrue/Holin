extends RigidBody3D

## Objeto que el agujero puede tragar. Es un rígido de verdad, no una animación:
## mientras la ciudad está intacta vive congelado (el motor lo trata como cuerpo
## estático y no cuesta casi nada) y recién se suelta cuando el agujero se le
## acerca. Desde ahí manda la física: se apoya en el anillo de suelo que rodea
## la boca, se vuelca solo al perder apoyo, choca contra los demás objetos y
## contra las paredes del pozo. Por eso las cosas grandes se traban en el borde
## y bajan a los tumbos en vez de entrar de una: nadie teletransporta nada.
##
## Tres modos de vida antes de la caída: estático (edificios, árboles, props),
## auto (recorre su calle frenando ante el agujero y ante el auto de adelante) y
## peatón (camina por la vereda y huye del agujero). Los dos móviles andan como
## cuerpos congelados-cinemáticos y sólo se sueltan al quedar sobre la boca.

const Sfx = preload("res://scripts/sfx.gd")

@export var swallow_size: float = 1.0
@export var xp_value: int = 1
@export var sfx_kind: int = Sfx.Kind.NONE  # qué se escucha cuando cae
## En cuántos pedazos se parte al derrumbarse. 1 = cae entero.
@export var break_pieces: int = 1
## Cuánto pesa este objeto para el golpe (shake/hitstop). Los pedazos de un
## edificio traen una fracción: si no, un derrumbe de tres partes sacudiría tres
## veces con la fuerza del edificio completo.
@export var impact_weight: float = 1.0

## Tamaño real en el mundo, medido al armar el cuerpo. Lo necesita quien lo parta.
var world_size := Vector3.ONE

signal consumed(xp: int)
## Cruzó la boca del pozo: el instante del golpe (shake + hitstop). Va aparte de
## `consumed`, que llega recién al fondo, medio segundo tarde para el feedback.
signal fell_in(size: float, at: Vector3, weight: float)
## Pide que lo reemplacen por pedazos. Lo atiende main.gd, que es la fábrica de
## swallowables: desde acá no hay con qué conectarle las señales a las piezas ni
## cómo repartirles la XP.
signal wants_break(obj)

enum Mode { STATIC, CAR, PEDESTRIAN }

const KILL_DEPTH := 6.5         # profundidad a la que se consume y se otorga la XP
const NO_COLLIDE_DEPTH := -4.0  # más abajo deja de chocar: nada se traba en el fondo
const SFX_TRIGGER_Y := -0.15    # y a la que suena: recién cuando cruza el borde
const SHRINK_START := -1.0      # y desde la que empieza a achicarse (succión)
const SHRINK_END := -5.2
const FUNNEL_ACCEL := 16.0      # succión hacia el eje del pozo, en m/s²
const FALL_TRIGGER := 0.8       # un móvil se suelta cuando el pozo lo tapa tanto
const CAR_BRAKE_DIST := 6.0     # distancia a la que un auto frena por el agujero
const CAR_FOLLOW_DIST := 2.6    # distancia mínima con el auto de adelante
const PED_FLEE_SPEED := 2.6
const BREAK_TILT := 0.88        # coseno del vuelco que parte al edificio (~28°)
const BREAK_DEPTH := -0.35      # o cuando la base ya bajó del nivel de la calle

var _mode := Mode.STATIC
var _hole = null                # el agujero; sin tipar para no ciclar con Hole
var _dynamic := false           # ya se soltó: la física tiene el control
var _eaten := false
var _crossed := false           # ya cruzó la boca: sonido y golpe ya disparados
var _broke := false             # ya pidió romperse: que no lo pida dos veces
var _visual: Node3D
var _base_visual_scale := Vector3.ONE
# Auto.
var _drive_dir := Vector3.ZERO
var _drive_speed := 0.0
var _cur_speed := 0.0
var _map_half := 36.0
# Peatón.
var _walk_dir := Vector3.ZERO
var _walk_speed := 0.8
var _cur_walk_speed := 0.0
var _walk_timer := 0.0
var _bob_t := 0.0
var _base_y := 0.0

func _ready() -> void:
	add_to_group("swallowable")
	_visual = $Visual
	_base_visual_scale = _visual.scale
	freeze = true
	freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	set_physics_process(false)

func setup_body(size: Vector3) -> void:
	# Caja de colisión del tamaño real del modelo, apoyada en el piso.
	world_size = size
	var col := $CollisionShape3D as CollisionShape3D
	var box: BoxShape3D = (col.shape as BoxShape3D).duplicate()  # no tocar la compartida
	box.size = Vector3(maxf(size.x, 0.2), maxf(size.y, 0.2), maxf(size.z, 0.2))
	col.shape = box
	col.position.y = box.size.y * 0.5
	# Masa según el porte: un rascacielos no lo mueve un arbusto.
	mass = clampf(pow(swallow_size, 2.2) * 3.0, 0.4, 140.0)
	# Centro de masa un poco abajo del geométrico: las torres no se caen solas
	# por cualquier roce, pero igual se vuelcan cuando pierden medio apoyo.
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, box.size.y * 0.4, 0.0)

func start_driving(dir: Vector3, speed: float, map_half: float, hole) -> void:
	_mode = Mode.CAR
	_drive_dir = dir
	_drive_speed = speed
	_cur_speed = speed
	_map_half = map_half
	_hole = hole
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	add_to_group("car")
	set_physics_process(true)

func start_walking(dir: Vector3, map_half: float, hole) -> void:
	_mode = Mode.PEDESTRIAN
	_walk_dir = dir
	_cur_walk_speed = _walk_speed
	_map_half = map_half
	_hole = hole
	_walk_timer = randf_range(2.0, 5.0)
	_base_y = position.y
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	add_to_group("pedestrian")
	set_physics_process(true)

# ----------------------------------------------------------------------------
# Aviso del agujero
# ----------------------------------------------------------------------------

func hole_nearby(hole, dist: float) -> void:
	# El agujero avisa que está cerca y que este objeto entra por tamaño.
	_hole = hole
	if not _dynamic:
		# Lo estático se suelta ya, para poder apoyarse y volcarse como
		# corresponde; lo móvil sigue su ruta hasta quedar sobre la boca.
		if _mode == Mode.STATIC or dist < hole.radius * FALL_TRIGGER:
			_go_dynamic()
	elif sleeping and dist < hole.radius * 2.0:
		# El piso se le va a mover por abajo: no lo dejamos dormido o quedaría
		# flotando sobre el vacío hasta que algo lo toque.
		sleeping = false

func suck_by_rival(center: Node3D) -> bool:
	# Succión "de mentira", para los rivales. Ellos no abren un pozo real —ver el
	# encabezado de rival_hole.gd—, así que la física no tiene de dónde agarrarse
	# y la caída va por tween: baja, se encoge y desaparece. Es el método que este
	# proyecto usaba para todo antes de que el agujero del jugador se llevara el
	# suelo consigo.
	#
	# Devuelve si efectivamente se lo comió, para que el rival no se acredite XP
	# de algo que ya se estaba tragando otro.
	if _eaten:
		return false
	_eaten = true
	set_physics_process(false)
	freeze = true
	collision_layer = 0
	collision_mask = 0
	remove_from_group("swallowable")
	var dest := Vector3(center.global_position.x, global_position.y - 2.5, center.global_position.z)
	var t := create_tween().set_parallel(true)
	t.tween_property(self, "global_position", dest, 0.35).set_ease(Tween.EASE_IN)
	t.tween_property(_visual, "scale", Vector3.ZERO, 0.35)
	t.tween_property(self, "rotation:y", rotation.y + randf_range(-2.0, 2.0), 0.35)
	t.chain().tween_callback(queue_free)
	return true

func release_into(hole) -> void:
	# Suelta el cuerpo ya, sin esperar a que el agujero lo detecte por área. Lo
	# usan los pedazos de un edificio: nacen con el piso ya abierto abajo, y el
	# frame que tardarían en ser detectados los deja colgados en el aire.
	_hole = hole
	_go_dynamic()

func _go_dynamic() -> void:
	if _dynamic:
		return
	_dynamic = true
	var vel := _drive_dir * _cur_speed + _walk_dir * _cur_walk_speed
	_mode = Mode.STATIC  # deja de conducir/caminar: manda la física
	if is_in_group("car"):
		remove_from_group("car")
	if is_in_group("pedestrian"):
		remove_from_group("pedestrian")
	freeze = false
	continuous_cd = true  # el piso y las paredes son mallas finas: nada de tunelear
	linear_velocity = vel  # conserva la inercia que traía
	angular_velocity = Vector3(randf_range(-0.5, 0.5), randf_range(-0.5, 0.5), randf_range(-0.5, 0.5))
	set_physics_process(true)

# ----------------------------------------------------------------------------
# Caída
# ----------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if _dynamic:
		_fall_step()
		return
	match _mode:
		Mode.CAR:
			_car_step(delta)
		Mode.PEDESTRIAN:
			_ped_step(delta)

func _fall_step() -> void:
	var y := global_position.y
	# Se parte recién cuando ya está comprometido: volcado más de ~28° o con la
	# base bajo el nivel de la calle. NO al soltarse, que es lo intuitivo pero
	# está mal: el agujero suelta todo lo que tenga a 15 m (WAKE_FACTOR), así que
	# romperlo ahí lo haría estallar parado en medio de la manzana, a media
	# cuadra del pozo. Primero se vuelca entero como torre, después se quiebra.
	if break_pieces > 1 and not _broke:
		if global_transform.basis.y.y < BREAK_TILT or y < BREAK_DEPTH:
			_broke = true
			emit_signal("wants_break", self)
		return
	if y > -0.1:
		return  # todavía sobre el nivel de la calle: física pura, sin ayudas
	# Suena y golpea al cruzar la boca, no al soltarse: un edificio puede quedar
	# tambaleando en el borde un buen rato antes de terminar de caer.
	if not _crossed and y < SFX_TRIGGER_Y:
		_crossed = true
		if sfx_kind != Sfx.Kind.NONE:
			Sfx.play(sfx_kind, get_parent(), global_position)
		emit_signal("fell_in", swallow_size, global_position, impact_weight)
	# Succión: ya adentro, tira hacia el eje para que no se quede raspando pared.
	if _hole != null and is_instance_valid(_hole):
		var pull: Vector3 = _hole.global_position - global_position
		pull.y = 0.0
		if pull.length() > 0.05:
			apply_central_force(pull.normalized() * FUNNEL_ACCEL * mass)
	# Se achica al hundirse: desaparece antes de llegar al fondo del pozo.
	var t := clampf(inverse_lerp(SHRINK_START, SHRINK_END, y), 0.0, 1.0)
	_visual.scale = _base_visual_scale * maxf(1.0 - t, 0.01)
	if y < NO_COLLIDE_DEPTH and collision_layer != 0:
		collision_layer = 0
		collision_mask = 0
	if y < -KILL_DEPTH and not _eaten:
		_eaten = true
		emit_signal("consumed", xp_value)
		queue_free()

# ----------------------------------------------------------------------------
# Auto: maneja recto por su carril, frena ante el agujero y ante otro auto.
# ----------------------------------------------------------------------------

func _car_step(delta: float) -> void:
	var target := _drive_speed
	# Frenar si el agujero está cerca y adelante.
	if _hole != null:
		var to_hole: Vector3 = _hole.global_position - global_position
		to_hole.y = 0.0
		if to_hole.length() < CAR_BRAKE_DIST and _drive_dir.dot(to_hole.normalized()) > 0.5:
			target = 0.0
	# Frenar detrás del auto de adelante en el mismo carril (no atravesarse).
	for other in get_tree().get_nodes_in_group("car"):
		var car = other  # sin tipar: es otro Swallowable, pero es esta misma clase
		if car == self:
			continue
		if car._dynamic or car._drive_dir.dot(_drive_dir) < 0.9:
			continue
		var rel: Vector3 = car.global_position - global_position
		var ahead := rel.dot(_drive_dir)
		var lateral := (rel - _drive_dir * ahead).length()
		if ahead > 0.0 and ahead < CAR_FOLLOW_DIST and lateral < 0.8:
			target = minf(target, maxf(car._cur_speed - 0.5, 0.0))
	_cur_speed = move_toward(_cur_speed, target, 12.0 * delta)
	global_position += _drive_dir * _cur_speed * delta
	_wrap()

# ----------------------------------------------------------------------------
# Peatón: pasea por la vereda, dobla al azar, huye del agujero si se acerca.
# ----------------------------------------------------------------------------

func _ped_step(delta: float) -> void:
	_bob_t += delta
	var dir := _walk_dir
	var speed := _walk_speed
	var fleeing := false
	if _hole != null:
		var away: Vector3 = global_position - _hole.global_position
		away.y = 0.0
		var panic_r: float = _hole.radius * 4.0 + 2.0
		if away.length() < panic_r and away != Vector3.ZERO:
			dir = away.normalized()
			speed = PED_FLEE_SPEED
			fleeing = true
	if not fleeing:
		_walk_timer -= delta
		if _walk_timer <= 0.0:
			_walk_timer = randf_range(2.0, 5.0)
			_walk_dir = _random_turn(_walk_dir)
			dir = _walk_dir
	_cur_walk_speed = speed
	global_position += dir * speed * delta
	if dir != Vector3.ZERO:
		rotation.y = atan2(dir.x, dir.z)
	# Trotecito: rebote vertical, más frenético si huye.
	position.y = _base_y + absf(sin(_bob_t * (10.0 if fleeing else 6.0))) * 0.06
	_wrap()

func _random_turn(d: Vector3) -> Vector3:
	var r := randf()
	if r < 0.4:
		return d                          # sigue derecho
	elif r < 0.7:
		return Vector3(d.z, 0.0, -d.x)    # dobla a un lado
	else:
		return Vector3(-d.z, 0.0, d.x)    # dobla al otro

func _wrap() -> void:
	# Al llegar al borde del mapa reaparece del lado opuesto.
	if absf(global_position.x) > _map_half:
		global_position.x = -signf(global_position.x) * _map_half
	if absf(global_position.z) > _map_half:
		global_position.z = -signf(global_position.z) * _map_half

func wobble() -> void:
	# "Todavía no entrás": el objeto se sacude contra el borde. Es sólo visual;
	# el cuerpo sigue congelado, si no media ciudad saldría empujada de lugar.
	if _dynamic or has_meta("wobbling"):
		return
	set_meta("wobbling", true)
	var base := _visual.rotation
	var t := create_tween()
	t.tween_property(_visual, "rotation", base + Vector3(0.05, 0.0, 0.05), 0.06)
	t.tween_property(_visual, "rotation", base - Vector3(0.05, 0.0, 0.05), 0.06)
	t.tween_property(_visual, "rotation", base, 0.06)
	t.tween_callback(func(): remove_meta("wobbling"))
