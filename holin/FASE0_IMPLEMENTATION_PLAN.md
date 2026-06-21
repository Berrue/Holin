# Fase 0 — Plan de implementación (prototipo del feel)

> **Para el agente de código.** Objetivo de esta fase: tener un prototipo jugable donde un agujero se mueve por un plano y se traga objetos, creciendo a medida que come. Sin menús, sin ads, sin arte definitivo. Si esto se siente bien, el juego es viable.
>
> **Motor:** Godot 4.x · **Lenguaje:** GDScript · **Plataforma objetivo:** móvil (pero debe ser testeable en desktop con teclado/mouse).

---

## 0. Estado actual del proyecto

El proyecto Godot ya existe en esta carpeta (`holin/`):

```
holin/
├── project.godot        # proyecto vacío recién creado
├── icon.svg
└── assets/
    └── kenney_city/      # 41 modelos .glb (CC0, City Kit de Kenney)
        ├── building-a.glb ... building-n.glb
        ├── building-skyscraper-a.glb ... -e.glb
        ├── low-detail-building-*.glb
        ├── detail-*.glb
        └── Textures/colormap.png   # los .glb la referencian por ruta relativa
```

Los `.glb` se importan nativos en Godot 4. No tocar la carpeta `Textures/` ni mover los `.glb` (rompería la ruta de la textura embebida por referencia).

---

## 1. Resultado esperado (Definition of Done)

Al terminar la Fase 0, al dar **Play** debe pasar esto:

1. Se ve un plano (suelo) desde una **cámara cenital** (top-down, con leve ángulo).
2. Hay un **agujero** (disco oscuro) en el suelo que el jugador mueve:
   - En desktop: con **WASD / flechas** y/o **arrastrando con el mouse**.
   - En móvil: **arrastrando el dedo** por la pantalla.
3. Hay objetos repartidos por el escenario (cubos de prueba de varios tamaños + algunos edificios Kenney).
4. Cuando el centro del agujero pasa por encima de un objeto **de tamaño ≤ al del agujero**, el objeto es **succionado** (cae hacia el centro, rota, se encoge a 0 y desaparece).
5. Objetos **más grandes** que el agujero **no** se tragan (idealmente tiemblan un poco como feedback).
6. Cada objeto tragado suma masa; al cruzar umbrales, el **agujero crece** de forma visible (escalón satisfactorio), y entonces puede tragar objetos más grandes.
7. Hay un contador en pantalla (objetos tragados o "masa"/score) — un `Label` simple alcanza.

**Criterio de éxito subjetivo:** mover el agujero y tragar cosas tiene que sentirse *fluido y satisfactorio*. Priorizar el feel del movimiento y la animación de succión por encima de todo lo demás.

---

## 2. Configuración del proyecto (`project.godot` / Project Settings)

- **Rendering → Renderer:** `Mobile` (Project Settings → Rendering → Renderer, o `rendering/renderer/rendering_method = "mobile"`).
- **Display → Window → Stretch:** mode `canvas_items`, aspect `expand`.
- **Display → Window:** orientación `portrait` (juego vertical de celular) — ajustable, pero asumir portrait.
- **Input Map:** crear acciones `move_up`, `move_down`, `move_left`, `move_right` mapeadas a WASD + flechas, para poder testear en desktop. (El input táctil se maneja por código aparte.)
- **Physics:** dejar default. No habrá RigidBodies activos; todo se anima por código.

---

## 3. Estructura de archivos a crear

```
holin/
├── scenes/
│   ├── main.tscn          # escena principal (raíz del juego)
│   ├── hole.tscn          # el agujero (jugador)
│   └── swallowable.tscn   # objeto tragable reutilizable
├── scripts/
│   ├── main.gd
│   ├── hole.gd
│   └── swallowable.gd
└── (assets/ ya existe)
```

Setear `main.tscn` como **escena principal** (Project → Project Settings → Application → Run → Main Scene).

---

## 4. Escenas — árbol de nodos

### 4.1 `swallowable.tscn`
Objeto genérico que el agujero puede tragar. Raíz **`Area3D`** (así el agujero lo detecta por solapamiento, sin física pesada).

```
Swallowable (Area3D)            # script: swallowable.gd
├── MeshInstance3D              # el cuerpo visible (cubo por defecto; reemplazable por un .glb)
└── CollisionShape3D            # BoxShape3D acorde al mesh
```

- Propiedad exportada `swallow_size: float` — el "tamaño" del objeto. El agujero solo lo traga si `hole_size >= swallow_size`.
- `monitorable = true`, `monitoring = false` (solo necesita ser detectado, no detectar).
- Para variantes grandes, instanciar con un `.glb` de Kenney como hijo del MeshInstance3D (o reemplazar el mesh) y subir `swallow_size`.

### 4.2 `hole.tscn`
El agujero / jugador. Raíz **`Node3D`**.

```
Hole (Node3D)                  # script: hole.gd
├── Visual (MeshInstance3D)     # disco oscuro: CylinderMesh muy chato (height ~0.05) o un QuadMesh con material negro
├── DetectionArea (Area3D)
│   └── CollisionShape3D        # CylinderShape3D (radio = radio del agujero)
└── Camera3D                    # cenital con leve ángulo, hija del agujero para que lo siga
```

- El `Visual` es un disco negro a ras del suelo (y ≈ 0.02 para evitar z-fighting con el piso). En Fase 0 no hace falta shader real de "recorte"; el disco oscuro alcanza para vender la idea.
- La `Camera3D`: posición tipo `(0, 12, 6)` relativa al agujero, rotación mirando hacia abajo (~ -60° en X). Que sea hija del Hole hace que lo siga automáticamente. (Si se quiere suavizar, interpolar la cámara aparte; opcional en Fase 0.)
- El radio del `CylinderShape3D` de `DetectionArea` se actualiza por código cuando el agujero crece.

### 4.3 `main.tscn`
```
Main (Node3D)                  # script: main.gd
├── Ground (StaticBody3D)
│   ├── MeshInstance3D          # PlaneMesh grande (ej. 60 x 60), material gris claro
│   └── CollisionShape3D        # opcional en Fase 0
├── DirectionalLight3D          # luz + sombras
├── WorldEnvironment            # environment básico (cielo o color de fondo)
├── Hole                        # instancia de hole.tscn
├── Swallowables (Node3D)       # contenedor; se llena por código en _ready
└── UI (CanvasLayer)
    └── ScoreLabel (Label)      # "Tragados: 0" o "Masa: 0"
```

---

## 5. Scripts — lógica y código de referencia

> Código de referencia, no dogma. El agente puede ajustar nombres/valores pero debe respetar el comportamiento descrito en la sección 1.

### 5.1 `hole.gd`

```gdscript
extends Node3D

@export var move_speed: float = 8.0
@export var radius: float = 1.0          # radio actual del agujero
@export var growth_per_unit: float = 0.02 # cuánto crece el radio por unidad de masa

var mass: float = 0.0
var _drag_input: Vector2 = Vector2.ZERO   # input táctil/mouse acumulado

@onready var visual: MeshInstance3D = $Visual
@onready var detection_area: Area3D = $DetectionArea
@onready var shape: CollisionShape3D = $DetectionArea/CollisionShape3D

signal swallowed(amount: float, total_mass: float)

func _ready() -> void:
    _apply_radius()

func _physics_process(delta: float) -> void:
    var dir := _get_move_direction()
    # mover en el plano XZ
    global_position += Vector3(dir.x, 0.0, dir.y) * move_speed * delta
    _check_swallow()

func _get_move_direction() -> Vector2:
    # teclado (desktop) + input táctil/mouse (drag)
    var kb := Input.get_vector("move_left", "move_right", "move_up", "move_down")
    if kb != Vector2.ZERO:
        return kb
    if _drag_input != Vector2.ZERO:
        return _drag_input.normalized()
    return Vector2.ZERO

func _input(event: InputEvent) -> void:
    # arrastrar dedo (móvil) o mouse (desktop) define dirección
    if event is InputEventScreenDrag:
        _drag_input = event.relative
    elif event is InputEventScreenTouch and not event.pressed:
        _drag_input = Vector2.ZERO
    elif event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
        _drag_input = event.relative
    elif event is InputEventMouseButton and not event.pressed:
        _drag_input = Vector2.ZERO

func _check_swallow() -> void:
    for area in detection_area.get_overlapping_areas():
        if not area.is_in_group("swallowable"):
            continue
        if area.has_meta("being_swallowed"):
            continue
        var sw_size: float = area.get("swallow_size")
        # distancia horizontal centro-agujero -> centro-objeto
        var hpos := Vector2(global_position.x, global_position.z)
        var opos := Vector2(area.global_position.x, area.global_position.z)
        var dist := hpos.distance_to(opos)
        if sw_size <= radius and dist < radius * 0.9:
            area.set_meta("being_swallowed", true)
            area.call("be_swallowed", global_position)
            _grow(sw_size)
        elif sw_size > radius and dist < radius * 1.1:
            area.call("wobble")  # feedback "todavía no podés"

func _grow(amount: float) -> void:
    mass += amount
    radius += amount * growth_per_unit
    _apply_radius()
    emit_signal("swallowed", amount, mass)

func _apply_radius() -> void:
    # escalar el disco visual y el shape de detección
    visual.scale = Vector3(radius, 1.0, radius)
    if shape.shape is CylinderShape3D:
        (shape.shape as CylinderShape3D).radius = radius
```

### 5.2 `swallowable.gd`

```gdscript
extends Area3D

@export var swallow_size: float = 1.0

func _ready() -> void:
    add_to_group("swallowable")

func be_swallowed(hole_center: Vector3) -> void:
    # animación de succión: caer hacia el centro + bajar + encoger + rotar
    var tween := create_tween().set_parallel(true)
    var target := Vector3(hole_center.x, hole_center.y - 1.5, hole_center.z)
    tween.tween_property(self, "global_position", target, 0.35).set_ease(Tween.EASE_IN)
    tween.tween_property(self, "scale", Vector3.ZERO, 0.35).set_ease(Tween.EASE_IN)
    tween.tween_property(self, "rotation", rotation + Vector3(0, TAU, 0), 0.35)
    tween.chain().tween_callback(queue_free)

func wobble() -> void:
    # pequeño feedback de "no entrás todavía"
    if has_meta("wobbling"):
        return
    set_meta("wobbling", true)
    var t := create_tween()
    var base := position
    t.tween_property(self, "position", base + Vector3(0.05, 0, 0), 0.04)
    t.tween_property(self, "position", base - Vector3(0.05, 0, 0), 0.04)
    t.tween_property(self, "position", base, 0.04)
    t.tween_callback(func(): remove_meta("wobbling"))
```

### 5.3 `main.gd`

```gdscript
extends Node3D

@export var swallowable_scene: PackedScene
@onready var hole = $Hole
@onready var swallowables := $Swallowables
@onready var score_label: Label = $UI/ScoreLabel

var count := 0

func _ready() -> void:
    _spawn_field()
    hole.swallowed.connect(_on_swallowed)
    _update_label()

func _spawn_field() -> void:
    # grilla de objetos de tamaños variados sobre el plano
    var sizes := [0.5, 0.8, 1.0, 1.5, 2.0, 3.0]
    for x in range(-20, 21, 4):
        for z in range(-20, 21, 4):
            var s = swallowable_scene.instantiate()
            s.swallow_size = sizes[randi() % sizes.size()]
            s.scale = Vector3.ONE * s.swallow_size
            s.position = Vector3(x + randf_range(-1, 1), s.swallow_size * 0.5, z + randf_range(-1, 1))
            swallowables.add_child(s)

func _on_swallowed(_amount: float, _total: float) -> void:
    count += 1
    _update_label()

func _update_label() -> void:
    score_label.text = "Tragados: %d  |  Tamaño: %.1f" % [count, hole.radius]
```

> Asignar `swallowable_scene` = `swallowable.tscn` en el inspector de `Main`.

---

## 6. Notas para el agente

- **Probar primero con cubos** (mesh por defecto), no con los `.glb`. Validar el feel con primitivas; recién después reemplazar algunos swallowables grandes por edificios de `assets/kenney_city/` (subiéndoles `swallow_size`).
- **No usar RigidBody3D** para los tragables. Todo se anima con `Tween`. Cientos de cuerpos físicos matan el rendimiento en celular.
- **El disco del agujero** en Fase 0 es solo un cilindro/quad oscuro. El shader real de "recorte del suelo" es pulido de fases posteriores; no bloquear la Fase 0 con eso.
- **Input táctil:** Godot emula touch con mouse si está activada la opción `Input Devices → Pointing → Emulate Touch From Mouse` (útil para testear drag en desktop). Activarla.
- **Tunear estos valores hasta que se sienta bien** (es el corazón de la fase): `move_speed`, `growth_per_unit`, duración del tween de succión (0.35s), el umbral `dist < radius * 0.9`.
- **Cámara:** si sigue al agujero de forma muy rígida y marea, suavizarla con un lerp en `_process`. Opcional.
- **Fuera de alcance en Fase 0:** menús, ads, monedas, skins, mapas múltiples, bots, sonido. No implementar nada de eso todavía.

---

## 7. Checklist de entrega

- [ ] Proyecto configurado (renderer Mobile, input map, main scene).
- [ ] `swallowable.tscn` + `swallowable.gd` funcionando (succión + wobble).
- [ ] `hole.tscn` + `hole.gd`: movimiento (teclado + drag) y crecimiento.
- [ ] `main.tscn` + `main.gd`: plano, luz, campo de objetos, cámara, label.
- [ ] Al dar Play: el agujero se mueve, traga objetos ≤ su tamaño, crece, y el label actualiza.
- [ ] Objetos más grandes no se tragan (hacen wobble).
- [ ] Se reemplazaron algunos objetos grandes por edificios `.glb` de Kenney.
- [ ] El movimiento y la succión se sienten fluidos (juicio subjetivo — es el objetivo de la fase).
```
