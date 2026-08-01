extends RefCounted

## Bot que maneja el agujero solo. No es IA de juego: es andamio para poder mirar
## y medir el juego sin jugarlo a mano. Lo usan devtools/shots.gd y
## devtools/stress.gd.
##
## ⚠ `attach()` va DESPUÉS del primer frame, nunca en el `_initialize()` de un
## SceneTree: `main._ready()` recién corre en el frame 1 y ahí adentro hace
## `hole.joystick = joystick`, o sea que pisa el joystick falso con el real.

const Joystick = preload("res://scripts/virtual_joystick.gd")

# El movimiento responde en ~0.15 s. Corregir cada medio segundo hacía que el
# bot cruzara de largo props chicos; 0.1 s se aproxima mejor a un dedo real.
const STEER_EVERY_FRAMES := 6

var hole: Node3D
var joystick: Control

var _swallowables: Node

func attach(main: Node) -> void:
	hole = main.get_node("Hole")
	_swallowables = main.get_node("Swallowables")
	# El agujero sólo le lee `direction`, así que alcanza con un joystick suelto
	# fuera del árbol para manejarlo sin tocar nada del código del juego.
	joystick = Control.new()
	joystick.set_script(Joystick)
	hole.joystick = joystick

func boost(levels: int) -> void:
	# Salta niveles para llegar directo a la parte que se quiere mirar, sin
	# esperar a que el bot se coma media ciudad.
	for i in levels:
		hole.debug_step_level(1)

func steer() -> void:
	# Va por lo más valioso que le entre POR TAMAÑO, penalizado por distancia.
	# Sin el filtro de tamaño el bot se planta contra un rascacielos que todavía
	# no puede tragar y no crece nunca.
	var best: Node3D = null
	var top := -1.0
	for c in _swallowables.get_children():
		# Ojo: en Swallowables también viven los AudioStreamPlayer3D que suelta
		# sfx.gd, así que hay que filtrar por grupo y no asumir el tipo.
		if not c.is_in_group("swallowable") or not c.fits_hole(hole.radius):
			continue
		var d: float = c.global_position.distance_to(hole.global_position)
		var v: float = float(c.xp_value) / (d + 3.0)
		if v > top:
			top = v
			best = c
	if best == null:
		return
	var dir := Vector2(best.global_position.x - hole.global_position.x,
		best.global_position.z - hole.global_position.z)
	joystick.direction = dir.normalized()

func each_swallowable() -> Array[Node]:
	var out: Array[Node] = []
	for c in _swallowables.get_children():
		if c.is_in_group("swallowable"):
			out.append(c)
	return out
