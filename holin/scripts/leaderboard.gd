extends VBoxContainer

## Tabla de posiciones: jugador y rivales ordenados por puntaje.
##
## Vive DENTRO del panel de puntaje de arriba a la izquierda, debajo de la barra
## de objetivo, así que no dibuja fondo propio: el panel ya se lo pone.
##
## El puntaje del jugador incluye el multiplicador de combo y el de los rivales
## no, porque no tienen combo. No es un error de comparación: esa ventaja es
## exactamente lo que el combo compra, y verla en la tabla es lo que le da
## sentido a encadenar bocados en vez de pasear.

const REFRESH := 0.2   # no hace falta reordenar 60 veces por segundo
const PLAYER_NAME := "VOS"
const PLAYER_COLOR := Color(1.0, 0.85, 0.35)

var _player: Node3D
var _rivals: Array = []
var _rows: Array[Dictionary] = []
var _tick := 0.0
## El puntaje del jugador no vive en el agujero sino en main.gd (es el que aplica
## el combo), así que llega como callable en vez de leerse de un nodo.
var _player_score: Callable

func setup(player: Node3D, rivals: Array, player_score: Callable) -> void:
	_player = player
	_rivals = rivals
	_player_score = player_score
	_build(rivals.size() + 1)
	_refresh()

func _build(n: int) -> void:
	add_theme_constant_override("separation", 3)
	for i in n:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		# Punto de color: es lo que ata cada fila con su flecha de borde y con el
		# aro del agujero en el mundo.
		var dot := ColorRect.new()
		dot.custom_minimum_size = Vector2(12, 12)
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var name_lbl := Label.new()
		name_lbl.add_theme_font_size_override("font_size", 16)
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var pts_lbl := Label.new()
		pts_lbl.add_theme_font_size_override("font_size", 16)
		pts_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(dot)
		row.add_child(name_lbl)
		row.add_child(pts_lbl)
		add_child(row)
		_rows.append({"dot": dot, "name": name_lbl, "pts": pts_lbl})

func _process(delta: float) -> void:
	_tick -= delta
	if _tick <= 0.0:
		_tick = REFRESH
		_refresh()

func _refresh() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var entries: Array[Dictionary] = [{
		"nombre": PLAYER_NAME, "color": PLAYER_COLOR,
		"pts": _player_score.call(), "yo": true,
	}]
	for r in _rivals:
		if r == null or not is_instance_valid(r):
			continue
		entries.append({
			"nombre": r.rival_name, "color": r.color,
			"pts": r.score, "yo": false,
		})
	entries.sort_custom(func(a, b): return a["pts"] > b["pts"])
	for i in _rows.size():
		var row := _rows[i]
		if i >= entries.size():
			(row["dot"] as ColorRect).visible = false
			(row["name"] as Label).text = ""
			(row["pts"] as Label).text = ""
			continue
		var e := entries[i]
		(row["dot"] as ColorRect).visible = true
		(row["dot"] as ColorRect).color = e["color"]
		var name_lbl := row["name"] as Label
		name_lbl.text = e["nombre"]
		# El jugador va resaltado: en una lista de cuatro nombres de colores hay
		# que poder encontrarse de un vistazo.
		var claro := Color(1.0, 1.0, 1.0) if e["yo"] else Color(0.78, 0.8, 0.86)
		name_lbl.add_theme_color_override("font_color", claro)
		var pts_lbl := row["pts"] as Label
		pts_lbl.text = _miles(int(e["pts"]))
		pts_lbl.add_theme_color_override("font_color", claro)

func _miles(n: int) -> String:
	# Separador de miles, igual que el contador grande de arriba.
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "." + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out
