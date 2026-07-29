extends SceneTree

## Capturador de frames: arranca la partida, la maneja con el bot y saca PNGs
## justo cuando pasa lo que se quiere mirar. Para juzgar cambios visuales sin
## tener que jugar y apretar Impr Pant en el momento exacto.
##
## Correr (SIN --headless: hace falta que renderice de verdad):
##     godot --path holin --script res://devtools/shots.gd
##
## Los PNG salen en user://; la ruta absoluta se imprime al arrancar.
## Configurar con las constantes de abajo.

const Autoplay = preload("res://devtools/autoplay.gd")

## Qué se espera para disparar la captura: "break" (un edificio se derrumba) o
## "impact" (algo cruza la boca del pozo).
const WATCH := "break"
## Tamaño mínimo del objeto que dispara (sólo con WATCH="impact").
## ⚠ No sirve pedir MIN_SIZE grande: los objetos de ese porte son edificios, y un
## edificio se PARTE antes de caer, así que nunca emite `fell_in` — lo emiten sus
## pedazos, que nacen después de este setup y no quedan conectados. Para mirar
## edificios usá WATCH="break".
const MIN_SIZE := 1.4
const MIN_PIECES := 2
## Nivel de arranque: 5 = radio 5.8, ya se come edificios.
const LEVELS := 5
## Cuántos frames después del evento sacar cada foto.
const AT_FRAMES := [2, 10, 22]
## Frames absolutos desde el arranque en los que capturar igual, haya evento o no.
## Para mirar el HUD de entrada, el cartel de objetivo, etc.
const ALSO_AT: Array[int] = []
const MAX_SHOTS := 9
const MAX_FRAMES := 1400
## Prefijo de los archivos: conviene cambiarlo entre "antes" y "despues".
const TAG := "shot"

var _main: Node
var _bot: RefCounted
var _dir := ""
var _frame := 0
var _shots := 0
var _since := -1     # frames desde el evento; -1 = no hay evento en curso
var _ready_done := false

func _initialize() -> void:
	_dir = "user://holin_shots"
	DirAccess.make_dir_recursive_absolute(_dir)
	print("capturas en: ", ProjectSettings.globalize_path(_dir))
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(_main)

func _setup() -> void:
	_bot = Autoplay.new()
	_bot.attach(_main)
	_bot.boost(LEVELS)
	var armados := 0
	for c in _bot.each_swallowable():
		if WATCH == "break":
			if c.break_pieces >= MIN_PIECES:
				c.wants_break.connect(_on_event.unbind(1))
				armados += 1
		elif c.swallow_size >= MIN_SIZE:
			c.fell_in.connect(_on_event.unbind(3))
			armados += 1
	print("watch=%s  objetos armados: %d" % [WATCH, armados])

func _on_event() -> void:
	if _since < 0 and _shots < MAX_SHOTS:
		_since = 0

func _process(_delta: float) -> bool:
	_frame += 1
	if not _ready_done:
		if _frame >= 2:  # ver el aviso de autoplay.gd sobre main._ready()
			_setup()
			_ready_done = true
		return false
	if _frame % 30 == 0:
		_bot.steer()
	if ALSO_AT.has(_frame):
		root.get_texture().get_image().save_png("%s/%s_%02d.png" % [_dir, TAG, _shots])
		_shots += 1
	if _since >= 0:
		if AT_FRAMES.has(_since):
			root.get_texture().get_image().save_png("%s/%s_%02d.png" % [_dir, TAG, _shots])
			_shots += 1
		_since += 1
		if _since > int(AT_FRAMES[-1]):
			_since = -1
	if _shots >= MAX_SHOTS or _frame > MAX_FRAMES:
		print("listo: %d capturas en %d frames" % [_shots, _frame])
		return true
	return false
