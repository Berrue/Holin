extends Area3D

## Objeto que el agujero puede tragar. Raíz Area3D para que el agujero
## lo detecte por solapamiento, sin física pesada. Tres modos de vida:
## estático (edificios, árboles), auto (maneja por su calle) y peatón
## (camina por la vereda y huye del agujero).
##
## Ragdoll en dos fases, siguiendo al agujero EN VIVO:
##  - Borde (y > ESCAPE_DEPTH): pierde el piso, se inclina hacia el pozo y cae.
##    Si el agujero se corre, puede recuperarse (tilt chico) o volcarse contra
##    la ciudad y quedar tirado sin ser comido (tilt grande).
##  - Pozo (y <= ESCAPE_DEPTH): comprometido; cae rebotando contra las paredes
##    y recién al fondo se consume (ahí se otorga la XP).

@export var swallow_size: float = 1.0
@export var xp_value: int = 1

signal consumed(xp: int)

const GRAVITY := 25.0
const PULL_STRENGTH := 6.0     # deslizamiento horizontal hacia el centro del pozo
const KILL_DEPTH := 3.0        # profundidad a la que se consume
const ESCAPE_DEPTH := -0.6     # más profundo que esto ya no se escapa
const TOPPLE_ACCEL := 3.5      # aceleración angular del vuelco (rad/s²)
const RECOVER_TILT := 0.55     # tilt (rad) bajo el cual se endereza si el pozo se va
const CAR_BRAKE_DIST := 6.0    # distancia a la que un auto frena por el agujero
const CAR_FOLLOW_DIST := 2.6   # distancia mínima con el auto de adelante
const PED_FLEE_SPEED := 2.6

enum Mode { STATIC, CAR, PEDESTRIAN }

var _mode := Mode.STATIC
var _ragdoll := false
var _hole: Node3D = null       # referencia al agujero, para reaccionar a él
var _lin_vel: Vector3
var _ang_vel: Vector3
var _base_scale: Vector3
# Vuelco (fase borde).
var _tip_axis := Vector3.RIGHT
var _tilt := 0.0
var _tilt_vel := 0.0
var _pre_rotation: Vector3
var _pre_y := 0.0
# Auto.
var _drive_dir := Vector3.ZERO
var _drive_speed := 0.0
var _cur_speed := 0.0
var _map_half := 36.0
# Peatón.
var _walk_dir := Vector3.ZERO
var _walk_speed := 0.8
var _walk_timer := 0.0
var _bob_t := 0.0
var _base_y := 0.0

func _ready() -> void:
	add_to_group("swallowable")
	set_physics_process(false)

func start_driving(dir: Vector3, speed: float, map_half: float, hole: Node3D) -> void:
	_mode = Mode.CAR
	_drive_dir = dir
	_drive_speed = speed
	_cur_speed = speed
	_map_half = map_half
	_hole = hole
	add_to_group("car")
	set_physics_process(true)

func start_walking(dir: Vector3, map_half: float, hole: Node3D) -> void:
	_mode = Mode.PEDESTRIAN
	_walk_dir = dir
	_map_half = map_half
	_hole = hole
	_walk_timer = randf_range(2.0, 5.0)
	_base_y = position.y
	add_to_group("pedestrian")
	set_physics_process(true)

func be_swallowed(hole: Node3D) -> void:
	# Perdió el piso: arranca el ragdoll. Conserva la inercia que traía y
	# se inclina HACIA el pozo (no al azar), como una torre que se cae.
	_hole = hole
	_ragdoll = true
	_base_scale = scale
	_pre_rotation = rotation
	_pre_y = position.y
	_tilt = 0.0
	_tilt_vel = randf_range(0.4, 1.2)
	var dir := hole.global_position - global_position
	dir.y = 0.0
	dir = dir.normalized() if dir.length() > 0.01 else Vector3.FORWARD
	_tip_axis = Vector3.UP.cross(dir).normalized()
	_lin_vel = _drive_dir * _cur_speed + _walk_dir * _walk_speed \
		+ Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
	_ang_vel = _tip_axis * randf_range(2.0, 4.0) + Vector3(
		randf_range(-2.0, 2.0),
		randf_range(-2.0, 2.0),
		randf_range(-2.0, 2.0))
	set_physics_process(true)

func _physics_process(delta: float) -> void:
	if _ragdoll:
		_ragdoll_step(delta)
		return
	match _mode:
		Mode.CAR:
			_car_step(delta)
		Mode.PEDESTRIAN:
			_ped_step(delta)

# ----------------------------------------------------------------------------
# Ragdoll
# ----------------------------------------------------------------------------

func _ragdoll_step(delta: float) -> void:
	if global_position.y > ESCAPE_DEPTH:
		_edge_step(delta)
	else:
		_shaft_step(delta)

func _edge_step(delta: float) -> void:
	# Fase borde: el pozo se sigue moviendo; todavía hay chance de escapar.
	var hole_pos: Vector3 = _hole.global_position
	var hole_r: float = _hole.get("radius")
	var off := global_position - hole_pos
	off.y = 0.0
	if off.length() < hole_r * 0.95:
		# Sin piso debajo: cae, se inclina hacia el pozo y desliza al centro.
		_lin_vel.y -= GRAVITY * delta
		if off.length() > 0.01:
			_lin_vel += -off.normalized() * PULL_STRENGTH * delta
		_tilt_vel += TOPPLE_ACCEL * delta
		var dt := _tilt_vel * delta
		global_rotate(_tip_axis, dt)
		_tilt += dt
		global_position += _lin_vel * delta
	elif _tilt < RECOVER_TILT:
		_recover_upright()
	else:
		_fall_flat()

func _shaft_step(delta: float) -> void:
	# Fase pozo: comprometido. Cae rebotando contra la pared del cilindro.
	var hole_pos: Vector3 = _hole.global_position
	var hole_r: float = _hole.get("radius")
	_lin_vel.y -= GRAVITY * delta
	var pull := hole_pos - global_position
	pull.y = 0.0
	_lin_vel += pull * PULL_STRENGTH * delta
	global_position += _lin_vel * delta
	var off := global_position - hole_pos
	off.y = 0.0
	var max_r := hole_r * 0.85
	if off.length() > max_r:
		var n := off.normalized()
		global_position.x = hole_pos.x + n.x * max_r
		global_position.z = hole_pos.z + n.z * max_r
		var bounced := Vector3(_lin_vel.x, 0.0, _lin_vel.z).bounce(n) * 0.45
		_lin_vel.x = bounced.x
		_lin_vel.z = bounced.z
		_ang_vel = _ang_vel.rotated(Vector3.UP, randf_range(-0.6, 0.6)) * 0.9
	rotation += _ang_vel * delta
	# Deformación de succión: se afina y se estira hacia abajo al hundirse.
	var d := clampf(-global_position.y / KILL_DEPTH, 0.0, 1.0)
	var pinch := 1.0 - 0.7 * d
	var stretch := 1.0 + 1.2 * d
	var vanish := maxf(1.0 - smoothstep(0.55, 1.0, d), 0.01)
	scale = _base_scale * Vector3(pinch * vanish, stretch * vanish, pinch * vanish)
	if d >= 1.0:
		emit_signal("consumed", xp_value)
		queue_free()

func _recover_upright() -> void:
	# Zafó con poco tilt: tambalea y vuelve a pararse. Sigue comible después.
	_ragdoll = false
	remove_meta("being_swallowed")
	_lin_vel = Vector3.ZERO
	scale = _base_scale
	var t := create_tween().set_parallel(true)
	t.tween_property(self, "rotation", _pre_rotation, 0.3) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(self, "position:y", _pre_y, 0.3)
	if _mode == Mode.STATIC:
		set_physics_process(false)

func _fall_flat() -> void:
	# Se volcó fuera del pozo: queda tirado contra la ciudad SIN ser comido.
	# No otorga XP; se lo puede tragar más tarde como cualquier objeto.
	_ragdoll = false
	remove_meta("being_swallowed")
	_mode = Mode.STATIC  # un auto volcado no maneja más; un peatón queda KO
	_lin_vel = Vector3.ZERO
	scale = _base_scale
	set_physics_process(false)
	var target := (Basis(_tip_axis, PI * 0.5) * Basis.from_euler(_pre_rotation)).get_euler()
	var t := create_tween().set_parallel(true)
	t.tween_property(self, "rotation", target, 0.35).set_ease(Tween.EASE_IN)
	t.tween_property(self, "position:y", 0.0, 0.35).set_ease(Tween.EASE_IN)

# ----------------------------------------------------------------------------
# Auto: maneja recto por su carril, frena ante el agujero y ante otro auto.
# ----------------------------------------------------------------------------

func _car_step(delta: float) -> void:
	var target := _drive_speed
	# Frenar si el agujero está cerca y adelante.
	if _hole != null:
		var to_hole := _hole.global_position - global_position
		to_hole.y = 0.0
		if to_hole.length() < CAR_BRAKE_DIST and _drive_dir.dot(to_hole.normalized()) > 0.5:
			target = 0.0
	# Frenar detrás del auto de adelante en el mismo carril (no atravesarse).
	for other in get_tree().get_nodes_in_group("car"):
		if other == self or not is_instance_valid(other):
			continue
		if other._ragdoll or other._drive_dir.dot(_drive_dir) < 0.9:
			continue
		var rel: Vector3 = other.global_position - global_position
		var ahead := rel.dot(_drive_dir)
		var lateral := (rel - _drive_dir * ahead).length()
		if ahead > 0.0 and ahead < CAR_FOLLOW_DIST and lateral < 0.8:
			target = minf(target, maxf(other._cur_speed - 0.5, 0.0))
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
		var away := global_position - _hole.global_position
		away.y = 0.0
		var panic_r: float = _hole.get("radius") * 4.0 + 2.0
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
	# Pequeño feedback de "todavía no entrás". Solo para objetos estáticos:
	# autos y peatones se mueven solos y el tween pelearía con su posición.
	if _mode != Mode.STATIC or has_meta("wobbling"):
		return
	set_meta("wobbling", true)
	var base := position
	var t := create_tween()
	t.tween_property(self, "position", base + Vector3(0.05, 0, 0), 0.04)
	t.tween_property(self, "position", base - Vector3(0.05, 0, 0), 0.04)
	t.tween_property(self, "position", base, 0.04)
	t.tween_callback(func(): remove_meta("wobbling"))
