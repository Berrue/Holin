# Game Design Doc — Clon de hole.io (Godot 4)

> Documento de diseño y plan de producción. Motor: **Godot 4**. Estado: solo diseño (sin código todavía).
> Última actualización: 2026-06-21

---

## 1. Concepto en una línea

Controlás un agujero negro que se mueve por una ciudad/escenario y "se traga" todo lo que toca (autos, gente, edificios). Cuanto más comés, más grande te hacés, y podés tragar cosas cada vez más grandes. Partidas cortas (2-3 min) con timer, ideal para sesiones de un viaje en colectivo. Monetización por ads intersticiales + rewarded.

**Por qué funciona para monetizar:** loop instantáneo de entender, "una más" constante, y puntos naturales para meter ads (entre partidas). Es el género hipercasual clásico.

---

## 2. Mecánica core (el "feel" del juego)

El 80% del éxito de este género está en que el agujero se sienta bien. Detalles clave:

- **Movimiento del agujero:** se controla con un joystick virtual (pulgar) o arrastrando el dedo. El agujero se mueve sobre un plano; los objetos caen dentro cuando su centro pasa por encima del borde.
- **Regla de tamaño:** un objeto solo se puede tragar si el agujero es ≥ que el objeto. Si es más chico, el objeto tiembla/se sacude pero no cae (feedback de "todavía no podés con esto"). Esto crea la progresión dentro de la partida.
- **Crecimiento:** cada objeto tragado suma a una barra de "masa". Al llenar un umbral, el agujero crece de tamaño (escalón visible y satisfactorio). Curva de crecimiento: rápido al principio, más lento después (para que la partida tenga arco).
- **Física de absorción:** el truco visual es que los objetos caen, rotan y se encogen al entrar. No hace falta física real compleja — un efecto de "succión" (mover hacia el centro + escalar a 0 + rotar) alcanza y rinde mejor en celular.
- **Timer:** 120 segundos por partida. El objetivo es maximizar el tamaño/puntaje antes de que se acabe.

### Variante competitiva (opcional, fase 2)
Como hole.io original: varios agujeros (bots o multijugador) en el mismo mapa compitiendo. Un agujero más grande puede tragarse a otro más chico. Esto agrega rejugabilidad pero **complica mucho** (netcode o IA). Recomendación: arrancá **single-player contra el reloj**, agregá bots locales después.

---

## 3. Progresión y retención

La parte que hace que el jugador vuelva (= más impresiones de ads):

**Dentro de la partida:**
- Subir de tamaño desbloquea tragar objetos más grandes (peatón → banco de plaza → auto → camión → casa → edificio). Esto da el "power fantasy".

**Entre partidas (meta-progresión):**
- **Monedas** ganadas por puntaje en cada partida.
- **Skins del agujero** comprables con monedas (portal de colores, remolino, lava, agujero negro con estrellas). Las skins son el principal sink de monedas y motor de retención sin afectar balance.
- **Escenarios/mapas** desbloqueables: Ciudad → Pueblo medieval → Espacio → Oficina → Playa. Cada uno reusa la misma mecánica con assets distintos = mucho contenido percibido con poco trabajo.
- **Misiones diarias** (ej: "tragá 50 autos", "alcanzá tamaño 10"): dan monedas y un motivo para volver cada día. Clave para retención D1/D7.
- **Niveles/objetivos** por mapa (3 estrellas según puntaje) para los que quieren completar.

**Sistemas que mueven la aguja en hipercasual:** misiones diarias, racha de login, y un evento semanal simple. No te compliques al inicio: monedas + skins + misiones diarias ya es suficiente para un MVP retentivo.

---

## 4. Monetización (ads)

Modelo: **gratis con ads + opción de remover ads (IAP único)**.

### Tipos de ad y dónde van
- **Intersticial:** entre partidas, cada 2-3 partidas (NO en cada una — molesta y baja retención). Es tu ingreso principal por volumen.
- **Rewarded (recompensado):** el más rentable y el que NO molesta porque es opcional. Úsalo para:
  - "Revivir" o "+30 segundos" al terminar la partida.
  - Duplicar las monedas ganadas.
  - Desbloquear una skin temporalmente.
- **Banner:** opcional, solo en menús (no en gameplay). Ingreso bajo, puede ensuciar la pantalla.
- **App Open:** al abrir la app (con moderación).

### Buenas prácticas (no quemar al usuario)
- Frecuencia de intersticiales con un límite (cap) y un cooldown mínimo entre ellos.
- Nunca un ad en medio del gameplay.
- Pedir consentimiento GDPR/privacidad (los plugins de AdMob traen el User Messaging Platform integrado).
- IAP "Remove Ads" (~USD 2-3): saca intersticiales y banners, deja rewarded como opción. Da un ingreso estable de los usuarios más enganchados.

### Estado de ads en Godot 4 (2026)
Buenas noticias: hay soporte sólido de AdMob para Godot 4. Opciones principales:

- **Godot SDK Integrations — AdMob** (la opción oficial-ish, antes plugin de cengiz-pz): interfaz unificada en GDScript, soporta banner/intersticial/rewarded/rewarded interstitial/app open/native, mediación con hasta 15 redes, y GDPR via User Messaging Platform. Android + iOS. Es la más recomendable hoy.
- **Poing Studios godot-admob-plugin:** maduro, soporta GDScript y C#, Android + iOS.

Ambos se instalan desde el AssetLib de Godot y vienen con los **test IDs de Google** para probar sin tu cuenta real. Importante: los ads **no funcionan en el editor** — hay que exportar a un dispositivo Android/iOS real para testearlos.

---

## 5. Assets — texturas y modelos gratis (licencia comercial OK)

Como es un juego comercial, necesitás licencia que permita uso comercial. **CC0** es ideal (dominio público, sin atribución, modificable). Fuentes:

| Fuente | Qué tiene | Licencia |
|---|---|---|
| **Poly Haven** (polyhaven.com) | +40.000 assets: texturas PBR, HDRIs, modelos 3D. La mejor calidad. | CC0 |
| **Kenney.nl** | Packs de modelos low-poly listos para juegos (ciudad, autos, naturaleza, props). **Ideal para este juego** — estilo limpio y liviano. | CC0 |
| **KayKit (itch.io)** | Kits modulares low-poly (ciudad, dungeon, etc.). | CC0 / gratis |
| **OpenGameArt.org** | Texturas CC0, sprites, audio. | Variada (filtrá CC0) |
| **itch.io** (tag cc0 + 3d) | Packs sueltos, autos PSX, props retro. | Filtrá por CC0 |
| **3D Model Haven** | Modelos CC0 en FBX/Blend (creciendo). | CC0 |
| **Quaternius** | Modelos low-poly gratis muy usados en hipercasual. | CC0 |

**Recomendación de estilo:** **low-poly** (estilo Kenney/Quaternius). Razones: liviano para celular, fácil de mezclar, no necesitás texturas de alta resolución (mucho se resuelve con colores planos + un material simple), y da un look coherente y "limpio" que pega bien con hipercasual. Evita el realismo: pesa más y es más difícil de hacer consistente.

### ¿Generar las nuestras?
- **Texturas:** Para low-poly casi no necesitás texturas — colores planos o un atlas chico alcanza. Si querés PBR realista, podés generar con herramientas como Material Maker (open source, gratis, hecho con Godot) o usar las de Poly Haven directo.
- **Modelos 3D:** Generarlos a mano lleva tiempo. Para el MVP, usá Kenney/Quaternius y reservá hacer modelos propios para diferenciarte después.
- **Conviene:** empezar 100% con assets CC0 gratis, validar el juego, y recién después invertir en arte propio/diferenciado si funciona.

---

## 6. Stack técnico (Godot 4)

- **Motor:** Godot 4.x (la versión estable más reciente; algunos plugins de AdMob piden 4.3+).
- **Lenguaje:** GDScript (suficiente y más rápido de iterar para un primer juego; sos programador así que te va a resultar familiar — es tipo Python).
- **3D vs 2D:** hole.io es 3D pero con cámara cenital (top-down). Conviene hacerlo en **3D real** (es más fácil que fakearlo en 2D y los assets vienen en 3D).
- **Cómo resolver el "agujero":** el efecto del agujero que se traga cosas se suele hacer con un **mesh con shader** (un disco oscuro) + un Area3D que detecta qué objetos están encima. No necesitás recortar el suelo de verdad; visualmente alcanza con el disco negro y la animación de succión.
- **Físicas:** mantenelas mínimas. Los objetos pueden ser estáticos hasta que entran al área del agujero; ahí los animás cayendo. Evitá tener cientos de RigidBody activos = mata el rendimiento en celular.
- **Optimización móvil:** usar el renderer **Mobile** o **Compatibility** de Godot 4, pooling de objetos, LODs simples, y cuidar la cantidad de draw calls.
- **Monetización:** plugin de AdMob (Godot SDK Integrations).
- **Analytics:** algo simple para medir retención y ad revenue (Firebase / GameAnalytics tienen plugins o se integran).

---

## 7. Roadmap por fases

### Fase 0 — Prototipo del feel (1-2 semanas)
Objetivo: que mover el agujero y tragar cosas se sienta bien. Sin arte, sin menús.
- Plano + agujero (disco) que se mueve con el dedo.
- Area3D detecta objetos encima; los animás cayendo y escalando a 0.
- Crecimiento del agujero al tragar.
- **Hito:** si esto no es divertido, nada lo va a salvar. Validá acá.

### Fase 1 — MVP jugable (2-4 semanas)
- Timer + puntaje + pantalla de fin de partida.
- Un mapa (ciudad) con assets de Kenney.
- Regla de tamaño (no podés tragar lo más grande hasta crecer).
- Menú principal básico.

### Fase 2 — Monetización + retención
- Integrar AdMob (intersticial + rewarded).
- Monedas, tienda de skins, misiones diarias.
- 2-3 mapas más.
- IAP "Remove Ads".

### Fase 3 — Pulido y lanzamiento
- Juice: partículas, sonido, screen shake, feedback al tragar.
- Optimización en dispositivos reales.
- Build de Android (Play Store) primero; iOS después (App Store cuesta USD 99/año y revisión más estricta).
- Testeo con usuarios reales, medir retención D1/D7 y ad revenue.

### Fase 4 — Crecer (si funciona)
- Bots/competitivo, eventos, más mapas, arte propio diferenciado.

---

## 8. Riesgos y consejos

- **El feel es todo.** Dedicá tiempo desproporcionado a la Fase 0. Un clon con mal control no retiene.
- **No abuses de los ads.** Un intersticial en cada partida mata la retención y baja el ingreso total. Menos ads bien puestos = más plata.
- **Rendimiento en celulares baratos.** El público hipercasual usa gama baja. Testeá ahí, no solo en tu teléfono.
- **Saturación del género.** hole.io tiene muchos clones. Diferenciate con un tema/escenario original o un twist de mecánica, no copiando 1:1.
- **Cuenta de AdMob + Play Console.** Play Console cuesta USD 25 una vez; AdMob es gratis pero requiere cuenta aprobada y políticas de privacidad en la app.
- **Empezá single-player.** El multijugador del hole.io original es tentador pero es 10x el trabajo. Bots locales primero.

---

## 9. Próximos pasos sugeridos

1. Instalar Godot 4 y hacer el tutorial oficial de 3D (medio día).
2. Bajar el pack "City Kit" de Kenney.
3. Construir la Fase 0 (agujero que se mueve + traga). **Acá pasamos a la sección Code.**
4. Volver con el prototipo y decidir si seguimos.

---

## Fuentes

- [Godot SDK Integrations — AdMob](https://github.com/godot-sdk-integrations/godot-admob)
- [Poing Studios — godot-admob-plugin](https://github.com/poingstudios/godot-admob-plugin)
- [Cengiz-pz AdMob plugin (Asset Store)](https://store.godotengine.org/asset/cengiz/admob-plugin/)
- [Using AdMob on Godot 4.3+ — Palaweno Programmer](https://palawenos.com/2025/03/21/using-admob-on-godot-4-3/)
- [Poly Haven](https://polyhaven.com/)
- [awesome-cc0 (lista de assets CC0)](https://github.com/madjin/awesome-cc0)
- [OpenGameArt — CC0 Textures](https://opengameart.org/content/cc0-textures-0)
- [itch.io — assets 3D CC0](https://itch.io/game-assets/free/tag-3d/tag-cc0)
