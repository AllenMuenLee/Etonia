"""Puppet renderer for Etonia (layers come from build_layers.py)."""
import json
import math
import os
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).parent
LAYERS = HERE / 'layers'
META = json.load(open(LAYERS / 'meta.json'))
ANGLE = META['angle']
C = tuple(META['center'])

# world (native 2480 px) -> canvas
CANVAS_W, CANVAS_H = 2480, 2920
OFFSET_X = -190         # shift the art left a little: the pencil and the leaning poses need room on the right
OFFSET_Y = 500          # headroom for hops and the pen spinning above the head
SS = float(os.environ.get('ETONIA_SS', 0.5))  # supersample scale for compositing (ETONIA_SS=0.25 for quick previews)


# ----------------------------------------------------------------- matrices
def T(tx, ty):
    return np.array([[1, 0, tx], [0, 1, ty], [0, 0, 1]], float)


def Rot(deg, cx=0.0, cy=0.0):
    """Clockwise-visual rotation (image y points down) about (cx, cy)."""
    a = math.radians(deg)
    r = np.array([[math.cos(a), -math.sin(a), 0], [math.sin(a), math.cos(a), 0], [0, 0, 1]], float)
    return T(cx, cy) @ r @ T(-cx, -cy)


def Sc(sx, sy, cx=0.0, cy=0.0):
    s = np.array([[sx, 0, 0], [0, sy, 0], [0, 0, 1]], float)
    return T(cx, cy) @ s @ T(-cx, -cy)


def apply(m, x, y):
    p = m @ np.array([x, y, 1.0])
    return p[0], p[1]


BASE_ROT = Rot(ANGLE, *C)  # rotated (pencil) frame -> original frame

# pivots (native, original frame)
P_BODY = (1150.0, 2140.0)
P_FOOT = {'foot_l': (880.0, 2110.0), 'foot_r': (1480.0, 2130.0)}
EYE_C = (1089.0, 1208.5)   # centre of the two eye strokes (mirror axis)
MOUTH_C = (1116.5, 1853.5)
PENCIL_ROT_PIVOT = (1685.0, (META['band_rows'][0] + META['band_rows'][1]) / 2)
P_PENCIL = apply(BASE_ROT, *PENCIL_ROT_PIVOT)
FLAP_APEX_ROT = (1683.0, float(META['flap_apex_row']) - 6)  # where the fold's point meets the paper
FLAP_CREASE_ROT_Y = 526.0  # the fold's crease in the pencil frame
SPROUT_ROT_PIVOT = (935.0, 610.0)  # where the stem meets the pencil cap (rotated frame)


# ------------------------------------------------------------------- layers
def _load(name):
    im = Image.open(LAYERS / f'{name}.png').convert('RGBA')
    return im


_cache = {}


def layer(name):
    if name in _cache:
        return _cache[name]
    if name in ('eyes', 'mouth', 'patch_eyes', 'patch_mouth'):
        face = np.array(_load('face_patch' if name.startswith('patch') else 'face'))
        if name.endswith('eyes'):
            face[1700:] = 0
        else:
            face[:1700] = 0
        im = Image.fromarray(face, 'RGBA')
    else:
        im = _load(name)
    sz = (int(im.width * SS), int(im.height * SS))
    pm = im.convert('RGBa').resize(sz, Image.LANCZOS)
    _cache[name] = pm
    return pm


def place(name, m_world, opacity=1.0):
    """Return the layer transformed to the supersampled canvas as RGBA."""
    src = layer(name)
    m = Sc(SS, SS) @ T(OFFSET_X, OFFSET_Y) @ m_world @ Sc(1 / SS, 1 / SS)
    inv = np.linalg.inv(m)
    out_size = (int(CANVAS_W * SS), int(CANVAS_H * SS))
    out = src.transform(out_size, Image.AFFINE,
                        (inv[0, 0], inv[0, 1], inv[0, 2], inv[1, 0], inv[1, 1], inv[1, 2]),
                        resample=Image.BICUBIC)
    if opacity < 1.0:
        out = out.point(lambda v: int(v * opacity))
    return out.convert('RGBA')


# --------------------------------------------------------------------- pose
def body_matrix(b):
    tx, ty, rot, sx, sy = b
    return T(tx, ty) @ Rot(rot, *P_BODY) @ Sc(sx, sy, *P_BODY)


def render(pose, size=None):
    b = pose.get('body', (0, 0, 0, 1, 1))
    mb = body_matrix(b)

    def child(local=None, pivot=(0, 0)):
        if local is None:
            return mb
        tx, ty, rot = local[:3]
        return mb @ T(tx, ty) @ Rot(rot, *pivot)

    # pencil (and sprout) are children of the body, then spin about their centre
    pl = pose.get('pencil', (0, 0, 0))
    # `pencil_spin` squeezes the pencil along its own length: a turn about a vertical axis
    # seen from the front (1 = side on, 0 = end on, negative = turned around)
    spin_x = pose.get('pencil_spin', 1.0)
    m_pencil = child(pl, P_PENCIL) @ BASE_ROT @ Sc(spin_x, 1.0, *PENCIL_ROT_PIVOT)
    sp = pose.get('sprout', 0.0)
    m_sprout = m_pencil @ Rot(sp, *SPROUT_ROT_PIVOT)

    # eyes / mouth: (dx, dy, height scale[, flip]); flip = -1 mirrors the strokes left-right,
    # as when the face turns the other way
    ey = tuple(pose.get('eyes', (0, 0, 1.0))) + (1.0,)
    m_eyes = mb @ T(ey[0], ey[1]) @ Sc(ey[3] if len(pose.get('eyes', (0, 0, 1.0))) > 3 else 1.0, ey[2], *EYE_C)
    mo = tuple(pose.get('mouth', (0, 0, 1.0))) + (1.0,)
    m_mouth = mb @ T(mo[0], mo[1]) @ Sc(mo[3] if len(pose.get('mouth', (0, 0, 1.0))) > 3 else 1.0, mo[2], *MOUTH_C)

    def moved(t, n=3):
        return t is not None and any(abs(v) > 1e-6 for v in t[:n])

    eyes_moved = abs(ey[0]) > 1e-6 or abs(ey[1]) > 1e-6 or abs(ey[2] - 1) > 1e-6 or len(pose.get('eyes', ())) > 3 and pose['eyes'][3] != 1
    mouth_moved = abs(mo[0]) > 1e-6 or abs(mo[1]) > 1e-6 or abs(mo[2] - 1) > 1e-6 or len(pose.get('mouth', ())) > 3 and pose['mouth'][3] != 1
    pencil_free = moved(pl) or abs(spin_x - 1.0) > 1e-6
    suffix = lambda k: '' if moved(pose.get(k)) else '_rest'

    # she faces right: the left-hand foot is the near one, so it is drawn over the far (right) foot
    order = [
        ('foot_r' + suffix('foot_r'), child(pose.get('foot_r'), P_FOOT['foot_r']), 1.0),
        ('foot_l' + suffix('foot_l'), child(pose.get('foot_l'), P_FOOT['foot_l']), 1.0),
        ('body', mb, 1.0),
    ]
    if eyes_moved:
        order.append(('patch_eyes', mb, 1.0))
    if mouth_moved:
        order.append(('patch_mouth', mb, 1.0))
    order += [('eyes', m_eyes, 1.0), ('mouth', m_mouth, 1.0)]
    if pencil_free:
        order.append(('paper_fill', mb, 1.0))
    # the fold is carried off with the pencil (see m_flap), which leaves a hole in the body where
    # it was: fill it with the paper colour whenever the pencil is free or the fold opens
    if pencil_free or abs(pose.get('flap_open', 0.0)) > 1e-6:
        order.append(('flap_under', mb, 1.0))
    pencil_name = 'pencil' if pencil_free else 'pencil_rest'
    pencil_stack = [(pencil_name, m_pencil, 1.0), ('sprout', m_sprout, 1.0)]
    # the folded corner stretches a little while the pencil spins (about its tip, which stays on the paper)
    # `flap_open` unfolds the corner about its crease (the pencil's top line): 0 = folded,
    # 90 = edge on, 180 = flat out, showing the reverse side in paper colour
    fo = pose.get('flap_open', 0.0)
    sy = math.cos(math.radians(fo)) * (1.08 if fo > 90 else 1.0)
    sy = math.copysign(max(abs(sy), 0.04), sy)
    # the fold is pinned to the pencil: it moves and rotates with it (about the same pivot), so it
    # never gets left behind or slides under the pencil when the pencil is moved
    m_flap = child(pl, P_PENCIL) @ BASE_ROT @ Sc(1.0, sy, 0.0, FLAP_CREASE_ROT_Y) @ np.linalg.inv(BASE_ROT)
    flap = [('flap_back' if fo > 90 else 'flap', m_flap, 1.0)]
    if pose.get('pencil_behind', False):
        # the pencil has gone round the back of the corner: paper and fold hide its middle
        order = order[:2] + pencil_stack + order[2:] + flap
    elif pose.get('flap_front', True):
        order += pencil_stack + flap
    else:
        order += flap + pencil_stack

    cw, ch = int(CANVAS_W * SS), int(CANVAS_H * SS)
    canvas = Image.new('RGBA', (cw, ch), (0, 0, 0, 0))
    for name, m, op in order:
        canvas.alpha_composite(place(name, m, op))
    if size:
        pm = canvas.convert('RGBa').resize(size, Image.LANCZOS)
        return pm.convert('RGBA')
    return canvas
