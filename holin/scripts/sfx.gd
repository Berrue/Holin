extends RefCounted

## Banco de efectos. Los .wav no vienen de ningún pack: se generan por síntesis
## con tools/gen_sfx.py, así que para retocarlos se editan los números de ese
## script y se vuelve a correr (ver el docstring de ahí).
##
## El reproductor NO cuelga del objeto que suena: el objeto se libera al llegar
## al fondo del pozo y cortaría el grito por la mitad. Se crea suelto en la
## escena, en la posición donde pasó la cosa, y se borra solo al terminar.

enum Kind { NONE, VOICE, DEBRIS, HEAVY, CAR }

const SCREAMS: Array[AudioStream] = [
	preload("res://assets/audio/scream_1.wav"),
	preload("res://assets/audio/scream_2.wav"),
	preload("res://assets/audio/scream_3.wav"),
	preload("res://assets/audio/scream_4.wav"),
	preload("res://assets/audio/scream_5.wav"),
]
const CRUMBLES: Array[AudioStream] = [
	preload("res://assets/audio/crumble_1.wav"),
	preload("res://assets/audio/crumble_2.wav"),
	preload("res://assets/audio/crumble_3.wav"),
]
const CRUMBLES_BIG: Array[AudioStream] = [
	preload("res://assets/audio/crumble_big_1.wav"),
	preload("res://assets/audio/crumble_big_2.wav"),
]
const CARS: Array[AudioStream] = [
	preload("res://assets/audio/car_1.wav"),
	preload("res://assets/audio/car_2.wav"),
	preload("res://assets/audio/car_3.wav"),
]

# Tragarse un parque entero de una no puede sonar a mazacote. Se cuentan los
# reproductores vivos por grupo en vez de llevar un contador estático: así el
# número no queda desfasado si se reinicia la partida a mitad de un sonido.
const MAX_VOICES := 8
const GROUP := "sfx"

# La cámara está 12-14 unidades arriba del agujero: con el unit_size por defecto
# (10) todo llegaría ya atenuado.
const UNIT_SIZE := 24.0
const MAX_DISTANCE := 48.0


static func play(kind: int, parent: Node, pos: Vector3) -> void:
	var bank := _bank(kind)
	if bank.is_empty() or parent == null or not parent.is_inside_tree():
		return
	var tree := parent.get_tree()
	if tree.get_node_count_in_group(GROUP) >= MAX_VOICES:
		return
	var p := AudioStreamPlayer3D.new()
	p.add_to_group(GROUP)
	p.stream = bank.pick_random()
	p.unit_size = UNIT_SIZE
	p.max_distance = MAX_DISTANCE
	# Los gritos tienen bastante más energía que los derrumbes (voz angosta y
	# pareja contra ruido ancho y percusivo): sin compensar acá, los edificios
	# se caerían en silencio al lado de los peatones.
	match kind:
		Kind.VOICE:
			# Cada peatón con su tono: si suenan todos igual se nota el truco.
			p.volume_db = -6.0
			p.pitch_scale = randf_range(0.88, 1.18)
		Kind.DEBRIS:
			p.volume_db = 2.0
			p.pitch_scale = randf_range(0.90, 1.10)
		Kind.HEAVY:
			p.volume_db = 4.0
			p.pitch_scale = randf_range(0.82, 1.00)
		Kind.CAR:
			p.volume_db = -3.0
			p.pitch_scale = randf_range(0.90, 1.12)
	parent.add_child(p)
	p.global_position = pos
	p.finished.connect(p.queue_free)
	p.play()


static func _bank(kind: int) -> Array[AudioStream]:
	match kind:
		Kind.VOICE:
			return SCREAMS
		Kind.DEBRIS:
			return CRUMBLES
		Kind.HEAVY:
			return CRUMBLES_BIG
		Kind.CAR:
			return CARS
	return []
