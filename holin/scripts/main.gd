extends Node3D

## Escena de juego: arma la ciudad, lleva timer + puntaje y maneja el fin de
## partida (overlay de game over con reinicio / volver al menú).

@export var swallowable_scene: PackedScene

const MENU_SCENE := "res://scenes/main_menu.tscn"
const GAME_DURATION := 120.0

# --- Objetivo de la partida ---
# La partida se gana llegando al puntaje, no sobreviviendo al reloj. Un objetivo
# cerrado es lo que genera el "una más": un high score suelto no se falla por
# poco, un 740 de 800 sí. El reloj pasa a ser la presión, no la meta.
## Calibrado con devtools/stress.gd, no a ojo.
##
## La curva de puntaje es muy acelerada —el bot lleva ~300 puntos a los 40 s y
## ~3300 a los 120— porque el agujero crece y cada bocado vale más. Para
## recalibrar: poner un número inalcanzable acá, correr el stress y leer la curva.
##
## OJO: este número depende de los rivales. Sin ellos el bot llegaba a 1800; con
## tres compitiendo por la misma comida se queda en ~1580. Cualquier cambio en la
## cantidad de rivales o en su handicap obliga a rehacerlo.
const SCORE_GOAL := 1200
const HINT_SECS := 4.5  # cuánto queda en pantalla el cartel de arranque

# --- Combo ---
# Encadenar bocados multiplica el PUNTAJE, nunca la XP: si tocara la XP movería
# la curva de crecimiento y con ella todo el balance de tamaños.
## Ventana corta a propósito: cruzar de una manzana a otra lleva ~2 s, así que
## el combo se corta al viajar. Con 1.8 s no se cortaba nunca en el juego tardío
## y el multiplicador quedaba clavado en x4, o sea que dejaba de ser una decisión.
const COMBO_WINDOW := 1.2   # segundos para encadenar el siguiente
const COMBO_PER_STEP := 4   # cada cuántos bocados sube un escalón el multiplicador
const COMBO_MAX_MULT := 4

# El piso usa shader propio: recorta la boca del pozo y se oscurece en el borde.
const GROUND_SHADER := preload("res://shaders/ground_hole.gdshader")
# Recorta un pedazo del modelo por franja de altura (ver el shader).
const PIECE_SHADER := preload("res://shaders/building_piece.gdshader")

# Tipos por preload en vez de class_name: la caché de clases globales vive en
# .godot/ (ignorada por git) y sin ella el proyecto no arranca fuera del editor.
const HoleRef = preload("res://scripts/hole.gd")
const SwallowableRef = preload("res://scripts/swallowable.gd")
const Sfx = preload("res://scripts/sfx.gd")
const JoystickRef = preload("res://scripts/virtual_joystick.gd")
const RivalRef = preload("res://scripts/rival_hole.gd")
const ArrowsRef = preload("res://scripts/rival_arrows.gd")
const BoardRef = preload("res://scripts/leaderboard.gd")

# --- Rivales ---
const RIVALS := [
	{"nombre": "Chillkill", "color": Color(0.95, 0.85, 0.2)},
	{"nombre": "Bache", "color": Color(0.35, 0.95, 0.45)},
	{"nombre": "Sumidero", "color": Color(0.95, 0.4, 0.75)},
]
const RIVAL_START_CLEAR := 18.0  # a qué distancia mínima del jugador arrancan

@onready var hole := $Hole as HoleRef
@onready var swallowables: Node3D = $Swallowables
@onready var level_label: Label = $UI/ScorePanel/VBox/Row/Badge/LevelLabel
@onready var badge: PanelContainer = $UI/ScorePanel/VBox/Row/Badge
@onready var score_value: Label = $UI/ScorePanel/VBox/Row/ScoreCol/ScoreValue
@onready var goal_bar: ProgressBar = $UI/ScorePanel/VBox/GoalBar
@onready var goal_label: Label = $UI/ScorePanel/VBox/GoalBar/GoalLabel
@onready var timer_label: Label = $UI/TimerPanel/TimerLabel
@onready var joystick := $UI/Joystick as JoystickRef
@onready var rival_arrows := $UI/RivalArrows as ArrowsRef
@onready var leaderboard := $UI/ScorePanel/VBox/Leaderboard as BoardRef
@onready var game_over: Control = $UI/GameOver
@onready var game_over_title: Label = $UI/GameOver/Center/Panel/Margin/VBox/Title
@onready var final_score_label: Label = $UI/GameOver/Center/Panel/Margin/VBox/ScoreResult
@onready var replay_button: Button = $UI/GameOver/Center/Panel/Margin/VBox/ReplayButton
@onready var menu_button: Button = $UI/GameOver/Center/Panel/Margin/VBox/MenuButton
@onready var sun: DirectionalLight3D = $DirectionalLight3D
@onready var ground: MeshInstance3D = $Ground
@onready var music: AudioStreamPlayer = $Music

var time_left := GAME_DURATION
var score := 0
var count := 0
var running := true
var won := false
var combo := 0
var rivals: Array = []
var _combo_left := 0.0
var _combo_label: Label

# --- Layout de la ciudad ---
const ROAD_LINES := [-32, -16, 0, 16, 32]   # ejes de las calles (X y Z)
const BLOCK_CENTERS := [-24, -8, 8, 24]      # centros de manzana (entre calles)
const MAP_HALF := 36.0
const ROAD_W := 5.0
const SIDE_W := 1.6
const Y_SIDEWALK := 0.006
const Y_ROAD := 0.010
const Y_LINE := 0.014
const START_CLEAR := 4.5  # radio despejado alrededor del arranque del agujero

# Modelos Kenney (CC0).
const BUILDINGS_LOW := [
	"res://assets/kenney_city/building-a.glb",
	"res://assets/kenney_city/building-c.glb",
	"res://assets/kenney_city/building-e.glb",
	"res://assets/kenney_city/building-g.glb",
	"res://assets/kenney_city/building-i.glb",
	"res://assets/kenney_city/building-k.glb",
]
const SKYSCRAPERS := [
	"res://assets/kenney_city/building-skyscraper-a.glb",
	"res://assets/kenney_city/building-skyscraper-c.glb",
	"res://assets/kenney_city/building-skyscraper-e.glb",
]
const CARS := [
	"res://assets/kenney_car/sedan.glb",
	"res://assets/kenney_car/suv.glb",
	"res://assets/kenney_car/taxi.glb",
	"res://assets/kenney_car/van.glb",
	"res://assets/kenney_car/police.glb",
	"res://assets/kenney_car/hatchback-sports.glb",
	"res://assets/kenney_car/delivery.glb",
	"res://assets/kenney_car/truck.glb",
	"res://assets/kenney_car/firetruck.glb",
	"res://assets/kenney_car/ambulance.glb",
]
const TREES := [
	"res://assets/kenney_nature/tree_default.glb",
	"res://assets/kenney_nature/tree_oak.glb",
	"res://assets/kenney_nature/tree_fat.glb",
	"res://assets/kenney_nature/tree_small.glb",
	"res://assets/kenney_nature/tree_pineDefaultA.glb",
	"res://assets/kenney_nature/tree_pineRoundA.glb",
]
# Props de parque (naturaleza): solo en manzanas-parque.
const PARK_PROPS := [
	"res://assets/kenney_nature/plant_bush.glb",
	"res://assets/kenney_nature/plant_bushLarge.glb",
	"res://assets/kenney_nature/rock_smallA.glb",
	"res://assets/kenney_nature/rock_smallB.glb",
	"res://assets/kenney_nature/rock_smallC.glb",
	"res://assets/kenney_nature/flower_redA.glb",
	"res://assets/kenney_nature/flower_yellowA.glb",
	"res://assets/kenney_nature/log_stack.glb",
]
# Props urbanos: solo en manzanas con edificios.
const URBAN_PROPS := [
	"res://assets/kenney_nature/sign.glb",
	"res://assets/kenney_city/detail-parasol-a.glb",
	"res://assets/kenney_city/detail-parasol-b.glb",
]

const BLOCK_HALF := 3.6  # medio ancho útil de una manzana (sin pisar vereda/calle)

# XP que da cada tipo de objeto al ser tragado.
const XP_SKYSCRAPER := 60
const XP_BUILDING := 25
const XP_CAR := 12
const XP_TREE := 6
const XP_URBAN_PROP := 3
const XP_PARK_PROP := 2
const XP_PEDESTRIAN := 1

# --- Golpe al tragar ---
# Los umbrales están en swallow_size, que es el ancho real del objeto en metros:
# props y peatones 0.4-0.9, árboles 1.0-1.6, autos 1.5-1.9, edificios 2.4-4.0,
# rascacielos 3.4-4.8.
const IMPACT_MIN_SIZE := 1.2    # abajo de esto no pasa nada: sacudir por un cesto es ruido
const IMPACT_FULL_SIZE := 4.5   # de acá para arriba, golpe máximo
const IMPACT_CURVE := 1.4       # >1 aplasta la parte baja: el auto se insinúa, el edificio pega
const HITSTOP_MIN_SIZE := 2.8   # frenar el tiempo sólo de edificio para arriba
const HITSTOP_SCALE := 0.08
const HITSTOP_SECS := 0.07
# Un derrumbe manda tres pedazos a la boca en menos de medio segundo. Sin este
# piso entre frenos, el juego tartamudea tres veces seguidas.
const HITSTOP_COOLDOWN := 0.35

# --- Derrumbe por pedazos ---
const PIECES_SKYSCRAPER := 3
const PIECES_BUILDING := 2

const SHIRT_COLORS := [
	Color(0.85, 0.30, 0.30), Color(0.30, 0.50, 0.85), Color(0.35, 0.70, 0.40),
	Color(0.90, 0.75, 0.30), Color(0.70, 0.40, 0.80), Color(0.95, 0.55, 0.25),
]

var _strip_mesh: BoxMesh
# Recursos compartidos. El renderer junta en un solo draw call todo lo que
# comparta el par (malla, material), así que crear una malla y un material por
# instancia son draw calls regalados: 32 peatones pasan de 6 a 128.
var _ped_body_mesh: CapsuleMesh
var _ped_head_mesh: SphereMesh
var _shirt_mats: Array[StandardMaterial3D] = []
var _skin_mat: StandardMaterial3D
var _grass_mat: ShaderMaterial
var _city: Node3D
var _park_blocks := {}       # Vector2i(ix, iz) -> true: manzanas que son parque
var _placed: Array[Vector3] = []  # (x, z, radio) ya ocupados: evita superposiciones
var _score_shown := 0.0
var _score_tween: Tween
var _bar_tween: Tween
var _timer_urgent := false
var _hitstop_until := 0.0    # msec del reloj REAL en que se suelta el freno
var _hitstop_ready_at := 0.0 # msec antes del cual no se admite otro freno

func _ready() -> void:
	Engine.time_scale = 1.0  # red de contención: si una partida anterior murió frenada
	# Orientar el sol en código (evita serializar una base rotada en el .tscn).
	# X = -40: el sol pega desde 40° sobre el horizonte (sol bajo, de tarde), que
	# da sombras largas y marcadas — un edificio de 10 m tira unos 12 m. Y = -35
	# las mantiene en diagonal: alineadas a las calles se comerían con el asfalto.
	sun.rotation_degrees = Vector3(-40, -35, 0)
	# El overlay debe procesar input aun con el árbol pausado.
	game_over.process_mode = Node.PROCESS_MODE_ALWAYS
	game_over.visible = false
	# Y la música también: si no, al pausar en el game over se corta de golpe a
	# mitad de compás, que suena a que se colgó el juego.
	music.process_mode = Node.PROCESS_MODE_ALWAYS
	# El loop se activa acá y no en el .import: con compress/mode=2 (QOA), poner
	# edit/loop_mode=1 no llega al recurso importado — probado, sigue leyéndose
	# loop_mode=0 y el tema se corta a los 30 s. El tema está hecho para
	# empalmar consigo mismo, así que va LOOP_FORWARD de punta a punta.
	# Se trabaja sobre una copia del stream, no sobre el importado: modificar el
	# compartido emite changed() y el player se resetea. Copiar, configurar,
	# asignar, arrancar (por eso tampoco hay autoplay en la escena).
	var theme := (music.stream as AudioStreamWAV).duplicate() as AudioStreamWAV
	theme.loop_mode = AudioStreamWAV.LOOP_FORWARD
	theme.loop_begin = 0
	# loop_end va en MUESTRAS y es literal: dejarlo en 0 no significa "hasta el
	# final" sino un loop de largo cero, y el tema no suena nada.
	theme.loop_end = int(theme.get_length() * theme.mix_rate)
	music.stream = theme
	music.play()
	# El número crece desde su izquierda, no desde el centro del label.
	score_value.pivot_offset = Vector2(0.0, 22.0)
	badge.pivot_offset = Vector2(26.0, 26.0)
	_placed.append(Vector3(0.0, 0.0, START_CLEAR))  # el agujero arranca despejado
	_build_shared_assets()
	_build_city_ground()
	_pick_parks()
	_populate_blocks()
	_spawn_cars_on_roads()
	_spawn_pedestrians()
	_spawn_rivals()
	_build_combo_label()
	_show_hint()
	hole.joystick = joystick  # el joystick es del HUD, el agujero sólo lo lee
	hole.swallowed.connect(_on_swallowed)
	hole.leveled_up.connect(_on_leveled_up)
	replay_button.pressed.connect(_on_replay)
	menu_button.pressed.connect(_on_menu)
	_update_hud()

# ----------------------------------------------------------------------------
# Loop de partida
# ----------------------------------------------------------------------------

func _process(delta: float) -> void:
	# Primero de todo y FUERA del `running`: si el hitstop quedara enganchado, el
	# juego entero se arrastra al 8% de velocidad. Y time_scale es del Engine, no
	# del árbol, así que ni recargar la escena lo arregla.
	if Engine.time_scale < 1.0 and Time.get_ticks_msec() >= _hitstop_until:
		Engine.time_scale = 1.0
	if not running:
		return
	if _combo_left > 0.0:
		_combo_left -= delta
		if _combo_left <= 0.0:
			_reset_combo()
	time_left -= delta
	if time_left <= 0.0:
		time_left = 0.0
		_end_game(false)
	_update_timer_label()

func _end_game(win: bool) -> void:
	running = false
	won = win
	# Con el árbol pausado _process deja de correr, así que el hitstop no se
	# soltaría solo: hay que devolverlo acá o el game over queda en cámara lenta.
	Engine.time_scale = 1.0
	joystick.release()  # si el timer corta a mitad de un arrastre, sacarlo de pantalla
	if win:
		game_over_title.text = "¡Objetivo cumplido!"
		game_over_title.add_theme_color_override("font_color", Color(0.55, 1.0, 0.5))
		final_score_label.text = "%s puntos, con %d s de sobra" % [
			_format_number(score), int(ceil(time_left))]
	else:
		game_over_title.text = "¡Se acabó el tiempo!"
		final_score_label.text = "%s de %s puntos" % [
			_format_number(score), _format_number(SCORE_GOAL)]
	game_over.visible = true
	# El tween cuelga del reproductor, que procesa siempre: por eso corre igual
	# con el árbol pausado.
	music.create_tween().tween_property(music, "volume_db", -60.0, 1.2)
	get_tree().paused = true  # congela agujero/objetos; el overlay sigue activo

func _on_replay() -> void:
	get_tree().paused = false  # despausar ANTES de recargar (paused vive en el árbol)
	get_tree().reload_current_scene()

func _on_menu() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file(MENU_SCENE)

func _on_object_consumed(xp: int) -> void:
	# El objeto llegó al fondo del pozo: recién ahora se acredita la XP.
	hole.gain_xp(xp)

func _on_object_fell_in(size: float, at: Vector3, weight: float) -> void:
	# Golpe proporcional a lo que entró: un cesto no mueve nada, un rascacielos
	# sacude el teléfono. Este es el momento que nos diferencia y hasta ahora
	# pasaba en silencio.
	var t := clampf(inverse_lerp(IMPACT_MIN_SIZE, IMPACT_FULL_SIZE, size), 0.0, 1.0)
	if t <= 0.0:
		return
	var punch := pow(t, IMPACT_CURVE) * weight
	hole.shake(hole.shake_strength * punch)
	hole.pulse_rim(0.06 + 0.14 * punch, at)
	hole.burst_dust(size, punch, at)
	if size >= HITSTOP_MIN_SIZE:
		_hitstop()

func _hitstop() -> void:
	# Freno brevísimo justo cuando la mole cruza la boca: la imagen se clava un
	# instante y arranca de golpe. Es lo que le da peso a la caída.
	# El plazo se mide con el reloj real (a Time.get_ticks_msec no lo afecta
	# time_scale): con un contador por delta, frenar el tiempo frenaría también
	# al contador que lo tiene que soltar, y el freno duraría 12 veces más.
	var now := float(Time.get_ticks_msec())
	if now < _hitstop_ready_at:
		return
	_hitstop_ready_at = now + HITSTOP_COOLDOWN * 1000.0
	Engine.time_scale = HITSTOP_SCALE
	_hitstop_until = now + HITSTOP_SECS * 1000.0

# ----------------------------------------------------------------------------
# Derrumbe: un edificio no cae entero, se parte
# ----------------------------------------------------------------------------

func _on_wants_break(obj: SwallowableRef) -> void:
	# Reemplaza el edificio por N pedazos apilados en el mismo lugar. Se hace acá
	# y no al generar la ciudad porque pre-partir las ~40 manzanas triplicaría los
	# draw calls de edificios, con un material distinto por pedazo (no batchean).
	# Así sólo pagan el costo los dos o tres que se están viniendo abajo.
	var model := obj.get_node_or_null("Visual/Model") as Node3D
	if model == null:
		return
	var meshes := _all_meshes(model)
	if meshes.is_empty():
		return
	var mesh: Mesh = meshes[0].mesh
	var src := mesh.surface_get_material(0) as StandardMaterial3D
	var tex: Texture2D = src.albedo_texture if src != null else null
	var native := mesh.get_aabb()

	var n: int = obj.break_pieces
	var piece_h: float = obj.world_size.y / float(n)
	var piece_xp: int = maxi(1, int(round(float(obj.xp_value) / float(n))))
	var piece_mass: float = obj.mass / float(n)
	for i in n:
		var p := swallowable_scene.instantiate() as SwallowableRef
		p.swallow_size = obj.swallow_size  # el pedazo no es "más fácil": es el mismo ancho
		p.xp_value = piece_xp
		p.sfx_kind = obj.sfx_kind
		p.impact_weight = 1.0 / float(n)
		p.consumed.connect(_on_object_consumed)
		p.fell_in.connect(_on_object_fell_in)
		var pv := p.get_node("Visual") as Node3D
		(pv.get_node("MeshInstance3D") as MeshInstance3D).visible = false
		# Cada pedazo dibuja el modelo entero y recorta su franja. El modelo se
		# baja lo que sube el corte, porque el origen del pedazo está en SU base
		# (igual que el de cualquier swallowable).
		# Sin DUPLICATE_USE_INSTANTIATION: con esa bandera Godot rearma el nodo
		# desde el .glb original y se pierde la escala con que se plantó en la ciudad.
		var clone := model.duplicate(
			Node.DUPLICATE_SIGNALS | Node.DUPLICATE_GROUPS | Node.DUPLICATE_SCRIPTS) as Node3D
		clone.position.y -= piece_h * float(i)
		pv.add_child(clone)
		# La franja va en unidades de la malla, no del mundo: así no hace falta
		# saber cuánto se escaló el modelo al plantarlo.
		var lo := native.position.y + native.size.y * float(i) / float(n)
		var hi := native.position.y + native.size.y * float(i + 1) / float(n)
		if i == 0:
			lo -= 0.01   # que el piso y el techo no se pierdan por redondeo
		if i == n - 1:
			hi += 0.01
		for m in _all_meshes(clone):
			m.material_override = _make_piece_mat(tex, lo, hi)

		swallowables.add_child(p)
		# Hereda la orientación completa, no sólo la posición: cuando se parte ya
		# viene volcado, y apilar los pedazos sobre el eje Y del mundo los dejaría
		# cruzados respecto de la torre en vez de alineados con ella.
		var up := obj.global_transform.basis.y
		p.global_transform = Transform3D(obj.global_transform.basis,
			obj.global_position + up * (piece_h * float(i)))
		p.setup_body(Vector3(obj.world_size.x, piece_h, obj.world_size.z))
		p.mass = piece_mass  # setup_body la calcula por swallow_size y daría la del entero
		p.release_into(hole)
		# Hereda el envión del edificio entero y suma un empujón lateral que crece
		# con la altura: una torre que se viene abajo se abre desde arriba, no baja
		# como un acordeón perfectamente apilado.
		var kick := 0.55 * float(i)
		p.linear_velocity = obj.linear_velocity + Vector3(randf_range(-kick, kick), 0.0, randf_range(-kick, kick))
		p.angular_velocity = obj.angular_velocity
	obj.queue_free()

func _make_piece_mat(tex: Texture2D, y_lo: float, y_hi: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = PIECE_SHADER
	m.set_shader_parameter("albedo_tex", tex)
	m.set_shader_parameter("y_min", y_lo)
	m.set_shader_parameter("y_max", y_hi)
	return m

func _on_swallowed(xp_gained: int, _total_xp: int) -> void:
	count += 1
	combo += 1
	_combo_left = COMBO_WINDOW
	var mult := combo_mult()
	var ganado := xp_gained * mult
	score += ganado
	_update_hud()
	_update_combo_label()
	_bump_score()
	_spawn_float_label("+%d" % ganado, hole.global_position + Vector3.UP * 0.5, mult > 1)
	if score >= SCORE_GOAL:
		_end_game(true)

func combo_mult() -> int:
	return clampi(1 + combo / COMBO_PER_STEP, 1, COMBO_MAX_MULT)

func _reset_combo() -> void:
	combo = 0
	_combo_left = 0.0
	_update_combo_label()

func _update_combo_label() -> void:
	var mult := combo_mult()
	if mult <= 1:
		# Sólo aparece cuando ya multiplica: un "x1" permanente es ruido de HUD.
		if _combo_label.visible:
			_combo_label.visible = false
		return
	var nuevo := not _combo_label.visible
	_combo_label.visible = true
	_combo_label.text = "x%d  COMBO" % mult
	# Golpecito en cada bocado, más fuerte cuando sube de escalón.
	_combo_label.scale = Vector2.ONE * (1.5 if nuevo or combo % COMBO_PER_STEP == 0 else 1.18)
	create_tween().tween_property(_combo_label, "scale", Vector2.ONE, 0.3) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _on_leveled_up(new_level: int) -> void:
	# Cartel central con pop elástico.
	var lbl := Label.new()
	lbl.text = "¡NIVEL %d!" % (new_level + 1)
	lbl.add_theme_font_size_override("font_size", 56)
	lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.add_theme_constant_override("outline_size", 10)
	lbl.custom_minimum_size = Vector2(420, 70)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	$UI.add_child(lbl)
	var vp := get_viewport().get_visible_rect().size
	lbl.position = Vector2(vp.x * 0.5 - 210.0, vp.y * 0.28)
	lbl.pivot_offset = Vector2(210, 35)
	lbl.scale = Vector2(0.2, 0.2)
	var t := create_tween()
	t.tween_property(lbl, "scale", Vector2.ONE, 0.35) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_interval(0.8)
	t.tween_property(lbl, "modulate:a", 0.0, 0.35)
	t.tween_callback(lbl.queue_free)
	# Latido del badge de nivel del HUD.
	badge.scale = Vector2(1.5, 1.5)
	create_tween().tween_property(badge, "scale", Vector2.ONE, 0.4) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	_update_hud()

func _spawn_float_label(text: String, world_pos: Vector3, big: bool = false) -> void:
	# "+N" flotante: puntos ganados, dibujados sobre el agujero y subiendo. Con
	# combo van más grandes y en naranja, para que se note que valen más.
	var cam := get_viewport().get_camera_3d()
	if cam == null or cam.is_position_behind(world_pos):
		return
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 38 if big else 26)
	lbl.add_theme_color_override("font_color",
		Color(1.0, 0.62, 0.2) if big else Color(1.0, 0.9, 0.35))
	lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.add_theme_constant_override("outline_size", 6)
	$UI.add_child(lbl)
	lbl.position = cam.unproject_position(world_pos) + Vector2(randf_range(-34.0, 34.0), -12.0)
	var t := create_tween().set_parallel(true)
	t.tween_property(lbl, "position:y", lbl.position.y - 72.0, 0.8).set_ease(Tween.EASE_OUT)
	t.tween_property(lbl, "modulate:a", 0.0, 0.8).set_ease(Tween.EASE_IN)
	t.chain().tween_callback(lbl.queue_free)

# ----------------------------------------------------------------------------
# HUD
# ----------------------------------------------------------------------------

func _update_hud() -> void:
	level_label.text = str(hole.level + 1)
	_update_goal_bar()
	_update_timer_label()

func _build_combo_label() -> void:
	_combo_label = Label.new()
	_combo_label.add_theme_font_size_override("font_size", 30)
	_combo_label.add_theme_color_override("font_color", Color(1.0, 0.62, 0.2))
	_combo_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_combo_label.add_theme_constant_override("outline_size", 8)
	_combo_label.position = Vector2(22.0, 262.0)  # despejado del panel de puntaje
	_combo_label.pivot_offset = Vector2(0.0, 18.0)  # crece desde su izquierda
	_combo_label.visible = false
	$UI.add_child(_combo_label)

func _show_hint() -> void:
	# Cartel de arranque, como el del juego de referencia: la partida ahora empieza
	# sin pasar por el menú, así que el objetivo hay que decirlo acá o no se dice
	# en ninguna parte.
	var lbl := Label.new()
	lbl.text = "Comé todo hasta llegar a %s puntos" % _format_number(SCORE_GOAL)
	lbl.add_theme_font_size_override("font_size", 30)
	lbl.add_theme_color_override("font_color", Color(0.6, 1.0, 0.55))
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	lbl.add_theme_constant_override("outline_size", 10)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var vp := get_viewport().get_visible_rect().size
	lbl.size = Vector2(vp.x, 46.0)
	lbl.position = Vector2(0.0, vp.y * 0.17)
	$UI.add_child(lbl)
	var t := create_tween()
	t.tween_interval(HINT_SECS)
	t.tween_property(lbl, "modulate:a", 0.0, 0.6)
	t.tween_callback(lbl.queue_free)

func _bump_score() -> void:
	# El número no salta: sube contando, y pega un golpecito de escala.
	if _score_tween != null and _score_tween.is_valid():
		_score_tween.kill()
	_score_tween = create_tween()
	_score_tween.tween_method(_set_score_display, _score_shown, float(score), 0.35) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	score_value.scale = Vector2(1.22, 1.22)
	create_tween().tween_property(score_value, "scale", Vector2.ONE, 0.25) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _set_score_display(v: float) -> void:
	_score_shown = v
	score_value.text = _format_number(int(round(v)))

func _update_goal_bar() -> void:
	# La barra mide el OBJETIVO de la partida, no la XP al próximo nivel. El nivel
	# ya tiene su propio feedback —el badge que late y el cartel central—, y lo que
	# el jugador necesita ver todo el tiempo es cuánto le falta para ganar.
	goal_label.text = "%s / %s" % [_format_number(score), _format_number(SCORE_GOAL)]
	var target := clampf(float(score) / float(SCORE_GOAL) * 100.0, 0.0, 100.0)
	if _bar_tween != null and _bar_tween.is_valid():
		_bar_tween.kill()
	_bar_tween = create_tween()
	_bar_tween.tween_property(goal_bar, "value", target, 0.3).set_trans(Tween.TRANS_CUBIC)

func _update_timer_label() -> void:
	var m: int = int(time_left) / 60
	var s: int = int(time_left) % 60
	timer_label.text = "%d:%02d" % [m, s]
	# Los últimos 15 segundos en rojo (se aplica una sola vez, no cada frame).
	var urgent := time_left <= 15.0
	if urgent != _timer_urgent:
		_timer_urgent = urgent
		timer_label.add_theme_color_override("font_color",
			Color(1.0, 0.35, 0.3) if urgent else Color.WHITE)

func _format_number(n: int) -> String:
	# Separador de miles, que 1240 no se lea como un número cualquiera.
	var s := str(n)
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "." + out
	return out

# ----------------------------------------------------------------------------
# Generación de la ciudad
# ----------------------------------------------------------------------------

func _build_city_ground() -> void:
	# Calles (asfalto) + veredas (gris claro) + línea central, en una grilla.
	var city := Node3D.new()
	city.name = "City"
	add_child(city)
	_city = city
	_strip_mesh = BoxMesh.new()
	_strip_mesh.size = Vector3(1, 0.02, 1)

	# Todo el piso comparte el shader que recorta la boca del pozo.
	ground.material_override = _make_ground_mat(Color(0.58, 0.62, 0.55))
	var mat_side := _make_ground_mat(Color(0.72, 0.72, 0.70))
	var mat_asph := _make_ground_mat(Color(0.16, 0.16, 0.19))
	var mat_line := _make_ground_mat(Color(0.92, 0.80, 0.22))
	var length := MAP_HALF * 2.0

	for line in ROAD_LINES:
		var lf := float(line)
		# Vereda (más ancha, abajo) — corre a lo largo de Z y de X.
		_add_strip(city, lf, 0.0, ROAD_W + SIDE_W * 2.0, length, Y_SIDEWALK, mat_side)
		_add_strip(city, 0.0, lf, length, ROAD_W + SIDE_W * 2.0, Y_SIDEWALK, mat_side)
		# Asfalto.
		_add_strip(city, lf, 0.0, ROAD_W, length, Y_ROAD, mat_asph)
		_add_strip(city, 0.0, lf, length, ROAD_W, Y_ROAD, mat_asph)
		# Línea central.
		_add_strip(city, lf, 0.0, 0.25, length, Y_LINE, mat_line)
		_add_strip(city, 0.0, lf, length, 0.25, Y_LINE, mat_line)

func _add_strip(parent: Node, cx: float, cz: float, sx: float, sz: float, y: float, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = _strip_mesh
	mi.material_override = mat
	mi.scale = Vector3(sx, 1.0, sz)
	mi.position = Vector3(cx, y, cz)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)

func _build_shared_assets() -> void:
	# Una malla y un material por VARIANTE, no por instancia. Ver el comentario de
	# los campos: es la diferencia entre 6 y 128 draw calls sólo en peatones.
	_ped_body_mesh = CapsuleMesh.new()
	_ped_body_mesh.radius = 0.09
	_ped_body_mesh.height = 0.34
	_ped_head_mesh = SphereMesh.new()
	_ped_head_mesh.radius = 0.07
	_ped_head_mesh.height = 0.14
	for c in SHIRT_COLORS:
		_shirt_mats.append(_make_mat(c))
	_skin_mat = _make_mat(Color(0.94, 0.76, 0.62))
	_grass_mat = _make_ground_mat(Color(0.38, 0.62, 0.32))

func _make_ground_mat(color: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = GROUND_SHADER
	m.set_shader_parameter("base_color", color)
	return m

func _make_mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 1.0
	return m

func _pick_parks() -> void:
	# 4 manzanas al azar (de 16) son parques: solo naturaleza, sin edificios.
	while _park_blocks.size() < 4:
		_park_blocks[Vector2i(randi() % BLOCK_CENTERS.size(), randi() % BLOCK_CENTERS.size())] = true

func _populate_blocks() -> void:
	# Cada manzana se llena según su tipo: parque o edificios.
	for ix in BLOCK_CENTERS.size():
		for iz in BLOCK_CENTERS.size():
			var bx := float(BLOCK_CENTERS[ix])
			var bz := float(BLOCK_CENTERS[iz])
			if _park_blocks.has(Vector2i(ix, iz)):
				_spawn_park(bx, bz)
			else:
				_spawn_building_block(bx, bz)

func _find_spot(bx: float, bz: float, spread: float, footprint: float) -> Vector3:
	# Punto libre dentro de la manzana. Ahora que los objetos son rígidos de
	# verdad, dos que nacen encajados se repelen de golpe al despertar: hay que
	# garantizar que nadie se superponga con nadie desde el arranque.
	var r := footprint * 0.5
	for _try in 16:
		var x := bx + randf_range(-spread, spread)
		var z := bz + randf_range(-spread, spread)
		if _is_free(x, z, r):
			_placed.append(Vector3(x, z, r))
			return Vector3(x, 0.0, z)
	return Vector3.INF  # sin lugar: el llamador saltea este objeto

func _is_free(x: float, z: float, r: float) -> bool:
	for p in _placed:
		if Vector2(x - p.x, z - p.y).length() < r + p.z:
			return false
	return true

func _spawn_park(bx: float, bz: float) -> void:
	# Césped + árboles + arbustos/rocas/flores. Comida chica y mediana.
	_add_strip(_city, bx, bz, BLOCK_HALF * 2.0 + 1.4, BLOCK_HALF * 2.0 + 1.4, 0.004, _grass_mat)
	for _k in range(randi_range(4, 7)):
		var foot := randf_range(1.0, 1.6)
		var pos := _find_spot(bx, bz, BLOCK_HALF, foot)
		if pos != Vector3.INF:
			_spawn_model_swallowable(TREES.pick_random(), pos, foot, randf_range(0.0, TAU), XP_TREE)
	for _k in range(randi_range(6, 10)):
		var foot := randf_range(0.4, 0.8)
		var pos := _find_spot(bx, bz, BLOCK_HALF, foot)
		if pos != Vector3.INF:
			_spawn_model_swallowable(PARK_PROPS.pick_random(), pos, foot, randf_range(0.0, TAU), XP_PARK_PROP)

func _spawn_building_block(bx: float, bz: float) -> void:
	# 1-3 edificios (a veces rascacielos) + props urbanos chicos.
	for _k in range(randi_range(1, 3)):
		var sky := randf() < 0.22
		var foot := randf_range(3.4, 4.8) if sky else randf_range(2.4, 4.0)
		var pos := _find_spot(bx, bz, 3.0, foot)
		if pos == Vector3.INF:
			continue
		var model: String = SKYSCRAPERS.pick_random() if sky else BUILDINGS_LOW.pick_random()
		var b := _spawn_model_swallowable(model, pos, foot, 0.0, XP_SKYSCRAPER if sky else XP_BUILDING)
		b.sfx_kind = Sfx.Kind.HEAVY if sky else Sfx.Kind.DEBRIS
		b.break_pieces = PIECES_SKYSCRAPER if sky else PIECES_BUILDING
	for _k in range(randi_range(2, 4)):
		var foot := randf_range(0.5, 0.9)
		var pos := _find_spot(bx, bz, BLOCK_HALF, foot)
		if pos != Vector3.INF:
			_spawn_model_swallowable(URBAN_PROPS.pick_random(), pos, foot, randf_range(0.0, TAU), XP_URBAN_PROP)

func _spawn_cars_on_roads() -> void:
	# Autos con ruta simple: recorren su calle en línea recta y al llegar al
	# borde del mapa reaparecen del lado opuesto. Solo spawn en carriles.
	for line in ROAD_LINES:
		var lf := float(line)
		for _k in range(randi_range(2, 4)):
			# Calle a lo largo de Z (x = línea). El carril define el sentido.
			var lane := 1.25 * (1.0 if randf() < 0.5 else -1.0)
			var dir_z := -1.0 if lane > 0.0 else 1.0
			var z := randf_range(-MAP_HALF + 3.0, MAP_HALF - 3.0)
			_spawn_car(Vector3(lf + lane, 0.0, z), Vector3(0.0, 0.0, dir_z))
		for _k in range(randi_range(2, 4)):
			# Calle a lo largo de X (z = línea).
			var lane2 := 1.25 * (1.0 if randf() < 0.5 else -1.0)
			var dir_x := 1.0 if lane2 > 0.0 else -1.0
			var x := randf_range(-MAP_HALF + 3.0, MAP_HALF - 3.0)
			_spawn_car(Vector3(x, 0.0, lf + lane2), Vector3(dir_x, 0.0, 0.0))

func _spawn_car(pos: Vector3, dir: Vector3) -> void:
	if Vector2(pos.x, pos.z).length() < START_CLEAR + 2.0:
		return  # no arrancar con un auto encima del agujero
	var rot := atan2(dir.x, dir.z)  # mirar hacia la dirección de marcha
	var car := _spawn_model_swallowable(CARS.pick_random(), pos, randf_range(1.5, 1.9), rot, XP_CAR)
	car.sfx_kind = Sfx.Kind.CAR
	car.start_driving(dir, randf_range(2.5, 4.5), MAP_HALF, hole)

func _spawn_pedestrians() -> void:
	# Peatones por las veredas: comida mínima, móvil, que huye del agujero.
	var spawned := 0
	while spawned < 32:
		var line := float(ROAD_LINES.pick_random())
		var side := (ROAD_W * 0.5 + SIDE_W * 0.5) * (1.0 if randf() < 0.5 else -1.0)
		var along := randf_range(-MAP_HALF + 2.0, MAP_HALF - 2.0)
		var pos: Vector3
		var dir: Vector3
		if randf() < 0.5:
			pos = Vector3(line + side, 0.0, along)  # vereda de una calle N-S
			dir = Vector3(0.0, 0.0, 1.0 if randf() < 0.5 else -1.0)
		else:
			pos = Vector3(along, 0.0, line + side)  # vereda de una calle E-O
			dir = Vector3(1.0 if randf() < 0.5 else -1.0, 0.0, 0.0)
		if Vector2(pos.x, pos.z).length() < START_CLEAR + 1.0:
			continue  # centro despejado (arranca el agujero)
		_spawn_pedestrian(pos, dir)
		spawned += 1

func _spawn_pedestrian(pos: Vector3, dir: Vector3) -> void:
	# Personita procedural: cápsula (cuerpo) + esfera (cabeza).
	var s := swallowable_scene.instantiate() as SwallowableRef
	var visual := s.get_node("Visual") as Node3D
	(visual.get_node("MeshInstance3D") as MeshInstance3D).visible = false
	var body := MeshInstance3D.new()
	body.mesh = _ped_body_mesh
	body.material_override = _shirt_mats.pick_random()
	body.position.y = 0.20
	visual.add_child(body)
	var head := MeshInstance3D.new()
	head.mesh = _ped_head_mesh
	head.material_override = _skin_mat
	head.position.y = 0.44
	visual.add_child(head)
	s.swallow_size = 0.35
	s.xp_value = XP_PEDESTRIAN
	s.sfx_kind = Sfx.Kind.VOICE
	s.consumed.connect(_on_object_consumed)
	s.fell_in.connect(_on_object_fell_in)
	s.position = pos
	swallowables.add_child(s)
	s.setup_body(Vector3(0.25, 0.55, 0.25))
	s.start_walking(dir, MAP_HALF, hole)

func _spawn_rivals() -> void:
	# Arrancan lejos del jugador: verse comer al vecino en el segundo uno, sin
	# haber entendido todavía que hay vecinos, es confuso y no enseña nada.
	for i in RIVALS.size():
		var r := RivalRef.new()
		r.rival_name = RIVALS[i]["nombre"]
		r.color = RIVALS[i]["color"]
		var pos := Vector3.ZERO
		for _try in 30:
			pos = Vector3(randf_range(-MAP_HALF + 4.0, MAP_HALF - 4.0), 0.0,
				randf_range(-MAP_HALF + 4.0, MAP_HALF - 4.0))
			if Vector2(pos.x, pos.z).length() > RIVAL_START_CLEAR:
				break
		add_child(r)
		r.global_position = pos
		# Las tablas de progresión salen del agujero del jugador: son balance del
		# juego y no tienen por qué existir duplicadas en dos archivos.
		r.setup(swallowables, hole.level_radii, hole.level_xp_req, MAP_HALF)
		rivals.append(r)
	rival_arrows.setup(hole.camera, hole, rivals)
	leaderboard.setup(hole, rivals, func(): return score)

func _spawn_model_swallowable(model_path: String, pos: Vector3, target_footprint: float, rot_y: float = 0.0, xp: int = 1) -> SwallowableRef:
	# Crea un swallowable con un modelo .glb. El swallow_size y la colisión se
	# derivan del tamaño REAL del modelo (swallow_size = ancho en el mundo), así
	# "disco >= objeto" se siente igual que con los cubos.
	var s := swallowable_scene.instantiate() as SwallowableRef
	s.xp_value = xp
	s.consumed.connect(_on_object_consumed)
	s.fell_in.connect(_on_object_fell_in)
	s.wants_break.connect(_on_wants_break)  # sólo dispara si le ponen break_pieces > 1
	var visual := s.get_node("Visual") as Node3D
	(visual.get_node("MeshInstance3D") as MeshInstance3D).visible = false
	var model: Node3D = (load(model_path) as PackedScene).instantiate()
	model.name = "Model"  # nombre estable: el derrumbe lo busca por acá, y el hijo 0 es el cubo placeholder
	visual.add_child(model)
	s.position = pos  # los modelos Kenney tienen el origen en la base
	swallowables.add_child(s)  # ya en el árbol para poder medir su AABB

	var native: Vector3 = _merged_aabb(model).size
	var native_w: float = maxf(maxf(native.x, native.z), 0.001)
	var scale_f: float = target_footprint / native_w
	model.scale = Vector3.ONE * scale_f
	s.swallow_size = target_footprint
	s.setup_body(native * scale_f)
	s.rotation.y = rot_y  # rotar recién después de medir el AABB (si no, se infla)
	return s

# --- Utilidades de medición de modelos ---

func _merged_aabb(node: Node) -> AABB:
	# AABB combinado (en espacio mundo) de todos los MeshInstance3D del subárbol.
	var out := AABB()
	var has := false
	for mi in _all_meshes(node):
		var world_a: AABB = mi.global_transform * mi.get_aabb()
		if not has:
			out = world_a
			has = true
		else:
			out = out.merge(world_a)
	return out

func _all_meshes(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		result.append(node)
	for c in node.get_children():
		result.append_array(_all_meshes(c))
	return result
