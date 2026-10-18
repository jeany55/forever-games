#!/usr/bin/env python3
"""Makes the sounds of the pinball table's machinery (Tools/PinballBench/Sounds.lua says which is
played when), the way a real machine's sounds come about: a coil's plunger slamming home, steel
ringing, rubber thudding, plastic clacking, the cabinet's wood booming under all of it, and the
small room the cabinet stands in.

    python3 Tools/make_pinball_sounds.py <folder>

Writes <folder>/<name>.ogg, mono, and needs ffmpeg to write Ogg. Only the standard library is
used besides. Nothing is made again if every sound is already there and newer than this file.

Every sound is made of a few things:
  modes     the ringing of something struck: sines at its own frequencies, each dying away at its
            own rate (steel rings long and high, wood short and low)
  thump     a coil's plunger hitting its stop: a low tone falling in pitch, gone in a few
            hundredths of a second
  bursts    noise, filtered to the band of what made it: a click is high and short, rubber is
            middling and dull
  room      the cabinet's body and the room: a short reverberation mixed in under everything
Small differences in pitch and strength make the variations of the sounds heard often, so that a
flipper doesn't sound like a recording of one.

Then the machine's own music, the little tunes it plays from its speakers: bells over a soft
brass, for the machine calling to be played while it stands idle, being switched on, and a game
starting; and the blips of entering a high score's initials.
"""
import math
import random
import struct
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

RATE = 44100
# The same noise, and the same variations, every time the sounds are made
CHANCE = random.Random(7)


def silence(seconds):
    return [0.0] * int(RATE * seconds)


def add(into, sound, at=0.0, gain=1.0):
    start = int(at * RATE)
    if len(into) < start + len(sound):
        into.extend([0.0] * (start + len(sound) - len(into)))
    for index, value in enumerate(sound):
        into[start + index] += value * gain
    return into


def modes(frequencies, decays, gains, seconds, attack=0.0005, wobble=0.0):
    """Something struck, ringing at its own frequencies, each fading at its own rate (seconds to
    fall to a third). `wobble` detunes each a little, as no two parts are cut exactly alike"""
    out = [0.0] * int(RATE * seconds)
    for frequency, decay, gain in zip(frequencies, decays, gains):
        frequency *= 1 + CHANCE.uniform(-wobble, wobble)
        phase = CHANCE.uniform(0, 2 * math.pi)
        step = 2 * math.pi * frequency / RATE
        fade = math.exp(-1 / (decay * RATE))
        level = gain
        for index in range(len(out)):
            out[index] += math.sin(phase + step * index) * level
            level *= fade
    ramp = max(1, int(attack * RATE))
    for index in range(min(ramp, len(out))):
        out[index] *= index / ramp
    return out


def thump(start, end, seconds, decay, gain=1.0):
    """A coil's plunger hitting its stop: a low tone sliding down, dying fast"""
    out, phase = [], 0.0
    for index in range(int(RATE * seconds)):
        t = index / RATE
        frequency = end + (start - end) * math.exp(-t / (decay * 0.6))
        phase += 2 * math.pi * frequency / RATE
        out.append(math.sin(phase) * math.exp(-t / decay) * min(1.0, t / 0.0008) * gain)
    return out


def noise(seconds, decay=None, gain=1.0, rise=0.0):
    """White noise, fading away (decay seconds) or held, rising in over `rise` seconds"""
    out = []
    count = int(RATE * seconds)
    for index in range(count):
        t = index / RATE
        envelope = math.exp(-t / decay) if decay else 1.0
        if rise:
            envelope *= min(1.0, t / rise)
        out.append(CHANCE.uniform(-1, 1) * envelope * gain)
    return out


def biquad(sound, kind, frequency, q=0.707):
    """The usual filters of a mixing desk (Robert Bristow-Johnson's): lowpass, highpass, bandpass"""
    w = 2 * math.pi * frequency / RATE
    cos_w, alpha = math.cos(w), math.sin(w) / (2 * q)
    if kind == "lowpass":
        b0, b1, b2 = (1 - cos_w) / 2, 1 - cos_w, (1 - cos_w) / 2
    elif kind == "highpass":
        b0, b1, b2 = (1 + cos_w) / 2, -(1 + cos_w), (1 + cos_w) / 2
    else:
        b0, b1, b2 = alpha, 0.0, -alpha
    a0, a1, a2 = 1 + alpha, -2 * cos_w, 1 - alpha
    b0, b1, b2, a1, a2 = b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0
    out, x1, x2, y1, y2 = [], 0.0, 0.0, 0.0, 0.0
    for x in sound:
        y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, x, y1, y
        out.append(y)
    return out


def burst(seconds, decay, low, high, gain=1.0):
    """A burst of noise in one band: a click high and short, a thud low and dull"""
    sound = noise(seconds, decay)
    if high:
        sound = biquad(sound, "lowpass", high)
    if low:
        sound = biquad(sound, "highpass", low)
    return [value * gain for value in sound]


def room(sound, wet=0.16, size=1.0, tail=0.25):
    """The cabinet and the room it stands in: Schroeder's reverberation, four echoes going round
    at their own lengths and two that smear them, mixed in under the sound"""
    sound = sound + silence(tail)
    combs = [(0.0297 * size, 0.72), (0.0371 * size, 0.70), (0.0411 * size, 0.68), (0.0437 * size, 0.66)]
    wet_sum = [0.0] * len(sound)
    for delay_seconds, feedback in combs:
        delay = int(delay_seconds * RATE)
        line, damp = [0.0] * delay, 0.0
        for index, x in enumerate(sound):
            out = line[index % delay]
            # A little lost to the soft wood on every round, the highs most
            damp = out * 0.6 + damp * 0.4
            line[index % delay] = x + damp * feedback
            wet_sum[index] += out
    for delay_seconds in (0.005, 0.0017):
        delay = int(delay_seconds * RATE)
        line = [0.0] * delay
        out = []
        for index, x in enumerate(wet_sum):
            buffered = line[index % delay]
            y = -0.5 * x + buffered
            line[index % delay] = x + 0.5 * y
            out.append(y)
        wet_sum = out
    return [dry + w * wet / 4 for dry, w in zip(sound, wet_sum)]


def body(sound, gain=0.5):
    """The cabinet's wood booming along: the sound again, only its low middle, which a box of
    plywood gives back"""
    boom = biquad(sound, "bandpass", 170, 1.4)
    return [value + b * gain for value, b in zip(sound, boom)]


def finish(sound, level):
    """Brought to its level at its loudest, softly limited, and faded at the very end"""
    peak = max(abs(value) for value in sound) or 1.0
    out = [math.tanh(value / peak * 1.3) / math.tanh(1.3) * level for value in sound]
    # Trimmed where it has died away to nothing
    quiet = level * 0.002
    end = len(out)
    while end > RATE // 50 and abs(out[end - 1]) < quiet:
        end -= 1
    out = out[:end]
    fade = min(len(out), int(RATE * 0.008))
    for index in range(fade):
        out[-1 - index] *= index / fade
    return out


def vary(base, amount=0.06):
    return base * (1 + CHANCE.uniform(-amount, amount))


# Steel's frequencies, as a struck bar's: its overtones aren't whole multiples of the first
STEEL = (1.0, 2.76, 5.40, 8.93)


def steel(frequency, decay, gain=1.0, seconds=0.4):
    return modes([frequency * ratio for ratio in STEEL], [decay, decay * 0.6, decay * 0.35, decay * 0.2],
                 [gain, gain * 0.6, gain * 0.35, gain * 0.2], seconds, wobble=0.01)


def coil(strength=1.0, low=150, high=60, decay=0.035):
    """A coil firing: the plunger's slam, the click of it starting and the link rattling"""
    out = thump(vary(low), vary(high), 0.25, decay * strength ** 0.3, 1.0 * strength)
    add(out, burst(0.02, 0.003, 2000, 9000, 0.7 * strength))
    add(out, steel(vary(1150), 0.03, 0.18 * strength, 0.15), at=0.002)
    return out


def note(name):
    """A note's frequency, "A4" being 440"""
    steps = {"C": -9, "D": -7, "E": -5, "F": -4, "G": -2, "A": 0, "B": 2}[name[0]]
    steps += name.count("#") - name.count("b")
    return 440 * 2 ** ((steps + 12 * (int(name[-1]) - 4)) / 12)


def bell(frequency, seconds=1.6, gain=1.0):
    """A small bell or a glockenspiel bar: bright, ringing on"""
    return modes([frequency * r for r in (1.0, 2.0, 3.01, 4.17, 5.43)], [seconds * k for k in (0.5, 0.3, 0.18, 0.1, 0.06)],
                 [gain * k for k in (1.0, 0.45, 0.25, 0.12, 0.08)], seconds, attack=0.002, wobble=0.002)


def brass(frequency, seconds, gain=1.0, attack=0.04):
    """A soft brass note: the first harmonics of a saw, swelling in and dying away, darkened"""
    out = []
    for i in range(int(RATE * seconds)):
        t = i / RATE
        level = min(1.0, t / attack) * min(1.0, (seconds - t) / 0.12) * (1 + 0.04 * math.sin(2 * math.pi * 5.5 * t))
        value = sum(math.sin(2 * math.pi * frequency * k * t * (1 + 0.0007 * k)) / k for k in range(1, 7))
        out.append(value * level * gain * 0.4)
    return biquad(out, "lowpass", 2400)


def tune(notes, step, voice=bell, **kw):
    """Notes one after another, `step` seconds apart; None for a rest"""
    out = []
    for index, name in enumerate(notes):
        if name:
            add(out, voice(note(name), **kw), at=index * step)
    return out


def make_sounds():
    sounds = {}

    # The machine calling while nobody plays it: a rising run of bells over a held chord, ending on
    # a shimmer; and a second, a falling sparkle down to a low bell
    call = tune(["D5", "F5", "A5", "C6", "D6", "F6", "A6"], 0.11, gain=0.7)
    add(call, tune(["D6", "A6", "D7"], 0.04, gain=0.35), at=0.8)
    for name in ("D3", "A3", "D4", "F4"):
        add(call, brass(note(name), 2.2, 0.25, attack=0.4), at=0.05)
    sounds["attract1"] = finish(room(call, 0.3, 1.4, 0.6), 0.75)
    call = tune(["A6", "F6", "D6", "C6", "A5", "F5", "D5", None, "D4"], 0.075, gain=0.6)
    add(call, bell(note("D3"), 2.4, 0.8), at=0.62)
    for name in ("Bb2", "F3", "D4"):
        add(call, brass(note(name), 1.8, 0.22, attack=0.3), at=0.6)
    sounds["attract2"] = finish(room(call, 0.3, 1.4, 0.6), 0.75)

    # Switched on: the relays clattering as the machine comes up, its lamps' transformer humming,
    # and a chord from the speakers
    power = []
    at = 0.0
    for _ in range(9):
        add(power, coil(vary(0.5, 0.3), low=vary(320), high=140, decay=0.012), at=at)
        at += CHANCE.uniform(0.03, 0.09)
    hum = []
    for i in range(int(RATE * 1.0)):
        t = i / RATE
        hum.append((math.sin(2 * math.pi * 60 * t) + 0.5 * math.sin(2 * math.pi * 120 * t)) * min(1, t / 0.4) * min(1, (1.0 - t) / 0.3) * 0.25)
    add(power, hum, at=0.1)
    for name in ("D4", "A4", "D5", "F5"):
        add(power, bell(note(name), 1.8, 0.5), at=at + 0.15)
    sounds["powerOn"] = finish(room(body(power, 0.4), 0.25, 1.2, 0.5), 0.8)

    # A game started: a fanfare, up to a held chord
    start = tune(["G4", "C5", "E5"], 0.12, voice=brass, seconds=0.16, gain=0.8)
    for name in ("G4", "C5", "E5", "G5"):
        add(start, brass(note(name), 0.9, 0.6, attack=0.02), at=0.36)
    add(start, tune(["G6", "C7", "E7", "G7"], 0.05, gain=0.3), at=0.36)
    sounds["gameStart"] = finish(room(start, 0.25, 1.2, 0.5), 0.85)

    # The post between the flippers coming up, a coil and steel shooting home; and going down
    post = coil(1.3, low=110, high=50, decay=0.05)
    add(post, steel(vary(950), 0.18, 0.5, 0.5), at=0.01)
    add(post, burst(0.15, 0.05, 2000, 9000, 0.2))
    sounds["postUp"] = finish(room(body(post, 0.6), 0.2), 0.9)
    post = thump(140, 60, 0.15, 0.03, 0.6)
    add(post, burst(0.03, 0.005, 800, 5000, 0.4), at=0.01)
    add(post, steel(vary(700), 0.05, 0.2, 0.2), at=0.012)
    sounds["postDown"] = finish(room(body(post, 0.5)), 0.6)

    # Entering initials: a blip for each letter, and a chime for one chosen
    blip = []
    for i in range(int(RATE * 0.05)):
        t = i / RATE
        blip.append((1 if math.sin(2 * math.pi * 1320 * t) > 0 else -1) * min(1, (0.05 - t) / 0.02) * 0.4)
    sounds["letter"] = finish(biquad(blip, "lowpass", 5000), 0.4)
    sounds["letterChosen"] = finish(room(tune(["E6", "B6"], 0.06, gain=0.7, seconds=0.5), 0.2), 0.6)

    # The flippers: the coil and the bat's stop, and the clack of it falling back
    for index in range(1, 4):
        up = coil(vary(1.0, 0.1), low=170, high=70, decay=0.04)
        add(up, steel(vary(2600), 0.05, 0.15, 0.2), at=0.012)
        add(up, burst(0.04, 0.006, 300, 2500, 0.25), at=0.011)
        sounds[f"flipperUp{index}"] = finish(room(body(up, 0.6)), 0.9)
    for index in range(1, 3):
        down = thump(vary(130), 55, 0.15, 0.025, 0.5)
        add(down, burst(0.03, 0.004, 900, 6000, 0.45))
        add(down, steel(vary(1900), 0.025, 0.1, 0.1), at=0.003)
        sounds[f"flipperDown{index}"] = finish(room(body(down, 0.5)), 0.55)

    # A pop bumper: its coil pulls the ring down hard on the ball, the skirt's rubber slaps, the
    # metal ring sings a little
    for index in range(1, 4):
        pop = coil(1.2, low=vary(125), high=45, decay=0.06)
        add(pop, burst(0.05, 0.01, 400, 2200, 0.5), at=0.003)
        add(pop, steel(vary(1750), 0.12, 0.22, 0.4), at=0.004)
        add(pop, modes([vary(820), vary(1340)], [0.05, 0.03], [0.12, 0.08], 0.2), at=0.004)
        sounds[f"bumper{index}"] = finish(room(body(pop, 0.7), 0.2), 0.95)

    # A slingshot: the kicker's coil and the rubber band twanging
    for index in range(1, 3):
        sling = coil(1.0, low=vary(140), high=55, decay=0.045)
        twang = []
        for i in range(int(RATE * 0.18)):
            t = i / RATE
            twang.append(math.sin(2 * math.pi * (vary(380, 0.02) - 900 * t) * t) * math.exp(-t / 0.04))
        add(sling, biquad(twang, "lowpass", 1500), gain=0.35, at=0.004)
        add(sling, burst(0.04, 0.008, 500, 3000, 0.3), at=0.003)
        sounds[f"sling{index}"] = finish(room(body(sling, 0.6)), 0.85)

    # A rollover: the wire pressed down and let go, the switch's two clicks
    roll = burst(0.01, 0.0015, 2500, 12000, 1.0)
    add(roll, burst(0.01, 0.0012, 3000, 12000, 0.6), at=0.035)
    add(roll, steel(4100, 0.012, 0.25, 0.05))
    sounds["rollover"] = finish(room(roll, 0.1), 0.35)

    # A drop target: the ball's clack on the plastic, and the target falling into its slot
    drop = burst(0.03, 0.004, 1200, 7000, 1.0)
    add(drop, modes([1450, 2300], [0.02, 0.012], [0.5, 0.3], 0.08))
    add(drop, thump(220, 90, 0.12, 0.03, 0.6), at=0.025)
    add(drop, burst(0.05, 0.01, 200, 1500, 0.35), at=0.03)
    sounds["targetDrop"] = finish(room(body(drop, 0.5)), 0.7)

    # The bank coming back up: a big coil and three targets snapping up together
    reset = coil(1.4, low=95, high=40, decay=0.07)
    for i in range(3):
        add(reset, burst(0.025, 0.004, 1000, 6000, 0.5), at=0.012 + i * 0.006 + CHANCE.uniform(0, 0.004))
        add(reset, modes([vary(1400), vary(2250)], [0.02, 0.012], [0.25, 0.15], 0.06), at=0.014 + i * 0.006)
    sounds["targetsReset"] = finish(room(body(reset, 0.7), 0.2), 0.9)

    # A standup target: plastic and the rubber behind it
    standup = burst(0.02, 0.003, 1300, 8000, 0.8)
    add(standup, modes([1650, 2900], [0.018, 0.01], [0.4, 0.2], 0.06))
    add(standup, burst(0.06, 0.012, 150, 900, 0.5))
    sounds["standup"] = finish(room(body(standup, 0.4)), 0.6)

    # One turn of the spinner: its blade's wire and the switch ticking
    spin = burst(0.006, 0.001, 3000, 14000, 0.7)
    add(spin, steel(3300, 0.015, 0.3, 0.05))
    sounds["spinner"] = finish(spin, 0.4)

    # Into the saucer: the ball drops into a steel cup, which rings dull under the wood
    saucer_in = thump(240, 110, 0.2, 0.05, 0.9)
    add(saucer_in, modes([880, 2050, 3500], [0.08, 0.04, 0.02], [0.35, 0.2, 0.1], 0.3), at=0.002)
    add(saucer_in, burst(0.03, 0.006, 600, 4000, 0.3))
    sounds["saucerIn"] = finish(room(body(saucer_in, 0.7)), 0.75)
    saucer_kick = coil(1.2, low=120, high=50, decay=0.05)
    add(saucer_kick, modes([900, 2100], [0.06, 0.03], [0.25, 0.12], 0.2), at=0.004)
    add(saucer_kick, burst(0.12, 0.04, 200, 1200, 0.15), at=0.02)
    sounds["saucerKick"] = finish(room(body(saucer_kick, 0.7)), 0.9)

    kickback = coil(1.5, low=110, high=40, decay=0.07)
    add(kickback, steel(1300, 0.08, 0.2, 0.3), at=0.003)
    add(kickback, burst(0.15, 0.05, 200, 1500, 0.15), at=0.02)
    sounds["kickback"] = finish(room(body(kickback, 0.8), 0.2), 0.95)

    # The plunger: its spring stretched as it is pulled, and let go: the spring rings, the ball goes
    pull = []
    for i in range(int(RATE * 0.35)):
        t = i / RATE
        pull.append(math.sin(2 * math.pi * (300 + 900 * t) * t) * 0.15 * min(1, t / 0.05) * math.exp(-max(0, t - 0.25) / 0.03))
    add(pull, biquad(noise(0.35, None, 0.6, 0.1), "bandpass", 2400, 3), gain=0.4)
    add(pull, burst(0.015, 0.002, 2000, 8000, 0.4))
    sounds["plungerPull"] = finish(room(pull, 0.1), 0.35)
    release = thump(180, 70, 0.3, 0.05, 0.9)
    add(release, steel(620, 0.18, 0.35, 0.5), at=0.003)
    whoosh = biquad(noise(0.35, None, 1.0, 0.03), "bandpass", 900, 0.8)
    for i in range(len(whoosh)):
        whoosh[i] *= math.exp(-i / RATE / 0.12)
    add(release, whoosh, gain=0.25, at=0.01)
    sounds["plungerRelease"] = finish(room(body(release, 0.6)), 0.8)

    # The wire gate flapping as the ball goes through and falling back
    gate = steel(2900, 0.03, 0.6, 0.12)
    add(gate, steel(3100, 0.02, 0.35, 0.1), at=0.07)
    add(gate, burst(0.008, 0.0015, 2500, 10000, 0.4))
    sounds["gate"] = finish(room(gate, 0.1), 0.35)

    # Up onto the ramp: hollow plastic rumbling under the ball
    ramp = biquad(noise(0.6, None, 1.0, 0.05), "bandpass", 520, 2.0)
    add(ramp, biquad(noise(0.6, None, 0.6, 0.05), "bandpass", 1300, 4.0))
    for i in range(len(ramp)):
        t = i / RATE
        ramp[i] *= math.exp(-max(0, t - 0.35) / 0.08) * (0.8 + 0.2 * math.sin(2 * math.pi * 23 * t))
    add(ramp, burst(0.02, 0.004, 800, 5000, 0.5))
    sounds["rampEnter"] = finish(room(ramp, 0.12), 0.45)

    # The ramp made: the ball over its plastic flap at the top, and onto the wire
    flap = burst(0.025, 0.004, 900, 6000, 0.9)
    add(flap, modes([1100, 1900], [0.025, 0.015], [0.4, 0.2], 0.06))
    add(flap, steel(2700, 0.05, 0.4, 0.2), at=0.06)
    sounds["rampFlap"] = finish(room(flap, 0.12), 0.55)

    # Down the wire habitrail: the ball rattling between its rails, faster as it goes, a clunk off the end
    wire = biquad(noise(1.15, None, 0.25, 0.05), "bandpass", 2600, 1.2)
    t = 0.0
    while t < 1.0:
        add(wire, steel(vary(3400, 0.12), 0.02, vary(0.6, 0.3), 0.06), at=t)
        t += CHANCE.uniform(0.018, 0.045) * (1.2 - t * 0.5)
    add(wire, thump(200, 90, 0.15, 0.03, 0.7), at=1.02)
    add(wire, burst(0.03, 0.006, 600, 4000, 0.4), at=1.02)
    sounds["wireRail"] = finish(room(wire, 0.12), 0.5)

    # Down the drain: the ball falls, rolls along the trough's wood, and stops against the others
    drain = thump(150, 70, 0.2, 0.05, 0.9)
    roll = biquad(noise(0.5, None, 1.0, 0.02), "lowpass", 380)
    for i in range(len(roll)):
        roll[i] *= math.exp(-i / RATE / 0.2)
    add(drain, roll, gain=0.6, at=0.03)
    add(drain, modes([1900, 4800], [0.03, 0.015], [0.3, 0.15], 0.1), at=0.45)
    add(drain, thump(120, 60, 0.12, 0.03, 0.4), at=0.45)
    sounds["drain"] = finish(room(body(drain, 0.8), 0.18), 0.7)

    # Two balls meeting: steel on steel, a bright click
    ball_hit = modes([5200, 8900, 12400], [0.008, 0.005, 0.003], [1.0, 0.6, 0.4], 0.05)
    add(ball_hit, burst(0.004, 0.0008, 4000, 16000, 0.5))
    sounds["ballHit"] = finish(ball_hit, 0.4)

    # Off a steel rail, softly and hard
    for name, strength in (("railHit1", 0.5), ("railHit2", 1.0)):
        rail = steel(vary(2300), 0.04 + 0.04 * strength, 1.0, 0.3)
        add(rail, burst(0.006, 0.001, 3000, 14000, 0.6 * strength))
        sounds[name] = finish(room(rail, 0.1), 0.3 + 0.3 * strength)

    # Off a rubber post: a dull thud
    rubber = burst(0.08, 0.012, 150, 900, 1.0)
    add(rubber, modes([420], [0.02], [0.5], 0.06))
    sounds["rubberHit"] = finish(room(body(rubber, 0.5)), 0.45)

    # The tilt buzzer
    buzz = []
    for i in range(int(RATE * 0.8)):
        t = i / RATE
        square = 1.0 if math.sin(2 * math.pi * 118 * t) > 0 else -1.0
        buzz.append((square * 0.6 + math.sin(2 * math.pi * 236 * t) * 0.3) * (0.7 + 0.3 * math.sin(2 * math.pi * 30 * t))
                    * min(1, t / 0.01) * min(1, (0.8 - t) / 0.05))
    sounds["tilt"] = finish(room(biquad(buzz, "lowpass", 2500), 0.1), 0.6)

    # A ball served from the trough into the shooter lane: the trough's coil, the ball rolling over
    serve = coil(1.1, low=110, high=45, decay=0.05)
    roll = biquad(noise(0.4, None, 1.0, 0.03), "lowpass", 500)
    for i in range(len(roll)):
        roll[i] *= math.exp(-i / RATE / 0.15)
    add(serve, roll, gain=0.5, at=0.04)
    add(serve, modes([1700, 4300], [0.03, 0.015], [0.3, 0.12], 0.08), at=0.32)
    sounds["ballServe"] = finish(room(body(serve, 0.7)), 0.75)

    # A ball rolling, two seconds that go round without a seam: the playfield's rumble under it
    sounds["rolling"] = rolling_loop(2.0)
    return sounds


def rolling_loop(seconds):
    """Rumble that loops: made longer than it is, and its end faded into its beginning"""
    overlap = 0.25
    long = biquad(noise(seconds + overlap, None, 1.0), "lowpass", 420)
    long = biquad(long, "highpass", 70)
    for i in range(len(long)):
        t = i / RATE
        long[i] *= 0.8 + 0.2 * math.sin(2 * math.pi * t / seconds * 3)
    count, joined = int(seconds * RATE), int(overlap * RATE)
    out = long[:count]
    for i in range(joined):
        mix = i / joined
        out[i] = out[i] * mix + long[count + i] * (1 - mix)
    peak = max(abs(value) for value in out) or 1.0
    return [value / peak * 0.3 for value in out]


def write_sound(folder, name, sound):
    with tempfile.TemporaryDirectory() as scratch:
        raw = Path(scratch) / "sound.wav"
        with wave.open(str(raw), "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(RATE)
            out.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, value)) * 32767)) for value in sound))
        target = folder / (name + ".ogg")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(raw), "-c:a", "libvorbis", "-q:a", "4", str(target)],
                       check=True)


NAMES = ["flipperUp1", "flipperUp2", "flipperUp3", "flipperDown1", "flipperDown2", "bumper1", "bumper2", "bumper3",
         "sling1", "sling2", "rollover", "targetDrop", "targetsReset", "standup", "spinner", "saucerIn", "saucerKick",
         "kickback", "plungerPull", "plungerRelease", "gate", "rampEnter", "rampFlap", "wireRail", "drain", "ballHit",
         "railHit1", "railHit2", "rubberHit", "tilt", "ballServe", "rolling", "attract1", "attract2", "powerOn",
         "gameStart", "postUp", "postDown", "letter", "letterChosen"]


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    folder = Path(sys.argv[1])
    folder.mkdir(parents=True, exist_ok=True)
    made = Path(__file__).stat().st_mtime
    if all((folder / (name + ".ogg")).exists() and (folder / (name + ".ogg")).stat().st_mtime > made for name in NAMES):
        print(folder, "sounds already made")
        return
    sounds = make_sounds()
    assert sorted(sounds) == sorted(NAMES), set(sounds) ^ set(NAMES)
    for name, samples in sounds.items():
        write_sound(folder, name, samples)
    print(folder, len(sounds), "sounds")


if __name__ == "__main__":
    main()
