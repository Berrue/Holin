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
## Calibrado con devtools/stress.gd, no a ojo. Para recalibrar: poner un número
## inalcanzable acá, correr el stress, y leer la curva del informe.
##
## Curva medida en el mapa actual (MAP_HALF 72, con lago y 3 rivales), en puntaje
## por segundo transcurrido: 33 a los 20 s, 159 a los 60, 722 a los 80, 1467 a
## los 100 y 2845 a los 120. Es muy acelerada porque el agujero crece y cada
## bocado vale más — de ahí que casi todo el puntaje salga del último tercio.
##
## 2100 es ~74% del techo del bot, la misma proporción que tenía el 1200 anterior
## contra su techo de ~1580 en el mapa de la mitad de lado. Todavía SIN validar
## con un humano: un jugador real rinde bastante menos que el bot, así que si en
## el celular se siente inalcanzable, este es el número a bajar.
##
## OJO: depende del tamaño del mapa Y de los rivales. Duplicar el lado del mapa
## cuadruplicó la comida y movió el techo de 1580 a 2845; cambiar la cantidad de
## rivales o su handicap también obliga a rehacerlo.
const SCORE_GOAL := 2100
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
const COMBO_HUD_COLORS := [
	Color(1.0, 0.56, 0.12),
	Color(1.0, 0.76, 0.14),
	Color(1.0, 0.94, 0.52),
]

# El piso usa shader propio: recorta la boca del pozo y se oscurece en el borde.
const GROUND_SHADER := preload("res://shaders/ground_hole.gdshader")
# Material propio del lago: textura procedural animada, brillo y espuma de costa.
const WATER_SHADER := preload("res://shaders/water.gdshader")
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
const TrafficSpawnerRef = preload("res://scripts/traffic_spawner.gd")
const RemoteHoleRef = preload("res://scripts/remote_hole.gd")
const REMOTE_HOLE_SCENE := preload("res://scenes/remote_hole.tscn")

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
@onready var player_start: Marker3D = $AuthoredCity/Markers/PlayerStart
@onready var lake_root: Node3D = $AuthoredCity/Lake
@onready var traffic_spawner := $TrafficSpawner as TrafficSpawnerRef
@onready var remote_players: Node3D = $RemotePlayers
@onready var network_status: Label = $UI/NetworkStatus

var time_left := GAME_DURATION
var score := 0
var count := 0
var running := true
var won := false
var combo := 0
var rivals: Array = []
var _combo_left := 0.0
var _combo_panel: PanelContainer
var _combo_label: Label
var _combo_bar: ProgressBar
var _combo_panel_style: StyleBoxFlat
var _combo_fill_style: StyleBoxFlat
var _combo_panel_tween: Tween
var _combo_last_mult := 1
var _start_position := START_POS

# --- Layout de la ciudad ---
# Mundo del doble de lado que antes (era MAP_HALF 36, 5 calles, 4 manzanas por
# eje): mismo paso de 16 entre calles, más calles. Cuadruplica el área, así que
# también se cuadruplican parques y peatones más abajo para mantener la densidad.
const ROAD_LINES := [-64, -48, -32, -16, 0, 16, 32, 48, 64]   # ejes de las calles (X y Z)
const BLOCK_CENTERS := [-56, -40, -24, -8, 8, 24, 40, 56]      # centros de manzana (entre calles)
const MAP_HALF := 72.0

const LAKE_HALF_EXTENTS := Vector2(3.0, 2.5)
const BASIN_HALF_EXTENTS := Vector2(3.5, 3.0)

# --- Agua del mapa ---
# El lago principal vive dentro de una manzana en main.tscn, sin cortar calles.
# La plaza central tiene una fuente más chica, también authored en la escena.
# Estas medidas mantienen libre la red vial y delimitan la zona no transitable.
const LAKE_RADIUS := 3.0
# El agua vive dentro de una pileta cuadrada de hormigón. El borde es visible y
# también tiene colisión; BASIN_OUTER_HALF incluye el espesor de los muros.
const BASIN_HALF := 3.5
const BASIN_WALL_WIDTH := 0.5
const BASIN_WALL_HEIGHT := 0.55
const BASIN_OUTER_HALF := BASIN_HALF + BASIN_WALL_WIDTH * 0.5
const BASIN_FLOOR_HEIGHT := 0.18
const Y_BASIN_TOP := 0.018
const Y_WATER := 0.040
## Posición de respaldo. En juego manda AuthoredCity/Markers/PlayerStart.
const START_POS := Vector3(0.0, 0.0, 32.0)
const ROAD_W := 5.0
const SIDE_W := 1.6
const Y_SIDEWALK := 0.006
const Y_ROAD := 0.010
const Y_LINE := 0.014
const START_CLEAR := 4.5  # radio despejado alrededor del arranque del agujero

# --- Biblioteca de props (escenas, no .glb sueltos) ---
# Cada entrada es una escena de scenes/props/ que se configura sola: trae su
# modelo, su paleta, su ancho, su XP y en cuántos pedazos se parte. Para tocar
# cualquiera de esas cosas se abre la escena en el editor — no hay que venir acá.
# Para sumar un edificio nuevo: duplicás una escena de props, le cambiás el
# modelo, y la agregás a la lista.
#
# Los 19 tipos salen del pack Kenney (CC0) repartidos en 3 paletas
# (resources/city_palette_*.tres): mismo modelo, otro atlas, otra fachada.
const BUILDINGS_LOW := [
	preload("res://scenes/props/building_a.tscn"),
	preload("res://scenes/props/building_b.tscn"),
	preload("res://scenes/props/building_c.tscn"),
	preload("res://scenes/props/building_d.tscn"),
	preload("res://scenes/props/building_e.tscn"),
	preload("res://scenes/props/building_f.tscn"),
	preload("res://scenes/props/building_g.tscn"),
	preload("res://scenes/props/building_h.tscn"),
	preload("res://scenes/props/building_i.tscn"),
	preload("res://scenes/props/building_j.tscn"),
	preload("res://scenes/props/building_k.tscn"),
	preload("res://scenes/props/building_l.tscn"),
	preload("res://scenes/props/building_m.tscn"),
	preload("res://scenes/props/building_n.tscn"),
]
const SKYSCRAPERS := [
	preload("res://scenes/props/skyscraper_a.tscn"),
	preload("res://scenes/props/skyscraper_b.tscn"),
	preload("res://scenes/props/skyscraper_c.tscn"),
	preload("res://scenes/props/skyscraper_d.tscn"),
	preload("res://scenes/props/skyscraper_e.tscn"),
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
# Los edificios y rascacielos NO están acá: su XP (25 y 60) vive en cada escena
# de scenes/props/, junto con su tamaño y su paleta.
const XP_CAR := 12
const XP_TREE := 6
const XP_URBAN_PROP := 3
const XP_PARK_PROP := 2
const XP_PEDESTRIAN := 1

# --- Golpe al tragar: tres escalones perceptualmente distintos ---
# Los umbrales están en swallow_size, que es el ancho real del objeto en metros:
# props y peatones 0.4-0.9, árboles 1.0-1.6, autos 1.5-1.9, edificios 2.4-4.0,
# rascacielos 3.4-4.8.
const IMPACT_MEDIUM_SIZE := 1.2
const IMPACT_LARGE_SIZE := 2.8
const IMPACT_FULL_SIZE := 4.5   # de acá para arriba, golpe máximo
const HITSTOP_SCALE := 0.08
const HITSTOP_SECS := 0.07
# Un derrumbe manda tres pedazos a la boca en menos de medio segundo. Sin este
# piso entre frenos, el juego tartamudea tres veces seguidas.
const HITSTOP_COOLDOWN := 0.35

# --- Revelado al crecer ---
const UNLOCK_REVEAL_MIN_RANGE := 14.0
const UNLOCK_REVEAL_RADIUS_FACTOR := 3.0
const UNLOCK_REVEAL_MAX_OBJECTS := 12

# El derrumbe por pedazos (break_pieces: 2 para edificios, 3 para rascacielos)
# también se define por prop, en scenes/props/.

# --- Rig del peatón ---
# Alturas medidas para que las piernas se VEAN. El primer intento tenía el torso
# centrado en 0.20 (o sea bajando hasta 0.03) y las piernas de 0 a 0.14: quedaban
# casi enteras adentro de la cápsula y sólo asomaban dos tacos. Subiendo el torso
# a 0.30 las piernas tienen los 0.16 completos por debajo.
#
#   piernas  0.00 → 0.16     cadera a 0.16
#   torso    0.13 → 0.47     cápsula r=0.09, centro 0.30
#   brazos   0.24 → 0.40     hombro a 0.40
#   cabeza   0.47 → 0.61     esfera r=0.07, centro 0.54
const LIMB_LEN := 0.16
const HIP_Y := 0.16
const SHOULDER_Y := 0.40
const BODY_Y := 0.30
const HEAD_Y := 0.54
const PED_HEIGHT := 0.62

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
var _ped_limb_mesh: BoxMesh          # la misma para brazos y piernas
var _shirt_mats: Array[StandardMaterial3D] = []
var _skin_mat: StandardMaterial3D
var _pants_mat: StandardMaterial3D
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
var _network_send_left := 0.0

func _ready() -> void:
	Engine.time_scale = 1.0  # red de contención: si una partida anterior murió frenada
	if NetworkSession.is_networked():
		seed(NetworkSession.match_seed)
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
	_adopt_manual_swallowables()
	# El inicio también vive en main.tscn: mover AuthoredCity/Markers/PlayerStart
	# en el editor cambia dónde arranca el jugador sin tocar este script.
	_start_position = player_start.global_position
	hole.global_position = _start_position
	if NetworkSession.is_networked():
		hole.global_position = _network_spawn_position(multiplayer.get_unique_id())
	# Estas reservas siguen protegiendo el tráfico dinámico y permiten conservar
	# las herramientas de generación antiguas como referencia, pero la geometría,
	# parques y edificios ya viven persistidos en AuthoredCity dentro de main.tscn.
	_placed.append(Vector3(_start_position.x, _start_position.z, START_CLEAR))
	var lake_center := _lake_center_xz()
	_placed.append(Vector3(lake_center.x, lake_center.y, BASIN_HALF_EXTENTS.length()))
	_build_shared_assets()
	_spawn_cars_on_roads()
	_spawn_pedestrians()
	traffic_spawner.car_spawn_requested.connect(_spawn_car_from_edge)
	traffic_spawner.npc_spawn_requested.connect(_spawn_pedestrian_from_edge)
	_spawn_rivals()
	_build_combo_label()
	_show_hint()
	hole.joystick = joystick  # el joystick es del HUD, el agujero sólo lo lee
	hole.swallowed.connect(_on_swallowed)
	hole.leveled_up.connect(_on_leveled_up)
	replay_button.pressed.connect(_on_replay)
	menu_button.pressed.connect(_on_menu)
	_setup_network_game()
	_update_hud()

func _adopt_manual_swallowables() -> void:
	# Un swallowable armado a mano (auto_setup=true en el Inspector) ya se
	# configuró solo en su propio _ready(), que corre ANTES que este —los hijos
	# de la escena siempre arrancan antes que el padre—. Sólo falta conectarlo a
	# la partida: sin esto comería igual (la física no distingue) pero no
	# sumaría puntaje, no pegaría el golpe de impacto, y si es un edificio
	# partible se quedaría tildado para siempre esperando que alguien atienda
	# wants_break.
	#
	# En el editor permanecen ordenados por manzana/parque dentro de AuthoredCity.
	# Al iniciar la partida se mueven a Swallowables conservando su transform
	# global: así los rivales, el bot de QA y el derrumbe los encuentran por el
	# mismo camino que a los autos y peatones dinámicos.
	for s in get_tree().get_nodes_in_group("swallowable"):
		var obj := s as SwallowableRef
		if obj == null or obj.consumed.is_connected(_on_object_consumed):
			continue
		if obj.get_parent() != swallowables:
			obj.reparent(swallowables, true)
		obj.consumed.connect(_on_object_consumed)
		obj.fell_in.connect(_on_object_fell_in)
		obj.wants_break.connect(_on_wants_break)

# ----------------------------------------------------------------------------
# Loop de partida
# ----------------------------------------------------------------------------

func _process(delta: float) -> void:
	# Primero de todo y FUERA del `running`: si el hitstop quedara enganchado, el
	# juego entero se arrastra al 8% de velocidad. Y time_scale es del Engine, no
	# del árbol, así que ni recargar la escena lo arregla.
	if Engine.time_scale < 1.0 and Time.get_ticks_msec() >= _hitstop_until:
		Engine.time_scale = 1.0
	_network_tick(delta)
	if not running:
		return
	if _combo_left > 0.0:
		_combo_left -= delta
		if _combo_left <= 0.0:
			_reset_combo()
	_update_combo_timer()
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
	NetworkSession.disconnect_session()
	get_tree().change_scene_to_file(MENU_SCENE)

func _setup_network_game() -> void:
	network_status.visible = NetworkSession.is_networked()
	if not NetworkSession.is_networked():
		return
	NetworkSession.peer_joined.connect(_on_network_peer_joined)
	NetworkSession.peer_left.connect(_on_network_peer_left)
	NetworkSession.players_changed.connect(_refresh_network_status)
	NetworkSession.state_changed.connect(_on_network_state_changed)
	for peer_id in multiplayer.get_peers():
		_ensure_remote_player(int(peer_id))
	_refresh_network_status()

func _network_tick(delta: float) -> void:
	if not NetworkSession.is_networked():
		return
	_network_send_left -= delta
	if _network_send_left > 0.0:
		return
	_network_send_left = 0.05
	var peer_id := multiplayer.get_unique_id()
	if multiplayer.is_server():
		_client_receive_player_state.rpc(peer_id, hole.global_position, hole.radius, score, hole.level)
	else:
		_server_receive_player_state.rpc_id(1, hole.global_position, hole.radius, score, hole.level)

func _network_spawn_position(peer_id: int) -> Vector3:
	var side := -1.0 if peer_id == 1 else 1.0
	return _start_position + Vector3(side * 4.0, 0.0, 0.0)

func _ensure_remote_player(peer_id: int) -> RemoteHoleRef:
	if peer_id == multiplayer.get_unique_id():
		return null
	var existing := remote_players.get_node_or_null(str(peer_id)) as RemoteHoleRef
	if existing != null:
		return existing
	var proxy := REMOTE_HOLE_SCENE.instantiate() as RemoteHoleRef
	proxy.name = str(peer_id)
	proxy.setup(peer_id, NetworkSession.get_player_name(peer_id), _network_spawn_position(peer_id))
	remote_players.add_child(proxy)
	return proxy

func _apply_remote_player_state(peer_id: int, pos: Vector3, radius: float, remote_score: int, remote_level: int) -> void:
	if peer_id == multiplayer.get_unique_id():
		return
	var safe_pos := pos
	safe_pos.x = clampf(safe_pos.x, -MAP_HALF - 12.0, MAP_HALF + 12.0)
	safe_pos.y = 0.0
	safe_pos.z = clampf(safe_pos.z, -MAP_HALF - 12.0, MAP_HALF + 12.0)
	var proxy := _ensure_remote_player(peer_id)
	if proxy != null:
		proxy.push_state(safe_pos, radius, remote_score, remote_level)

func _on_network_peer_joined(peer_id: int) -> void:
	_ensure_remote_player(peer_id)
	_refresh_network_status()

func _on_network_peer_left(peer_id: int) -> void:
	var proxy := remote_players.get_node_or_null(str(peer_id))
	if proxy != null:
		proxy.queue_free()
	_refresh_network_status()

func _on_network_state_changed() -> void:
	if NetworkSession.is_networked():
		_refresh_network_status()
		return
	for proxy in remote_players.get_children():
		proxy.queue_free()
	network_status.visible = false

func _refresh_network_status() -> void:
	if not NetworkSession.is_networked():
		network_status.visible = false
		return
	network_status.visible = true
	var role := "HOST" if NetworkSession.is_host() else "CLIENTE"
	network_status.text = "%s  |  %s  |  ENet :%d" % [
		role, NetworkSession.get_player_name(multiplayer.get_unique_id()), NetworkSession.DEFAULT_PORT]

@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _server_receive_player_state(pos: Vector3, radius: float, remote_score: int, remote_level: int) -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not NetworkSession.player_names.has(peer_id):
		return
	_apply_remote_player_state(peer_id, pos, radius, remote_score, remote_level)
	_client_receive_player_state.rpc(peer_id, pos, radius, remote_score, remote_level)

@rpc("authority", "call_remote", "unreliable_ordered", 1)
func _client_receive_player_state(peer_id: int, pos: Vector3, radius: float, remote_score: int, remote_level: int) -> void:
	_apply_remote_player_state(peer_id, pos, radius, remote_score, remote_level)

func _on_object_consumed(xp: int) -> void:
	# El objeto llegó al fondo del pozo: recién ahora se acredita la XP.
	hole.gain_xp(xp)

func _on_object_fell_in(size: float, at: Vector3, weight: float) -> void:
	# Cada rango usa una gramática distinta. Si todo fuera el mismo efecto
	# escalado, veinte props chicos ensuciarían la pantalla y un edificio no
	# tendría un escalón propio de peso.
	if size < IMPACT_MEDIUM_SIZE:
		hole.pulse_rim(0.025 * weight, at)
		return
	if size < IMPACT_LARGE_SIZE:
		var medium_t := clampf(inverse_lerp(IMPACT_MEDIUM_SIZE, IMPACT_LARGE_SIZE, size), 0.0, 1.0)
		var medium_punch := (0.16 + medium_t * 0.24) * weight
		hole.shake(hole.shake_strength * medium_punch * 0.45)
		hole.pulse_rim((0.055 + medium_t * 0.05) * weight, at)
		hole.burst_dust(size, medium_punch, at)
		return
	var large_t := clampf(inverse_lerp(IMPACT_LARGE_SIZE, IMPACT_FULL_SIZE, size), 0.0, 1.0)
	var large_punch := (0.48 + pow(large_t, 1.25) * 0.52) * weight
	hole.shake(hole.shake_strength * large_punch)
	hole.pulse_rim((0.12 + 0.10 * large_punch) * weight, at)
	hole.burst_dust(size, large_punch, at)
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
	_update_combo_timer()
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
	_update_combo_timer()

func _update_combo_label() -> void:
	var mult := combo_mult()
	if mult <= 1:
		_hide_combo_panel()
		return
	var tier_changed := mult != _combo_last_mult
	_combo_last_mult = mult
	var color: Color = COMBO_HUD_COLORS[mult - 2]
	_combo_label.text = "x%d" % mult
	_combo_label.add_theme_color_override("font_color", color)
	_combo_panel_style.border_color = color
	_combo_fill_style.bg_color = color
	if _combo_panel_tween != null and _combo_panel_tween.is_valid():
		_combo_panel_tween.kill()
	_combo_panel.visible = true
	_combo_panel.modulate.a = 1.0
	_combo_panel.rotation = -0.035 if tier_changed else 0.0
	_combo_panel.scale = Vector2.ONE * (1.28 if tier_changed else 1.10)
	_combo_panel_tween = create_tween().set_parallel(true)
	_combo_panel_tween.tween_property(_combo_panel, "scale", Vector2.ONE, 0.30) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_combo_panel_tween.tween_property(_combo_panel, "rotation", 0.0, 0.24) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _hide_combo_panel() -> void:
	_combo_last_mult = 1
	if _combo_panel == null or not _combo_panel.visible:
		return
	if _combo_panel_tween != null and _combo_panel_tween.is_valid():
		_combo_panel_tween.kill()
	_combo_panel_tween = create_tween().set_parallel(true)
	_combo_panel_tween.tween_property(_combo_panel, "scale", Vector2.ONE * 0.82, 0.16) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_combo_panel_tween.tween_property(_combo_panel, "modulate:a", 0.0, 0.16)
	_combo_panel_tween.chain().tween_callback(func(): _combo_panel.visible = false)

func _update_combo_timer() -> void:
	if _combo_bar == null:
		return
	_combo_bar.value = clampf(_combo_left / COMBO_WINDOW, 0.0, 1.0) * 100.0

func _on_leveled_up(new_level: int) -> void:
	_reveal_newly_swallowable(new_level)
	Sfx.play(Sfx.Kind.LEVEL_UP, self, hole.global_position)
	# El cartel dice qué cambió en el juego, no sólo el número administrativo.
	var lbl := Label.new()
	lbl.text = "¡NIVEL %d!\n¡PODÉS COMER MÁS GRANDE!" % (new_level + 1)
	lbl.add_theme_font_size_override("font_size", 42)
	lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.add_theme_constant_override("outline_size", 10)
	lbl.custom_minimum_size = Vector2(620, 116)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	$UI.add_child(lbl)
	var vp := get_viewport().get_visible_rect().size
	lbl.position = Vector2(vp.x * 0.5 - 310.0, vp.y * 0.24)
	lbl.pivot_offset = Vector2(310, 58)
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

func _reveal_newly_swallowable(new_level: int) -> int:
	if new_level <= 0 or new_level >= hole.level_radii.size():
		return 0
	var old_radius: float = hole.level_radii[new_level - 1]
	var new_radius: float = hole.level_radii[new_level]
	var reveal_range := maxf(UNLOCK_REVEAL_MIN_RANGE, new_radius * UNLOCK_REVEAL_RADIUS_FACTOR)
	var candidates: Array = []
	for node in swallowables.get_children():
		var obj := node as SwallowableRef
		if obj == null or not obj.is_in_group("swallowable"):
			continue
		if obj.fits_hole(old_radius) or not obj.fits_hole(new_radius):
			continue
		var distance_sq: float = obj.global_position.distance_squared_to(hole.global_position)
		if distance_sq <= reveal_range * reveal_range:
			candidates.append({"obj": obj, "distance_sq": distance_sq})
	candidates.sort_custom(func(a, b): return a.distance_sq < b.distance_sq)
	var shown := mini(candidates.size(), UNLOCK_REVEAL_MAX_OBJECTS)
	for i in shown:
		(candidates[i].obj as SwallowableRef).reveal_unlocked()
	return shown

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
	_combo_panel = PanelContainer.new()
	_combo_panel.name = "ComboPanel"
	_combo_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_combo_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_combo_panel.offset_left = -190.0
	_combo_panel.offset_top = 112.0
	_combo_panel.offset_right = -22.0
	_combo_panel.offset_bottom = 236.0
	_combo_panel.pivot_offset = Vector2(84.0, 62.0)
	_combo_panel_style = StyleBoxFlat.new()
	_combo_panel_style.bg_color = Color(0.055, 0.045, 0.075, 0.92)
	_combo_panel_style.border_width_left = 3
	_combo_panel_style.border_width_top = 3
	_combo_panel_style.border_width_right = 3
	_combo_panel_style.border_width_bottom = 3
	_combo_panel_style.corner_radius_top_left = 24
	_combo_panel_style.corner_radius_top_right = 24
	_combo_panel_style.corner_radius_bottom_left = 24
	_combo_panel_style.corner_radius_bottom_right = 24
	_combo_panel_style.shadow_color = Color(0.0, 0.0, 0.0, 0.42)
	_combo_panel_style.shadow_size = 9
	_combo_panel.add_theme_stylebox_override("panel", _combo_panel_style)
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	_combo_panel.add_child(margin)
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", -5)
	margin.add_child(box)
	_combo_label = Label.new()
	_combo_label.text = "x2"
	_combo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_combo_label.add_theme_font_size_override("font_size", 54)
	_combo_label.add_theme_color_override("font_color", COMBO_HUD_COLORS[0])
	_combo_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_combo_label.add_theme_constant_override("outline_size", 7)
	box.add_child(_combo_label)
	var caption := Label.new()
	caption.text = "COMBO"
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.add_theme_font_size_override("font_size", 16)
	caption.add_theme_color_override("font_color", Color(0.92, 0.90, 0.98, 0.84))
	caption.add_theme_constant_override("outline_size", 4)
	box.add_child(caption)
	_combo_bar = ProgressBar.new()
	_combo_bar.custom_minimum_size = Vector2(132.0, 8.0)
	_combo_bar.min_value = 0.0
	_combo_bar.max_value = 100.0
	_combo_bar.value = 100.0
	_combo_bar.show_percentage = false
	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(1.0, 1.0, 1.0, 0.12)
	bar_bg.corner_radius_top_left = 4
	bar_bg.corner_radius_top_right = 4
	bar_bg.corner_radius_bottom_left = 4
	bar_bg.corner_radius_bottom_right = 4
	_combo_fill_style = StyleBoxFlat.new()
	_combo_fill_style.bg_color = COMBO_HUD_COLORS[0]
	_combo_fill_style.corner_radius_top_left = 4
	_combo_fill_style.corner_radius_top_right = 4
	_combo_fill_style.corner_radius_bottom_left = 4
	_combo_fill_style.corner_radius_bottom_right = 4
	_combo_bar.add_theme_stylebox_override("background", bar_bg)
	_combo_bar.add_theme_stylebox_override("fill", _combo_fill_style)
	box.add_child(_combo_bar)
	_combo_panel.visible = false
	$UI.add_child(_combo_panel)

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

	for line in ROAD_LINES:
		var lf := float(line)
		for along_x in [false, true]:
			# Vereda (más ancha, abajo), asfalto, y línea central.
			_add_road(along_x, lf, ROAD_W + SIDE_W * 2.0, Y_SIDEWALK, mat_side)
			_add_road(along_x, lf, ROAD_W, Y_ROAD, mat_asph)
			_add_road(along_x, lf, 0.25, Y_LINE, mat_line)
	_add_lake()

func _add_road(along_x: bool, lf: float, width: float, y: float, mat: Material) -> void:
	# Una calle de punta a punta del mapa, PERO cortada si el lago se le cruza:
	# ahí se emiten dos tramos que mueren en la orilla. `along_x` = corre a lo
	# largo del eje X (o sea z = lf); si no, corre a lo largo de Z (x = lf).
	#
	# `gap` es la media cuerda del círculo del lago a la altura de esta calle:
	# de Pitágoras, sqrt(r² - lf²). Si la calle pasa por afuera del lago no hay
	# corte y va entera.
	var gap := 0.0
	if absf(lf) < LAKE_RADIUS:
		gap = sqrt(LAKE_RADIUS * LAKE_RADIUS - lf * lf)
	if gap <= 0.0:
		if along_x:
			_add_strip(_city, 0.0, lf, MAP_HALF * 2.0, width, y, mat)
		else:
			_add_strip(_city, lf, 0.0, width, MAP_HALF * 2.0, y, mat)
		return
	var seg := MAP_HALF - gap
	if seg <= 0.1:
		return  # el lago se la come entera
	var mid := (MAP_HALF + gap) * 0.5
	for s in [-1.0, 1.0]:
		if along_x:
			_add_strip(_city, s * mid, lf, seg, width, y, mat)
		else:
			_add_strip(_city, lf, s * mid, width, seg, y, mat)

func _add_lake() -> void:
	# Pileta completa: una losa bajo el agua y cuatro muros bajos alrededor. La
	# losa tapa el suelo/calles que pasan debajo; los muros hacen que el lago no
	# parezca un disco flotante y frenan cuerpos físicos que lleguen al borde.
	var basin := Node3D.new()
	basin.name = "LakeBasin"
	_city.add_child(basin)

	var concrete := _make_mat(Color(0.48, 0.51, 0.54))
	var rim_mat := _make_mat(Color(0.72, 0.74, 0.75))
	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(
		BASIN_OUTER_HALF * 2.0,
		BASIN_FLOOR_HEIGHT,
		BASIN_OUTER_HALF * 2.0
	)
	var floor := MeshInstance3D.new()
	floor.name = "BasinFloor"
	floor.mesh = floor_mesh
	floor.material_override = concrete
	floor.position.y = Y_BASIN_TOP - BASIN_FLOOR_HEIGHT * 0.5
	floor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	basin.add_child(floor)

	# Un solo StaticBody con cuatro cajas: la barrera sigue existiendo aunque un
	# auto/peatón se vuelva dinámico al acercarse el agujero.
	var walls_body := StaticBody3D.new()
	walls_body.name = "BasinWallsCollision"
	walls_body.collision_layer = 1
	walls_body.collision_mask = 2
	basin.add_child(walls_body)
	var long_wall := BASIN_OUTER_HALF * 2.0
	_add_basin_wall(
		basin, walls_body,
		Vector3(long_wall, BASIN_WALL_HEIGHT, BASIN_WALL_WIDTH),
		Vector3(0.0, Y_BASIN_TOP + BASIN_WALL_HEIGHT * 0.5, -BASIN_HALF),
		rim_mat
	)
	_add_basin_wall(
		basin, walls_body,
		Vector3(long_wall, BASIN_WALL_HEIGHT, BASIN_WALL_WIDTH),
		Vector3(0.0, Y_BASIN_TOP + BASIN_WALL_HEIGHT * 0.5, BASIN_HALF),
		rim_mat
	)
	_add_basin_wall(
		basin, walls_body,
		Vector3(BASIN_WALL_WIDTH, BASIN_WALL_HEIGHT, BASIN_HALF * 2.0),
		Vector3(-BASIN_HALF, Y_BASIN_TOP + BASIN_WALL_HEIGHT * 0.5, 0.0),
		rim_mat
	)
	_add_basin_wall(
		basin, walls_body,
		Vector3(BASIN_WALL_WIDTH, BASIN_WALL_HEIGHT, BASIN_HALF * 2.0),
		Vector3(BASIN_HALF, Y_BASIN_TOP + BASIN_WALL_HEIGHT * 0.5, 0.0),
		rim_mat
	)

	# Disco de agua con ondas, brillo y espuma procedural. La textura se calcula
	# en coordenadas globales para que no se deforme por el UV radial del cilindro.
	var m := CylinderMesh.new()
	m.top_radius = LAKE_RADIUS
	m.bottom_radius = LAKE_RADIUS
	m.height = 0.02
	m.radial_segments = 48
	m.rings = 1
	m.cap_bottom = false  # nadie ve la cara de abajo
	var mi := MeshInstance3D.new()
	mi.name = "Lake"
	mi.mesh = m
	mi.material_override = _make_water_mat()
	mi.position = Vector3(0.0, Y_WATER, 0.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	basin.add_child(mi)

func _add_basin_wall(parent: Node3D, body: StaticBody3D, size: Vector3, pos: Vector3, mat: Material) -> void:
	var wall_mesh := BoxMesh.new()
	wall_mesh.size = size
	var wall := MeshInstance3D.new()
	wall.mesh = wall_mesh
	wall.material_override = mat
	wall.position = pos
	parent.add_child(wall)
	var shape := BoxShape3D.new()
	shape.size = size
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position = pos
	body.add_child(collider)

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
	_ped_limb_mesh = BoxMesh.new()
	_ped_limb_mesh.size = Vector3(0.045, LIMB_LEN, 0.045)
	for c in SHIRT_COLORS:
		_shirt_mats.append(_make_mat(c))
	_skin_mat = _make_mat(Color(0.94, 0.76, 0.62))
	_pants_mat = _make_mat(Color(0.24, 0.27, 0.36))
	_grass_mat = _make_ground_mat(Color(0.38, 0.62, 0.32))

func _make_ground_mat(color: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = GROUND_SHADER
	m.set_shader_parameter("base_color", color)
	return m

func _make_water_mat() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = WATER_SHADER
	m.set_shader_parameter("lake_half_extents", LAKE_HALF_EXTENTS)
	m.set_shader_parameter("corner_radius", 1.8)
	return m

func _make_mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 1.0
	return m

func _pick_parks() -> void:
	# Un cuarto de las manzanas son parques: solo naturaleza, sin edificios. La
	# proporción se mantiene aunque cambie el tamaño del mapa.
	var total := BLOCK_CENTERS.size() * BLOCK_CENTERS.size()
	while _park_blocks.size() < total / 4:
		_park_blocks[Vector2i(randi() % BLOCK_CENTERS.size(), randi() % BLOCK_CENTERS.size())] = true

func _populate_blocks() -> void:
	# Cada manzana se llena según su tipo: parque o edificios.
	for ix in BLOCK_CENTERS.size():
		for iz in BLOCK_CENTERS.size():
			var bx := float(BLOCK_CENTERS[ix])
			var bz := float(BLOCK_CENTERS[iz])
			# Las manzanas que quedaron bajo el lago no se llenan. El césped y el
			# asfalto se dibujan igual pero el agua los tapa; lo que hay que
			# evitar es plantar árboles y edificios flotando en el medio del agua.
			if Vector2(bx, bz).length() < LAKE_RADIUS + BLOCK_HALF:
				continue
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
	# La pileta ocupa un cuadrado, no sólo el disco de agua: tampoco plantar
	# props en las esquinas secas de la losa ni encajados dentro de sus muros.
	if _inside_basin(x, z, r):
		return false
	for p in _placed:
		if Vector2(x - p.x, z - p.y).length() < r + p.z:
			return false
	return true

func _inside_basin(x: float, z: float, padding: float = 0.0) -> bool:
	var center := _lake_center_xz()
	var half := BASIN_HALF_EXTENTS + Vector2.ONE * maxf(padding, 0.0)
	return absf(x - center.x) < half.x and absf(z - center.y) < half.y

func _lake_center_xz() -> Vector2:
	return Vector2(lake_root.global_position.x, lake_root.global_position.z)

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
	# Los edificios salen de la biblioteca de escenas: el tamaño, la XP, la
	# paleta y los pedazos vienen de cada prop, no se deciden acá.
	for _k in range(randi_range(1, 3)):
		var sky := randf() < 0.22
		var lista: Array = SKYSCRAPERS if sky else BUILDINGS_LOW
		_spawn_prop(lista.pick_random(), bx, bz, 3.0)
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
	if Vector2(pos.x - _start_position.x, pos.z - _start_position.z).length() < START_CLEAR + 2.0:
		return  # no arrancar con un auto encima del agujero
	# Nada de autos dentro del cubículo, ni siquiera en las esquinas que quedan
	# afuera del disco circular de agua. El margen contempla su ancho completo.
	if _inside_basin(pos.x, pos.z, 1.5):
		return
	var rot := atan2(dir.x, dir.z)  # mirar hacia la dirección de marcha
	var car := _spawn_model_swallowable(CARS.pick_random(), pos, randf_range(1.5, 1.9), rot, XP_CAR)
	car.sfx_kind = Sfx.Kind.CAR
	car.set_forbidden_rect(_lake_center_xz(), BASIN_HALF_EXTENTS)
	car.start_driving(dir, randf_range(2.5, 4.5), MAP_HALF, hole, ROAD_LINES)

func _spawn_car_from_edge() -> void:
	# Entra desde un borde, en el sentido correcto del carril. Asi un auto nuevo
	# no aparece de golpe en el centro de la camara.
	var line := float(ROAD_LINES.pick_random())
	var lane := 1.25 * (1.0 if randf() < 0.5 else -1.0)
	if randf() < 0.5:
		var dir_z := -1.0 if lane > 0.0 else 1.0
		var z := MAP_HALF - 1.0 if dir_z < 0.0 else -MAP_HALF + 1.0
		_spawn_car(Vector3(line + lane, 0.0, z), Vector3(0.0, 0.0, dir_z))
	else:
		var dir_x := 1.0 if lane > 0.0 else -1.0
		var x := -MAP_HALF + 1.0 if dir_x > 0.0 else MAP_HALF - 1.0
		_spawn_car(Vector3(x, 0.0, line + lane), Vector3(dir_x, 0.0, 0.0))

func _spawn_pedestrians() -> void:
	# Peatones por las veredas: comida mínima, móvil, que huye del agujero.
	var spawned := 0
	var intentos := 0
	# Escalan con el área del mapa para no quedar perdidos en una ciudad 4 veces
	# más grande. El tope de intentos es por si el lago tapa demasiadas veredas:
	# sin él, un mapa con poco lugar libre colgaría el while para siempre.
	var cuantos := 32 * int(pow(MAP_HALF / 36.0, 2.0))
	while spawned < cuantos and intentos < cuantos * 20:
		intentos += 1
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
		if Vector2(pos.x - _start_position.x, pos.z - _start_position.z).length() < START_CLEAR + 1.0:
			continue  # despejado alrededor del arranque del agujero
		if _inside_basin(pos.x, pos.z, 0.35):
			continue  # no nacen sobre el agua ni en las esquinas de la pileta
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
	body.position.y = BODY_Y
	visual.add_child(body)
	var head := MeshInstance3D.new()
	head.mesh = _ped_head_mesh
	head.material_override = _skin_mat
	head.position.y = HEAD_Y
	visual.add_child(head)
	# Brazos y piernas, para que la caminata se vea. Comparten malla y material
	# entre las ~128 personas, así que no agregan draw calls (sí nodos).
	var legs: Array[Node3D] = []
	var arms: Array[Node3D] = []
	for side in [-1.0, 1.0]:
		legs.append(_add_limb(visual, Vector3(side * 0.045, HIP_Y, 0.0), _pants_mat))
		arms.append(_add_limb(visual, Vector3(side * 0.105, SHOULDER_Y, 0.0), _skin_mat))
	s.swallow_size = 0.35
	s.xp_value = XP_PEDESTRIAN
	s.sfx_kind = Sfx.Kind.VOICE
	s.consumed.connect(_on_object_consumed)
	s.fell_in.connect(_on_object_fell_in)
	s.position = pos
	swallowables.add_child(s)
	s.setup_body(Vector3(0.25, PED_HEIGHT, 0.25))
	s.set_walk_rig(legs, arms)
	s.set_forbidden_rect(_lake_center_xz(), BASIN_HALF_EXTENTS)
	s.start_walking(dir, MAP_HALF, hole)

func _spawn_pedestrian_from_edge() -> void:
	# Igual que los autos: nace en un extremo de una vereda y camina hacia el
	# interior. Los chequeos de lago no hacen falta en el borde del mapa.
	var line := float(ROAD_LINES.pick_random())
	var side := (ROAD_W * 0.5 + SIDE_W * 0.5) * (1.0 if randf() < 0.5 else -1.0)
	if randf() < 0.5:
		var dir_z := 1.0 if randf() < 0.5 else -1.0
		var z := -MAP_HALF + 1.0 if dir_z > 0.0 else MAP_HALF - 1.0
		_spawn_pedestrian(Vector3(line + side, 0.0, z), Vector3(0.0, 0.0, dir_z))
	else:
		var dir_x := 1.0 if randf() < 0.5 else -1.0
		var x := -MAP_HALF + 1.0 if dir_x > 0.0 else MAP_HALF - 1.0
		_spawn_pedestrian(Vector3(x, 0.0, line + side), Vector3(dir_x, 0.0, 0.0))

func _add_limb(parent: Node3D, anclaje: Vector3, mat: Material) -> Node3D:
	# Devuelve un PIVOTE en la cadera/hombro con la malla colgando debajo. El
	# pivote no es decorativo: la malla tiene el origen en su centro, así que
	# rotarla directamente haría que la pierna gire desde la rodilla en vez de
	# desde la cadera.
	var pivot := Node3D.new()
	pivot.position = anclaje
	parent.add_child(pivot)
	var mi := MeshInstance3D.new()
	mi.mesh = _ped_limb_mesh
	mi.material_override = mat
	mi.position.y = -LIMB_LEN * 0.5
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # a este tamaño no aporta
	pivot.add_child(mi)
	return pivot

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
			# Lejos del jugador Y fuera del lago: en el agua no tendrían nada que
			# comer y se quedarían quietos toda la partida.
			if Vector2(pos.x - _start_position.x, pos.z - _start_position.z).length() > RIVAL_START_CLEAR \
					and not _inside_basin(pos.x, pos.z, 4.0):
				break
		add_child(r)
		r.global_position = pos
		# Las tablas de progresión salen del agujero del jugador: son balance del
		# juego y no tienen por qué existir duplicadas en dos archivos.
		r.setup(swallowables, hole.level_radii, hole.level_xp_req, MAP_HALF)
		rivals.append(r)
	rival_arrows.setup(hole.camera, hole, rivals)
	leaderboard.setup(hole, rivals, func(): return score)

func _spawn_prop(scene: PackedScene, bx: float, bz: float, spread: float) -> SwallowableRef:
	# Planta un prop de la biblioteca (scenes/props/). A diferencia de
	# _spawn_model_swallowable, acá NO se decide nada del objeto: la escena ya
	# trae su modelo, su ancho, su paleta, su XP y sus pedazos, y se arma sola en
	# su _ready() vía auto_setup. Lo único que hace main.gd es buscarle lugar,
	# ubicarlo y engancharlo a las señales de la partida.
	var s := scene.instantiate() as SwallowableRef
	if s == null:
		return null
	# El ancho se lee ANTES de meterlo al árbol: _find_spot necesita saber cuánto
	# ocupa para reservar el lugar, y el auto_setup recién corre en el add_child.
	var pos := _find_spot(bx, bz, spread, s.auto_footprint)
	if pos == Vector3.INF:
		s.free()  # no había lugar en la manzana: se descarta sin haber entrado al árbol
		return null
	s.consumed.connect(_on_object_consumed)
	s.fell_in.connect(_on_object_fell_in)
	s.wants_break.connect(_on_wants_break)
	s.position = pos
	s.rotation.y = randf_range(0.0, TAU)
	# force_readable_name: sin esto los nombres que chocan con un hermano quedan
	# como "@RigidBody3D@61" (la vía rápida de add_child) en vez de "BuildingC2",
	# y en el árbol remoto del depurador no se entiende qué es cada cosa. La vía
	# lenta cuesta, pero son ~27 edificios por partida: no se nota.
	swallowables.add_child(s, true)  # acá corre su _ready(): se mide y arma su cuerpo
	return s

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
