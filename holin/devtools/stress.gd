extends SceneTree

## Partida completa jugada por el bot, de punta a punta, informando al final.
## Sirve para ver que un cambio no rompa nada a lo largo de 120 s con todo
## pasando: muchos derrumbes, mucha física, muchos objetos naciendo y muriendo.
##
## Lo que hay que mirar del informe:
##   - `objetos` tiene que BAJAR con el tiempo. Si sube, algo se está acumulando.
##   - `time_scale` tiene que terminar en 1.00. Si no, un hitstop quedó trabado
##     — y como vive en Engine, ni recargar la escena lo arregla.
##
## Correr:
##     godot --headless --path holin --script res://devtools/stress.gd

const Autoplay = preload("res://devtools/autoplay.gd")

## Cada cuántos segundos DE JUEGO informar. Va por tiempo de juego y no por
## frames porque en headless el motor corre lo más rápido que puede: los frames
## no dicen nada del ritmo real de la partida.
const REPORT_EVERY_SECS := 20.0
const MAX_FRAMES := 60000

var _main: Node
var _bot: RefCounted
var _frame := 0
var _ready_done := false
var _breaks := 0
var _peak_objs := 0
var _max_mult := 1
var _next_report := 0.0

func _initialize() -> void:
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(_main)

func _setup() -> void:
	_bot = Autoplay.new()
	_bot.attach(_main)   # ver el aviso de autoplay.gd: nunca en _initialize()
	for c in _bot.each_swallowable():
		if c.break_pieces > 1:
			c.wants_break.connect(func(_o): _breaks += 1)

func _report(tag: String) -> void:
	print("%-8s t=%5.1fs  nivel=%d  score=%5d/%d  combo_max=x%d  derrumbes=%2d  objetos=%d  time_scale=%.2f" % [
		tag, _main.time_left, _bot.hole.level, _main.score, _main.SCORE_GOAL, _max_mult, _breaks,
		Performance.get_monitor(Performance.OBJECT_COUNT), Engine.time_scale])

func _process(_delta: float) -> bool:
	_frame += 1
	if not _ready_done:
		if _frame >= 2:
			_setup()
			_next_report = _main.GAME_DURATION - REPORT_EVERY_SECS
			_ready_done = true
		return false
	if _frame % Autoplay.STEER_EVERY_FRAMES == 0:
		_bot.steer()
	_peak_objs = maxi(_peak_objs, Performance.get_monitor(Performance.OBJECT_COUNT))
	_max_mult = maxi(_max_mult, _main.combo_mult())
	if _main.time_left <= _next_report:
		_next_report -= REPORT_EVERY_SECS
		_report("t-%.0f" % (_main.GAME_DURATION - _main.time_left))
	if not _main.running:
		_report("GANO" if _main.won else "PERDIO")
		print("pico de objetos=%d  |  tiempo usado=%.1fs de %.0f" % [
			_peak_objs, _main.GAME_DURATION - _main.time_left, _main.GAME_DURATION])
		# Confirma que salió el final correcto, no sólo la bandera interna.
		print("overlay: \"%s\" / \"%s\"" % [
			_main.game_over_title.text, _main.final_score_label.text])
		return true
	if _frame > MAX_FRAMES:
		print("corte por MAX_FRAMES sin llegar al fin de partida")
		_report("CORTE")
		return true
	return false
