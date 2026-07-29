extends Control

## Flechas de borde: una por rival que esté fuera de cuadro, en su color,
## apuntando hacia dónde está. Es lo que en el juego de referencia convierte a
## los rivales en una presencia constante aunque no se los vea — sin esto un
## rival fuera de pantalla simplemente no existe para el jugador.
##
## La dirección NO sale de `unproject_position()`. Esa función devuelve basura
## espejada para puntos detrás de la cámara, que es justo el caso que más
## importa acá: el rival que tenés atrás. En su lugar se proyecta el vector
## jugador→rival sobre los ejes de la cámara aplastados contra el piso, que da
## una dirección en pantalla siempre válida y sin casos raros.

const MARGIN := 46.0         # cuánto se despega la flecha del borde
const SIZE := 20.0           # largo de la flecha desde su centro
const ON_SCREEN_PAD := 40.0  # tolerancia para considerar que el rival "ya se ve"

var _camera: Camera3D
var _player: Node3D
var _rivals: Array = []

func setup(camera: Camera3D, player: Node3D, rivals: Array) -> void:
	_camera = camera
	_player = player
	_rivals = rivals

func _process(_delta: float) -> void:
	if _camera != null:
		queue_redraw()

func _draw() -> void:
	if _camera == null or _player == null:
		return
	var rect := size
	var center := rect * 0.5
	# Ejes de la cámara llevados al plano del piso: "derecha en pantalla" es su
	# eje x (que ya es horizontal, la cámara sólo cabecea), y "arriba en pantalla"
	# es su frente aplastado contra el suelo.
	var b := _camera.global_transform.basis
	var right := Vector2(b.x.x, b.x.z)
	var fwd := Vector2(-b.z.x, -b.z.z)
	if right.length() < 0.001 or fwd.length() < 0.001:
		return
	right = right.normalized()
	fwd = fwd.normalized()
	for r in _rivals:
		if r == null or not is_instance_valid(r):
			continue
		if _on_screen(r.global_position, rect):
			continue
		var delta3: Vector3 = r.global_position - _player.global_position
		var d := Vector2(delta3.x, delta3.z)
		if d.length() < 0.01:
			continue
		# El signo de y: en pantalla el eje crece hacia abajo, pero "adelante"
		# en el mundo se ve hacia arriba.
		var dir := Vector2(d.dot(right), -d.dot(fwd)).normalized()
		_draw_arrow(center + dir * _edge_dist(dir, rect), dir, r.color)

func _edge_dist(dir: Vector2, rect: Vector2) -> float:
	# Hasta dónde llega el rayo desde el centro antes de tocar el marco.
	var tx := INF
	var ty := INF
	if absf(dir.x) > 0.0001:
		tx = (rect.x * 0.5 - MARGIN) / absf(dir.x)
	if absf(dir.y) > 0.0001:
		ty = (rect.y * 0.5 - MARGIN) / absf(dir.y)
	return minf(tx, ty)

func _on_screen(pos: Vector3, rect: Vector2) -> bool:
	if _camera.is_position_behind(pos):
		return false
	var p := _camera.unproject_position(pos)
	return p.x > -ON_SCREEN_PAD and p.x < rect.x + ON_SCREEN_PAD \
		and p.y > -ON_SCREEN_PAD and p.y < rect.y + ON_SCREEN_PAD

func _draw_arrow(at: Vector2, dir: Vector2, color: Color) -> void:
	var n := dir.orthogonal()
	var pts := PackedVector2Array([
		at + dir * SIZE,
		at - dir * SIZE * 0.5 + n * SIZE * 0.72,
		at - dir * SIZE * 0.5 - n * SIZE * 0.72,
	])
	draw_colored_polygon(pts, color)
	# Contorno: sobre el asfalto oscuro los colores saturados se leen igual, pero
	# sobre el pasto o una vereda clara se pierden sin borde.
	draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[0]]),
		Color(0.0, 0.0, 0.0, 0.55), 2.5, true)
