"""Genera los efectos de sonido de Holin por síntesis, sin dependencias.

Se generan en vez de bajarse para que no haya problemas de licencia y para que
se puedan retocar: si un grito quedó poco gracioso, se cambian los números de
SCREAMS y se vuelve a correr. Salida en holin/assets/audio/*.wav (mono 16 bits).

    python tools/gen_sfx.py

Dos familias:

  scream_N     Peatón cayendo. Voz de dibujito: síntesis de vocal (armónicos
               moldeados por formantes) con glissando descendente, vibrato
               exagerado, un gallo a mitad de camino y morfeo de vocal
               ("uuuAAAH"). Agudo y corto, para que sea chistoso y no molesto.

  crumble_N    Edificio tragado. Tres capas: retumbe grave (ruido marrón
               filtrado), golpe sub (barrido de seno hacia abajo) y cascotes
               (ráfagas cortas de ruido pasa-banda, más densas al principio).
  crumble_big  Igual pero más grave y más largo, para los rascacielos.

  car_N        Auto tragado. Chirrido de goma, bocina de dos tonos que se va
               hacia abajo mientras cae (el efecto doppler de dibujito) y
               chapa contra el fondo: parciales inarmónicos, que es lo que
               hace que algo suene a metal y no a tambor.

  swallow_pop  Props chicos. Ataque corto y brillante con una gota tonal: tiene
               que poder repetirse en cadena sin ensuciar la mezcla.
  swallow_mid  Props medianos sin sonido propio. Golpe redondo, aire y una cola
               grave corta; ocupa el espacio entre el pop y el derrumbe.
  level_up      Acorde ascendente corto para marcar que cambió la capacidad del
               agujero, no sólo un número del HUD.
"""

import math
import os
import random
import struct
import wave

SR = 44100
TAU = math.tau
OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "holin", "assets", "audio")

# Formantes aproximadas por vocal: (frecuencia, ancho de banda, amplitud).
VOWELS = {
    "a": [(800, 130, 1.00), (1250, 180, 0.65), (2800, 300, 0.28)],
    "e": [(520, 120, 1.00), (1900, 200, 0.55), (2600, 300, 0.25)],
    "o": [(450, 110, 1.00), (820, 150, 0.60), (2600, 300, 0.18)],
    "u": [(340, 100, 1.00), (700, 140, 0.45), (2500, 300, 0.14)],
    "i": [(300, 100, 1.00), (2300, 220, 0.60), (3100, 320, 0.30)],
}


# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------

def lowpass(buf, cutoff):
    a = 1.0 - math.exp(-TAU * cutoff / SR)
    out = [0.0] * len(buf)
    prev = 0.0
    for i, v in enumerate(buf):
        prev += a * (v - prev)
        out[i] = prev
    return out


def highpass(buf, cutoff):
    lp = lowpass(buf, cutoff)
    return [buf[i] - lp[i] for i in range(len(buf))]


def bandpass(buf, lo, hi):
    return highpass(lowpass(buf, hi), lo)


def normalize(buf, peak=0.86):
    top = max((abs(v) for v in buf), default=0.0)
    if top < 1e-9:
        return buf
    g = peak / top
    return [v * g for v in buf]


def rms(buf):
    return math.sqrt(sum(v * v for v in buf) / max(1, len(buf)))


def set_rms(buf, target):
    """Normaliza por energía, no por pico.

    Mezclar capas por pico deja el derrumbe 99% en los graves: un seno de 40 Hz
    tiene muchísima más energía que un cascote con el mismo pico. En un parlante
    de celular eso se oye como nada. Balanceando por RMS cada capa pesa lo que
    uno quiere que pese.
    """
    r = rms(buf)
    if r < 1e-9:
        return buf
    g = target / r
    return [v * g for v in buf]


def soft_clip(buf, drive=1.0):
    return [math.tanh(drive * v) for v in buf]


def fade_edges(buf, ms_in=6.0, ms_out=40.0):
    """Evita el 'click' de arranque y de corte."""
    n_in = max(1, int(SR * ms_in / 1000.0))
    n_out = max(1, int(SR * ms_out / 1000.0))
    for i in range(min(n_in, len(buf))):
        buf[i] *= i / n_in
    for i in range(min(n_out, len(buf))):
        buf[len(buf) - 1 - i] *= i / n_out
    return buf


def write_wav(name, buf):
    path = os.path.join(OUT_DIR, name)
    data = b"".join(struct.pack("<h", int(max(-1.0, min(1.0, v)) * 32767)) for v in buf)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data)
    rms = math.sqrt(sum(v * v for v in buf) / max(1, len(buf)))
    print(f"  {name:22s} {len(buf) / SR:5.2f}s  pico {max(abs(v) for v in buf):.2f}  rms {rms:.3f}")


# ---------------------------------------------------------------------------
# Gritos
# ---------------------------------------------------------------------------

def formant_gain(freq, formants):
    g = 0.0
    for fc, bw, amp in formants:
        d = (freq - fc) / bw
        g += amp * math.exp(-0.5 * d * d)
    return g


def scream(dur, f_start, f_end, vowel_from, vowel_to, vib_hz, vib_depth,
           yodel_at=None, yodel_amt=1.6, n_harm=24):
    n = int(SR * dur)
    buf = [0.0] * n
    phase = 0.0
    amps = [0.0] * (n_harm + 1)
    sin = math.sin
    f_a = VOWELS[vowel_from]
    f_b = VOWELS[vowel_to]

    for i in range(n):
        t = i / n
        # Glissando: baja rápido al principio y se arrastra al final.
        f0 = f_start * (f_end / f_start) ** (t ** 0.7)
        # Vibrato + temblequeo: lo que lo vuelve caricaturesco.
        f0 *= 1.0 + vib_depth * sin(TAU * vib_hz * i / SR)
        f0 *= 1.0 + 0.02 * sin(TAU * 2.3 * i / SR + 1.1)
        # Gallo: salto brusco de tono a mitad de la caída.
        if yodel_at is not None:
            d = (t - yodel_at) / 0.06
            f0 *= 1.0 + (yodel_amt - 1.0) * math.exp(-0.5 * d * d)

        # La tabla de armónicos se recalcula cada 128 muestras: el timbre se
        # mueve mucho más lento que la onda y ahorra ~99% del trabajo.
        if i % 128 == 0:
            mix = t
            formants = [
                (a[0] + (b[0] - a[0]) * mix, a[1] + (b[1] - a[1]) * mix,
                 a[2] + (b[2] - a[2]) * mix)
                for a, b in zip(f_a, f_b)
            ]
            for k in range(1, n_harm + 1):
                fk = k * f0
                amps[k] = 0.0 if fk > SR * 0.45 else formant_gain(fk, formants) / k

        phase += f0 / SR
        s = 0.0
        for k in range(1, n_harm + 1):
            a = amps[k]
            if a:
                s += a * sin(TAU * k * phase)
        # Envolvente: ataque de golpe, sostiene y se apaga al final.
        env = min(1.0, t / 0.04) * min(1.0, (1.0 - t) / 0.30) ** 0.8
        buf[i] = s * env

    buf = soft_clip(normalize(buf, 0.95), 1.7)
    return fade_edges(normalize(buf))


SCREAMS = [
    # dur, f0 ini, f0 fin, vocal ini, vocal fin, vibrato hz, prof., gallo
    dict(dur=0.85, f_start=560, f_end=190, vowel_from="u", vowel_to="a",
         vib_hz=7.5, vib_depth=0.055, yodel_at=0.45, yodel_amt=1.7),
    dict(dur=1.05, f_start=430, f_end=150, vowel_from="a", vowel_to="o",
         vib_hz=6.2, vib_depth=0.075, yodel_at=0.62, yodel_amt=1.45),
    dict(dur=0.68, f_start=680, f_end=260, vowel_from="i", vowel_to="a",
         vib_hz=9.0, vib_depth=0.045, yodel_at=0.30, yodel_amt=1.9),
    dict(dur=0.95, f_start=500, f_end=170, vowel_from="o", vowel_to="a",
         vib_hz=8.0, vib_depth=0.085, yodel_at=None),
    dict(dur=0.75, f_start=620, f_end=230, vowel_from="e", vowel_to="o",
         vib_hz=7.0, vib_depth=0.060, yodel_at=0.52, yodel_amt=0.62),
]


# ---------------------------------------------------------------------------
# Derrumbes
# ---------------------------------------------------------------------------

def crumble(dur, rumble_hz, sub_from, sub_to, debris_n, debris_lo, debris_hi,
            seed):
    rnd = random.Random(seed)
    n = int(SR * dur)

    # Capa 1: retumbe. Ruido marrón (blanco integrado) pasado por lowpass.
    brown = [0.0] * n
    acc = 0.0
    for i in range(n):
        acc = acc * 0.985 + rnd.uniform(-1.0, 1.0) * 0.08
        brown[i] = acc
    brown = lowpass(brown, rumble_hz)
    for i in range(n):
        t = i / n
        brown[i] *= min(1.0, t / 0.015) * math.exp(-2.6 * t)

    # Capa 2: golpe sub, barrido descendente de seno.
    sub = [0.0] * n
    ph = 0.0
    for i in range(n):
        t = i / n
        f = sub_from * (sub_to / sub_from) ** (t ** 0.5)
        ph += f / SR
        sub[i] = math.sin(TAU * ph) * math.exp(-5.0 * t) * min(1.0, t / 0.006)

    # Capa 3: cascotes. Ráfagas cortas, más densas al principio.
    deb = [0.0] * n
    for _ in range(debris_n):
        # sesgo hacia el arranque: el grueso del escombro cae primero
        start = int(n * (rnd.random() ** 1.8) * 0.85)
        length = int(SR * rnd.uniform(0.012, 0.055))
        amp = rnd.uniform(0.35, 1.0)
        for j in range(length):
            k = start + j
            if k >= n:
                break
            deb[k] += rnd.uniform(-1.0, 1.0) * amp * math.exp(-9.0 * j / length)
    deb = bandpass(deb, debris_lo, debris_hi)
    for i in range(n):
        deb[i] *= math.exp(-1.9 * (i / n))

    # Capa 4: crujido inicial, el "crack" del arranque.
    crack = [rnd.uniform(-1.0, 1.0) for _ in range(n)]
    crack = bandpass(crack, 350, 2600)
    for i in range(n):
        crack[i] *= math.exp(-26.0 * (i / n) * dur)

    # Balance por energía: los cascotes tienen que MANDAR, si no en un parlante
    # chico el derrumbe es un soplido inaudible. El grave sólo da el cuerpo.
    brown = set_rms(brown, 0.14)
    sub = set_rms(sub, 0.11)
    deb = set_rms(deb, 0.34)
    crack = set_rms(crack, 0.22)

    # El drive alto hace de limitador: aplasta el pico del "crack" inicial, que
    # si no obliga a bajar todo el resto, y de paso ensucia el escombro.
    mix = [brown[i] + sub[i] + deb[i] + crack[i] for i in range(n)]
    mix = soft_clip(normalize(mix, 1.1), 2.2)
    return fade_edges(normalize(mix), ms_in=2.0, ms_out=60.0)


CRUMBLES = [
    ("crumble_1.wav", dict(dur=1.05, rumble_hz=150, sub_from=105, sub_to=42,
                           debris_n=34, debris_lo=700, debris_hi=4200, seed=11)),
    ("crumble_2.wav", dict(dur=0.92, rumble_hz=175, sub_from=125, sub_to=50,
                           debris_n=28, debris_lo=850, debris_hi=5000, seed=22)),
    ("crumble_3.wav", dict(dur=1.18, rumble_hz=135, sub_from=95, sub_to=38,
                           debris_n=40, debris_lo=600, debris_hi=3800, seed=33)),
    ("crumble_big_1.wav", dict(dur=1.55, rumble_hz=95, sub_from=80, sub_to=28,
                              debris_n=60, debris_lo=450, debris_hi=3400, seed=44)),
    ("crumble_big_2.wav", dict(dur=1.72, rumble_hz=85, sub_from=70, sub_to=25,
                              debris_n=70, debris_lo=400, debris_hi=3000, seed=55)),
]


# ---------------------------------------------------------------------------
# Autos
# ---------------------------------------------------------------------------

def place(dst, seg, at_sec, gain=1.0):
    """Pega un segmento sobre el buffer principal en un momento dado."""
    off = int(at_sec * SR)
    for i, v in enumerate(seg):
        k = off + i
        if 0 <= k < len(dst):
            dst[k] += v * gain


def horn(dur, f_lo, bend, rnd):
    """Bocina de dos tonos. Las bocinas de auto son dos notas a una tercera;
    con una sola suena a pito de bici. El bend hacia abajo es la caída."""
    n = int(SR * dur)
    out = [0.0] * n
    p1 = p2 = 0.0
    for i in range(n):
        t = i / n
        f = f_lo * (bend ** t)
        p1 += f / SR
        p2 += (f * 1.26) / SR  # tercera mayor
        # Cuadradas suavizadas: la bocina real es rica en armónicos impares.
        s = 0.0
        for h, a in ((1, 1.0), (3, 0.34), (5, 0.18), (7, 0.10)):
            s += a * (math.sin(TAU * h * p1) + 0.85 * math.sin(TAU * h * p2))
        env = min(1.0, i / (SR * 0.008)) * min(1.0, (1.0 - t) / 0.12)
        out[i] = s * env
    return normalize(out, 1.0)


def skid(dur, freq, rnd):
    """Chirrido de goma: tono áspero con vibrato rápido + ruido."""
    n = int(SR * dur)
    out = [0.0] * n
    ph = 0.0
    for i in range(n):
        t = i / n
        f = freq * (1.0 + 0.06 * math.sin(TAU * 23.0 * i / SR)) * (1.0 - 0.25 * t)
        ph += f / SR
        tone = 2.0 * (ph % 1.0) - 1.0  # diente de sierra: bien chillón
        out[i] = (tone * 0.7 + rnd.uniform(-1.0, 1.0) * 0.5) * math.exp(-2.0 * t)
    out = bandpass(out, 700, 5200)
    return normalize(out, 1.0)


def clang(dur, base, rnd):
    """Chapa. Los parciales inarmónicos son lo que separa 'metal' de 'tambor'."""
    n = int(SR * dur)
    out = [0.0] * n
    partials = [1.0, 1.72, 2.44, 3.11, 4.03, 5.43, 6.79]
    for i in range(n):
        t = i / n
        s = 0.0
        for k, r in enumerate(partials):
            s += math.sin(TAU * base * r * (i / SR)) * math.exp(-(3.0 + k * 2.2) * t) / (k + 1)
        out[i] = s
    crunch = [rnd.uniform(-1.0, 1.0) for _ in range(n)]
    crunch = bandpass(crunch, 900, 6000)
    for i in range(n):
        crunch[i] *= math.exp(-18.0 * (i / n))
    out = set_rms(out, 0.22)
    crunch = set_rms(crunch, 0.16)
    return normalize([out[i] + crunch[i] for i in range(n)], 1.0)


def car(dur, honks, horn_f, seed):
    rnd = random.Random(seed)
    n = int(SR * dur)
    buf = [0.0] * n
    place(buf, skid(0.30, rnd.uniform(950, 1400), rnd), 0.0, 0.55)
    # Bocinazos cortos y después uno largo que se va cayendo con el auto.
    t = 0.10
    for _ in range(honks):
        place(buf, horn(0.13, horn_f, 0.97, rnd), t, 0.75)
        t += 0.22
    place(buf, horn(dur - t - 0.22, horn_f, 0.55, rnd), t, 0.8)
    place(buf, clang(0.45, rnd.uniform(210, 330), rnd), dur - 0.42, 0.9)
    buf = soft_clip(normalize(buf, 1.05), 1.6)
    return fade_edges(normalize(buf), ms_in=3.0, ms_out=45.0)


CARS = [
    ("car_1.wav", dict(dur=1.25, honks=2, horn_f=430, seed=101)),
    ("car_2.wav", dict(dur=1.10, honks=1, horn_f=380, seed=202)),
    ("car_3.wav", dict(dur=1.40, honks=3, horn_f=490, seed=303)),
]


# ---------------------------------------------------------------------------
# Absorciones genéricas
# ---------------------------------------------------------------------------

def swallow_tone(dur, f_start, f_end, noise_gain, body_gain, seed):
    """Golpe descendente compacto. La caída de tono da sensación de profundidad."""
    rnd = random.Random(seed)
    n = int(SR * dur)
    tone = [0.0] * n
    noise = [rnd.uniform(-1.0, 1.0) for _ in range(n)]
    noise = bandpass(noise, 500 if dur < 0.2 else 180, 5200 if dur < 0.2 else 2600)
    phase = 0.0
    for i in range(n):
        t = i / n
        f = f_start * (f_end / f_start) ** (t ** 0.55)
        phase += f / SR
        attack = min(1.0, t / 0.025)
        tone[i] = math.sin(TAU * phase) * attack * math.exp(-5.5 * t)
        noise[i] *= math.exp(-12.0 * t)
    tone = set_rms(tone, body_gain)
    noise = set_rms(noise, noise_gain)
    mix = [tone[i] + noise[i] for i in range(n)]
    return fade_edges(normalize(soft_clip(mix, 1.5)), ms_in=2.0, ms_out=24.0)


SWALLOW_POPS = [
    ("swallow_pop_1.wav", dict(dur=0.13, f_start=760, f_end=210,
                               noise_gain=0.10, body_gain=0.22, seed=401)),
    ("swallow_pop_2.wav", dict(dur=0.15, f_start=640, f_end=175,
                               noise_gain=0.09, body_gain=0.24, seed=402)),
    ("swallow_pop_3.wav", dict(dur=0.12, f_start=880, f_end=250,
                               noise_gain=0.11, body_gain=0.20, seed=403)),
]

SWALLOW_MIDS = [
    ("swallow_mid_1.wav", dict(dur=0.34, f_start=260, f_end=72,
                               noise_gain=0.16, body_gain=0.31, seed=501)),
    ("swallow_mid_2.wav", dict(dur=0.40, f_start=220, f_end=58,
                               noise_gain=0.18, body_gain=0.33, seed=502)),
    ("swallow_mid_3.wav", dict(dur=0.31, f_start=310, f_end=82,
                               noise_gain=0.15, body_gain=0.29, seed=503)),
]


def level_up(dur=0.72):
    n = int(SR * dur)
    out = [0.0] * n
    # Tres notas ascendentes, solapadas: reconocimiento inmediato sin una cola
    # larga que tape los sonidos de los primeros objetos del nivel nuevo.
    for start, freq in ((0.00, 440.0), (0.10, 554.37), (0.20, 659.25)):
        off = int(start * SR)
        for i in range(n - off):
            t = i / SR
            env = min(1.0, t / 0.012) * math.exp(-5.8 * t)
            shimmer = (math.sin(TAU * freq * t)
                       + 0.42 * math.sin(TAU * freq * 2.0 * t)
                       + 0.18 * math.sin(TAU * freq * 3.01 * t))
            out[off + i] += shimmer * env
    # Barrido grave suave: une el acorde con el crecimiento físico de la boca.
    phase = 0.0
    for i in range(n):
        t = i / n
        freq = 95.0 * (2.1 ** t)
        phase += freq / SR
        out[i] += math.sin(TAU * phase) * math.sin(math.pi * t) * 0.34
    return fade_edges(normalize(soft_clip(out, 1.35)), ms_in=3.0, ms_out=55.0)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    print(f"Generando en {OUT_DIR}")
    print("Gritos:")
    for i, params in enumerate(SCREAMS, 1):
        write_wav(f"scream_{i}.wav", scream(**params))
    print("Derrumbes:")
    for name, params in CRUMBLES:
        write_wav(name, crumble(**params))
    print("Autos:")
    for name, params in CARS:
        write_wav(name, car(**params))
    print("Absorciones genéricas:")
    for name, params in SWALLOW_POPS + SWALLOW_MIDS:
        write_wav(name, swallow_tone(**params))
    print("Crecimiento:")
    write_wav("level_up.wav", level_up())


if __name__ == "__main__":
    main()
