extends Control

## Joystick virtual flotante: aparece donde tocás y se va al soltar.
##
## Reemplaza al control por delta de arrastre que había antes, que tomaba como
## dirección el ÚLTIMO movimiento del dedo (`event.relative`). Eso tenía dos
## problemas: el vector venía ruidoso porque un delta de un frame es diminuto, y
## si dejabas el dedo quieto el agujero seguía empujando para el lado del último
## micro-movimiento. Acá la dirección es siempre origen-del-toque → dedo, que es
## lo que hace hole.io: estable, y se corta sola al soltar.
##
## Lee eventos crudos en `_input()` y dibuja con `_draw()`, no usa `_gui_input`:
## así no compite por el foco de UI con el overlay de game over (que está arriba
## en el árbol y necesita sus botones). Con el árbol pausado el nodo deja de
## recibir input solo, por `process_mode` heredado.

@export var max_radius: float = 110.0  # radio del anillo, en px de viewport
@export var dead_zone: float = 0.15    # fracción del radio sin respuesta
@export var knob_ratio: float = 0.38   # tamaño del pulgar respecto del anillo

## Dirección de empuje, magnitud 0..1 (analógica). x = derecha, y = abajo.
var direction: Vector2 = Vector2.ZERO

var _finger := -1               # índice del dedo que manda; -1 = ninguno
var _origin := Vector2.ZERO     # centro del anillo
var _knob := Vector2.ZERO       # posición dibujada del pulgar
var _fade: Tween

func _ready() -> void:
	dead_zone = clampf(dead_zone, 0.0, 0.9)  # en 1.0 la rampa dividiría por cero
	modulate.a = 0.0

func _input(event: InputEvent) -> void:
	# El mouse llega acá como touch: el proyecto tiene activado
	# input_devices/pointing/emulate_touch_from_mouse.
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			if _finger != -1:
				return  # ya hay un dedo mandando; los demás no interrumpen
			_finger = touch.index
			_origin = touch.position
			_knob = touch.position
			direction = Vector2.ZERO
			_fade_to(1.0, 0.12)
		elif touch.index == _finger:
			_finger = -1
			direction = Vector2.ZERO
			_fade_to(0.0, 0.18)
		queue_redraw()
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if drag.index != _finger:
			return
		_move_knob(drag.position)
		queue_redraw()

func _move_knob(pos: Vector2) -> void:
	var offset := pos - _origin
	var dist := offset.length()
	if dist > max_radius:
		# El anillo sigue al dedo en vez de quedarse clavado donde tocaste: en
		# partidas largas terminás arrastrando lejos del punto inicial y con el
		# origen fijo te quedarías sin recorrido para corregir el rumbo.
		offset *= max_radius / dist
		_origin = pos - offset
		dist = max_radius
	_knob = _origin + offset
	var t := dist / max_radius
	if t <= dead_zone:
		direction = Vector2.ZERO
		return
	# Rampa desde la zona muerta: empuje máximo justo en el borde del anillo.
	direction = offset.normalized() * ((t - dead_zone) / (1.0 - dead_zone))

func release() -> void:
	# Corte desde afuera (fin de partida). Sin tween: el árbol está por pausarse
	# y el anillo quedaría dibujado abajo del overlay con el último toque puesto.
	_finger = -1
	direction = Vector2.ZERO
	modulate.a = 0.0
	queue_redraw()

func _fade_to(alpha: float, secs: float) -> void:
	if _fade != null and _fade.is_valid():
		_fade.kill()  # si no, aparecer y desaparecer rápido deja dos tweens peleando
	_fade = create_tween()
	_fade.tween_property(self, "modulate:a", alpha, secs)

func _draw() -> void:
	if modulate.a <= 0.001:
		return
	draw_circle(_origin, max_radius, Color(1.0, 1.0, 1.0, 0.06))
	draw_arc(_origin, max_radius, 0.0, TAU, 48, Color(1.0, 1.0, 1.0, 0.32), 3.0, true)
	draw_circle(_knob, max_radius * knob_ratio, Color(1.0, 1.0, 1.0, 0.85))
