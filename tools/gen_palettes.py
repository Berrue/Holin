"""Genera atlas de paleta para los edificios de la ciudad, sin dependencias.

    python tools/gen_palettes.py            # escribe las paletas de PALETTES
    python tools/gen_palettes.py --probe    # atlas de diagnostico (ver abajo)

Los .glb de Kenney no traen textura propia: mapean sus UV contra un atlas de
paleta de 512x512, o sea que cambiar el atlas repinta el modelo entero sin
tocar la geometria. El pack trae 3 (colormap, variation-a, variation-b); esto
permite inventar las que quieras.

Salida en holin/assets/kenney_city/palette-<nombre>.png. Para usar una desde el
juego hay que envolverla en un StandardMaterial3D (.tres) y ponerlo en el
`palette_material` de una escena de scenes/props/ — ver holin/resources/.

ESTRUCTURA DEL ATLAS (medida, no adivinada)
-------------------------------------------
Grilla de 16 columnas x 4 filas = 64 celdas de 32x128 px. Cada celda es un color
PLANO (desvio interno 0.0): lo que parece un degrade son celdas contiguas de
colores parecidos. La fila 0 es toda negra. Alfa uniforme 255.

Las columnas van en pares (0,1), (2,3), ... (14,15): cada par es el tono claro y
el oscuro de un mismo material.

QUE CELDAS IMPORTAN (leido de las UV de los 19 modelos)
------------------------------------------------------
Se midio el area de triangulo que cae en cada celda, sumando los 19 edificios.
Cuatro celdas se comen el 99% de la superficie visible:

    r2 c1   47.8%   marcos, molduras, parantes  -> rol "marco"
    r2 c7   26.5%   el panel de pared           -> rol "pared"
    r2 c3   13.7%   gris oscuro de base y techo -> rol "oscuro"
    r1 c11  10.9%   el vidrio de las ventanas   -> rol "vidrio"

Dato importante: de esas cuatro, **el pack solo varia "pared"**. Los otros dos
pares que cambian entre colormap/variation-a/variation-b (r1c0-c1 y r1c2-c3) no
los usa NINGUN edificio (0.6% y 0.2% del area) — deben ser para otros modelos
del pack. Por eso una paleta que solo toque esos pares se ve casi igual a la
base: es el error que cometio la primera version de este script.

Se pueden editar las 64 celdas sin miedo: este atlas lo samplean UNICAMENTE los
modelos de kenney_city (los autos tienen su propio colormap.png y los de
kenney_nature no usan textura), asi que no hay riesgo de repintar un auto sin
querer. Para explorar mas alla de los cuatro roles esta --probe.
"""

import os
import struct
import sys
import zlib

CELL_W, CELL_H = 32, 128
COLS, ROWS = 16, 4
WIDTH, HEIGHT = CELL_W * COLS, CELL_H * ROWS

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "holin", "assets", "kenney_city")

# Las 64 celdas de colormap.png, leidas del archivo del pack. Es la base sobre
# la que cada paleta pisa los roles que quiera.
BASE = [
    # fila 0 (negra)
    [(0, 0, 0)] * 16,
    # fila 1: acentos saturados + el vidrio de las ventanas en c10/c11
    [(97, 203, 139), (61, 166, 121), (255, 192, 68), (255, 179, 73),
     (255, 126, 68), (255, 135, 68), (207, 83, 79), (231, 96, 71),
     (103, 148, 217), (95, 116, 202), (208, 232, 255), (155, 189, 236),
     (168, 120, 232), (129, 88, 207), (243, 120, 240), (204, 119, 235)],
    # fila 2: la fila que importa — marcos (c0/c1), oscuros (c2/c3), pared (c6/c7)
    [(134, 139, 161), (109, 115, 138), (79, 82, 96), (71, 74, 88),
     (160, 168, 201), (157, 164, 196), (255, 255, 255), (220, 220, 233),
     (241, 151, 108), (208, 123, 86), (176, 96, 65), (153, 90, 65),
     (242, 191, 153), (221, 159, 121), (253, 228, 199), (248, 214, 174)],
    # fila 3: terracota, verde, y grises oscuros
    [(207, 115, 91), (196, 109, 86), (97, 203, 139), (61, 166, 121),
     (250, 174, 138), (233, 156, 120), (58, 60, 63), (70, 75, 82),
     (81, 85, 102), (81, 85, 102), (102, 107, 128), (102, 107, 128),
     (142, 149, 179), (142, 149, 179), (56, 56, 61), (62, 62, 68)],
]

# Los cuatro roles que cubren el 99% de lo que se ve de un edificio, con el par
# de celdas (claro, oscuro) que le corresponde a cada uno. Salieron de medir las
# UV de los 19 modelos — ver el encabezado.
SLOTS = {
    "marco":  ((2, 0), (2, 1)),   # 47.8% del area
    "pared":  ((2, 6), (2, 7)),   # 26.5% — el unico que varia el pack
    "oscuro": ((2, 2), (2, 3)),   # 13.7%
    "vidrio": ((1, 10), (1, 11)),  # 10.9%
}

# Cada paleta pisa los roles que nombra y deja los demas como la base. Cada rol
# lleva su par (claro, oscuro) explicito y no derivado de un factor: en las
# paletas del pack la relacion entre claro y oscuro no es uniforme (un par
# incluso se ACLARA), asi que no hay una regla que imitar.
#
# Para inventar una: agregas una entrada aca y volves a correr el script. Con
# tocar "pared" ya se nota; sumando "marco" el cambio es total.
PALETTES = {
    # Ciudad de noche: paredes y marcos oscuros, y el vidrio encendido. Es la
    # que muestra que se puede cambiar el clima entero, no solo el color.
    "noche": {
        "pared":  ((58, 66, 92), (44, 50, 72)),
        "marco":  ((78, 86, 112), (58, 65, 88)),
        "oscuro": ((32, 36, 48), (26, 29, 40)),
        "vidrio": ((255, 226, 140), (250, 198, 92)),
    },
    "menta": {
        "pared": ((94, 209, 196), (62, 175, 164)),
        "marco": ((216, 234, 232), (176, 199, 197)),
    },
    "pastel": {
        "pared": ((245, 166, 190), (224, 132, 160)),
        "marco": ((250, 240, 235), (214, 200, 198)),
    },
    "tierra": {
        "pared":  ((178, 138, 92), (148, 113, 72)),
        "marco":  ((156, 146, 124), (128, 118, 99)),
        "oscuro": ((72, 62, 52), (62, 54, 45)),
    },
}

# Colores del atlas de diagnostico: uno por fila, bien distintos entre si.
PROBE_ROW_COLORS = [(255, 0, 255), (255, 0, 0), (0, 255, 0), (0, 128, 255)]


def write_png(path, cells):
    """Escribe la grilla `cells` (ROWS x COLS de (r,g,b)) como PNG RGB de 8 bits.

    A mano con zlib y struct para no depender de PIL, igual que gen_sfx.py hace
    los .wav con el modulo wave. El formato es simple: firma, IHDR, IDAT con las
    scanlines comprimidas (cada una con su byte de filtro en 0 = sin filtro) e
    IEND. Cada chunk lleva su CRC32.
    """
    row_bytes = []
    for r in range(ROWS):
        line = bytearray()
        for c in range(COLS):
            line += bytes(cells[r][c]) * CELL_W
        row_bytes.append(bytes(line))

    raw = bytearray()
    for r in range(ROWS):
        for _ in range(CELL_H):
            raw += b"\x00" + row_bytes[r]   # 0 = filtro "None" para esta scanline

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 2, 0, 0, 0))  # 8 bits, RGB
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def build(roles):
    """Copia BASE y le pisa los roles que la paleta defina."""
    cells = [list(row) for row in BASE]
    for rol, (claro, oscuro) in roles.items():
        if rol not in SLOTS:
            raise SystemExit("rol desconocido: %r (validos: %s)" % (rol, ", ".join(SLOTS)))
        (cr, cc), (orr, oc) = SLOTS[rol]
        cells[cr][cc] = claro
        cells[orr][oc] = oscuro
    return cells


def build_probe():
    """Atlas de diagnostico: cada fila de un color distinto.

    Para que sirve: se lo pone como palette_material de un prop, se renderiza el
    edificio, y por el color de cada parte se ve de que FILA del atlas sale. Es
    el primer paso para mapear celdas nuevas mas alla de los cuatro roles. Para
    bajar a nivel de celda se edita esta funcion.
    """
    return [[PROBE_ROW_COLORS[r]] * COLS for r in range(ROWS)]


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    if "--probe" in sys.argv:
        path = os.path.join(OUT_DIR, "palette-probe.png")
        write_png(path, build_probe())
        print("diagnostico -> %s" % os.path.relpath(path))
        for r, c in enumerate(PROBE_ROW_COLORS):
            print("  fila %d = rgb%s" % (r, c))
        return
    for nombre, roles in PALETTES.items():
        path = os.path.join(OUT_DIR, "palette-%s.png" % nombre)
        write_png(path, build(roles))
        print("%-10s -> %-52s roles: %s" % (
            nombre, os.path.relpath(path), ", ".join(sorted(roles))))


if __name__ == "__main__":
    main()
