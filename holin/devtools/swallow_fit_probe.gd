extends SceneTree

## Prueba corta de regresión para la relación objeto/agujero. Verifica con
## física real que una huella chica cae, que una grande espera el próximo nivel
## y que un objeto apoyado cerca del borde termina centrándose y consumiéndose.
##
##     godot --headless --path holin --script res://devtools/swallow_fit_probe.gd

const HOLE_SCENE := preload("res://scenes/hole.tscn")
const SWALLOWABLE_SCENE := preload("res://scenes/swallowable.tscn")

const TEST_TIMEOUT_FRAMES := 240

var _hole: Node3D
var _frame := 0
var _phase := 0
var _phase_start := 0
var _current: RigidBody3D
var _consumed := false

func _initialize() -> void:
	_hole = HOLE_SCENE.instantiate()
	root.add_child(_hole)

func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 2:
		_start_case("prop centrado", Vector3(0.8, 0.8, 0.8), Vector3.ZERO)
		return false
	if _phase == 0 and _consumed:
		_pass("prop centrado")
		_phase = 1
		_start_case("prop en el borde", Vector3(0.9, 0.8, 0.9), Vector3(0.9, 0.0, 0.0))
	elif _phase == 1 and _consumed:
		_pass("prop en el borde")
		_phase = 2
		_start_case("objeto que requiere nivel 2", Vector3(1.5, 1.0, 1.5), Vector3.ZERO)
		print("FIT_PROBE espera_nivel_2 fit_nivel_1=", _current.fits_hole(_hole.radius))
	elif _phase == 2 and _frame - _phase_start >= 60:
		if _consumed or not _current.freeze:
			_fail("el objeto grande no esperó el nivel siguiente")
			return true
		_hole.debug_step_level(1)
		_phase = 3
		_phase_start = _frame
		print("FIT_PROBE sube_nivel radio_objeto=%.3f radio_agujero_destino=%.3f" % [
			_current.footprint_radius, _hole.level_radii[1]])
	elif _phase == 3 and _consumed:
		_pass("objeto habilitado al crecer")
		print("SWALLOW_FIT_PROBE_OK")
		return true
	if _frame - _phase_start > TEST_TIMEOUT_FRAMES:
		_fail("timeout en fase %d" % _phase)
		return true
	return false

func _start_case(label: String, size: Vector3, position: Vector3) -> void:
	_consumed = false
	_phase_start = _frame
	_current = SWALLOWABLE_SCENE.instantiate()
	_current.position = position
	root.add_child(_current)
	_current.swallow_size = maxf(size.x, size.z)
	_current.setup_body(size)
	_current.consumed.connect(func(_xp: int): _consumed = true)
	print("FIT_PROBE caso=%s base=%s radio_objeto=%.3f radio_agujero=%.3f fit=%s" % [
		label, Vector2(size.x, size.z), _current.footprint_radius, _hole.radius,
		_current.fits_hole(_hole.radius)])

func _pass(label: String) -> void:
	print("FIT_PROBE PASS: ", label)

func _fail(reason: String) -> void:
	push_error("SWALLOW_FIT_PROBE_FAIL: " + reason)
