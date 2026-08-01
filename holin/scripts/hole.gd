extends Node3D

## El agujero / jugador. Se mueve por el plano XZ con teclado o joystick virtual
## y crece por niveles: la XP acumulada desbloquea saltos escalonados de radio.
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
const JoystickRef = preload("res://scripts/virtual_joystick.gd")

@export_group("Movimiento")
@export var move_speed: float = 8.0
@export var acceleration: float = 52.0       # salida: alcanza la velocidad base en ~0.15 s
@export var turn_acceleration: float = 72.0  # correcciones y contramarcha responden antes
@export var deceleration: float = 36.0       # conserva una cola breve al soltar, sin patinar
@export_range(0.0, 0.5, 0.01) var max_speed_growth_bonus: float = 0.22

@export_group("Cámara e impacto")
@export var radius: float = 1.0           # radio actual del agujero
@export var camera_zoom_speed: float = 3.0  # suavizado del alejamiento de cámara
@export var camera_zoom_factor: float = 0.15 # 1.0 = alejamiento proporcional al radio; menos = más cerca
@export var shake_strength: float = 0.55  # amplitud máxima del temblor, en unidades de mundo
@export var shake_decay: float = 7.0      # qué tan rápido se apaga (mayor = más seco)

# Progresión escalonada: radio por nivel y XP acumulada requerida.
@export_group("Progresión")
@export var level_radii: Array[float] = [1.0, 1.5, 2.2, 3.2, 4.4, 5.8, 7.4, 9.2]
@export var level_xp_req: Array[int] = [0, 25, 70, 150, 300, 520, 820, 1200]

const SHAFT_DEPTH := 9.0        # alto de las paredes del pozo (debe coincidir con el shader)
const SHAFT_TAPER := 0.78       # el pozo se afina hacia el fondo (idem malla visual)
# Radio del anillo de suelo que viaja con el agujero. Tiene que alcanzar la
# esquina más lejana del mapa desde cualquier posición: con MAP_HALF 72 la
# diagonal completa es ~204, así que 220 cubre el peor caso. No cuesta más
# triángulos (son GROUND_SEGMENTS fijos), sólo un anillo más ancho.
const GROUND_OUTER := 220.0
const GROUND_SEGMENTS := 40
const SHAPE_EPSILON := 0.05     # cuánto tiene que cambiar el radio para rehacer la colisión
const WAKE_FACTOR := 2.3        # radio de "despertar" objetos, en radios de agujero
const WAKE_EXTRA := 1.8
const DUST_AMOUNT := 34         # partículas por estallido, a golpe máximo
# Varios emisores en round-robin: uno solo se pisaría a sí mismo. Con el agujero
# grande caen tres edificios casi juntos y restart() le cortaría el polvo al
# anterior a mitad de vuelo.
const DUST_EMITTERS := 3
const MOTES := 26               # motas flotando dentro del pozo

var xp := 0
var level := 0
# El joystick vive en el HUD de la partida, así que lo inyecta main.gd. Queda
# null si la escena del agujero se corre suelta: ahí se juega con teclado.
var joystick: JoystickRef = null
var _velocity: Vector2 = Vector2.ZERO      # velocidad actual en el plano XZ
var _base_radius: float
var _base_camera_offset: Vector3
var _cam_anchor: Vector3                   # posición de cámara sin temblor
var _shake := 0.0                          # amplitud actual del temblor (decae sola)
var _rim_pulse := 0.0                      # deformación del borde al recibir un golpe
var _rim_tween: Tween
var _fit_preview := 0.0                    # aviso suave: el objeto cercano sí entra
var _fit_preview_target := 0.0
var _blocked_preview := 0.0                # aviso cálido: todavía es demasiado grande
var _blocked_preview_target := 0.0
var _rim_material: StandardMaterial3D
var _dust: Array[GPUParticles3D] = []
var _dust_next := 0
var _motes: GPUParticles3D
var _shape_radius := -1.0                  # radio con el que se generó la malla de colisión

@onready var visual: Node3D = $Visual
@onready var shaft: MeshInstance3D = $Visual/Shaft
@onready var rim: MeshInstance3D = $Rim
@onready var detection_area: Area3D = $DetectionArea
@onready var shape: CollisionShape3D = $DetectionArea/CollisionShape3D
@onready var ground_shape: CollisionShape3D = $Ground/CollisionShape3D
@onready var camera: Camera3D = $Camera3D

signal swallowed(xp_gained: int, total_xp: int)
signal leveled_up(new_level: int)

func _ready() -> void:
	# Un swallowable armado a mano (auto_setup en swallowable.gd) se busca el
	# agujero solo por acá en vez de que main.gd se lo tenga que inyectar.
	add_to_group("hole")
	radius = level_radii[0]
	_base_radius = radius
	_base_camera_offset = camera.position
	_cam_anchor = camera.position
	_prepare_rim_material()
	_build_motes()
	_apply_radius()
	_build_dust()
	_publish_hole_uniforms()
	# La cámara es hija del agujero (lo sigue). La orientamos una vez hacia él.
	camera.look_at(global_position, Vector3.UP)

func _physics_process(delta: float) -> void:
	var dir := _get_move_direction()
	_update_velocity(dir, delta)
	global_position += Vector3(_velocity.x, 0.0, _velocity.y) * delta
	_publish_hole_uniforms()
	_update_camera(delta)
	_fit_preview_target = 0.0
	_blocked_preview_target = 0.0
	_check_swallow()
	_update_rim_preview(delta)

func _update_velocity(dir: Vector2, delta: float) -> void:
	# Separar salida, giro y frenada hace que el agujero obedezca enseguida sin
	# perder por completo la inercia al levantar el dedo. La magnitud analógica
	# del joystick sigue definiendo la velocidad objetivo.
	var target := dir * _current_move_speed()
	var response := acceleration
	if dir.is_zero_approx():
		response = deceleration
	elif not _velocity.is_zero_approx():
		# Cuanto más brusco el cambio de rumbo, más autoridad recibe el giro.
		# En línea recta conserva `acceleration`; a 180° usa `turn_acceleration`.
		var alignment := _velocity.normalized().dot(dir.normalized())
		var turn_amount := clampf((1.0 - alignment) * 0.5, 0.0, 1.0)
		response = lerpf(acceleration, turn_acceleration, turn_amount)
	_velocity = _velocity.move_toward(target, response * delta)

func _current_move_speed() -> float:
	# La cámara se aleja al crecer. Una compensación moderada evita que el agujero
	# grande parezca más lento en pantalla, pero mantiene el mapa y las decisiones
	# de recorrido relevantes. El bonus llega gradualmente con el tween de radio.
	if level_radii.size() < 2:
		return move_speed
	var growth := clampf(inverse_lerp(level_radii[0], level_radii[-1], radius), 0.0, 1.0)
	return move_speed * lerpf(1.0, 1.0 + max_speed_growth_bonus, growth)

func preview_fit(strength: float) -> void:
	_fit_preview_target = maxf(_fit_preview_target, clampf(strength, 0.0, 1.0))

func preview_blocked(strength: float) -> void:
	_blocked_preview_target = maxf(_blocked_preview_target, clampf(strength, 0.0, 1.0))

func _update_rim_preview(delta: float) -> void:
	# Entra rápido para que se lea al apuntar y sale más despacio para que no
	# parpadee cuando una esquina del objeto roza el límite de detección.
	var fit_speed := 16.0 if _fit_preview_target > _fit_preview else 8.0
	var blocked_speed := 18.0 if _blocked_preview_target > _blocked_preview else 10.0
	_fit_preview = lerpf(_fit_preview, _fit_preview_target, 1.0 - exp(-fit_speed * delta))
	_blocked_preview = lerpf(_blocked_preview, _blocked_preview_target,
		1.0 - exp(-blocked_speed * delta))
	_apply_rim()

func _prepare_rim_material() -> void:
	var source := rim.mesh.surface_get_material(0) as StandardMaterial3D
	_rim_material = source.duplicate() as StandardMaterial3D
	_rim_material.emission_enabled = true
	_rim_material.emission_energy_multiplier = 0.0
	rim.material_override = _rim_material

func _publish_hole_uniforms() -> void:
	# El piso recorta su propio agujero en el shader: necesita saber dónde está.
	RenderingServer.global_shader_parameter_set(&"hole_position", global_position)
	RenderingServer.global_shader_parameter_set(&"hole_radius", radius)

func _update_camera(delta: float) -> void:
	# El offset base escala con el radio, amortiguado para no alejarse tanto al final.
	var ratio := 1.0 + (radius / _base_radius - 1.0) * camera_zoom_factor
	var target := _base_camera_offset * ratio
	# El anclaje es la posición limpia, sin temblor. Si el temblor se sumara antes
	# del lerp, el suavizado se lo comería: en vez de un golpe seco quedaría un
	# bamboleo lento que además arrastra la cámara fuera de lugar.
	_cam_anchor = _cam_anchor.lerp(target, 1.0 - exp(-camera_zoom_speed * delta))
	if _shake <= 0.0001:
		_shake = 0.0
		camera.position = _cam_anchor
		return
	_shake *= exp(-shake_decay * delta)
	# Ruido barato: dos senos de frecuencias que no son múltiplos entre sí, así el
	# patrón no se repite en los pocos frames que dura el golpe. Cargar un
	# FastNoiseLite para esto sería matar una mosca a cañonazos.
	var t := float(Time.get_ticks_msec()) * 0.001
	var ox := sin(t * 47.0) * 0.6 + sin(t * 31.0) * 0.4
	var oy := sin(t * 53.0) * 0.6 + sin(t * 37.0) * 0.4
	# Compensar el alejamiento: a más zoom, el mismo temblor en unidades de mundo
	# ocupa menos píxeles. Escalarlo por ratio lo mantiene constante en pantalla.
	# La base de la cámara es fija (la rotación se fijó en _ready), así que
	# sacudir sobre sus ejes x/y es sacudir en pantalla, no en el mundo.
	var b := camera.transform.basis
	camera.position = _cam_anchor + (b.x * ox + b.y * oy) * (_shake * ratio)

func shake(amount: float) -> void:
	# Se queda con el golpe más fuerte en vez de sumarlos: dos edificios que caen
	# juntos no tienen por qué sacudir el doble, y sumando se va de escala ya.
	_shake = maxf(_shake, minf(amount, shake_strength))

func _build_motes() -> void:
	# Motas cayendo en espiral DENTRO del pozo. Es un efecto contenido a propósito:
	# vive entero abajo del nivel de la calle, así que no toca el recorte del piso
	# ni la colisión ni la silueta de la boca. Nada que pueda abrir una costura.
	#
	# No hace falta ocultarlas cuando el agujero está lejos o de costado: el piso
	# escribe profundidad, así que las tapa solo. Se ven únicamente por la boca,
	# que es justo por donde los fragmentos se descartan.
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3.UP
	pm.emission_ring_height = 0.4
	pm.emission_ring_radius = 1.0        # lo reescala _apply_radius con el agujero
	pm.emission_ring_inner_radius = 0.45
	pm.direction = Vector3.DOWN
	pm.spread = 10.0
	pm.initial_velocity_min = 0.8
	pm.initial_velocity_max = 1.9
	pm.gravity = Vector3(0.0, -2.2, 0.0)  # liviana: flotan, no se desploman
	# Hacia adentro y de costado: la suma de las dos da la espiral. El pozo se
	# angosta hacia abajo, así que la componente radial además las mantiene
	# despegadas de la pared en vez de atravesarla.
	pm.radial_velocity_min = -1.1
	pm.radial_velocity_max = -0.4
	pm.tangential_accel_min = 1.4
	pm.tangential_accel_max = 3.2
	pm.damping_min = 0.2
	pm.damping_max = 0.8
	pm.scale_min = 0.5
	pm.scale_max = 1.3
	var grad := Gradient.new()
	grad.set_color(0, Color(0.62, 0.66, 0.78, 0.0))   # aparecen de a poco
	grad.set_color(1, Color(0.35, 0.38, 0.5, 0.0))
	grad.add_point(0.3, Color(0.7, 0.74, 0.86, 0.55))
	var ramp := GradientTexture1D.new()
	ramp.gradient = grad
	pm.color_ramp = ramp

	var quad := QuadMesh.new()
	quad.size = Vector2(0.12, 0.12)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	quad.material = mat

	_motes = GPUParticles3D.new()
	_motes.process_material = pm
	_motes.draw_pass_1 = quad
	_motes.amount = MOTES
	_motes.lifetime = 2.4
	_motes.preprocess = 2.4    # arranca con el pozo ya poblado, sin llenarse a la vista
	_motes.local_coords = true  # el interior viaja con el agujero
	_motes.position.y = -0.6    # apenas abajo de la boca
	_motes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_motes)

func _build_dust() -> void:
	# Polvo del impacto, armado por código como el resto de los materiales del
	# proyecto: la alternativa es serializar un ParticleProcessMaterial entero en
	# el .tscn, que después nadie lee ni toca.
	var quad := QuadMesh.new()
	# Grande a propósito: con la mancha radial el alfa promedio del quad cae a un
	# cuarto del de un cuadrado sólido, así que hay que compensar en tamaño.
	quad.size = Vector2(0.9, 0.9)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED  # más barato y el polvo no necesita luz
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true  # sin esto la rampa de color no se aplica
	mat.disable_receive_shadows = true
	# Mancha radial suave. Sin textura el QuadMesh se ve como lo que es —un cuadrado
	# gris de bordes duros— y el polvo parece confeti, no tierra levantada.
	var dot := GradientTexture2D.new()
	dot.width = 32
	dot.height = 32
	dot.fill = GradientTexture2D.FILL_RADIAL
	dot.fill_from = Vector2(0.5, 0.5)
	dot.fill_to = Vector2(1.0, 0.5)
	var dot_grad := Gradient.new()
	dot_grad.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	dot_grad.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	dot.gradient = dot_grad
	mat.albedo_texture = dot
	quad.material = mat

	var grad := Gradient.new()
	grad.set_color(0, Color(0.80, 0.77, 0.72, 1.0))
	grad.set_color(1, Color(0.60, 0.58, 0.56, 0.0))
	# Punto intermedio: que aguante opaco hasta pasada la mitad de la vida y recién
	# ahí se disuelva. Con dos puntos se desvanece desde el frame uno y no se ve.
	grad.add_point(0.5, Color(0.74, 0.71, 0.67, 0.9))
	var ramp := GradientTexture1D.new()
	ramp.gradient = grad

	for i in DUST_EMITTERS:
		var pm := ParticleProcessMaterial.new()
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE
		pm.emission_sphere_radius = 0.5   # se ajusta al tamaño de lo que cayó
		pm.direction = Vector3.UP
		pm.spread = 65.0
		pm.initial_velocity_min = 0.8
		pm.initial_velocity_max = 2.2
		pm.radial_velocity_min = 1.2      # se abre hacia afuera del punto de impacto
		pm.radial_velocity_max = 3.0
		pm.gravity = Vector3(0.0, -3.5, 0.0)  # más liviana que la real: es polvo, no escombro
		pm.damping_min = 1.2
		pm.damping_max = 2.8
		pm.scale_min = 0.5   # se recalcula por golpe según el tamaño de lo que cayó
		pm.scale_max = 1.5
		pm.angle_min = -180.0
		pm.angle_max = 180.0
		pm.angular_velocity_min = -110.0
		pm.angular_velocity_max = 110.0
		pm.color_ramp = ramp
		var p := GPUParticles3D.new()
		p.process_material = pm
		p.draw_pass_1 = quad
		p.amount = DUST_AMOUNT
		p.lifetime = 0.75
		p.one_shot = true
		p.explosiveness = 1.0             # todas de golpe, no goteando
		p.local_coords = false            # el polvo queda donde cayó, no sigue al agujero
		p.emitting = false
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(p)
		_dust.append(p)

func burst_dust(size: float, strength: float, at: Vector3) -> void:
	# Sale del BORDE, del lado por donde entró la cosa. Dos razones: lo que levanta
	# tierra es el suelo cediendo, y ahí abajo hay superficie de donde levantarla.
	# Emitiéndolo en el punto exacto de la caída queda flotando sobre el vacío,
	# porque con el agujero grande ese punto está en el medio de la nada.
	var p := _dust[_dust_next]
	_dust_next = (_dust_next + 1) % DUST_EMITTERS
	var away := Vector2(at.x - global_position.x, at.z - global_position.z)
	var dir := away.normalized() if away.length() > 0.05 else Vector2(1.0, 0.0)
	# La nube se dimensiona por el objeto, no por el agujero: un auto levanta poco
	# polvo lo tragues con radio 2 o con radio 9. Atado al radio, al principio de
	# la partida las partículas quedarían más grandes que la boca.
	var pm := p.process_material as ParticleProcessMaterial
	pm.scale_min = size * 0.13
	pm.scale_max = size * 0.40
	pm.emission_sphere_radius = size * 0.30
	p.global_position = global_position + Vector3(dir.x, 0.0, dir.y) * radius * 1.05
	p.amount_ratio = clampf(0.35 + strength * 0.65, 0.1, 1.0)
	p.restart()

func pulse_rim(amount: float, at: Vector3 = Vector3.INF) -> void:
	# Dos cosas a la vez: el anillo entero se ensancha y se achata (absorbe el
	# impacto), y además se levanta una ola LOCALIZADA en el ángulo por donde
	# entró la cosa. La segunda es la que dice de qué lado pasó.
	if _rim_tween != null and _rim_tween.is_valid():
		_rim_tween.kill()
	_set_rim_pulse(amount)
	_rim_tween = create_tween().set_parallel(true)
	_rim_tween.tween_method(_set_rim_pulse, amount, 0.0, 0.4) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)

func _set_rim_pulse(v: float) -> void:
	_rim_pulse = v
	_apply_rim()

func _get_move_direction() -> Vector2:
	# Teclado (desktop) si hay tecla apretada; si no, el joystick virtual.
	# El joystick devuelve magnitud 0..1, así que empujar poco mueve despacio.
	var kb := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if kb != Vector2.ZERO:
		return kb
	if joystick != null:
		return joystick.direction
	return Vector2.ZERO

func _input(event: InputEvent) -> void:
	# Teclas de debug: 1 achica un nivel, 2 agranda un nivel.
	if event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_1:
				debug_step_level(-1)
			KEY_2:
				debug_step_level(1)

func _check_swallow() -> void:
	# Acá no se traga nada: sólo se avisa. Lo que entra por tamaño se suelta como
	# cuerpo dinámico y la física resuelve el resto; lo que no entra, tiembla.
	# La prueba usa el radio real de la base del cuerpo contra el radio de la boca:
	# comparar ancho contra radio hacía temblar objetos que visualmente cabían.
	for body in detection_area.get_overlapping_bodies():
		var obj := body as SwallowableRef
		if obj == null:
			continue
		var dist := Vector2(global_position.x - obj.global_position.x,
			global_position.z - obj.global_position.z).length()
		if obj.fits_hole(radius):
			obj.hole_nearby(self, dist)
		elif dist < radius + obj.footprint_radius:
			var overlap := clampf(
				(radius + obj.footprint_radius - dist) / maxf(obj.footprint_radius, 0.05),
				0.0, 1.0)
			preview_blocked(overlap)
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
	if target_r > radius:
		_spawn_growth_wave(radius, target_r)
	var t := create_tween()
	t.tween_method(_set_radius, radius, target_r, 0.5) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _spawn_growth_wave(from_radius: float, to_radius: float) -> void:
	# Un halo físico recorre exactamente el tamaño recién desbloqueado. Al quedar
	# en el mundo y no en el HUD, conecta el cartel de nivel con la boca real.
	var mesh := TorusMesh.new()
	mesh.inner_radius = 0.92
	mesh.outer_radius = 1.0
	mesh.rings = 48
	mesh.ring_segments = 6
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.38, 1.0, 0.58, 0.88)
	mat.emission_enabled = true
	mat.emission = Color(0.30, 1.0, 0.52)
	mat.emission_energy_multiplier = 2.2
	mesh.material = mat
	var wave := MeshInstance3D.new()
	wave.mesh = mesh
	wave.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	wave.position.y = 0.06
	wave.scale = Vector3(from_radius, 0.32, from_radius)
	add_child(wave)
	var t := create_tween().set_parallel(true)
	t.tween_property(wave, "scale", Vector3(to_radius * 1.06, 0.18, to_radius * 1.06), 0.62) \
		.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	t.tween_property(wave, "transparency", 1.0, 0.62).set_ease(Tween.EASE_IN)
	t.chain().tween_callback(wave.queue_free)

func _set_radius(r: float) -> void:
	radius = r
	_apply_radius()

func _apply_radius() -> void:
	visual.scale = Vector3(radius, 1.0, radius)
	_apply_rim()
	if _motes != null:
		# Las motas acompañan el tamaño del pozo: el anillo de emisión y el porte
		# de cada mota. Si no, con el agujero grande quedan cuatro puntitos en el
		# centro y con el chico son manchones más anchos que la boca.
		var pm := _motes.process_material as ParticleProcessMaterial
		pm.emission_ring_radius = radius * 0.88
		pm.emission_ring_inner_radius = radius * 0.4
		pm.scale_min = 0.5 * radius
		pm.scale_max = 1.3 * radius
		_motes.position.y = -0.6 * radius
	if shape.shape is CylinderShape3D:
		(shape.shape as CylinderShape3D).radius = radius * WAKE_FACTOR + WAKE_EXTRA
	# La boca física se rehace sólo cuando el radio cambió lo suficiente: durante
	# el tween de crecimiento no hace falta regenerar la malla en cada frame.
	if absf(radius - _shape_radius) > SHAPE_EPSILON:
		_rebuild_ground_shape()

func _apply_rim() -> void:
	# Separado de _apply_radius() a propósito: el tween del pulso corre a 60 fps y
	# desde ahí adentro estaría reescribiendo la forma de colisión en cada frame
	# al pedo, cuando el radio real no cambió.
	var feedback_scale := _fit_preview * 0.018 - _blocked_preview * 0.008
	var s := 1.0 + _rim_pulse + feedback_scale
	rim.scale = Vector3(radius * s,
		(0.6 + radius * 0.3) * (1.0 - _rim_pulse * 0.5 + _blocked_preview * 0.035),
		radius * s)
	if _rim_material != null:
		var base := Color(0.18, 0.17, 0.21)
		var blocked_color := Color(0.78, 0.30, 0.16)
		# Un objeto compatible se comunica con inclinación + respiración del borde,
		# no con color. El tono cálido queda reservado para "todavía no entra".
		var color := base.lerp(blocked_color, _blocked_preview * 0.42)
		_rim_material.albedo_color = color
		_rim_material.emission = color
		_rim_material.emission_energy_multiplier = _blocked_preview * 0.42

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
