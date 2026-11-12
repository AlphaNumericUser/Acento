#!/usr/bin/env python3
"""Synthesizes the app's original UI sounds (no samples) into `Acento/Sounds`.

Designed with AI assistance (Claude), using Wispr Flow's interface sounds only as a
stylistic reference; every sound here is generated from scratch, with no sampled audio.

Style: soft bubble pops for dictation start/stop/lock, and soft pure or
kalimba-like tones built on perfect fifths for paste, cancel, error, and alert.

Run from the repository root: python3 Scripts/GenerateSounds.py
"""
import math
import os
import struct
import wave

RATE = 48_000
LOUDNESS = 1.10  # global gain over the reference loudness targets passed to write()
OUT = os.path.join(os.path.dirname(__file__), "..", "Acento", "Sounds")


def bubble(freq, decay, rise=0.18):
    """Bubble-like pop: a sine that glides slightly upward while it dies out fast."""
    out, phase = [], 0.0
    for i in range(int(RATE * decay * 7)):
        t = i / RATE
        phase += 2 * math.pi * freq * (1 + rise * (1 - math.exp(-t / 0.012))) / RATE
        out.append(min(1.0, t / 0.0015) * math.exp(-t / decay) * math.sin(phase))
    return out


def tone(freqs, decay, attack=0.002, overtone=(0.0, 1.0), tail=(0.0, 0.1), tremolo=(0.0, 0.0)):
    """Pure tones with an optional inharmonic overtone (kalimba-like), a soft sustained tail, and tremolo."""
    ratio_amp, ratio = overtone
    tail_amp, tail_decay = tail
    depth, rate = tremolo
    out = []
    for i in range(int(RATE * max(decay, tail_decay) * 7)):
        t = i / RATE
        body = sum(math.sin(2 * math.pi * f * t) + ratio_amp * math.sin(2 * math.pi * f * ratio * t) * math.exp(-t / (decay / 2)) for f in freqs)
        level = math.exp(-t / decay) + tail_amp * math.exp(-t / tail_decay)
        wobble = 1 - depth * (0.5 + 0.5 * math.sin(2 * math.pi * rate * t))
        out.append(min(1.0, t / attack) * level * wobble * body / len(freqs))
    return out


def mix(length, *layers):
    """layers: (offset_seconds, gain, samples); returns `length` seconds of audio."""
    out = [0.0] * int(length * RATE)
    for offset, gain, samples in layers:
        start = int(offset * RATE)
        for i, v in enumerate(samples[: len(out) - start]):
            out[start + i] += gain * v
    return out


def write(name, samples, rms):
    """Normalizes to a target loudness (RMS over the whole file) so cues sit at consistent levels."""
    scale = LOUDNESS * rms / math.sqrt(sum(v * v for v in samples) / len(samples))
    fade = int(RATE * 0.01)
    with wave.open(os.path.join(OUT, name), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        frames = []
        for i, v in enumerate(samples):
            v *= scale * min(1.0, (len(samples) - i) / fade)
            frames.append(struct.pack("<h", int(max(-1.0, min(1.0, v)) * 32767)))
        w.writeframes(b"".join(frames))
    print(f"{name}: {len(samples) / RATE * 1000:.0f} ms")


C4, G4, A4, C5, E5, B5, FS6 = 261.6, 392.0, 440.0, 523.3, 659.3, 987.8, 1480.0

os.makedirs(OUT, exist_ok=True)
write("acento-dictation-start.wav", mix(0.18, (0, 0.15, bubble(A4, 0.006)), (0.022, 1, bubble(A4, 0.009))), 0.017)
write("acento-dictation-stop.wav", mix(0.22, (0, 0.2, bubble(A4, 0.005)), (0.04, 1, bubble(290, 0.010, rise=0.08))), 0.015)
write("acento-lock.wav", mix(0.17, (0, 1, bubble(400, 0.005)), (0.062, 0.8, bubble(210, 0.009, rise=0.1))), 0.010)
kalimba = dict(attack=0.012, overtone=(0.25, 2.7))
write("acento-paste.wav", mix(0.62, (0, 1, tone((C4,), 0.045, **kalimba)), (0.095, 0.85, tone((G4,), 0.05, tail=(0.08, 0.25), **kalimba)), (0.285, 0.8, tone((C5,), 0.035, **kalimba))), 0.015)
write("acento-cancel.wav", mix(0.98, (0, 0.45, tone((C4,), 0.03, attack=0.008)), (0.06, 1, tone((G4, G4, C4), 0.04, attack=0.004, tail=(0.28, 0.14), tremolo=(0.3, 22)))), 0.067)
write("acento-error.wav", mix(0.47, (0, 1, tone((A4, E5), 0.075, attack=0.001, tail=(0.04, 0.15)))), 0.034)
write("acento-alert.wav", mix(0.95, (0.12, 1, tone((A4, E5, B5, FS6), 0.045, attack=0.018, tail=(0.04, 0.15)))), 0.010)
