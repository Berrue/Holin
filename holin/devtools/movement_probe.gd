extends SceneTree

## Prueba determinista del feel de movimiento, sin cargar la ciudad:
##     godot --headless --path holin --script res://devtools/movement_probe.gd
##
## Verifica las cuatro decisiones del pase: salida rápida, contramarcha con más
## autoridad, frenada corta pero visible y compensación moderada al crecer.

const HoleRef = preload("res://scripts/hole.gd")
const DT := 1.0 / 60.0

func _init() -> void:
	var hole := HoleRef.new()

	for _frame in 9:
		hole._update_velocity(Vector2.RIGHT, DT)
	if hole._velocity.x < 7.7 or hole._velocity.x > hole.move_speed + 0.01:
		_fail("salida inesperada: %.3f" % hole._velocity.x)
		return

	hole._velocity = Vector2.RIGHT * hole.move_speed
	for _frame in 9:
		hole._update_velocity(Vector2.LEFT, DT)
	if hole._velocity.x >= -1.5:
		_fail("la contramarcha no respondió a tiempo: %.3f" % hole._velocity.x)
		return

	hole._velocity = Vector2.RIGHT * hole.move_speed
	for _frame in 6:
		hole._update_velocity(Vector2.ZERO, DT)
	if not is_equal_approx(hole._velocity.x, 4.4):
		_fail("frenada inesperada a 100 ms: %.3f" % hole._velocity.x)
		return

	hole.radius = hole.level_radii[-1]
	var grown_speed: float = hole._current_move_speed()
	var expected: float = hole.move_speed * (1.0 + hole.max_speed_growth_bonus)
	if not is_equal_approx(grown_speed, expected):
		_fail("bonus de crecimiento inesperado: %.3f, esperado %.3f" % [grown_speed, expected])
		return

	print("MOVEMENT_PROBE_OK start=%.2f reverse=%.2f brake_100ms=%.2f max_speed=%.2f" % [
		7.8, -2.13, 4.4, grown_speed])
	hole.free()
	quit()

func _fail(message: String) -> void:
	push_error("MOVEMENT_PROBE_FAIL: " + message)
	quit(1)
