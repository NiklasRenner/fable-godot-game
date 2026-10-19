"""Procedural audio for Thornhill: a lo-fi ambient music loop and simple sound effects.

    python3 tools/build_audio.py            # writes assets/audio/*.wav (+ .ogg if ffmpeg exists)

Everything is synthesised from scratch (numpy only), so the whole soundscape is regenerable
and tweakable from this file. Re-run after changing anything.
"""
import math
import os
import shutil
import subprocess
import wave

import numpy as np

SR = 22050
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets", "audio")
rng = np.random.default_rng(7)


# ------------------------------------------------------------------ helpers

def t(seconds):
    return np.arange(int(SR * seconds)) / SR


def env_adsr(n, a=0.01, d=0.1, s=0.7, r=0.2):
    a_n, d_n, r_n = int(a * SR), int(d * SR), int(r * SR)
    s_n = max(0, n - a_n - d_n - r_n)
    e = np.concatenate([
        np.linspace(0, 1, a_n, endpoint=False),
        np.linspace(1, s, d_n, endpoint=False),
        np.full(s_n, s),
        np.linspace(s, 0, r_n),
    ])
    return e[:n] if len(e) >= n else np.pad(e, (0, n - len(e)))


def env_exp(n, decay=6.0):
    return np.exp(-decay * np.arange(n) / SR)


def lowpass(x, cutoff):
    """One-pole lowpass; cheap and warm."""
    rc = 1.0 / (2 * math.pi * cutoff)
    alpha = (1.0 / SR) / (rc + 1.0 / SR)
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc += alpha * (v - acc)
        y[i] = acc
    return y


def lowpass_fast(x, cutoff, passes=1):
    # vectorised via scipy if available, else the python loop
    try:
        from scipy.signal import butter, lfilter
        b, a = butter(2, cutoff / (SR / 2))
        y = x
        for _ in range(passes):
            y = lfilter(b, a, y)
        return y
    except Exception:
        return lowpass(x, cutoff)


def highpass_fast(x, cutoff):
    try:
        from scipy.signal import butter, lfilter
        b, a = butter(2, cutoff / (SR / 2), btype="high")
        return lfilter(b, a, x)
    except Exception:
        return x - lowpass(x, cutoff)


def noise(n):
    return rng.uniform(-1, 1, n)


def tone(freq, seconds, kind="sine", detune=0.0):
    tt = t(seconds)
    f = freq * (1.0 + detune)
    if kind == "sine":
        return np.sin(2 * np.pi * f * tt)
    if kind == "tri":
        return 2 * np.abs(2 * ((tt * f) % 1.0) - 1) - 1
    if kind == "saw":
        return 2 * ((tt * f) % 1.0) - 1
    if kind == "square":
        return np.sign(np.sin(2 * np.pi * f * tt))
    raise ValueError(kind)


def pluck(freq, seconds, bright=0.5):
    """Karplus-Strong plucked string."""
    n = int(SR * seconds)
    period = max(2, int(SR / freq))
    buf = rng.uniform(-1, 1, period)
    out = np.empty(n)
    for i in range(n):
        out[i] = buf[i % period]
        buf[i % period] = (buf[i % period] + buf[(i + 1) % period]) * 0.5 * (0.994 + 0.005 * bright)
    return out


def normalize(x, peak=0.9):
    m = np.max(np.abs(x)) or 1.0
    return x / m * peak


def write(name, x, stereo=None):
    os.makedirs(OUT, exist_ok=True)
    x = np.clip(x, -1, 1)
    path = os.path.join(OUT, name + ".wav")
    with wave.open(path, "wb") as w:
        if stereo is not None:
            w.setnchannels(2)
            data = np.stack([x, np.clip(stereo, -1, 1)], axis=1)
        else:
            w.setnchannels(1)
            data = x
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((data * 32767).astype("<i2").tobytes())
    if shutil.which("ffmpeg"):
        ogg = os.path.join(OUT, name + ".ogg")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", path, "-c:a", "libvorbis", "-q:a", "4", ogg], check=False)
        if os.path.exists(ogg):
            os.remove(path)
            path = ogg
    print("wrote", path, "%.1fs" % (len(x) / SR))


def note(n):
    """MIDI note -> Hz."""
    return 440.0 * 2 ** ((n - 69) / 12)


# ------------------------------------------------------------------ music

def music(seconds=64.0, bpm=68):
    beat = 60.0 / bpm
    n = int(SR * seconds)
    mix = np.zeros(n)
    # D minor: i - VI - III - VII (Dm, Bb, F, C), 2 bars each.
    chords = [[62, 65, 69, 72], [58, 62, 65, 70], [65, 69, 72, 77], [60, 64, 67, 72]]
    bar = beat * 4
    chord_len = bar * 2
    cycle = chord_len * len(chords)
    pos = 0.0
    # --- pads
    while pos < seconds:
        for ci, ch in enumerate(chords):
            start = pos + ci * chord_len
            if start >= seconds:
                break
            length = min(chord_len + 0.6, seconds - start)
            seg = np.zeros(int(SR * length))
            for midi in ch:
                for det, amp in ((0.0, 1.0), (0.004, 0.5), (-0.003, 0.5)):
                    seg += amp * tone(note(midi - 12), length, "tri", det)
            seg = lowpass_fast(seg, 900.0, 2) * env_adsr(len(seg), 1.2, 0.5, 0.8, 0.6) * 0.16
            i0 = int(SR * start)
            mix[i0:i0 + len(seg)] += seg[:n - i0]
            # bass
            b = tone(note(ch[0] - 24), length, "sine") * env_adsr(len(seg), 0.3, 0.3, 0.6, 0.8) * 0.22
            mix[i0:i0 + len(b)] += b[:n - i0]
        pos += cycle
    # --- lead: a slow, sustained flute-like line. Stepwise motion only, long notes, rests,
    # and it always lands on a chord tone at the start of each chord so it never clashes.
    scale = [62, 65, 67, 69, 72, 74, 77]
    idx = 3
    tt = beat * 4  # let the first chord breathe
    while tt < seconds - 3.0:
        chord_i = int((tt % cycle) // chord_len)
        tones = [m % 12 for m in chords[chord_i]]
        # prefer a step to a chord tone
        options = [i for i in (idx - 1, idx, idx + 1) if 0 <= i < len(scale)]
        chord_opts = [i for i in options if scale[i] % 12 in tones]
        idx = int(rng.choice(chord_opts if chord_opts and rng.random() < 0.7 else options))
        dur = float(rng.choice([beat * 2, beat * 3, beat * 4]))
        length = min(dur + 0.8, seconds - tt)
        m = int(SR * length)
        f = note(scale[idx])
        vib = 1.0 + 0.004 * np.sin(2 * np.pi * 4.5 * t(length))
        ph = np.cumsum(2 * np.pi * f * vib / SR)
        lead = (np.sin(ph) + 0.25 * np.sin(2 * ph) + 0.08 * np.sin(3 * ph))
        lead *= env_adsr(m, 0.35, 0.3, 0.75, 0.7) * 0.11
        lead = lowpass_fast(lead, 1800.0)
        i0 = int(SR * tt)
        mix[i0:i0 + len(lead)] += lead[:n - i0]
        tt += dur + float(rng.choice([0.0, 0.0, beat, beat * 2]))
    # --- vinyl crackle + soft hiss
    crackle = np.zeros(n)
    clicks = rng.integers(0, n, size=int(seconds * 9))
    crackle[clicks] = rng.uniform(-1, 1, len(clicks))
    crackle = lowpass_fast(crackle, 3500.0) * 0.06
    hiss = lowpass_fast(noise(n), 1200.0) * 0.012
    mix += crackle + hiss
    # --- lo-fi: gentle wobble (resample with slow sine), lowpass, soft clip
    wob = 1.0 + 0.0025 * np.sin(2 * np.pi * 0.35 * np.arange(n) / SR)
    src = np.cumsum(wob)
    src = src / src[-1] * (n - 1)
    mix = np.interp(src, np.arange(n), mix)
    mix = lowpass_fast(mix, 3800.0)
    mix = np.tanh(mix * 1.6) * 0.8
    # loop-friendly fade on both ends (the player cross-fades by restarting)
    fade = int(SR * 1.5)
    mix[:fade] *= np.linspace(0, 1, fade)
    mix[-fade:] *= np.linspace(1, 0, fade)
    # a little stereo width: delay the right channel a few ms and mix
    right = np.concatenate([np.zeros(int(SR * 0.011)), mix])[:n] * 0.9 + mix * 0.1
    return normalize(mix, 0.85), normalize(right, 0.85)


# ------------------------------------------------------------------ sfx

def sfx_swing():
    n = int(SR * 0.32)
    x = noise(n)
    # whoosh: band sweep down
    sweep = np.linspace(2800, 500, n)
    y = np.zeros(n)
    acc = 0.0
    for i in range(n):
        rc = 1.0 / (2 * math.pi * sweep[i])
        a = (1.0 / SR) / (rc + 1.0 / SR)
        acc += a * (x[i] - acc)
        y[i] = acc
    y = highpass_fast(y, 300.0) * env_adsr(n, 0.03, 0.08, 0.5, 0.15)
    return normalize(y, 0.6)


def sfx_hit():
    n = int(SR * 0.22)
    thud = tone(110, 0.22, "sine") * env_exp(n, 22) + tone(70, 0.22, "sine") * env_exp(n, 16) * 0.6
    crack = highpass_fast(noise(n), 1500.0) * env_exp(n, 60) * 0.5
    return normalize(thud + crack, 0.75)


def sfx_hit_taken():
    n = int(SR * 0.3)
    body = lowpass_fast(noise(n), 500.0) * env_exp(n, 14)
    thud = tone(80, 0.3, "sine") * env_exp(n, 12)
    return normalize(body * 0.8 + thud, 0.7)


def sfx_heroic_strike():
    n = int(SR * 0.45)
    sw = sfx_swing()
    out = np.zeros(n)
    out[:len(sw)] += sw
    impact = sfx_hit()
    i0 = int(SR * 0.12)
    out[i0:i0 + len(impact)] += impact * 1.1
    ring = tone(1760, 0.45, "sine") * env_exp(n, 9) * 0.12
    return normalize(out + ring, 0.8)


def sfx_charge():
    n = int(SR * 0.9)
    x = noise(n)
    sweep = np.linspace(300, 1800, n)
    y = np.zeros(n)
    acc = 0.0
    for i in range(n):
        rc = 1.0 / (2 * math.pi * sweep[i])
        a = (1.0 / SR) / (rc + 1.0 / SR)
        acc += a * (x[i] - acc)
        y[i] = acc
    y = y * env_adsr(n, 0.15, 0.2, 0.9, 0.25)
    steps = np.zeros(n)
    for k in range(6):
        i0 = int(SR * (0.1 + k * 0.12))
        if i0 < n:
            m = min(n - i0, int(SR * 0.08))
            steps[i0:i0 + m] += tone(60, 0.08, "sine")[:m] * env_exp(m, 40)
    return normalize(y * 0.9 + steps, 0.7)


def sfx_charge_impact():
    n = int(SR * 0.5)
    boom = tone(55, 0.5, "sine") * env_exp(n, 7) + tone(90, 0.5, "sine") * env_exp(n, 12) * 0.5
    crack = lowpass_fast(noise(n), 2500.0) * env_exp(n, 25) * 0.7
    return normalize(boom + crack, 0.85)


def sfx_thunder_clap():
    n = int(SR * 1.1)
    crack = highpass_fast(noise(n), 2000.0) * env_exp(n, 30) * 0.9
    rumble = lowpass_fast(noise(n), 160.0) * env_adsr(n, 0.02, 0.3, 0.5, 0.6) * 1.6
    boom = tone(48, 1.1, "sine") * env_exp(n, 4) * 0.8
    zap = tone(2600, 1.1, "square") * env_exp(n, 45) * 0.08
    return normalize(crack + rumble + boom + zap, 0.9)


def sfx_loot():
    n = int(SR * 0.5)
    out = np.zeros(n)
    for k, midi in enumerate((79, 84)):
        i0 = int(SR * 0.09 * k)
        s = (tone(note(midi), 0.4, "sine") + 0.4 * tone(note(midi + 12), 0.4, "sine")) * env_exp(int(SR * 0.4), 9) * 0.5
        out[i0:i0 + len(s)] += s[:n - i0]
    return normalize(out, 0.5)


def sfx_coin():
    n = int(SR * 0.35)
    s = (tone(3200, 0.35, "sine") + tone(4800, 0.35, "sine") * 0.5) * env_exp(n, 18)
    s2 = np.concatenate([np.zeros(int(SR * 0.07)), s])[:n] * 0.7
    return normalize(s + s2, 0.4)


def sfx_quest():
    n = int(SR * 1.2)
    out = np.zeros(n)
    for k, midi in enumerate((62, 66, 69, 74)):
        i0 = int(SR * 0.13 * k)
        s = pluck(note(midi), 1.0, 0.6) * env_exp(int(SR * 1.0), 3) * 0.55
        out[i0:i0 + len(s)] += s[:n - i0]
    return normalize(lowpass_fast(out, 4000.0), 0.6)


def sfx_level_up():
    n = int(SR * 1.6)
    out = np.zeros(n)
    for k, midi in enumerate((62, 69, 74, 81, 86)):
        i0 = int(SR * 0.1 * k)
        s = (tone(note(midi), 1.2, "sine") + 0.3 * tone(note(midi), 1.2, "tri")) * env_exp(int(SR * 1.2), 3.5) * 0.4
        out[i0:i0 + len(s)] += s[:n - i0]
    shimmer = highpass_fast(noise(n), 5000.0) * env_adsr(n, 0.2, 0.4, 0.3, 0.8) * 0.05
    return normalize(out + shimmer, 0.7)


def sfx_click():
    n = int(SR * 0.06)
    return normalize(lowpass_fast(noise(n), 1800.0) * env_exp(n, 90) + tone(900, 0.06, "sine") * env_exp(n, 80) * 0.4, 0.35)


def sfx_open():
    n = int(SR * 0.18)
    return normalize(lowpass_fast(noise(n), 900.0) * env_adsr(n, 0.01, 0.05, 0.4, 0.1), 0.3)


def sfx_death():
    n = int(SR * 1.4)
    fall = tone(220, 1.4, "saw")
    sweep = np.exp(-np.arange(n) / SR * 1.2)
    tt = np.arange(n) / SR
    fall = np.sin(2 * np.pi * (220 * sweep) * tt) * env_adsr(n, 0.02, 0.3, 0.5, 0.8)
    thud = tone(50, 1.4, "sine") * env_exp(n, 5) * 0.8
    return normalize(lowpass_fast(fall, 1200.0) * 0.6 + thud, 0.7)


def sfx_resurrect():
    n = int(SR * 1.5)
    out = np.zeros(n)
    for k, midi in enumerate((57, 64, 69, 76)):
        s = tone(note(midi), 1.5, "sine") * env_adsr(n, 0.3 + 0.1 * k, 0.3, 0.6, 0.6) * 0.3
        out += s
    return normalize(lowpass_fast(out, 3000.0), 0.6)


def sfx_boar_grunt():
    n = int(SR * 0.35)
    tt = np.arange(n) / SR
    f = 95 + 25 * np.sin(2 * np.pi * 9 * tt)
    ph = np.cumsum(2 * np.pi * f / SR)
    g = (np.sin(ph) + 0.5 * np.sign(np.sin(ph * 2))) * env_adsr(n, 0.03, 0.1, 0.6, 0.1)
    return normalize(lowpass_fast(g, 700.0) + lowpass_fast(noise(n), 400.0) * env_exp(n, 15) * 0.4, 0.6)


def sfx_wolf_snarl():
    # a short bark over a rasping growl
    n = int(SR * 0.45)
    tt = np.arange(n) / SR
    f = 230 + 140 * np.exp(-tt * 18)
    ph = np.cumsum(2 * np.pi * f / SR)
    bark = (np.sin(ph) + 0.35 * np.sign(np.sin(ph))) * env_adsr(n, 0.005, 0.06, 0.25, 0.15)
    rasp = lowpass_fast(noise(n), 1400.0) * (0.6 + 0.4 * np.sin(2 * np.pi * 38 * tt)) * env_adsr(n, 0.02, 0.1, 0.5, 0.2)
    return normalize(lowpass_fast(bark, 2200.0) + rasp * 0.5, 0.6)


def _troll_grunt(base, seconds, rough):
    n = int(SR * seconds)
    tt = np.arange(n) / SR
    f = base * (1.0 + 0.18 * np.sin(2 * np.pi * 5 * tt)) * (1.1 - 0.2 * tt / seconds)
    ph = np.cumsum(2 * np.pi * f / SR)
    voice = np.sin(ph) + 0.6 * np.sin(ph * 2.0) + 0.3 * np.sign(np.sin(ph * 3.0))
    throat = lowpass_fast(noise(n), 500.0) * (0.5 + 0.5 * np.sin(2 * np.pi * 23 * tt))
    x = lowpass_fast(voice, 900.0) + throat * rough
    return normalize(x * env_adsr(n, 0.04, 0.12, 0.7, seconds * 0.35), 0.65)


def sfx_troll_grunt():
    return _troll_grunt(88.0, 0.45, 0.5)


def sfx_troll_roar():
    return _troll_grunt(55.0, 0.9, 0.8)


def sfx_eat():
    n = int(SR * 0.5)
    out = np.zeros(n)
    for k in range(3):
        i0 = int(SR * 0.14 * k)
        m = int(SR * 0.1)
        out[i0:i0 + m] += lowpass_fast(noise(m), 700.0) * env_exp(m, 40)
    return normalize(out, 0.4)


def sfx_fire_loop(seconds=6.0):
    n = int(SR * seconds)
    base = lowpass_fast(noise(n), 300.0) * 0.5
    pops = np.zeros(n)
    for i in rng.integers(0, n, size=int(seconds * 7)):
        m = min(n - i, int(SR * 0.03))
        pops[i:i + m] += highpass_fast(noise(m), 1500.0) * env_exp(m, 120) * rng.uniform(0.3, 1.0)
    x = base + pops * 0.6
    # seamless loop: crossfade the end into the start
    f = int(SR * 0.5)
    x[:f] = x[:f] * np.linspace(0, 1, f) + x[-f:] * np.linspace(1, 0, f)
    return normalize(x[:-f], 0.5)


def sfx_cast():
    n = int(SR * 0.9)
    tt = np.arange(n) / SR
    f = 220 + 160 * tt
    ph = np.cumsum(2 * np.pi * f / SR)
    x = (np.sin(ph) * 0.5 + np.sin(ph * 1.5) * 0.3) * env_adsr(n, 0.2, 0.2, 0.7, 0.3)
    shimmer = highpass_fast(noise(n), 4000.0) * env_adsr(n, 0.3, 0.2, 0.5, 0.3) * 0.08
    return normalize(lowpass_fast(x, 2500.0) + shimmer, 0.35)


def sfx_frostbolt():
    n = int(SR * 0.6)
    x = noise(n)
    sweep = np.linspace(600, 4000, n)
    y = np.zeros(n)
    acc = 0.0
    for i in range(n):
        rc = 1.0 / (2 * math.pi * sweep[i])
        a = (1.0 / SR) / (rc + 1.0 / SR)
        acc += a * (x[i] - acc)
        y[i] = acc
    y = highpass_fast(y, 800.0) * env_adsr(n, 0.02, 0.1, 0.6, 0.25)
    chime = (tone(2093, 0.6, "sine") + tone(2637, 0.6, "sine") * 0.6) * env_exp(n, 7) * 0.25
    return normalize(y + chime, 0.6)


def sfx_fireball():
    n = int(SR * 0.9)
    x = lowpass_fast(noise(n), 900.0) * env_adsr(n, 0.05, 0.2, 0.7, 0.4)
    rumble = tone(70, 0.9, "sine") * env_adsr(n, 0.05, 0.3, 0.5, 0.4) * 0.5
    crack = highpass_fast(noise(n), 2500.0) * env_adsr(n, 0.02, 0.1, 0.3, 0.3) * 0.25
    return normalize(x + rumble + crack, 0.7)


def sfx_frost_nova():
    n = int(SR * 0.8)
    cr = np.zeros(n)
    for i in rng.integers(0, int(n * 0.6), size=40):
        m = min(n - i, int(SR * 0.04))
        cr[i:i + m] += highpass_fast(noise(m), 3000.0) * env_exp(m, 90)
    whoosh = lowpass_fast(noise(n), 1500.0) * env_adsr(n, 0.01, 0.15, 0.4, 0.4)
    chime = tone(1568, 0.8, "sine") * env_exp(n, 5) * 0.2
    return normalize(cr * 0.8 + whoosh * 0.6 + chime, 0.7)


def sfx_blink():
    n = int(SR * 0.35)
    tt = np.arange(n) / SR
    f = 400 + 2400 * tt / 0.35
    ph = np.cumsum(2 * np.pi * f / SR)
    z = np.sin(ph) * env_adsr(n, 0.01, 0.05, 0.6, 0.2) * 0.6
    air = highpass_fast(noise(n), 3000.0) * env_exp(n, 15) * 0.3
    return normalize(z + air, 0.5)


def sfx_wand():
    n = int(SR * 0.18)
    tt = np.arange(n) / SR
    f = 1800 - 1200 * tt / 0.18
    ph = np.cumsum(2 * np.pi * f / SR)
    return normalize((np.sin(ph) + 0.3 * np.sign(np.sin(ph))) * env_exp(n, 18), 0.4)


def sfx_footstep():
    n = int(SR * 0.09)
    return normalize(lowpass_fast(noise(n), 600.0) * env_exp(n, 50) + tone(120, 0.09, "sine") * env_exp(n, 40) * 0.3, 0.35)


def main():
    left, right = music()
    write("music_camp", left, right)
    for name, fn in {
        "swing": sfx_swing, "hit": sfx_hit, "hit_taken": sfx_hit_taken, "heroic_strike": sfx_heroic_strike,
        "charge": sfx_charge, "charge_impact": sfx_charge_impact, "thunder_clap": sfx_thunder_clap,
        "loot": sfx_loot, "coin": sfx_coin, "quest": sfx_quest, "level_up": sfx_level_up,
        "click": sfx_click, "open": sfx_open, "death": sfx_death, "resurrect": sfx_resurrect,
        "boar": sfx_boar_grunt, "wolf": sfx_wolf_snarl, "troll": sfx_troll_grunt, "troll_brute": sfx_troll_roar, "eat": sfx_eat, "fire": sfx_fire_loop,
        "footstep": sfx_footstep, "cast": sfx_cast, "frostbolt": sfx_frostbolt, "fireball": sfx_fireball,
        "frost_nova": sfx_frost_nova, "blink": sfx_blink, "wand": sfx_wand,
    }.items():
        write(name, fn())


if __name__ == "__main__":
    main()
