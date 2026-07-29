extends Node3D

## Agujero rival manejado por IA.
##
## NO reusa hole.gd, y no es por comodidad: el agujero del jugador es el único
## que puede existir en este mundo.
##
##  - Lleva el SUELO consigo. `hole.gd` arrastra un anillo de piso de 160 de
##    radio (GROUND_OUTER) que tapa el mapa entero desde donde esté; es lo que
##    hace que las cosas se caigan solas al quedarse sin apoyo. Dos agujeros
##    serían dos pisos superpuestos sobre toda la ciudad.
##  - El shader del piso recorta la boca con dos uniforms GLOBALES,
##    `hole_position` y `hole_radius`. Uno solo. Soportar N sería pasar arrays y
##    hacer un bucle por fragmento sobre todo el asfalto.
##
## Entonces el rival es un agujero "pintado": disco oscuro con borde de color
## apoyado sobre la calle, y succión por tween en vez de por física. Es
## exactamente lo que hace hole.io —si mirás el video, su agujero es un disco
## plano sin profundidad— y deja la física real, que es lo que nos diferencia,
## para el único agujero que el jugador tiene en pantalla todo el tiempo.

const SwallowableRef = preload("res://scripts/swallowable.gd")

const RETARGET_SECS := 0.5   # cada cuánto rehace la búsqueda de presa
const EAT_FRACTION := 0.82   # qué tan adentro del disco tiene que estar para caer
const FIT_MARGIN := 1.02     # misma tolerancia de tamaño que usa el jugador
const ACCEL := 20.0
const TAG_HEIGHT := 1.6
## Compensa una ventaja que el rival tiene por cómo está hecho: su succión es un
## tween de 0.35 s, mientras que el jugador tiene que esperar a que la torre se
## vuelque, se trabe en el borde y termine de caer. Sin esto un rival vacía una
## manzana en el tiempo que al jugador le lleva tragarse un edificio.
const EAT_COOLDOWN := 0.18

var rival_name := "Rival"
var color := Color(0.35, 0.8, 1.0)
## Handicap: el jugador va a 8.0. Un rival que se mueve igual de rápido, apunta
## perfecto y nunca duda no es un rival, es una aspiradora.
var move_speed := 5.5
## Cuánto de lo que come le cuenta para crecer. Es la perilla principal de
## balance de los rivales: 1.0 los hace crecer como el jugador.
var xp_scale := 0.55

var radius := 1.0
var xp := 0
## Puntaje, para poder compararlo con el del jugador en el contador. Acumula el
## valor CRUDO de lo que come, sin el handicap de `xp_scale`: ese handicap es de
## crecimiento, no de mérito. El jugador arriba de eso tiene el multiplicador de
## combo, que los rivales no tienen — y esa ventaja es justamente la que se
## quiere ver reflejada en el contador.
var score := 0
var level := 0
# Las tablas de progresión las inyecta main.gd desde el agujero del jugador: son
# balance del juego y no tienen por qué vivir duplicadas acá.
var level_radii: Array[float] = [1.0]
var level_xp_req: Array[int] = [0]

var _swallowables: Node
var _map_half := 36.0
var _target: Node3D = null
var _retarget := 0.0
var _eat_wait := 0.0
var _velocity := Vector2.ZERO
var _xp_debt := 0.0   # resto fraccionario de xp_scale, para no perderlo al truncar
var _mouth: MeshInstance3D
var _rim: MeshInstance3D
var _tag: Label3D
var _area: Area3D
var _shape: CylinderShape3D

signal ate(xp_value: int)

func setup(swallowables: Node, radii: Array[float], reqs: Array[int], map_half: float) -> void:
	_swallowables = swallowables
	level_radii = radii
	level_xp_req = reqs
	_map_half = map_half
	radius = level_radii[0]
	_build_visual()
	_build_area()
	_apply_radius()

func _build_visual() -> void:
	# Disco apoyado sobre el asfalto. Va a y=0.02, por encima de las líneas de la
	# calle (main.gd Y_LINE=0.014) para que no pelee el z-buffer con ellas.
	var mouth_mesh := CylinderMesh.new()
	mouth_mesh.top_radius = 1.0
	mouth_mesh.bottom_radius = 1.0
	mouth_mesh.height = 0.02
	mouth_mesh.radial_segments = 32
	var mouth_mat := StandardMaterial3D.new()
	mouth_mat.albedo_color = Color(0.02, 0.02, 0.035)
	mouth_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mouth_mesh.material = mouth_mat
	_mouth = MeshInstance3D.new()
	_mouth.mesh = mouth_mesh
	_mouth.position.y = 0.02
	_mouth.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mouth)

	var rim_mesh := TorusMesh.new()
	rim_mesh.inner_radius = 0.94
	rim_mesh.outer_radius = 1.14
	rim_mesh.rings = 32
	rim_mesh.ring_segments = 6
	var rim_mat := StandardMaterial3D.new()
	rim_mat.albedo_color = color
	rim_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rim_mesh.material = rim_mat
	_rim = MeshInstance3D.new()
	_rim.mesh = rim_mesh
	_rim.position.y = 0.03
	_rim.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_rim)

	# Nombre flotante, como los del juego de referencia: es lo que convierte a un
	# disco de color en un oponente.
	_tag = Label3D.new()
	_tag.text = rival_name
	_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_tag.no_depth_test = true
	# fixed_size: el nombre se lee igual de lejos que de cerca. El pixel_size es
	# chico porque con fixed_size deja de escalar con la distancia y se mide casi
	# en pantalla: con 0.0016 el nombre ocupaba media pantalla.
	_tag.fixed_size = true
	_tag.pixel_size = 0.0004
	_tag.font_size = 96
	_tag.outline_size = 28
	_tag.modulate = color
	_tag.outline_modulate = Color(0, 0, 0, 0.9)
	add_child(_tag)

func _build_area() -> void:
	# Área en vez de recorrer los ~170 objetos por frame: con tres rivales eso
	# serían 500 comparaciones por frame para nada.
	_area = Area3D.new()
	_area.collision_layer = 0
	_area.collision_mask = 2   # capa "objects"
	_area.monitorable = false
	_shape = CylinderShape3D.new()
	_shape.height = 24.0
	var cs := CollisionShape3D.new()
	cs.shape = _shape
	_area.add_child(cs)
	add_child(_area)

func _physics_process(delta: float) -> void:
	_retarget -= delta
	if _retarget <= 0.0:
		_retarget = RETARGET_SECS
		_pick_target()
	var dir := Vector2.ZERO
	if _target != null and is_instance_valid(_target):
		var d := Vector2(_target.global_position.x - global_position.x,
			_target.global_position.z - global_position.z)
		if d.length() > 0.1:
			dir = d.normalized()
	_velocity = _velocity.move_toward(dir * move_speed, ACCEL * delta)
	global_position += Vector3(_velocity.x, 0.0, _velocity.y) * delta
	# El mapa tiene borde: sin esto el rival se va al agua persiguiendo algo.
	global_position.x = clampf(global_position.x, -_map_half, _map_half)
	global_position.z = clampf(global_position.z, -_map_half, _map_half)
	_eat_step(delta)

func _pick_target() -> void:
	# Lo más valioso que le entre por tamaño, penalizado por distancia. Misma
	# heurística que el bot de devtools: es simple y se comporta razonable.
	var best: Node3D = null
	var top := -1.0
	for c in _swallowables.get_children():
		# Ojo: acá adentro también viven los AudioStreamPlayer3D que suelta sfx.gd.
		if not c.is_in_group("swallowable"):
			continue
		var obj := c as SwallowableRef
		if obj.swallow_size > radius * FIT_MARGIN:
			continue
		var d := global_position.distance_to(obj.global_position)
		var v := float(obj.xp_value) / (d + 3.0)
		if v > top:
			top = v
			best = obj
	_target = best

func _eat_step(delta: float) -> void:
	_eat_wait -= delta
	if _eat_wait > 0.0:
		return
	for body in _area.get_overlapping_bodies():
		var obj := body as SwallowableRef
		if obj == null or obj.swallow_size > radius * FIT_MARGIN:
			continue
		var d := Vector2(global_position.x - obj.global_position.x,
			global_position.z - obj.global_position.z).length()
		if d < radius * EAT_FRACTION:
			var value := obj.xp_value
			if obj.suck_by_rival(self):
				gain_xp(value)
				_eat_wait = EAT_COOLDOWN
				return  # uno por vez, no una manzana entera en un frame

func gain_xp(amount: int) -> void:
	# El handicap se acumula con el resto para que a los rivales no se les pierda
	# XP redondeando cada bocado chico a cero.
	score += amount
	_xp_debt += float(amount) * xp_scale
	var ganado := int(_xp_debt)
	_xp_debt -= float(ganado)
	xp += ganado
	emit_signal("ate", amount)
	while level + 1 < level_xp_req.size() and xp >= level_xp_req[level + 1]:
		level += 1
		var t := create_tween()
		t.tween_method(_set_radius, radius, level_radii[level], 0.5) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _set_radius(r: float) -> void:
	radius = r
	_apply_radius()

func _apply_radius() -> void:
	_mouth.scale = Vector3(radius, 1.0, radius)
	_rim.scale = Vector3(radius, 1.0, radius)
	_tag.position.y = TAG_HEIGHT + radius * 0.15
	_shape.radius = radius
