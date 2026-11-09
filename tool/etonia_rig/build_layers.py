"""Split Etonia.png into puppet layers (body, flap, pencil, sprout, face, feet).

Usage:  python tool/etonia_rig/build_layers.py [Etonia.png] [out_dir]

All layers are full-size RGBA images.  `pencil` and `sprout` are stored in a
frame rotated so the pencil lies horizontal (ANGLE degrees CCW about C); the
renderer rotates them back.  Everything else stays in the original frame.
"""
import json
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SRC = Path(sys.argv[1] if len(sys.argv) > 1 else 'Etonia.png')
OUT = Path(sys.argv[2] if len(sys.argv) > 2 else 'tool/etonia_rig/layers')
OUT.mkdir(parents=True, exist_ok=True)

im = Image.open(SRC).convert('RGBA')
W, H = im.size
A = np.array(im).astype(np.int32)

# ---------------------------------------------------------------- pencil axis
yel = (A[..., 0] > 230) & (A[..., 1] > 180) & (A[..., 2] < 120) & (A[..., 3] > 200)
ys, xs = np.where(yel)
pts = np.stack([xs, ys], 1).astype(float)
C = tuple(pts.mean(0))
d = np.linalg.svd(pts - pts.mean(0), full_matrices=False)[2][0]
ANGLE = math.degrees(math.atan2(d[1], d[0]))
rot = im.rotate(ANGLE, resample=Image.BICUBIC, center=C)
R = np.array(rot).astype(np.int32)


def lerp_fill(vals):
    """Linear interpolation over NaNs."""
    v = np.array(vals, float)
    idx = np.arange(len(v))
    ok = ~np.isnan(v)
    return np.interp(idx, idx[ok], v[ok])


# ------------------------------------------------- per-column pencil band (rot)
X0, X1 = 900, 2470
top = np.full(W, np.nan)
bot = np.full(W, np.nan)
FLAP_L, FLAP_R = 1405, 1975  # columns where the folded corner hides the pencil
for x in range(X0, X1):
    col = R[:, x]
    a = np.where(col[440:720, 3] > 100)[0]
    if len(a) == 0:
        continue
    if FLAP_L <= x <= FLAP_R:
        continue
    top[x] = a.min() + 440
    yy = np.where((col[:, 0] > 225) & (col[:, 1] > 180) & (col[:, 2] < 120) & (col[:, 3] > 200))[0]
    yy = yy[(yy > 440) & (yy < 760)]
    if len(yy) and x < 2185:
        ymax = yy.max()
        dd = np.where((col[ymax:ymax + 24, 0] < 90) & (col[ymax:ymax + 24, 1] < 100))[0] + ymax
        if len(dd):
            run = [dd[0]]
            for v in dd[1:]:
                if v == run[-1] + 1:
                    run.append(v)
                else:
                    break
            bot[x] = run[-1]
    else:  # tapered tip / cap: nothing under the pencil, use alpha extent
        a2 = np.where(col[440:800, 3] > 100)[0] + 440
        bot[x] = a2.max()
seg = bot[X0:X1].copy()
bot[X0:X1] = lerp_fill(seg)
topf = top[X0:X1].copy()
top[X0:X1] = lerp_fill(topf)
band = np.zeros((H, W), np.uint8)
for x in range(X0, X1):
    if not np.isnan(top[x]):
        band[int(top[x]) - 2:int(bot[x]) + 3, x] = 255

# ------------------------------------------------------------------ sprout
green = (R[..., 1] > R[..., 0] + 28) & (R[..., 1] > R[..., 2] + 28) & (R[..., 3] > 30)
green_img = Image.fromarray((green * 255).astype(np.uint8))
green_dil = np.array(green_img.filter(ImageFilter.MaxFilter(5))) > 0
gy, gx = np.where(green)
print('sprout bbox (rot):', gx.min(), gx.max(), gy.min(), gy.max())

# ------------------------------------------------------- folded corner (rot)
dark = (R[..., 0] < 110) & (R[..., 1] < 120) & (R[..., 2] < 130) & (R[..., 3] > 150)
xl = np.full(H, np.nan)
xr = np.full(H, np.nan)
Y0F, Y1F = 513, 800
for y in range(Y0F, Y1F):
    row = dark[y]
    l = np.where(row[1400:1700])[0]
    r_ = np.where(row[1680:1990])[0]
    if len(l):
        xl[y] = 1400 + l.min()
    if len(r_):
        xr[y] = 1680 + r_.max()
for y in range(648, 712):  # pencil lower outline merges with the V strokes here
    xl[y] = np.nan
    xr[y] = np.nan
for arr in (xl, xr):
    ys_fit = np.array([y for y in range(560, 640) if not np.isnan(arr[y])])
    coef = np.polyfit(ys_fit, arr[ys_fit], 1)
    for y in range(Y0F, 560):
        arr[y] = np.polyval(coef, y)
xl[Y0F:Y1F] = lerp_fill(xl[Y0F:Y1F])
xr[Y0F:Y1F] = lerp_fill(xr[Y0F:Y1F])
apex = Y1F - 1
for y in range(Y0F + 60, Y1F):
    if xr[y] - xl[y] < 20:
        apex = y
        break
print('flap apex row', apex)
PAD = 10
rows = list(range(Y0F, apex))
flap_poly = [(xl[y] - PAD, y) for y in rows] + [(xr[y] + PAD, y) for y in reversed(rows)]
flap_mask_rot = Image.new('L', (W, H), 0)
ImageDraw.Draw(flap_mask_rot).polygon(flap_poly, fill=255)
fm = np.array(flap_mask_rot)

# ------------------------------------------------------------- pencil layer
pencil = R.copy()
pencil[..., 3] = np.where(band > 0, pencil[..., 3], 0)
pencil[green_dil] = 0
for x in range(X0, 1000):  # stem overlap -> copy from the row above
    for y in range(int(top[x]), int(bot[x]) + 1):
        if green_dil[y, x]:
            yy = y
            while yy > 0 and green_dil[yy, x]:
                yy -= 1
            pencil[y, x] = R[yy, x]
yel_rot = (R[..., 0] > 200) & (R[..., 1] > 150) & (R[..., 2] < 150) & (R[..., 3] > 100)
hole_rest = (fm > 0) & (band > 0) & ~yel_rot
pencil_rest = pencil.copy()
pencil_rest[hole_rest] = 0
hole = np.zeros((H, W), bool)
for y in range(Y0F, apex):
    hole[y, int(xl[y] - 14):int(xr[y] + 14) + 1] = True
bmin = int(np.nanmin(bot[1380:2000])) - 18
bmax = int(np.nanmax(bot[1380:2000])) + 3
hole[bmin:bmax, 1490:1845] = True
hole &= band > 0
src = pencil.copy()
for y in range(H):
    xs_ = np.where(hole[y])[0]
    if len(xs_) == 0:
        continue
    for g in np.split(xs_, np.where(np.diff(xs_) > 1)[0] + 1):
        a, b = g.min() - 1, g.max() + 1
        for x in g:
            t = (x - a) / (b - a)
            v = (y - top[x]) / (bot[x] - top[x])
            ya = int(round(top[a] + v * (bot[a] - top[a])))
            yb = int(round(top[b] + v * (bot[b] - top[b])))
            pencil[y, x] = np.round((1 - t) * src[ya, a] + t * src[yb, b])
pencil_img = Image.fromarray(pencil.astype(np.uint8), 'RGBA')
pencil_rest_img = Image.fromarray(pencil_rest.astype(np.uint8), 'RGBA')

sprout = R.copy()
sprout[..., 3] = np.where(green_dil, sprout[..., 3], 0)
sprout_img = Image.fromarray(sprout.astype(np.uint8), 'RGBA')


# ------------------------------------------------ rot-frame masks -> orig frame
def to_orig(m):
    m = m if isinstance(m, Image.Image) else Image.fromarray(m)
    return np.array(m.rotate(-ANGLE, resample=Image.BICUBIC, center=C)).astype(np.float32) / 255.0


keep_strip = np.zeros((H, W), np.uint8)
for x in range(1240, 2040):
    keep_strip[int(bot[x]) - 17:int(bot[x]) + 3, x] = 255
remove_m = to_orig(np.maximum(band, (green_dil * 255).astype(np.uint8))) > 0.5
flap_m = to_orig(fm) > 0.5
strip_m = (to_orig(keep_strip) > 0.5) & ~flap_m & (A[..., :3].max(-1) < 100)

body = A.astype(np.float32).copy()
body[..., 3] *= (~(remove_m | flap_m)).astype(np.float32)
flap = A.astype(np.float32).copy()
yel_orig = (A[..., 0] > 200) & (A[..., 1] > 150) & (A[..., 2] < 150) & (A[..., 3] > 100)
flap[..., 3] *= (flap_m & ~yel_orig).astype(np.float32)
cut_edge = A.astype(np.float32).copy()
cut_edge[..., 3] *= strip_m.astype(np.float32)

# ------------------------------------------------- paper behind the pencil (rot)
# The paper's corner was hidden under the pencil.  Rebuild it so the folded corner always
# sits on solid paper: extend the two paper edges that run into the pencil up to the
# pencil's top line and fill between them.
band_y = lambda arr, x: arr[int(round(x))]
ys_l, xs_l, ys_r, xs_r = [], [], [], []
bmean = float(np.nanmean(bot[1262:2040]))
for y in range(int(bmean) + 30, int(bmean) + 150):
    l = np.where(dark[y, 900:1480])[0]
    r_ = np.where(dark[y, 1900:2300])[0]
    if len(l):
        ys_l.append(y)
        xs_l.append(900 + l.min() + 7)
    if len(r_):
        ys_r.append(y)
        xs_r.append(1900 + r_.min() + 7)
edge_l = np.polyfit(ys_l, xs_l, 1)  # x = a*y + b
edge_r = np.polyfit(ys_r, xs_r, 1)
xl_at = lambda y: np.polyval(edge_l, y)
xr_at = lambda y: np.polyval(edge_r, y)


def hit(edge, arr, y0):
    """y where the edge line meets the pencil line `arr` (top or bot)."""
    y = y0
    for _ in range(6):
        y = arr[int(round(np.polyval(edge, y)))]
    return float(y)


yl_t, yr_t = hit(edge_l, top, 520), hit(edge_r, top, 520)
yl_b, yr_b = hit(edge_l, bot, 690), hit(edge_r, bot, 690)
print('paper edges meet pencil top at', xl_at(yl_t), yl_t, xr_at(yr_t), yr_t, ' bottom at', xl_at(yl_b), yl_b, xr_at(yr_b), yr_b)
SS2 = 2
fill_mask = np.zeros((H, W), np.uint8)
for x in range(int(min(xl_at(yl_b), xl_at(yl_t))) - 4, int(max(xr_at(yr_b), xr_at(yr_t))) + 6):
    y0 = int(top[x])
    y1 = int(bot[x]) + 34
    ys_ = np.arange(y0, y1 + 1)
    lo = xl_at(ys_)
    hi = xr_at(ys_)
    inset = np.where(ys_ > bot[x] + 1, 16, 0)
    ok = (x >= lo + inset) & (x <= hi - inset)
    fill_mask[ys_[ok], x] = 255
cream = (255, 248, 236)
fill_rgba = np.zeros((H, W, 4), np.uint8)
fill_rgba[..., :3] = cream
fill_rgba[..., 3] = fill_mask
# outline strokes along the two extended edges (same look as the drawing: ~72 % black)
stroke_big = Image.new('L', (W * SS2, H * SS2), 0)
sd = ImageDraw.Draw(stroke_big)
for edge, yt, yb in ((edge_l, yl_t, yl_b), (edge_r, yr_t, yr_b)):
    pts = [(np.polyval(edge, y) * SS2, y * SS2) for y in (yt - 2, yb + 1)]
    sd.line(pts, fill=190, width=15 * SS2)
stroke = np.array(stroke_big.resize((W, H), Image.LANCZOS)).astype(np.float32) / 255.0
a_f = fill_rgba[..., 3].astype(np.float32) / 255.0
out_a = stroke + a_f * (1 - stroke)
out_rgb = np.where(out_a[..., None] > 0,
                   (np.array(cream, np.float32) * (a_f * (1 - stroke))[..., None]) / np.maximum(out_a[..., None], 1e-6), 0)
paper_fill_rot = np.dstack([out_rgb, out_a * 255]).astype(np.uint8)
paper_fill_img = Image.fromarray(paper_fill_rot, 'RGBA').convert('RGBa').rotate(
    -ANGLE, resample=Image.BICUBIC, center=C).convert('RGBA')

# ------------------------------------------------------------------- face
BX0, BX1, BY0, BY1 = 700, 1500, 850, 1980
box = A[BY0:BY1, BX0:BX1]
lum = box[..., :3].mean(-1)
stroke = (box[..., 3] < 254) | (lum < 240)
face = np.zeros((H, W, 4), np.float32)
face[BY0:BY1, BX0:BX1][stroke] = box[stroke]
body[BY0:BY1, BX0:BX1][stroke] = 0
cream_rgb = np.median(box[~stroke][:, :3], 0)
st_img = Image.fromarray((stroke * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(9))
patch = np.zeros((H, W, 4), np.float32)
pm_ = np.array(st_img) > 0
patch[BY0:BY1, BX0:BX1][pm_] = (*cream_rgb, 255)
print('cream', cream_rgb)

# -------------------------------------------------------------------- feet
dk = (A[..., 0] < 90) & (A[..., 1] < 100) & (A[..., 3] > 150)
FOOT = {'L': (690, 1065), 'R': (1305, 1655)}
band_end = np.full(W, np.nan)
for x in range(600, 1800):
    if any(a - 20 <= x <= b + 20 for a, b in FOOT.values()):
        continue
    idx = np.where(dk[1950:2200, x])[0]
    if len(idx):
        run = [idx[0]]
        for v in idx[1:]:
            if v == run[-1] + 1:
                run.append(v)
            else:
                break
        band_end[x] = 1950 + run[-1]
xs_all = np.arange(600, 1800)
ok = ~np.isnan(band_end[600:1800])
be = np.interp(xs_all, xs_all[ok], band_end[600:1800][ok])
EXT = 150
feet = {}
for k, (a, b) in FOOT.items():
    lay = np.zeros((H, W, 4), np.float32)
    lay_rest = np.zeros((H, W, 4), np.float32)
    for x in range(a, b + 1):
        e = int(round(be[x - 600]))
        ycol = A[e + 2:2400, x]
        m = ycol[:, 3] > 30
        lay_rest[e + 2:2400, x] = np.where(m[:, None], ycol, 0)
        # moving variant: drop the first rows (leftovers of the paper's outline) and
        # extend the foot upward, behind the paper, with a smoothed copy of its top
        lay[e + 12:2400, x] = lay_rest[e + 12:2400, x]
        lay[e - EXT:e + 12, x] = A[e + 14:e + 34, x].astype(np.float32).mean(0)
        body[e + 2:2400, x] = 0
    feet[k] = lay
    feet[k + '_rest'] = lay_rest
    ys_, xs_ = np.where(lay[..., 3] > 30)
    print('foot', k, xs_.min(), xs_.max(), ys_.min(), ys_.max())


from scipy import ndimage
body[body[..., 3] < 30] = 0  # faint alpha noise in the source art
lab, n_lab = ndimage.label(body[..., 3] > 25)
sizes = ndimage.sum(np.ones_like(lab), lab, range(1, n_lab + 1))
for i, sz in enumerate(sizes, 1):
    if sz < 20000:
        body[lab == i] = 0
print('body components kept:', int((sizes >= 20000).sum()), 'dropped:', int((sizes < 20000).sum()))


def save(arr, name):
    Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), 'RGBA').save(OUT / f'{name}.png', optimize=True)


save(body, 'body')
save(flap, 'flap')
save(face, 'face')
save(patch, 'face_patch')
paper_fill_img.save(OUT / 'paper_fill.png', optimize=True)
# paper-coloured fill behind the fold, drawn only while the fold moves, so lifting it never
# shows a hole where the original (fold-covered) paper pixels were taken out of the body layer
under_rot = fm.copy()
under_rot[:538] = 0
# the fold's mask reaches past the paper's right edge (its point sticks out over the pencil);
# the fill must stop at the paper's own edge, or a cream spike shows once the fold has moved off it
for y in range(538, H):
    under_rot[y, int(xr_at(y)) + 2:] = 0
under_a = (to_orig(under_rot) * 255).astype(np.uint8)
flap_under = np.zeros((H, W, 4), np.uint8)
flap_under[..., :3] = cream
flap_under[..., 3] = under_a
Image.fromarray(flap_under, 'RGBA').save(OUT / 'flap_under.png', optimize=True)
flap_back = flap.copy()  # the fold's reverse side: same drawing, paper colour instead of the darker underside
light = flap_back[..., :3].min(-1) > 150
flap_back[..., :3][light] = cream
save(flap_back, 'flap_back')
pencil_rest_img.save(OUT / 'pencil_rest.png', optimize=True)
save(feet['L'], 'foot_l')
save(feet['R'], 'foot_r')
save(feet['L_rest'], 'foot_l_rest')
save(feet['R_rest'], 'foot_r_rest')
pencil_img.save(OUT / 'pencil.png', optimize=True)
sprout_img.save(OUT / 'sprout.png', optimize=True)
cap_x = int(gx.max())
meta = {
    'angle': ANGLE,
    'center': list(C),
    'band_rows': [float(np.nanmin(top)), float(np.nanmax(bot))],
    'pencil_x': [float(np.nanmin(np.where(~np.isnan(top))[0])), float(np.nanmax(np.where(~np.isnan(top))[0]))],
    'flap_apex_row': apex,
}
json.dump(meta, open(OUT / 'meta.json', 'w'), indent=1)
print(meta)
