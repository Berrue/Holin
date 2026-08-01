extends Node

## Captura dirigida de los tres estados nuevos: anticipación compatible,
## rechazo por tamaño y crecimiento que desbloquea ese mismo objeto.
##
##     godot --path holin res://devtools/feel_shots.tscn

const MAIN_SCENE := preload("res://scenes/main.tscn")
const SWALLOWABLE_SCENE := preload("res://scenes/swallowable.tscn")
const OUT_DIR := "C:/tmp/holin_feel_shots"

var _main: Node
var _hole: Node3D
var _container: Node3D
var _candidate: RigidBody3D
var _frame := 0

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_main = MAIN_SCENE.instantiate()
	add_child(_main)

func _process(_delta: float) -> void:
	_frame += 1
	if _frame == 3:
		_hole = _main.get_node("Hole")
		_container = _main.get_node("Swallowables")
		_spawn_candidate(Vector3(0.8, 0.8, 0.8), 1.72)
	elif _frame == 15:
		_capture("01_fit_preview")
	elif _frame == 24:
		_candidate.free()
		_spawn_candidate(Vector3(1.5, 1.0, 1.5), 1.85)
	elif _frame == 36:
		_capture("02_blocked_preview")
	elif _frame == 44:
		_hole.debug_step_level(1)
	elif _frame == 47:
		_capture("03_growth_start")
	elif _frame == 55:
		_capture("04_growth_mid")
	elif _frame == 72:
		_capture("05_growth_settle")
	elif _frame == 78:
		_main.running = false
		_main.combo = 4
		_main._combo_left = _main.COMBO_WINDOW
		_main._update_combo_label()
		_main._update_combo_timer()
	elif _frame == 81:
		_capture("06_combo_x2_full")
	elif _frame == 89:
		_main.combo = 8
		_main._combo_left = _main.COMBO_WINDOW * 0.55
		_main._update_combo_label()
		_main._update_combo_timer()
	elif _frame == 92:
		_capture("07_combo_x3_half")
	elif _frame == 100:
		_main.combo = 12
		_main._combo_left = _main.COMBO_WINDOW * 0.25
		_main._update_combo_label()
		_main._update_combo_timer()
	elif _frame == 103:
		_capture("08_combo_x4_low")
	elif _frame == 110:
		print("FEEL_SHOTS_OK dir=", OUT_DIR)
		get_tree().quit()

func _spawn_candidate(size: Vector3, distance: float) -> void:
	_candidate = SWALLOWABLE_SCENE.instantiate()
	_candidate.swallow_size = maxf(size.x, size.z)
	_candidate.get_node("Visual").scale = size
	_container.add_child(_candidate)
	_candidate.global_position = _hole.global_position + Vector3(distance, 0.0, 0.0)
	_candidate.setup_body(size)

func _capture(label: String) -> void:
	var path := OUT_DIR + "/" + label + ".png"
	get_viewport().get_texture().get_image().save_png(path)
	print("FEEL_SHOT ", path)
