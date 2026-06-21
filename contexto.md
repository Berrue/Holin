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
