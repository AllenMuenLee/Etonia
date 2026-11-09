"""Etonia's animations. Every clip is a function of the frame index and is sampled at 12 fps.

Etonia faces RIGHT: the pencil points right, and in the drawing her left-hand foot (as we look
at her) is the near / front foot and the right-hand one the far / rear foot. So the near foot
leads every stride and is drawn in front, and a run to the left is the whole drawing mirrored
by the app, never a walk backwards.

Clips and where the app plays them:

  look_around  12  loop      the AI is searching / reading the person's files
  hop          12  loop      idle play: a bouncy hop (the blank chat in the study desk mixes it
                             with look_around and think)
  think        12  loop      the AI is composing an answer
  write        12  loop      the AI is writing a notation: she leans into the pen and scribbles
  run          12  loop      a note is being restored or synced in: runs along the screen edge
  pop_out      12  one-shot  the AI thinks the person can take a test: springs up from behind
                             the card and looks at them
  attend       12  loop      ...and keeps looking at them (continues pop_out)
  grade        24  loop      a finished test is being graded: hop, hop, shake, repeat (2 s)

Pose keys (see rig.render):
  body    (tx, ty, rot_deg, sx, sy)   about the bottom-centre of the paper
  foot_l / foot_r  (tx, ty, rot)      relative to the body
  pencil  (tx, ty, rot)               about the pencil's centre
  sprout  rot_deg                     about the stem
  eyes    (tx, ty, sy[, flip]) / mouth (tx, ty, sy[, flip])
  flap_open  degrees the folded corner lifts
"""
import math

import numpy as np

import rig

FPS = 12


def sin(u, k=1, ph=0.0):
    return math.sin(2 * math.pi * (k * u + ph))


def cos(u, k=1, ph=0.0):
    return math.cos(2 * math.pi * (k * u + ph))


def clamp(v, a, b):
    return max(a, min(b, v))


def key_time(i, n):
    """Frame index -> position on a 12-key timeline (0 .. 12) whatever the clip length."""
    return i * 12 / n


def sample(table, t):
    """Linear, cyclic interpolation of a key table (tuples or numbers) at key time t."""
    k = int(math.floor(t)) % len(table)
    f = t - math.floor(t)
    a, b = table[k], table[(k + 1) % len(table)]
    if isinstance(a, (tuple, list)):
        return tuple(x + (y - x) * f for x, y in zip(a, b))
    return a + (b - a) * f


def blink(t, centre):
    """Eye height for a blink centred on key time `centre` (1 = open)."""
    d = abs(t - centre)
    return 0.12 + 0.88 * d if d < 1.0 else 1.0


def plant(body, foot, world_dx=0.0, world_dy=0.0):
    """Foot offset (tx, ty, 0) that keeps `foot` on the spot (nominal position + world_dx/dy)
    while the body leans, squashes or rises."""
    mb = rig.body_matrix(body)
    px, py = rig.P_FOOT[foot]
    loc = np.linalg.inv(mb) @ np.array([px + world_dx, py + world_dy, 1.0])
    return (float(loc[0] - px), float(loc[1] - py), 0.0)


REST = {'body': (0, 0, 0, 1.0, 1.0), 'flap_front': True}


# ------------------------------------------------------------------ think (12)
def think(i, n=12):
    """The paper ponders: eyes drift up and across (the face turns, so the strokes mirror),
    the body leans into it, one foot taps, the pencil bobs and the folded corner flutters."""
    if i == 0:
        return dict(REST)
    u = i / n
    dx = 55 * sin(u)
    dy = -55 * math.sin(math.pi * u) ** 2
    flip = -1.0 if dx > 1 else 1.0
    k = dx / 55.0
    tap = max(0.0, sin(u, 2, 0.0))
    squint = 1 - 0.18 * math.sin(math.pi * u) ** 2
    pose = {
        'body': (dx * 0.25, 0, 2.2 * k, 1.0, 1.0 + 0.012 * sin(u, 2, 0.25)),
        'eyes': (dx, dy, squint, flip),
        'mouth': (dx * 0.6, dy * 0.3 + 6 * math.sin(math.pi * u), 1.0, flip),
        'foot_r': (0, -34 * tap, 0),
        'foot_l': (0, 0, 0),
        'pencil': (0, 0, 7 * sin(u, 2, 0.1)),
        'sprout': 14 * sin(u, 2, 0.35),
        'flap_open': 38 * tap,
        'flap_front': True,
    }
    eyes = blink(key_time(i, n), 8.0)
    if eyes < 1.0:
        pose['eyes'] = (dx, dy, min(squint, eyes), flip)
    return pose


# ------------------------------------------------------------ look around (12)
GAZE = [(0, 0), (-60, -6), (-115, -12), (-115, -12), (-70, -6), (0, 0),
        (70, -6), (115, -12), (115, -12), (55, -30), (0, -45), (0, -15)]


def look_around(i, n=12):
    """Searching: she glances left, then right, then up, with the whole body following."""
    if i == 0:
        return dict(REST)
    t = key_time(i, n)
    dx, dy = sample(GAZE, t)
    k = dx / 115.0
    return {
        'body': (dx * 0.18, 0, 2.4 * k, 1.0, 1.0 + 0.008 * sin(i / n)),
        # looking to the other side turns the face, so the three strokes mirror
        'eyes': (dx, dy, blink(t, 5.0), -1.0 if dx > 1 else 1.0),
        'mouth': (dx * 0.55, dy * 0.4, 1.0, -1.0 if dx > 1 else 1.0),
        'pencil': (0, 0, -4.0 * k + 2.5 * sin(i / n, 2)),
        'sprout': -16 * k + 6 * sin(i / n, 2),
        'foot_l': (0, 0, 0),
        'foot_r': (0, 0, 0),
        'flap_front': True,
    }


# ------------------------------------------------------------------------ hop (12)
HOP = [
    # ty, sx, sy, foot_ty, pencil_rot, sprout_rot, eyes_dy, eyes_sy
    (0, 1.00, 1.00, 0, 0, 0, 0, 1.0),
    (0, 1.06, 0.90, 0, -3, 6, 0, 0.9),
    (0, 1.10, 0.83, 0, -6, 12, 0, 0.9),
    (-110, 0.95, 1.10, -15, 8, -14, 0, 1.0),
    (-265, 0.97, 1.07, -50, 12, -22, 0, 1.0),
    (-325, 1.00, 1.00, -62, 3, -8, -12, 1.04),
    (-335, 1.00, 1.00, -64, -8, 16, -12, 1.04),
    (-260, 0.98, 1.05, -50, -12, 22, 0, 1.0),
    (-105, 0.95, 1.10, -20, -9, 12, 0, 1.0),
    (0, 1.12, 0.80, 0, 10, -20, 0, 0.9),
    (0, 0.98, 1.05, 0, -6, 10, 0, 1.0),
    (0, 1.01, 0.99, 0, 2, -4, 0, 1.0),
]


def hop(i, n=12):
    """One bouncy hop: crouch, spring, hang at the top, land squashed, settle."""
    if i == 0:
        return dict(REST)
    ty, sx, sy, fty, prot, spr, edy, esy = sample(HOP, key_time(i, n))
    pose = {
        'body': (0, ty, 0, sx, sy),
        'foot_l': (0, fty, 0),
        'foot_r': (0, fty, 0),
        'pencil': (0, 0, prot),
        'sprout': spr,
        'flap_front': True,
    }
    if abs(edy) > 1e-6 or abs(esy - 1) > 1e-6:
        pose['eyes'] = (0, edy, esy)
    return pose


# ----------------------------------------------------------------- write (12)
LEAN = 9.0      # degrees, towards the pen (clockwise = to the right)
LEAN_TX = 90    # and she shifts that way too


def write(i, n=12):
    """Notation: she leans out to the side with the pen and scribbles with it. The pen wiggles a
    little (three quick strokes per loop, tip tracing small loops) while her eyes follow it."""
    u = i / n
    breathe = 0.008 * sin(u)
    body = (LEAN_TX, 0, LEAN + 0.6 * sin(u, 3, 0.25), 1.0, 1.0 + breathe)
    # three strokes a loop; rotation and slide are a quarter apart so the tip draws a small loop
    stroke = sin(u, 3)
    slide = sin(u, 3, 0.25)
    pose = {
        'body': body,
        'pencil': (34 * slide, 10 * cos(u, 3), 10 + 4.5 * stroke),
        'sprout': 18 * sin(u, 3, 0.4),
        'foot_l': plant(body, 'foot_l'),
        # her weight is on the near foot; the far one tips up on the beat
        'foot_r': (0, -16 * max(0.0, sin(u, 3, 0.1)), 0),
        'eyes': (24 + 8 * slide, 22 + 3 * cos(u, 3), 1.0),
        'mouth': (14, 8, 1.0),
        'flap_open': 10 + 8 * stroke,
        'flap_front': True,
    }
    eyes = blink(key_time(i, n), 9.0)
    if eyes < 1.0:
        pose['eyes'] = (24 + 8 * slide, 22, min(1.0, eyes))
    return pose


# ------------------------------------------------------------------- run (12)
# A scampering gallop of two bounds a loop. In each bound one foot lands ahead of her, slides
# back under her while she pushes off, and trails; then it swings through to land again. The
# near (left) foot leads the first bound, the far (right) one the second. The body itself stays
# put in these frames: the app carries her across the screen at RUN_TRAVEL per frame, and the
# planted foot is slid back by exactly that much so it does not skate.
RUN_STEP = 520.0                  # native px she travels per frame (= 2 x REACH)
REACH = RUN_STEP / 2
RUN_TRAVEL_PER_LOOP = RUN_STEP * 12

# (ty, rot, sx, sy) per frame of one bound
BOUND = [
    (0, 5, 1.07, 0.90),        # lands, squashing
    (-60, 8, 0.97, 1.07),      # pushes off
    (-250, 9, 0.97, 1.05),     # rising
    (-320, 8, 1.0, 1.0),       # top
    (-190, 6, 0.98, 1.04),     # falling
    (-50, 5, 1.0, 1.02),       # reaching
]
# the swing of one foot over the 12 frames (local offsets); frames 0 and 1 are the stance
FOOT_CYCLE = [None, None, (-250, -60), (-260, -100), (-210, -90), (-150, -80),
              (-60, -110), (40, -120), (130, -100), (210, -70), (250, -40), (265, -10)]


def run(i, n=12):
    u = i / n
    ty, rot, sx, sy = BOUND[i % 6]
    body = (0, ty, rot, sx, sy)

    def foot(name, f):
        c = FOOT_CYCLE[f % 12]
        if c is None:
            return plant(body, name, REACH - RUN_STEP * (f % 12))
        return (c[0], c[1], 0.0)

    air = 1.0 if 2 <= i % 6 <= 4 else 0.0
    pose = {
        'body': body,
        'foot_l': foot('foot_l', i),
        'foot_r': foot('foot_r', i + 6),
        # the pencil trails behind her and the leaf streams back
        'pencil': (0, 0, -9 * sin(u, 2, 0.12) - 3),
        'sprout': -18 + 16 * sin(u, 2, 0.3),
        'flap_open': 30 * air,
        # she looks where she is going
        'eyes': (26, -6, 1.0),
        'mouth': (14, -4, 1.0),
        'flap_front': True,
    }
    return pose


# ------------------------------------------------------------------ pop out (12)
PEEK = 330.0      # how far down she stays: the card hides her lower body and mouth
PEEK_HIDDEN = 1500.0

# ty, rot, sx, sy, eye height, sprout, pencil
POP = [
    (PEEK_HIDDEN, 0, 1.0, 1.0, 1.0, 0, 0),
    (1150, 0, 0.95, 1.10, 1.0, 10, -3),
    (760, 0, 0.94, 1.12, 1.05, 20, -6),
    (420, -1.5, 0.95, 1.10, 1.1, 30, -10),
    (170, -2.5, 0.97, 1.08, 1.15, 34, -12),
    (90, -3, 1.0, 1.02, 1.15, 0, 4),          # the top of the spring
    (190, 2.5, 1.03, 0.97, 1.1, -26, 10),
    (300, 3, 1.04, 0.95, 1.05, -22, 6),
    (352, -1.5, 1.06, 0.93, 0.2, -10, -4),    # lands, blinks
    (322, 1.5, 0.99, 1.02, 0.8, 8, 3),
    (334, -0.5, 1.0, 1.0, 1.0, -3, -1),
    (PEEK, 0, 1.0, 1.0, 1.0, 0, 0),
]


def pop_out(i, n=12):
    """She springs up from behind the card (the app hides everything below the card's edge),
    overshoots, settles and looks straight out at the person."""
    ty, rot, sx, sy, eyes, spr, pen = POP[i]
    pose = {
        'body': (0, ty, rot, sx, sy),
        'foot_l': (0, -30, 0),
        'foot_r': (0, -30, 0),
        'sprout': spr,
        'pencil': (0, 0, pen),
        'flap_open': 20 if 2 <= i <= 6 else 0,
        'flap_front': True,
    }
    if abs(eyes - 1) > 1e-6:
        pose['eyes'] = (0, 0, eyes)
    return pose


# --------------------------------------------------------------------- attend (12)
def attend(i, n=12):
    """Peeking over the card at the person: a gentle bob, a blink, a wave of the pencil."""
    u = i / n
    if i == 0:
        return {'body': (0, PEEK, 0, 1.0, 1.0), 'foot_l': (0, -30, 0), 'foot_r': (0, -30, 0),
                'flap_front': True}
    bob = -22 * math.sin(math.pi * u) ** 2
    pose = {
        'body': (0, PEEK + bob, 1.6 * sin(u), 1.0 + 0.01 * sin(u, 2), 1.0 - 0.01 * sin(u, 2)),
        'foot_l': (0, -30, 0),
        'foot_r': (0, -30, 0),
        'pencil': (0, 0, 6 * sin(u, 2, 0.1)),
        'sprout': 12 * sin(u, 2, 0.35),
        'flap_open': 14 * max(0.0, sin(u, 2)),
        'eyes': (0, -4 * sin(u), blink(key_time(i, n), 8.0)),
        'flap_front': True,
    }
    return pose


# ---------------------------------------------------------------------- grade (24)
# Two quick hops (6 frames each), then a body shake, left to right, for the last 12.
HOP6 = [
    # ty, sx, sy, foot_ty, pencil_rot, sprout_rot, eyes_sy
    (0, 1.08, 0.88, 0, -4, 8, 0.9),
    (-190, 0.96, 1.10, -40, 8, -16, 1.0),
    (-330, 1.00, 1.00, -62, -4, 12, 1.05),
    (-200, 0.98, 1.05, -45, -10, 18, 1.0),
    (0, 1.10, 0.84, 0, 9, -18, 0.85),
    (0, 0.98, 1.04, 0, -3, 6, 1.0),
]


def grade(i, n=24):
    if i < 12:
        ty, sx, sy, fty, prot, spr, esy = HOP6[i % 6]
        pose = {
            'body': (0, ty, 0, sx, sy),
            'foot_l': (0, fty, 0),
            'foot_r': (0, fty, 0),
            'pencil': (0, 0, prot),
            'sprout': spr,
            'flap_front': True,
        }
        if abs(esy - 1) > 1e-6:
            pose['eyes'] = (0, -8 if fty < -30 else 0, esy)
        return pose
    # the shake: three full left-right swings, fading in and out so the loop closes cleanly
    u = (i - 12) / 12
    env = math.sin(math.pi * u) ** 0.6
    s = sin(u, 3)
    tx = 70 * s * env
    body = (tx, 0, 4.0 * s * env, 1.0 + 0.02 * abs(s) * env, 1.0 - 0.015 * abs(s) * env)
    return {
        'body': body,
        'foot_l': plant(body, 'foot_l'),
        'foot_r': plant(body, 'foot_r'),
        'pencil': (0, 0, -12 * s * env),
        'sprout': -26 * s * env,
        'eyes': (0.35 * tx, 0, 0.85 if env > 0.5 else 1.0),
        'flap_open': 26 * abs(s) * env,
        'flap_front': True,
    }


# name -> (function, frames)
ANIMATIONS = {
    'look_around': (look_around, 12),
    'think': (think, 12),
    'hop': (hop, 12),
    'write': (write, 12),
    'run': (run, 12),
    'pop_out': (pop_out, 12),
    'attend': (attend, 12),
    'grade': (grade, 24),
}
