# Contexto del proyecto — Holin

Hola 👋 Este documento es para que puedas seguir y sumarte al proyecto rápido.

## Qué es

**Holin** es un juego hipercasual para móvil: un clon de **hole.io**. Controlás un
agujero negro que se mueve por una ciudad y se traga todo lo que toca (props,
autos, edificios). Cuanto más comés, más grande te hacés y más cosas podés tragar.
Partidas cortas (120 s) contra el reloj.

- **Motor:** Godot **4.6** (probado en 4.6.1 stable).
- **Lenguaje:** GDScript.
- **Plataforma objetivo:** móvil (Android primero), pero se testea en desktop con teclado/mouse.
- **Assets:** Kenney *City Kit* (licencia **CC0**, ver `holin/assets/kenney_city/License.txt`).

## Cómo abrirlo y jugarlo

1. Instalá **Godot 4.6+** (https://godotengine.org/download).
2. En el editor: *Import* → elegí `holin/project.godot` (el proyecto está en la subcarpeta **`holin/`**, no en la raíz del repo).
3. Apretá **F5** (Play). Arranca en el menú principal.
4. **Controles:** WASD / flechas, o arrastrar con el mouse (en móvil, arrastrar el dedo).

> Nota: la carpeta `holin/.godot/` (cache de import) está en `.gitignore`. Godot
> la regenera sola la primera vez que abrís el proyecto — puede tardar unos segundos.

## Estado actual (al 2026-06-21)

Hecho y validado: **Fase 0** (prototipo del feel) y **Fase 1** (MVP jugable).

- Agujero que se mueve y traga objetos creciendo (regla: solo tragás lo que sea ≤ tu tamaño).
- Flujo completo: **menú → partida → game over → reiniciar / volver al menú**.
- **Timer de 120 s** + **puntaje** (objetos más grandes dan más puntos).
- **Ciudad detallada** generada por código: calles + veredas + líneas, edificios Kenney por manzana, y props (parasoles) + cubos como objetos chicos.

## Estructura

```
Holin/                         <- raíz del repo
├── GDD_juego_hole_clone.md    <- documento de diseño (el "qué" y el "por qué")
├── contexto.md                <- este archivo
└── holin/                     <- proyecto Godot (abrí ESTA carpeta)
    ├── project.godot          <- escena principal: scenes/main_menu.tscn
    ├── FASE0_IMPLEMENTATION_PLAN.md
    ├── scenes/
    │   ├── main_menu.tscn      <- menú (entrada)
    │   ├── main.tscn           <- la partida (timer, score, game over, ciudad)
    │   ├── hole.tscn           <- el agujero (jugador)
    │   └── swallowable.tscn    <- objeto tragable reutilizable
    ├── scripts/                <- main_menu.gd, main.gd, hole.gd, swallowable.gd
    └── assets/kenney_city/     <- modelos .glb (CC0) + textura colormap
```

## Cómo funciona (lo que conviene saber antes de tocar código)

- **`hole.gd`**: movimiento en el plano XZ + detección por `Area3D`. Al tragar, suma
  masa y crece el radio (`growth_per_unit`). La cámara es hija del agujero y lo sigue.
- **`swallowable.gd`**: cada objeto tiene `swallow_size`. El agujero lo traga si
  `radius >= swallow_size` y está suficientemente encima. La succión es un `Tween`
  (cae + encoge + rota), **sin física pesada** — nada de RigidBody (mata el rendimiento en celular).
- **`main.gd`**: genera la ciudad, lleva timer + puntaje, y maneja el game over.
  - **Regla de diseño clave:** `swallow_size` debe igualar el **ancho real del objeto en el mundo**.
    Para los modelos `.glb` se deriva del AABB real (ver `_spawn_model_swallowable`), así
    "el disco cubre el objeto → lo traga" se siente consistente.
  - **Game over / pausa:** el overlay es un `Control` con `process_mode = PROCESS_MODE_ALWAYS`
    y se usa `get_tree().paused = true`. Importante: **despausar antes** de
    `reload_current_scene()` / `change_scene_to_file()` (el `paused` vive en el árbol).

## Herramientas de dev (`holin/devtools/`)

Dos scripts para mirar y medir el juego sin jugarlo a mano. No son parte del
juego: no los carga ninguna escena, se corren desde la consola.

| Script | Para qué |
|---|---|
| `stress.gd` | Juega una partida entera sola e informa. Correlo después de cualquier cambio de física o de spawn. |
| `shots.gd` | Saca PNGs en el frame exacto en que pasa algo (un derrumbe, un impacto). Para comparar antes/después de un cambio visual. |
| `profile.gd` | Mide rendimiento durante una partida entera: draw calls, triángulos, tiempos de CPU, e inventario de mallas y materiales. |
| `autoplay.gd` | El bot que usan los tres. Va por lo más valioso que le entre por tamaño. |

```bash
godot --headless --path holin --script res://devtools/stress.gd
```

```bash
godot --path holin --script res://devtools/shots.gd
```

```bash
godot --path holin --script res://devtools/profile.gd
```

`shots.gd` y `profile.gd` van **sin** `--headless` (necesitan renderizar). El
primero deja los PNG en
`user://holin_shots` e imprime la ruta absoluta al arrancar. Se configura con
las constantes de arriba del archivo (qué evento espera, en qué nivel arranca,
cuántos frames después dispara cada foto, el prefijo de los archivos).

Del informe de `stress.gd` hay dos números que importan:

- **`objetos` tiene que bajar** con el tiempo. Si sube, algo se está acumulando.
- **`time_scale` tiene que terminar en 1.00.** Si no, quedó trabado un hitstop —
  y como vive en `Engine` y no en el árbol, ni recargar la escena lo arregla.

> ⚠ Trampa que ya costó una vez: `main._ready()` recién corre en el **primer
> frame**, no durante el `_initialize()` de un `SceneTree`. Cualquier setup que
> toque el agujero va después, o main lo pisa. Está comentado en `autoplay.gd`.

## Exportar a Android

```bash
godot --headless --path holin --export-debug "Android" "../build/holin.apk"
```

El APK sale en `build/` (ignorado por git). El preset está en
`holin/export_presets.cfg`; las rutas del SDK, el JDK y el keystore de debug
salen de la configuración del editor de Godot, no del repo.

> ⚠ **Trampa cara:** si falta `textures/vram_compression/import_etc2_astc=true`
> en `project.godot`, la exportación falla con un `Cannot export project ... due
> to configuration errors` que **no dice cuál es el error**. Android exige
> ETC2/ASTC. Ya está puesto, pero si alguna vez reaparece ese mensaje, empezá
> por ahí.

Instalar en un teléfono con depuración USB activada (`adb` no está en el PATH,
vive en `%LOCALAPPDATA%\Android\Sdk\platform-tools`):

```bash
"$LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe" install -r build/holin.apk
```

El APK de debug arranca con el **overlay de métricas** encendido
(`scripts/perf_overlay.gd`, abajo a la izquierda): fps, ms de CPU, draw calls y
triángulos. En release se apaga solo. En escritorio se alterna con **F3**.

Cómo leerlo: a 60 fps el presupuesto es 16,6 ms por frame. Si la CPU sola ya se
come la mitad, el cuello es CPU; si la CPU está baja y los fps igual caen, el
cuello es GPU — y ahí el sospechoso número uno es el `discard` de
`ground_hole.gdshader`, que corre sobre casi toda la pantalla.

## Próximos pasos (roadmap)

- **Fase 2 (siguiente):** monetización (AdMob: intersticial + rewarded) + retención
  (monedas, tienda de skins, misiones diarias) + 2-3 mapas más + IAP "Remove Ads".
- **Fase 3:** pulido (juice, sonido, partículas), optimización en celulares reales, build de Android.

Ver el roadmap completo en `GDD_juego_hole_clone.md` (sección 7).

## Para tunear / playtest (lo que está abierto)

El *feel* y el balance se ajustan con estos valores:
- `move_speed` (en `hole.gd`, default 8) — velocidad del agujero.
- `growth_per_unit` (en `hole.gd`, default 0.05) — cuán rápido crece al tragar.
- Duración del tween de succión (en `swallowable.gd`, 0.35 s).
- Tamaño/densidad de la ciudad (en `main.gd`: `MAP_HALF`, scatter, cantidad de edificios).

⚠️ Pendiente de playtest: el mapa es grande (`MAP_HALF=36`), así que crecer hasta los
rascacielos en 120 s puede sentirse lento. Si pasa, bajar `MAP_HALF`, subir densidad,
o subir un poco `move_speed` / `growth_per_unit`.
