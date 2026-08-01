extends SceneTree

## Perfilador: juega una partida entera con el bot y mide dónde se va el tiempo.
##
## Va SIN --headless a propósito: en headless el renderer es un dummy y todas las
## métricas de dibujo dan cero. Y apaga el vsync, porque con vsync los FPS se
## clavan en 60 y no se ve cuánto margen real hay.
##
##     godot --path holin --script res://devtools/profile.gd
##
## OJO con leer estos números como si fueran de un celular: esto corre en la
## placa del escritorio. Lo que SÍ traslada es la forma del problema —qué sube
## cuando— y las cuentas de draw calls y de triángulos, que son las mismas en
## cualquier hardware.
##
## Qué mirar, por confiabilidad:
##   - `inventario` es EXACTO y reproducible con la semilla fija. Es la métrica
##     buena para comparar antes/después.
##   - `draw calls` y `primitivas` varían ~12 % entre corridas idénticas: la
##     semilla fija el mapa, pero el recorrido del bot depende de los deltas
##     reales y termina mirando cosas distintas. No leer diferencias chicas.
##   - `cuerpos activos 3D` y `pares de colision` dan CERO: el proyecto usa Jolt
##     y Jolt no alimenta los monitores de física de Godot. Es un punto ciego,
##     no un cero real.

const Autoplay = preload("res://devtools/autoplay.gd")

const WARMUP := 120   # frames a descartar: la ciudad se arma en el primero
## Semilla fija: la ciudad se genera al azar, así que sin esto dos corridas no son
## comparables y cualquier "mejora" medida es ruido de layout. Con semilla fija el
## mapa y el recorrido del bot son idénticos y el antes/contra-después vale.
const SEED := 20260729

var _main: Node
var _bot: RefCounted
var _frame := 0
var _ready_done := false

var _fps: Array[float] = []
var _draws: Array[float] = []
var _prims: Array[float] = []
var _bodies: Array[float] = []
var _pairs: Array[float] = []
var _t_proc: Array[float] = []
var _t_phys: Array[float] = []

# Instantánea del peor frame, para saber QUÉ estaba pasando cuando se cayó.
var _worst_ms := 0.0
var _worst := ""

func _initialize() -> void:
	seed(SEED)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	# Techo de 200 y no libre: sin techo el motor corre a miles de FPS, el delta
	# se hace diminuto y los 120 s de partida no entran en ningún tope de frames
	# razonable. Con 200 la partida dura lo que tiene que durar y igual se ve
	# cualquier bajón: caer de 200 significa un frame de más de 5 ms.
	Engine.max_fps = 200
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(_main)

func _setup() -> void:
	_bot = Autoplay.new()
	_bot.attach(_main)
	_inventario()

func _inventario() -> void:
	# Los draw calls no salen de la cantidad de nodos sino de cuántos pares
	# (malla, material) distintos hay: el renderer junta en una sola llamada todo
	# lo que comparte los dos. Si hay muchos más materiales que colores en
	# pantalla, es que se están creando por instancia en vez de compartirse — y
	# eso es draw calls regalados.
	var mallas := {}
	var materiales := {}
	var instancias := 0
	var pila: Array[Node] = [_main]
	while not pila.is_empty():
		var n: Node = pila.pop_back()
		for c in n.get_children():
			pila.append(c)
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		instancias += 1
		mallas[mi.mesh.get_instance_id()] = true
		if mi.material_override != null:
			materiales[mi.material_override.get_instance_id()] = true
			continue
		for s in mi.mesh.get_surface_count():
			var m := mi.get_active_material(s)
			if m != null:
				materiales[m.get_instance_id()] = true
	print("inventario: %d MeshInstance3D  |  %d mallas distintas  |  %d materiales distintos" % [
		instancias, mallas.size(), materiales.size()])

func _p(a: Array[float], q: float) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	return s[clampi(int(float(s.size() - 1) * q), 0, s.size() - 1)]

func _line(nombre: String, a: Array[float], unidad: String) -> void:
	print("  %-22s mediana %8.1f   p95 %8.1f   peor %8.1f  %s" % [
		nombre, _p(a, 0.5), _p(a, 0.95), _p(a, 1.0), unidad])

func _process(_delta: float) -> bool:
	_frame += 1
	if not _ready_done:
		if _frame >= 2:
			_setup()
			_ready_done = true
		return false
	if _frame % Autoplay.STEER_EVERY_FRAMES == 0:
		_bot.steer()
	if _frame > WARMUP:
		var proc: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		var phys: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		_fps.append(Performance.get_monitor(Performance.TIME_FPS))
		_draws.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		_prims.append(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		_bodies.append(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS))
		_pairs.append(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS))
		_t_proc.append(proc)
		_t_phys.append(phys)
		if proc + phys > _worst_ms:
			_worst_ms = proc + phys
			_worst = "nivel=%d  cuerpos_activos=%d  pares=%d  draws=%d  proc=%.1fms  fisica=%.1fms" % [
				_bot.hole.level,
				Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS),
				Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS),
				Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
				proc, phys]
	if not _main.running or _frame > 40000:
		print("\n=== perfil de una partida (%d muestras) ===" % _fps.size())
		_line("FPS", _fps, "")
		_line("draw calls", _draws, "")
		_line("primitivas", _prims, "tris")
		_line("cuerpos activos 3D", _bodies, "")
		_line("pares de colision", _pairs, "")
		_line("tiempo _process", _t_proc, "ms")
		_line("tiempo fisica", _t_phys, "ms")
		print("\npeor frame (%.1f ms de CPU):\n  %s" % [_worst_ms, _worst])
		return true
	return false
