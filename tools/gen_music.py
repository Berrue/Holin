"""Genera la música de fondo de Holin. Sin dependencias, igual que gen_sfx.py.

    python tools/gen_music.py

Sale holin/assets/audio/theme.wav: 16 compases a 128 BPM (30 s exactos) en La
menor, pensado para loopear sin costura.

Cómo loopea: las colas de las notas que se pasan del final NO se cortan, se
suman dando la vuelta al principio del buffer (mix() hace módulo). Así el
empalme no tiene ni click ni silencio: lo que sonaba en el compás 16 sigue
sonando arriba del compás 1.

La melodía está escrita a mano, nota por nota, no salida de un random: una
progresión aleatoria suena a ejercicio, y la idea es que tenga gancho. Va en
tres secciones — A (compases 1-8), B más aguda y tensa (9-12, con un Mi mayor
que pide volver), y A' con una corrida ascendente en el 16 que engancha con el
arranque del loop.

Para retocarla: MELODY son los compases (paso, nota MIDI, duración en corcheas),
BARS_CHORDS la armonía y los GAIN_* la mezcla.
"""

import math
import os
import sys
from array import array

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_sfx import (SR, TAU, OUT_DIR, lowpass, highpass, bandpass,  # noqa: E402
                     normalize, soft_clip, write_wav)

import random  # noqa: E402

BPM = 128.0
STEPS_PER_BAR = 8          # corcheas
BARS = 16
STEP = 60.0 / BPM / 2.0    # duración de una corchea, en segundos
BAR = STEP * STEPS_PER_BAR
TOTAL = BAR * BARS
N = int(SR * TOTAL)

# Cada familia se arma en su propio stem y después se iguala por ENERGÍA, no
# por ganancia nominal: mezclando a ojo el bajo y el bombo se comen todo y la
# melodía —que es el gancho— queda inaudible. Estos son los RMS objetivo.
RMS_DRUMS = 0.150
RMS_BASS = 0.125
RMS_LEAD = 0.150
RMS_STAB = 0.045

# Ganancias relativas DENTRO de cada stem.
GAIN_KICK = 0.85
GAIN_SNARE = 0.45
GAIN_HAT = 0.16


def midi_hz(m):
    return 440.0 * (2.0 ** ((m - 69) / 12.0))


def mix(dst, seg, at_samples, gain=1.0):
    """Suma un segmento en el buffer, dando la vuelta al llegar al final."""
    n = len(dst)
    for i, v in enumerate(seg):
        dst[(at_samples + i) % n] += v * gain


# ---------------------------------------------------------------------------
# Instrumentos
# ---------------------------------------------------------------------------

def v_bass(freq, dur):
    n = int(SR * dur * 1.15)
    out = [0.0] * n
    p1 = p2 = 0.0
    for i in range(n):
        t = i / SR
        p1 += freq / SR
        p2 += freq * 1.006 / SR   # segunda sierra desafinada: engorda el bajo
        s = (2.0 * (p1 % 1.0) - 1.0) + (2.0 * (p2 % 1.0) - 1.0)
        env = min(1.0, i / (SR * 0.004)) * math.exp(-5.5 * t / dur)
        out[i] = s * env
    return lowpass(out, min(freq * 4.0 + 250.0, 3600.0))


def v_lead(freq, dur):
    n = int(SR * dur * 1.15)
    out = [0.0] * n
    ph = 0.0
    for i in range(n):
        t = i / SR
        f = freq * (1.0 + 0.006 * math.sin(TAU * 5.5 * t))  # vibrato
        ph += f / SR
        s = 1.0 if (ph % 1.0) < 0.45 else -1.0              # onda de pulso
        # Capa una octava arriba: le da presencia en 1-3 kHz, que es donde la
        # melodía tiene que pasar por encima del bajo y del bombo.
        s += 0.3 * (1.0 if ((ph * 2.0) % 1.0) < 0.5 else -1.0)
        env = (min(1.0, i / (SR * 0.010))
               * min(1.0, (n - i) / (SR * 0.030))
               * math.exp(-1.6 * t / dur))
        out[i] = s * env
    return lowpass(out, min(freq * 5.0 + 800.0, 6500.0))


def v_stab(freqs, dur):
    n = int(SR * dur)
    out = [0.0] * n
    phs = [0.0] * len(freqs)
    for i in range(n):
        t = i / SR
        s = 0.0
        for j, f in enumerate(freqs):
            phs[j] += f / SR
            s += 1.0 if (phs[j] % 1.0) < 0.5 else -1.0
        out[i] = s / len(freqs) * min(1.0, i / (SR * 0.003)) * math.exp(-16.0 * t)
    return lowpass(out, 2600.0)


def d_kick(dur=0.30):
    n = int(SR * dur)
    out = [0.0] * n
    ph = 0.0
    for i in range(n):
        t = i / SR
        ph += (44.0 + 115.0 * math.exp(-30.0 * t)) / SR  # barrido de tono
        out[i] = math.sin(TAU * ph) * math.exp(-8.0 * t)
    return out


def d_snare(dur=0.19, seed=0):
    rnd = random.Random(seed)
    n = int(SR * dur)
    noise = bandpass([rnd.uniform(-1.0, 1.0) for _ in range(n)], 900, 7000)
    out = [0.0] * n
    for i in range(n):
        t = i / SR
        out[i] = noise[i] * math.exp(-17.0 * t) + math.sin(TAU * 185.0 * t) * math.exp(-24.0 * t) * 0.5
    return normalize(out, 1.0)


def d_hat(dur, decay, seed):
    rnd = random.Random(seed)
    n = int(SR * dur)
    noise = highpass([rnd.uniform(-1.0, 1.0) for _ in range(n)], 7000)
    for i in range(n):
        noise[i] *= math.exp(-decay * (i / SR))
    return normalize(noise, 1.0)


# ---------------------------------------------------------------------------
# Partitura
# ---------------------------------------------------------------------------

# (nota del bajo, triada) por compás.
AM = (45, [57, 60, 64])
F_ = (41, [53, 57, 60])
C_ = (48, [60, 64, 67])
G_ = (43, [55, 59, 62])
DM = (50, [62, 65, 69])
E_ = (40, [64, 68, 71])   # Mi MAYOR: la tensión que empuja de vuelta a La menor

BARS_CHORDS = [AM, F_, C_, G_,
               AM, F_, C_, G_,
               DM, AM, F_, E_,
               AM, F_, C_, G_]

# Compases de melodía: (paso en corcheas, nota MIDI, duración en corcheas).
M1 = [(0, 76, 1.5), (2, 76, 1.0), (3, 81, 1.5), (5, 79, 1.0), (6, 76, 2.0)]
M2 = [(0, 77, 1.5), (2, 77, 1.0), (3, 84, 1.5), (5, 81, 1.0), (6, 77, 2.0)]
M3 = [(0, 76, 1.5), (2, 79, 1.0), (3, 84, 1.5), (5, 83, 1.0), (6, 79, 2.0)]
M4 = [(0, 74, 1.5), (2, 79, 1.0), (3, 83, 1.5), (5, 81, 1.0), (6, 79, 2.0)]
M8 = [(0, 79, 1.0), (1, 83, 1.0), (2, 86, 1.5), (4, 84, 1.0), (5, 83, 1.0), (6, 81, 2.0)]
# Sección B: la misma idea una cuarta arriba, más tensa.
M9 = [(0, 86, 1.5), (2, 86, 1.0), (3, 89, 1.5), (5, 88, 1.0), (6, 86, 2.0)]
M10 = [(0, 84, 1.5), (2, 84, 1.0), (3, 88, 1.5), (5, 86, 1.0), (6, 84, 2.0)]
M11 = [(0, 81, 1.5), (2, 84, 1.0), (3, 89, 1.5), (5, 88, 1.0), (6, 84, 2.0)]
M12 = [(0, 80, 1.5), (2, 83, 1.0), (3, 88, 1.5), (5, 87, 1.0), (6, 83, 2.0)]
# Corrida final: escala para arriba que desemboca en el compás 1 del loop.
M16 = [(0, 74, 1.0), (1, 76, 1.0), (2, 79, 1.0), (3, 81, 1.0),
       (4, 83, 1.0), (5, 84, 1.0), (6, 86, 2.0)]

MELODY = [M1, M2, M3, M4,
          M1, M2, M3, M8,
          M9, M10, M11, M12,
          M1, M2, M3, M16]

BASS_PATTERN = [0, 0, 12, 0, 0, 0, 12, 7]  # corcheas al hilo, con saltos de octava
KICK_STEPS = [0, 3, 4]
SNARE_STEPS = [2, 6]
STAB_STEPS = [1, 3, 5, 7]


def _rms(buf):
    return math.sqrt(sum(v * v for v in buf) / max(1, len(buf)))


def render():
    drums = array('d', bytes(8 * N))
    bass = array('d', bytes(8 * N))
    lead = array('d', bytes(8 * N))
    stab = array('d', bytes(8 * N))

    kick = d_kick()
    snare = d_snare(seed=7)
    hat_closed = d_hat(0.06, 46.0, 1)
    hat_open = d_hat(0.22, 11.0, 2)

    for bar in range(BARS):
        bar_t = bar * BAR
        root, triad = BARS_CHORDS[bar]
        in_b = 8 <= bar < 12  # la sección B va sin acordes picados, para contrastar

        for step in range(STEPS_PER_BAR):
            at = int((bar_t + step * STEP) * SR)
            mix(bass, v_bass(midi_hz(root + BASS_PATTERN[step]), STEP * 0.9), at)
            if step in KICK_STEPS:
                mix(drums, kick, at, GAIN_KICK)
            if step in SNARE_STEPS:
                mix(drums, snare, at, GAIN_SNARE)
            accent = 1.0 if step % 2 == 0 else 0.62
            if step == 7 and bar % 4 == 3:
                mix(drums, hat_open, at, GAIN_HAT * 1.5)
            else:
                mix(drums, hat_closed, at, GAIN_HAT * accent)
            if not in_b and step in STAB_STEPS:
                mix(stab, v_stab([midi_hz(m) for m in triad], STEP * 0.55), at)

        # Redoble al cerrar cada sección de 8 compases.
        if bar % 8 == 7:
            for k in (7.0, 7.5):
                mix(drums, snare, int((bar_t + k * STEP) * SR), GAIN_SNARE * 0.9)

        for step, note, dur in MELODY[bar]:
            mix(lead, v_lead(midi_hz(note), STEP * dur), int((bar_t + step * STEP) * SR))

    # El bajo por debajo de 45 Hz no se oye en un parlante chico y se come todo
    # el margen de volumen: se saca y así el resto puede sonar más fuerte.
    bass = highpass(list(bass), 45.0)

    stems = [(drums, RMS_DRUMS), (bass, RMS_BASS), (lead, RMS_LEAD), (stab, RMS_STAB)]
    gains = [target / max(_rms(s), 1e-9) for s, target in stems]
    out = [0.0] * N
    for (s, _), g in zip(stems, gains):
        for i in range(N):
            out[i] += s[i] * g

    out = soft_clip(normalize(out, 1.0), 1.35)
    return normalize(out, 0.90)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    print(f"Generando tema: {BARS} compases a {BPM:.0f} BPM = {TOTAL:.2f}s")
    write_wav("theme.wav", render())


if __name__ == "__main__":
    main()
