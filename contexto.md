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

- **`hole.gd`**: movimiento en el plano XZ + `Area3D` que avisa a los objetos cercanos.
  Crece por niveles (`level_radii` / `level_xp_req`), no de forma continua. La cámara es
  hija del agujero y lo sigue. Se lleva el **suelo** consigo: el piso alrededor de la boca
  viaja con el agujero, así que un objeto que queda sobre la boca se queda sin piso abajo
  y cae con física real — nadie lo teletransporta.
- **`swallowable.gd`**: cada objeto es un `RigidBody3D` de verdad, no una animación.
  Mientras la ciudad está intacta vive congelado (no cuesta nada); recién se suelta cuando
  el agujero se acerca, y ahí manda la física — se apoya, se vuelca, choca. El agujero lo
  traga si el radio circular de la base del objeto entra en el radio de la boca,
  con un 10 % de holgura física para que no se enganche en el borde.
- **`main.gd`**: genera la ciudad, lleva timer + puntaje + combo, arma los rivales, y maneja el game over.
  - **Regla de diseño clave:** `swallow_size` conserva el **ancho de referencia del objeto**
    para balance, masa e impacto; la entrada usa `footprint_radius`, derivado de la diagonal
    XZ de la colisión real. Para los modelos `.glb` se deriva del AABB real (ver
    `_spawn_model_swallowable`), así
    "el disco cubre el objeto → lo traga" se siente consistente.
  - **Game over / pausa:** el overlay es un `Control` con `process_mode = PROCESS_MODE_ALWAYS`
    y se usa `get_tree().paused = true`. Importante: **despausar antes** de
    `reload_current_scene()` / `change_scene_to_file()` (el `paused` vive en el árbol).

## El mapa

- **`MAP_HALF = 72`** → el mundo mide 144×144. Calles cada 16 (`ROAD_LINES`),
  8×8 = 64 manzanas (`BLOCK_CENTERS`), un cuarto de ellas parques.
- **Lago central** de radio 20 en el origen. Es un disco con el mismo shader del
  piso (así el agujero también le abre la boca), dibujado **por encima** del
  asfalto. Las calles que lo cruzan se cortan en la orilla — la media cuerda sale
  de Pitágoras en `_add_road`. Autos, peatones, props y rivales lo esquivan.
- **El jugador NO arranca en el origen** (`START_POS = (0,0,32)`): ahí ahora hay
  agua y no habría nada que comer. Arranca en la orilla. Todo lo que antes medía
  "distancia al centro" para despejar el arranque ahora mide contra `START_POS`.

> ⚠ Duplicar el lado del mapa cuadruplica la comida y **mueve el balance**: el
> techo del bot pasó de ~1580 a 2845 puntos, así que hubo que resubir
> `SCORE_GOAL` de 1200 a 2100. Si volvés a cambiar el tamaño, recalibrá (el
> procedimiento está en el comentario de `SCORE_GOAL`).

> ⚠ **Y cuesta rendimiento.** Medido con `devtools/profile.gd`, de `MAP_HALF` 36
> a 72 (más las extremidades de los peatones): draw calls 198 → 617, triángulos
> 123k → 820k, MeshInstance3D 511 → 2133. Son cuentas independientes del
> hardware, y para un Android de gama baja es mucho. El material para arreglarlo
> ya está en el repo sin usar: los 16 modelos `low-detail-building-*` de Kenney
> son LODs listos para los edificios lejanos.

## Biblioteca de props (`holin/scenes/props/`)

Los edificios **no** son rutas `.glb` hardcodeadas en `main.gd`: son escenas
editables, una por tipo. Cada una trae todo lo suyo y se arma sola en su
`_ready()` (vía `auto_setup`, ver la sección de abajo):

| Propiedad | Qué controla |
|---|---|
| `auto_footprint` | El ancho en metros. **Es EL parámetro de gameplay:** decide a partir de qué nivel del agujero se puede comer. |
| `palette_material` | Cuál de las 3 paletas usa (`resources/city_palette_*.tres`). |
| `xp_value` | Cuántos puntos da. |
| `break_pieces` | En cuántos pedazos se derrumba (2 edificios, 3 rascacielos). |
| `sfx_kind` | Qué se escucha al caer. |

**19 tipos** hoy: `building_a` … `building_n` (14) y `skyscraper_a` … `skyscraper_e` (5).

**Para tunear un edificio:** abrís su escena y cambiás la propiedad. No hay que
tocar código.

**Para agregar uno nuevo:** duplicás una escena de props, le cambiás el `.glb`
del nodo `Model`, y la sumás al array `BUILDINGS_LOW` o `SKYSCRAPERS` de
`main.gd` (es lo único que queda en código: *qué* props entran en la generación
procedural).

### Las paletas

Los `.glb` de Kenney mapean sus UV contra un **atlas de paleta** de 512×512. Eso
significa que cambiar el atlas por otro con el mismo layout **recolorea el modelo
entero sin tocar la geometría ni las UV**.

Hay **7 paletas** en `holin/resources/city_palette_*.tres`: 3 del pack
(`base`, `a`, `b`) y 4 generadas por `tools/gen_palettes.py`
(`noche`, `menta`, `pastel`, `tierra`). Seis están repartidas entre los 19 props;
`noche` queda afuera de la rotación diurna porque tiene las ventanas encendidas
—está lista para un mapa nocturno.

> Las paletas son **archivos `.tres`, no materiales creados por código**, y eso
> es a propósito: Godot cachea el recurso por ruta, así que todas las instancias
> comparten el mismo objeto y el renderer las junta en **un draw call por
> paleta**. Verificado: agregar 4 paletas dejó el inventario de materiales
> igual (68). Un material nuevo por instancia serían draw calls regalados — el
> mismo error que ya se arregló una vez con las camisas de los peatones.

### Inventar paletas nuevas (`tools/gen_palettes.py`)

```bash
python tools/gen_palettes.py
```

Agregás una entrada a `PALETTES` y volvés a correr. Sin dependencias (stdlib:
escribe el PNG a mano con `zlib`+`struct`), igual que `gen_sfx.py` con el audio.

Lo que hay que saber, porque **medirlo costó y la primera versión del script se
equivocó por no saberlo**: el atlas es una grilla de 16×4 celdas de color plano,
pero de esas 64 celdas **solo 4 cubren el 99% de lo que se ve** de un edificio.
Se midió leyendo las UV de los 19 modelos y sumando área de triángulo:

| Celda | Área | Rol en el script |
|---|---|---|
| `r2 c1` | 47.8% | `marco` — marcos, molduras, parantes |
| `r2 c7` | 26.5% | `pared` — el panel de pared |
| `r2 c3` | 13.7% | `oscuro` — gris de base y techo |
| `r1 c11` | 10.9% | `vidrio` — el vidrio de las ventanas |

⚠ **Trampa:** el pack solo varía `pared`. Los otros dos pares que cambian entre
`colormap`/`variation-a`/`variation-b` **no los usa ningún edificio** (0.6% y
0.2% del área). Una paleta que solo toque esos pares se ve casi idéntica a la
base — fue exactamente el error de la primera versión. Con tocar `pared` ya se
nota; sumando `marco` el cambio es total.

Se pueden editar las 64 celdas sin miedo: este atlas lo samplean **únicamente**
los modelos de `kenney_city` (los autos tienen su propio `colormap.png` y los de
`kenney_nature` no usan textura). Para explorar más allá de los 4 roles hay un
`--probe` que pinta cada fila del atlas de un color distinto.

## Mapas armados a mano

Además de la ciudad procedural (`main.gd` la arma sola en `_ready()`, distinta
cada partida), `swallowable.gd` soporta armarse **a mano** en el editor:
instanciás `scenes/swallowable.tscn` directo en cualquier escena, le ponés un
modelo, y funciona en Play sin escribir una línea de código.

> Hay un ejemplo real ya armado y verificado en `main.tscn`:
> `ManualCity/ExampleBuilding` — un `building-a.glb` puesto a mano, rotado 4°
> a propósito (para probar que la medición no depende de estar alineado a
> ejes), con `break_pieces = 2`. Abrilo en el editor y mirá cómo están puestas
> las propiedades antes de armar el tuyo.

**Receta:**

1. Abrí `main.tscn` (o cualquier escena que tenga un `Hole` en el árbol).
2. Arrastrá `res://scenes/swallowable.tscn` al viewport 3D.
3. Adentro de esa instancia, abrí `Visual/` y arrastrale un modelo (cualquier
   `.glb` de `assets/kenney_*/`) como hijo. **Si vas a usar `break_pieces > 1`,
   ese hijo tiene que llamarse exactamente `Model`** — es el nombre por el que
   `_on_wants_break` en `main.gd` lo busca para partirlo; con otro nombre no
   explota nada, pero tampoco se derrumba por pedazos (cae entero, calladito).
4. Movelo / rotalo / escalalo con el gizmo hasta que quede como querés — **ese
   es el tamaño final**, acá no se reescala nada (al revés que la ciudad
   procedural, que decide un tamaño primero y recién ahí escala el modelo).
5. En el Inspector del nodo raíz, grupo **"Armado a mano"**, tildá `auto_setup`.
6. Seteá `xp_value` y `sfx_kind` (es un `int` en el Inspector, no un dropdown:
   0=ninguno, 1=voz, 2=escombro, 3=pesado, 4=auto — ver el enum `Kind` en
   `sfx.gd`). Si es un edificio grande, `break_pieces = 2` o `3` para que
   colapse por pedazos en vez de caer entero.
7. Para autos/peatones: `auto_mode` = CAR o PEDESTRIAN, y `auto_dir` con la
   dirección de marcha o huida.
8. Play. Se mide solo, arma su colisión, y ya suma puntos, pega el golpe de
   impacto y (si corresponde) se derrumba por pedazos — por el mismo camino
   que la ciudad procedural.

**Por qué funciona:** `auto_setup` hace que `_ready()` mida el modelo que le
pusiste (en espacio LOCAL del propio nodo, así que da igual si lo rotaste) y
llame `setup_body()` con esa medida real, en vez de esperar a que `main.gd` se
la calcule. `main.gd`, antes de generar la ciudad procedural, adopta cualquier
swallowable que YA esté en la escena (`_adopt_manual_swallowables()`) y le
conecta las mismas señales (`consumed`, `fell_in`, `wants_break`) que usa todo
lo demás — así lo hecho a mano y lo procedural terminan siendo indistinguibles
para el resto del juego.

**Límites de esta primera versión:**
- El `_placed` que evita superposiciones en la ciudad procedural no sabe de los
  objetos armados a mano: si los ponés adentro de la grilla de calles, un
  edificio procedural puede nacer encima. Por ahora, ponelos afuera de
  `MAP_HALF` (36 m del centro).
- Sólo yaw (rotación en Y): el sistema asume todo parado derecho, como el resto
  del juego.
- Todavía no hay forma de elegir qué mapa cargar (procedural vs. a mano) desde
  el menú — hoy conviven en la misma escena. Separarlos en escenas de mapa
  intercambiables (Ciudad / Pueblo medieval / Espacio, como pide el GDD para
  Fase 2) es el paso que sigue.

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

> ⚠ **Otra trampa, distinta de la de arriba:** si alguna vez borrás
> `holin/.godot/` entero y reimportás desde cero, vas a ver
> `Condition "array_len == 0"` / `mesh.cpp:1825` al procesar
> `building-a.glb` (y probablemente otros `.glb` de Kenney). Es inofensivo —
> se cae un paso secundario del import (parece desenvolvido de UV2 para
> lightmap sobre una malla low-poly) pero el mesh principal importa bien
> igual: la escena carga y corre sin errores. **Si ves este mensaje en el
> Output del editor sin haber borrado `.godot/`, esa es otra causa** (revisá
> si hay otro proceso de Godot corriendo contra el mismo proyecto al mismo
> tiempo — dos procesos escribiendo la caché de import juntos también da
> exactamente este error, y ESE caso sí importa: ahí conviene cerrar todo y
> reabrir).

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
