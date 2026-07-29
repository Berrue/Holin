extends Label

## Overlay de métricas, para medir EN EL CELULAR.
##
## devtools/profile.gd sirve en escritorio, pero un APK no se corre con
## `--script`: en el teléfono arranca la escena principal y listo. Así que las
## mismas métricas tienen que poder verse en pantalla.
##
## Se prende sola en compilaciones de debug (que es lo que se instala para
## probar) y se apaga en release. F3 la alterna a mano en escritorio.
##
## Qué mirar en el teléfono, en este orden:
##  - `ms` es el presupuesto: a 60 fps hay 16,6 ms por frame. Si CPU sola ya come
##    la mitad, el problema es CPU; si CPU está baja y los FPS igual caen, el
##    cuello es la GPU (y ahí el sospechoso es el `discard` del shader del piso).
##  - `draws` y `tris` son la carga de dibujo, iguales en cualquier hardware.

const REFRESH := 0.25

var _tick := 0.0

func _ready() -> void:
	visible = OS.is_debug_build()
	add_theme_font_size_override("font_size", 18)
	add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
	add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	add_theme_constant_override("outline_size", 6)
	set_process_input(true)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_F3:
		visible = not visible

func _process(delta: float) -> void:
	if not visible:
		return
	_tick -= delta
	if _tick > 0.0:
		return
	_tick = REFRESH
	var cpu: float = (Performance.get_monitor(Performance.TIME_PROCESS)
		+ Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
	text = "%d fps   %.1f ms cpu\n%d draws   %dk tris\n%d objetos" % [
		int(Performance.get_monitor(Performance.TIME_FPS)),
		cpu,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1000.0),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
	]
