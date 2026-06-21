extends Node3D

## Escena de juego: arma la ciudad, lleva timer + puntaje y maneja el fin de
## partida (overlay de game over con reinicio / volver al menú).

@export var swallowable_scene: PackedScene

const MENU_SCENE := "res://scenes/main_menu.tscn"
const GAME_DURATION := 120.0

@onready var hole: Node3D = $Hole
@onready var swallowables: Node3D = $Swallowables
@onready var score_label: Label = $UI/ScoreLabel
@onready var timer_label: Label = $UI/TimerLabel
@onready var game_over: Control = $UI/GameOver
@onready var final_score_label: Label = $UI/GameOver/Center/Panel/Margin/VBox/ScoreResult
@onready var replay_button: Button = $UI/GameOver/Center/Panel/Margin/VBox/ReplayButton
@onready var menu_button: Button = $UI/GameOver/Center/Panel/Margin/VBox/MenuButton
@onready var sun: DirectionalLight3D = $DirectionalLight3D

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
const PARASOLS := [
	"res://assets/kenney_city/detail-parasol-a.glb",
	"res://assets/kenney_city/detail-parasol-b.glb",
]

var _strip_mesh: BoxMesh

func _ready() -> void:
	# Orientar el sol en código (evita serializar una base rotada en el .tscn).
	sun.rotation_degrees = Vector3(-55, -35, 0)
	# El overlay debe procesar input aun con el árbol pausado.
	game_over.process_mode = Node.PROCESS_MODE_ALWAYS
	game_over.visible = false
	_build_city_ground()
	_spawn_buildings_in_blocks()
	_scatter_small_objects()
	hole.swallowed.connect(_on_swallowed)
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
	final_score_label.text = "Puntos: %d" % score
	game_over.visible = true
	get_tree().paused = true  # congela agujero/objetos; el overlay sigue activo

func _on_replay() -> void:
	get_tree().paused = false  # despausar ANTES de recargar (paused vive en el árbol)
	get_tree().reload_current_scene()

func _on_menu() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file(MENU_SCENE)

func _on_swallowed(amount: float, _total: float) -> void:
	count += 1
	score += maxi(1, int(round(amount * 10.0)))  # objetos más grandes = más puntos
	_update_hud()

func _update_hud() -> void:
	score_label.text = "Puntos: %d" % score
	_update_timer_label()

func _update_timer_label() -> void:
	var m: int = int(time_left) / 60
	var s: int = int(time_left) % 60
	timer_label.text = "%d:%02d" % [m, s]

# ----------------------------------------------------------------------------
# Generación de la ciudad
# ----------------------------------------------------------------------------

func _build_city_ground() -> void:
	# Calles (asfalto) + veredas (gris claro) + línea central, en una grilla.
	var city := Node3D.new()
	city.name = "City"
	add_child(city)
	_strip_mesh = BoxMesh.new()
	_strip_mesh.size = Vector3(1, 0.02, 1)

	var mat_side := _make_mat(Color(0.72, 0.72, 0.70))
	var mat_asph := _make_mat(Color(0.16, 0.16, 0.19))
	var mat_line := _make_mat(Color(0.92, 0.80, 0.22))
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

func _make_mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 1.0
	return m

func _spawn_buildings_in_blocks() -> void:
	# 1-3 edificios por manzana; algunas con rascacielos (los objetivos grandes).
	for bx in BLOCK_CENTERS:
		for bz in BLOCK_CENTERS:
			var n := randi_range(1, 3)
			for _k in range(n):
				var pos := Vector3(bx + randf_range(-3.0, 3.0), 0.0, bz + randf_range(-3.0, 3.0))
				if randf() < 0.22:
					_spawn_model_swallowable(SKYSCRAPERS[randi() % SKYSCRAPERS.size()], pos, randf_range(3.4, 4.8))
				else:
					_spawn_model_swallowable(BUILDINGS_LOW[randi() % BUILDINGS_LOW.size()], pos, randf_range(2.4, 4.0))

func _scatter_small_objects() -> void:
	# Objetos chicos repartidos por calles y manzanas: parasoles Kenney + cubos.
	# Son la "comida" temprana para crecer. Centro despejado (arranca el agujero).
	var placed := 0
	var attempts := 0
	var cube_sizes := [0.4, 0.6, 0.8, 1.0, 1.4, 2.0]
	while placed < 140 and attempts < 700:
		attempts += 1
		var px := randf_range(-MAP_HALF + 2.0, MAP_HALF - 2.0)
		var pz := randf_range(-MAP_HALF + 2.0, MAP_HALF - 2.0)
		if abs(px) < 3.0 and abs(pz) < 3.0:
			continue
		if randf() < 0.45:
			_spawn_model_swallowable(PARASOLS[randi() % PARASOLS.size()], Vector3(px, 0.0, pz), randf_range(0.5, 0.9))
		else:
			var size: float = cube_sizes[randi() % cube_sizes.size()]
			_spawn_cube(Vector3(px, size * 0.5, pz), size)
		placed += 1

func _spawn_cube(pos: Vector3, size: float) -> void:
	var s := swallowable_scene.instantiate()
	s.swallow_size = size
	s.scale = Vector3.ONE * size
	s.position = pos
	swallowables.add_child(s)

func _spawn_model_swallowable(model_path: String, pos: Vector3, target_footprint: float) -> void:
	# Crea un swallowable con un modelo .glb. El swallow_size y la colisión se
	# derivan del tamaño REAL del modelo (swallow_size = ancho en el mundo), así
	# "disco >= objeto" se siente igual que con los cubos.
	var s := swallowable_scene.instantiate()
	(s.get_node("MeshInstance3D") as MeshInstance3D).visible = false
	var model: Node3D = (load(model_path) as PackedScene).instantiate()
	s.add_child(model)
	s.position = pos  # los modelos Kenney tienen el origen en la base
	swallowables.add_child(s)  # ya en el árbol para poder medir su AABB

	var native: Vector3 = _merged_aabb(model).size
	var native_w: float = maxf(maxf(native.x, native.z), 0.001)
	var scale_f: float = target_footprint / native_w
	model.scale = Vector3.ONE * scale_f
	s.swallow_size = target_footprint

	var col := s.get_node("CollisionShape3D") as CollisionShape3D
	var box: BoxShape3D = (col.shape as BoxShape3D).duplicate()  # no tocar la compartida
	var world_size: Vector3 = native * scale_f
	box.size = Vector3(maxf(world_size.x, 0.2), maxf(world_size.y, 0.2), maxf(world_size.z, 0.2))
	col.shape = box
	col.position.y = world_size.y * 0.5  # apoyar la caja en el piso

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
