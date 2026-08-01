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

## Ancho de referencia del objeto. Se usa para masa, impacto y balance; la
## comprobación de si entra usa `footprint_radius`, calculado desde la colisión
## real, para no confundir el radio del agujero con el ancho completo del objeto.
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
## Radio del círculo que contiene toda la base de la colisión. A diferencia de
## `swallow_size`, contempla los dos ejes: una caja cuadrada no entra en un
## círculo que apenas iguala el ancho de uno de sus lados porque chocan las
## esquinas.
var footprint_radius: float = sqrt(0.5)

signal consumed(xp: int)
## Cruzó la boca del pozo: el instante del golpe (shake + hitstop). Va aparte de
## `consumed`, que llega recién al fondo, medio segundo tarde para el feedback.
signal fell_in(size: float, at: Vector3, weight: float)
## Pide que lo reemplacen por pedazos. Lo atiende main.gd, que es la fábrica de
## swallowables: desde acá no hay con qué conectarle las señales a las piezas ni
## cómo repartirles la XP.
signal wants_break(obj)

enum Mode { STATIC, CAR, PEDESTRIAN }

## --- Armado a mano ---
## Instanciá swallowable.tscn directo en cualquier escena, arrastrá un modelo
## como hijo de Visual/, tildá auto_setup y anda: se mide TAL COMO quedó (con
## la escala y la rotación que le diste en el editor) y arma su propia colisión
## en _ready(). Es lo opuesto del camino procedural en main.gd, que primero
## decide un tamaño objetivo y RECIÉN AHÍ escala el modelo para llegar a él —
## acá el tamaño que se ve en el editor ES el tamaño final, nada se reescala.
## xp_value, sfx_kind, break_pieces e impact_weight ya son @export de arriba:
## no hace falta duplicarlos, se setean igual con auto_setup activado.
@export_group("Armado a mano")
@export var auto_setup: bool = false
@export var auto_mode: Mode = Mode.STATIC        ## sólo importa con auto_setup activo
@export var auto_dir: Vector3 = Vector3.FORWARD  ## dirección de marcha (CAR) o huida (PEDESTRIAN)
@export var auto_speed: float = 3.0              ## sólo CAR: PEDESTRIAN usa su propia velocidad fija
@export var auto_map_half: float = 500.0         ## a qué distancia del origen reaparece del otro lado
## Ancho que tiene que medir el objeto en el mundo, en metros. Es el parámetro
## principal de balance visual; la elegibilidad final se calcula con la base real
## de la colisión, de modo que lo que parece caber en la boca efectivamente cabe.
##
##  - 0 (default): no se reescala nada, se usa el tamaño tal como quedó en el
##    editor. Lo que ves es lo que hay.
##  - > 0: el modelo se reescala en _ready() para que su ancho dé exactamente
##    esto. Cómodo para props de biblioteca, donde importa el tamaño de juego y
##    no la escala cruda del .glb — pero ojo, el viewport del editor muestra el
##    modelo sin escalar, así que ahí NO se ve el tamaño final.
@export var auto_footprint: float = 0.0
## Repinta todas las mallas del modelo. Los .glb de Kenney mapean sus UV contra
## un atlas de paleta, así que cambiar el atlas por otro con el mismo layout
## recolorea el modelo entero sin tocar la geometría (ver resources/city_palette_*.tres).
##
## Conviene que sea un material de ARCHIVO (.tres) y no uno creado al vuelo:
## Godot cachea el recurso por ruta, así que todas las instancias comparten el
## mismo objeto y el renderer las junta en un draw call por paleta. Uno nuevo
## por instancia multiplicaría los draw calls por la cantidad de edificios.
##
## Funciona con auto_setup apagado también: se aplica igual.
@export var palette_material: Material = null

const KILL_DEPTH := 6.5         # profundidad a la que se consume y se otorga la XP
const NO_COLLIDE_DEPTH := -4.0  # más abajo deja de chocar: nada se traba en el fondo
const SFX_TRIGGER_Y := -0.15    # y a la que suena: recién cuando cruza el borde
const SHRINK_START := -1.0      # y desde la que empieza a achicarse (succión)
const SHRINK_END := -5.2
const FUNNEL_ACCEL := 16.0      # succión hacia el eje del pozo, en m/s²
const FALL_TRIGGER := 0.8       # un móvil se suelta cuando el pozo lo tapa tanto
## Deja un 10 % de aire entre el círculo que contiene al objeto y la pared. Sin
## esta holgura, los casos límite rozan la malla cóncava y quedan saltando sobre
## el borde aun cuando matemáticamente entran.
const FIT_RADIUS_MARGIN := 0.90
const EDGE_PULL_ACCEL := 20.0   # ayuda suave a centrar cuerpos comprometidos en la boca
const CAR_BRAKE_DIST := 6.0     # distancia a la que un auto frena por el agujero
const CAR_FOLLOW_DIST := 2.6    # distancia mínima con el auto de adelante
const PED_FLEE_SPEED := 2.6
const CAR_LANE_OFFSET := 1.25
const CAR_TURN_CHANCE := 0.32
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
var _road_lines: Array[float] = []
var _last_intersection := Vector2i(1000000, 1000000)
var _turn_count := 0
# Zona que los móviles no pueden atravesar. Se configura desde la escena que
# conoce el mapa; con half_extents=Vector2.ZERO queda desactivada.
var _forbidden_centers: Array[Vector2] = []
var _forbidden_half_extents: Array[Vector2] = []
# Peatón.
var _walk_dir := Vector3.ZERO
var _walk_speed := 0.8
var _cur_walk_speed := 0.0
var _walk_timer := 0.0
var _bob_t := 0.0
var _base_y := 0.0
# Extremidades del peatón, si quien lo armó le puso (ver set_walk_rig). Vacías =
# camina igual, sólo sin balanceo.
var _legs: Array[Node3D] = []
var _arms: Array[Node3D] = []

func _ready() -> void:
	add_to_group("swallowable")
	_visual = $Visual
	_base_visual_scale = _visual.scale
	freeze = true
	freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	set_physics_process(false)
	if auto_setup:
		_auto_configure()  # saca el placeholder antes de repintar, así no se pinta al vacío
	# Fuera del if: la paleta no depende de quién armó el cuerpo, así que también
	# repinta a los que spawnea main.gd por código.
	if palette_material != null:
		for m in _all_meshes(_visual):
			m.material_override = palette_material

func setup_body(size: Vector3) -> void:
	# Caja de colisión del tamaño real del modelo, apoyada en el piso.
	world_size = size
	var col := $CollisionShape3D as CollisionShape3D
	var box: BoxShape3D = (col.shape as BoxShape3D).duplicate()  # no tocar la compartida
	box.size = Vector3(maxf(size.x, 0.2), maxf(size.y, 0.2), maxf(size.z, 0.2))
	col.shape = box
	col.position.y = box.size.y * 0.5
	# La boca es circular. El medio de la diagonal XZ es el radio mínimo que
	# contiene la caja en cualquier rotación y por eso es la medida correcta para
	# decidir si físicamente puede atravesarla.
	footprint_radius = Vector2(box.size.x, box.size.z).length() * 0.5
	# Masa según el porte: un rascacielos no lo mueve un arbusto.
	mass = clampf(pow(swallow_size, 2.2) * 3.0, 0.4, 140.0)
	# Centro de masa un poco abajo del geométrico: las torres no se caen solas
	# por cualquier roce, pero igual se vuelcan cuando pierden medio apoyo.
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, box.size.y * 0.4, 0.0)

# ----------------------------------------------------------------------------
# Armado a mano: auto_setup mide su propio modelo en vez de esperar a que
# main.gd lo llame por código.
# ----------------------------------------------------------------------------

func _auto_configure() -> void:
	# El cubo placeholder que trae la escena de fábrica (para que se vea algo si
	# a alguien se olvida de poner un modelo) sólo se saca si HAY otra cosa
	# puesta encima: si no, se queda —visible— como recordatorio de "acá falta
	# un modelo", y se mide como un cubo de 1×1×1 cualquiera.
	var placeholder := _visual.get_node_or_null("MeshInstance3D") as MeshInstance3D
	var has_real_model := false
	for c in _visual.get_children():
		if c != placeholder:
			has_real_model = true
			break
	if placeholder != null and has_real_model:
		_visual.remove_child(placeholder)
		placeholder.free()  # free(), no queue_free(): la medición de abajo es en el mismo frame

	# En espacio LOCAL del propio swallowable, no del mundo: a diferencia del
	# camino procedural (que mide ANTES de rotar el objeto — ver el comentario
	# en _spawn_model_swallowable de main.gd), acá el nodo puede llegar ya
	# rotado desde el editor, y medir en espacio mundo daría una caja más
	# grande de lo que corresponde.
	var native := _merged_aabb_local(_visual)
	if auto_footprint > 0.0:
		# Reescalar para dar el ancho pedido y volver a medir. Se escala el Visual
		# (no cada hijo) para que valga igual si el modelo son varias mallas.
		var w: float = maxf(maxf(native.size.x, native.size.z), 0.001)
		_visual.scale *= auto_footprint / w
		_base_visual_scale = _visual.scale  # la succión encoge desde acá: si no, al caer daría un salto
		native = _merged_aabb_local(_visual)
	swallow_size = maxf(native.size.x, native.size.z)
	setup_body(native.size)

	if auto_mode == Mode.STATIC:
		return
	var hole := get_tree().get_first_node_in_group(&"hole")
	if hole == null:
		push_warning('%s: auto_mode=%s pero no hay ningún Hole en el grupo "hole"' % [name, auto_mode])
		return
	match auto_mode:
		Mode.CAR:
			start_driving(auto_dir.normalized(), auto_speed, auto_map_half, hole)
		Mode.PEDESTRIAN:
			start_walking(auto_dir.normalized(), auto_map_half, hole)

# Medición propia, no la de main.gd: un swallowable armado a mano tiene que
# poder vivir en cualquier escena, no sólo en main.tscn, así que no puede
# depender de la fábrica procedural.
func _merged_aabb_local(node: Node) -> AABB:
	var inv := global_transform.affine_inverse()
	var out := AABB()
	var has := false
	for mi in _all_meshes(node):
		var local_a: AABB = (inv * mi.global_transform) * mi.get_aabb()
		if not has:
			out = local_a
			has = true
		else:
			out = out.merge(local_a)
	return out

func _all_meshes(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		result.append(node)
	for c in node.get_children():
		result.append_array(_all_meshes(c))
	return result

func start_driving(dir: Vector3, speed: float, map_half: float, hole, road_lines: Array = []) -> void:
	_mode = Mode.CAR
	_drive_dir = dir
	_drive_speed = speed
	_cur_speed = speed
	_map_half = map_half
	_hole = hole
	_road_lines.clear()
	for line in road_lines:
		_road_lines.append(float(line))
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	add_to_group("car")
	set_physics_process(true)

func set_forbidden_square(center: Vector2, half_extent: float) -> void:
	set_forbidden_rect(center, Vector2.ONE * half_extent)

func set_forbidden_rect(center: Vector2, half_extents: Vector2) -> void:
	_forbidden_centers.clear()
	_forbidden_half_extents.clear()
	add_forbidden_rect(center, half_extents)

func add_forbidden_rect(center: Vector2, half_extents: Vector2) -> void:
	_forbidden_centers.append(center)
	_forbidden_half_extents.append(Vector2(
		maxf(half_extents.x, 0.0),
		maxf(half_extents.y, 0.0)
	))

func set_walk_rig(legs: Array[Node3D], arms: Array[Node3D]) -> void:
	# Los pivotes de brazos y piernas los arma quien construye la persona
	# (main.gd); acá sólo se los anima. Se pasan explícitos en vez de buscarlos
	# por nombre para que no haya un contrato oculto de nombres de nodo.
	_legs = legs
	_arms = arms

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

func fits_hole(hole_radius: float) -> bool:
	return footprint_radius <= hole_radius * FIT_RADIUS_MARGIN

func hole_nearby(hole, dist: float) -> void:
	# El agujero avisa que está cerca y que este objeto entra por tamaño.
	_hole = hole
	if not _dynamic:
		# Lo estático se suelta cuando su base ya toca la abertura, no apenas entra
		# en el área amplia de detección. Así no queda rebotando varios metros antes
		# de llegar. Lo móvil conserva su marcha hasta tapar buena parte de la boca.
		var static_trigger: float = hole.radius + footprint_radius * 0.75
		var trigger: float = static_trigger if _mode == Mode.STATIC else hole.radius * FALL_TRIGGER
		var preview_reach: float = trigger + maxf(0.65, footprint_radius * 0.7)
		if dist < preview_reach:
			var preview_strength := clampf(inverse_lerp(preview_reach, trigger, dist), 0.0, 1.0)
			hole.preview_fit(preview_strength)
			if _mode == Mode.STATIC:
				anticipate(hole, preview_strength)
		if (_mode == Mode.STATIC and dist < static_trigger) \
				or (_mode != Mode.STATIC and dist < hole.radius * FALL_TRIGGER):
			_go_dynamic()
	if _dynamic and dist < hole.radius + footprint_radius:
		# Si ya perdió apoyo, un tirón horizontal corto evita el equilibrio falso de
		# la caja entre dos puntos del borde. La gravedad sigue resolviendo la caída.
		if sleeping:
			sleeping = false
		var inward: Vector3 = hole.global_position - global_position
		inward.y = 0.0
		if inward.length() > 0.05:
			var overlap: float = clampf(
				(hole.radius + footprint_radius - dist) / maxf(footprint_radius, 0.05),
				0.0, 1.0)
			apply_central_force(inward.normalized() * EDGE_PULL_ACCEL * overlap * mass)

func anticipate(hole, strength: float) -> void:
	# Un pequeño gesto de entrega antes de perder apoyo. Se anima sólo el modelo:
	# la colisión sigue quieta y la decisión de caída continúa siendo física.
	if _dynamic or has_meta("anticipating") or strength < 0.08:
		return
	var inward: Vector3 = hole.global_position - global_position
	inward.y = 0.0
	if inward.length() < 0.05:
		return
	var local_dir := global_transform.basis.inverse() * inward.normalized()
	var lean := lerpf(0.012, 0.055, strength)
	var tilt := Vector3(local_dir.z, 0.0, -local_dir.x) * lean
	var base := _visual.rotation
	set_meta("anticipating", true)
	var t := create_tween()
	t.tween_property(_visual, "rotation", base + tilt, 0.075).set_trans(Tween.TRANS_SINE)
	t.tween_property(_visual, "rotation", base, 0.11).set_trans(Tween.TRANS_SINE)
	t.tween_callback(func(): remove_meta("anticipating"))

func reveal_unlocked() -> void:
	# Los objetos que acaban de entrar en rango contestan al crecimiento con un
	# rebote vertical. No se toca el cuerpo ni la colisión: es información visual.
	if _dynamic or _eaten or has_meta("unlock_reveal"):
		return
	set_meta("unlock_reveal", true)
	var base_scale := _visual.scale
	var base_pos := _visual.position
	var lift := clampf(world_size.y * 0.07, 0.08, 0.42)
	var scale_tween := create_tween()
	scale_tween.tween_property(_visual, "scale", base_scale * 1.12, 0.14) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	scale_tween.tween_property(_visual, "scale", base_scale, 0.30) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	scale_tween.tween_callback(func(): remove_meta("unlock_reveal"))
	var lift_tween := create_tween()
	lift_tween.tween_property(_visual, "position", base_pos + Vector3.UP * lift, 0.13) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	lift_tween.tween_property(_visual, "position", base_pos, 0.24) \
		.set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)

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
		Sfx.play_fall(sfx_kind, swallow_size, get_parent(), global_position)
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
	_maybe_turn_at_intersection(delta)
	var next := global_position + _drive_dir * _cur_speed * delta
	if _inside_forbidden(next, footprint_radius):
		# La calle termina contra el cubículo: frena, gira y vuelve por el mismo
		# carril. Estos cuerpos congelados se mueven por posición y no reaccionan
		# por sí solos a un StaticBody, por eso el límite también vive acá.
		_drive_dir = -_drive_dir
		_cur_speed = 0.0
		rotation.y = atan2(_drive_dir.x, _drive_dir.z)
		return
	global_position = next
	_wrap()

func _maybe_turn_at_intersection(delta: float) -> void:
	if _road_lines.is_empty() or _cur_speed < 0.1:
		return
	var vertical := absf(_drive_dir.z) > 0.5
	var road_coord := global_position.x if vertical else global_position.z
	var along_coord := global_position.z if vertical else global_position.x
	var road_center := _nearest_road_line(road_coord)
	var crossing := _nearest_road_line(along_coord)
	if is_inf(road_center) or is_inf(crossing):
		return
	var intersection := Vector2i(
		roundi(road_center) if vertical else roundi(crossing),
		roundi(crossing) if vertical else roundi(road_center)
	)
	if intersection == _last_intersection:
		return
	var reach := maxf(_cur_speed * delta + 0.12, 0.25)
	if absf(along_coord - crossing) > reach:
		return
	_last_intersection = intersection
	if randf() > CAR_TURN_CHANCE:
		return
	if vertical:
		_drive_dir = Vector3(1.0 if randf() < 0.5 else -1.0, 0.0, 0.0)
		global_position.z = crossing + CAR_LANE_OFFSET * signf(_drive_dir.x)
	else:
		_drive_dir = Vector3(0.0, 0.0, 1.0 if randf() < 0.5 else -1.0)
		global_position.x = crossing - CAR_LANE_OFFSET * signf(_drive_dir.z)
	rotation.y = atan2(_drive_dir.x, _drive_dir.z)
	_turn_count += 1

func _nearest_road_line(value: float) -> float:
	var nearest := INF
	var best_distance := INF
	for line in _road_lines:
		var distance := absf(value - line)
		if distance < best_distance:
			best_distance = distance
			nearest = line
	return nearest

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
	var next := global_position + dir * speed * delta
	var forbidden_index := _forbidden_zone_index(next, footprint_radius)
	if forbidden_index >= 0:
		# Refleja la marcha contra la cara del cubículo que intentó cruzar. Así
		# también funciona mientras huye del agujero y no depende del giro aleatorio.
		var local := Vector2(next.x, next.z) - _forbidden_centers[forbidden_index]
		var normal := Vector3.ZERO
		if absf(local.x) > absf(local.y):
			normal.x = signf(local.x)
		else:
			normal.z = signf(local.y)
		dir = (dir - 2.0 * dir.dot(normal) * normal).normalized()
		_walk_dir = dir
		next = global_position + dir * speed * delta
	global_position = next
	if dir != Vector3.ZERO:
		rotation.y = atan2(dir.x, dir.z)
	# Trotecito: rebote vertical, más frenético si huye.
	var freq := 10.0 if fleeing else 6.0
	position.y = _base_y + absf(sin(_bob_t * freq)) * 0.06
	_animate_walk(freq, fleeing)
	_wrap()

func _inside_forbidden(pos: Vector3, padding: float = 0.0) -> bool:
	return _forbidden_zone_index(pos, padding) >= 0

func _forbidden_zone_index(pos: Vector3, padding: float = 0.0) -> int:
	var extra := Vector2.ONE * maxf(padding, 0.0)
	for i in _forbidden_centers.size():
		var half: Vector2 = _forbidden_half_extents[i] + extra
		var center: Vector2 = _forbidden_centers[i]
		if absf(pos.x - center.x) < half.x and absf(pos.z - center.y) < half.y:
			return i
	return -1

func _animate_walk(freq: float, fleeing: bool) -> void:
	if _legs.is_empty() and _arms.is_empty():
		return
	# Misma frecuencia que el rebote del cuerpo a propósito: el rebote usa abs()
	# del seno, así que va al doble de ciclos que este balanceo — o sea un rebote
	# por pisada, que es justo lo que hace que la pisada no flote.
	var swing: float = sin(_bob_t * freq) * (0.9 if fleeing else 0.5)
	for i in _legs.size():
		_legs[i].rotation.x = swing if i == 0 else -swing
	# Los brazos van en contrafase con las piernas y más suaves. Es lo que
	# distingue una caminata de una marioneta sacudida.
	for i in _arms.size():
		_arms[i].rotation.x = -swing * 0.6 if i == 0 else swing * 0.6

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
