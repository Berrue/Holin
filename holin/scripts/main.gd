extends Node3D

## Escena de juego: arma la ciudad, lleva timer + puntaje y maneja el fin de
## partida (overlay de game over con reinicio / volver al menú).

@export var swallowable_scene: PackedScene

const MENU_SCENE := "res://scenes/main_menu.tscn"
const GAME_DURATION := 120.0

# El piso usa shader propio: recorta la boca del pozo y se oscurece en el borde.
const GROUND_SHADER := preload("res://shaders/ground_hole.gdshader")

# Tipos por preload en vez de class_name: la caché de clases globales vive en
# .godot/ (ignorada por git) y sin ella el proyecto no arranca fuera del editor.
const HoleRef = preload("res://scripts/hole.gd")
const SwallowableRef = preload("res://scripts/swallowable.gd")
const Sfx = preload("res://scripts/sfx.gd")

@onready var hole := $Hole as HoleRef
@onready var swallowables: Node3D = $Swallowables
@onready var level_label: Label = $UI/ScorePanel/VBox/Row/Badge/LevelLabel
@onready var badge: PanelContainer = $UI/ScorePanel/VBox/Row/Badge
@onready var score_value: Label = $UI/ScorePanel/VBox/Row/ScoreCol/ScoreValue
@onready var xp_bar: ProgressBar = $UI/ScorePanel/VBox/XPBar
@onready var xp_label: Label = $UI/ScorePanel/VBox/XPBar/XPLabel
@onready var timer_label: Label = $UI/TimerPanel/TimerLabel
@onready var game_over: Control = $UI/GameOver
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

const SHIRT_COLORS := [
	Color(0.85, 0.30, 0.30), Color(0.30, 0.50, 0.85), Color(0.35, 0.70, 0.40),
	Color(0.90, 0.75, 0.30), Color(0.70, 0.40, 0.80), Color(0.95, 0.55, 0.25),
]

var _strip_mesh: BoxMesh
var _city: Node3D
var _park_blocks := {}       # Vector2i(ix, iz) -> true: manzanas que son parque
var _placed: Array[Vector3] = []  # (x, z, radio) ya ocupados: evita superposiciones
var _score_shown := 0.0
var _score_tween: Tween
var _bar_tween: Tween
var _timer_urgent := false

func _ready() -> void:
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
	_build_city_ground()
	_pick_parks()
	_populate_blocks()
	_spawn_cars_on_roads()
	_spawn_pedestrians()
	hole.swallowed.connect(_on_swallowed)
	hole.leveled_up.connect(_on_leveled_up)
	replay_button.pressed.connect(_on_replay)
	menu_button.pressed.connect(_on_menu)
	_update_hud()

# ----------------------------------------------------------------------------
# Loop de partida
# ----------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not running:
		return
	time_left -= delta
	if time_left <= 0.0:
		time_left = 0.0
		_end_game()
	_update_timer_label()

func _end_game() -> void:
	running = false
	final_score_label.text = "Puntos: %s" % _format_number(score)
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

func _on_swallowed(xp_gained: int, _total_xp: int) -> void:
	count += 1
	score += xp_gained
	_update_hud()
	_bump_score()
	_spawn_float_label("+%d" % xp_gained, hole.global_position + Vector3.UP * 0.5)

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

func _spawn_float_label(text: String, world_pos: Vector3) -> void:
	# "+N" flotante: XP ganada, dibujada sobre el agujero y subiendo.
	var cam := get_viewport().get_camera_3d()
	if cam == null or cam.is_position_behind(world_pos):
		return
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 26)
	lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.35))
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
	_update_xp_bar()
	_update_timer_label()

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

func _update_xp_bar() -> void:
	var reqs: Array[int] = hole.level_xp_req
	var target := 100.0
	if hole.level + 1 < reqs.size():
		var cur := reqs[hole.level]
		var nxt := reqs[hole.level + 1]
		target = clampf(float(hole.xp - cur) / float(maxi(nxt - cur, 1)) * 100.0, 0.0, 100.0)
		xp_label.text = "%d / %d" % [hole.xp - cur, nxt - cur]
	else:
		xp_label.text = "MÁXIMO"
	if _bar_tween != null and _bar_tween.is_valid():
		_bar_tween.kill()
	_bar_tween = create_tween()
	_bar_tween.tween_property(xp_bar, "value", target, 0.3).set_trans(Tween.TRANS_CUBIC)

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
	var grass := _make_ground_mat(Color(0.38, 0.62, 0.32))
	_add_strip(_city, bx, bz, BLOCK_HALF * 2.0 + 1.4, BLOCK_HALF * 2.0 + 1.4, 0.004, grass)
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
	var cap := CapsuleMesh.new()
	cap.radius = 0.09
	cap.height = 0.34
	body.mesh = cap
	body.material_override = _make_mat(SHIRT_COLORS.pick_random())
	body.position.y = 0.20
	visual.add_child(body)
	var head := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.07
	sph.height = 0.14
	head.mesh = sph
	head.material_override = _make_mat(Color(0.94, 0.76, 0.62))
	head.position.y = 0.44
	visual.add_child(head)
	s.swallow_size = 0.35
	s.xp_value = XP_PEDESTRIAN
	s.sfx_kind = Sfx.Kind.VOICE
	s.consumed.connect(_on_object_consumed)
	s.position = pos
	swallowables.add_child(s)
	s.setup_body(Vector3(0.25, 0.55, 0.25))
	s.start_walking(dir, MAP_HALF, hole)

func _spawn_model_swallowable(model_path: String, pos: Vector3, target_footprint: float, rot_y: float = 0.0, xp: int = 1) -> SwallowableRef:
	# Crea un swallowable con un modelo .glb. El swallow_size y la colisión se
	# derivan del tamaño REAL del modelo (swallow_size = ancho en el mundo), así
	# "disco >= objeto" se siente igual que con los cubos.
	var s := swallowable_scene.instantiate() as SwallowableRef
	s.xp_value = xp
	s.consumed.connect(_on_object_consumed)
	var visual := s.get_node("Visual") as Node3D
	(visual.get_node("MeshInstance3D") as MeshInstance3D).visible = false
	var model: Node3D = (load(model_path) as PackedScene).instantiate()
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
