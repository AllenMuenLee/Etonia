"""Turn the flat Tonia.jpg drawing into the RGBA source that build_layers.py expects.

Usage:  python tool/etonia_rig/prepare_source.py [Tonia.jpg] [out.png]

The drawing is on a white background.  Background = near-white pixels reachable from the
image border (the paper's cream and the pencil's highlights are never that white, and the
outline keeps the flood out of the figure).  Pixels on the boundary are matted against
white: their colour is taken from the nearest solid pixel and the alpha is how much of
that colour is needed to explain the observed pixel, so edges stay soft and un-haloed.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

SRC = Path(sys.argv[1] if len(sys.argv) > 1 else 'Tonia.jpg')
OUT = Path(sys.argv[2] if len(sys.argv) > 2 else 'tool/etonia_rig/Tonia_rgba.png')

rgb = np.array(Image.open(SRC).convert('RGB')).astype(np.float32)
H, W, _ = rgb.shape

whiteish = rgb.min(-1) >= 246
lab, _ = ndimage.label(whiteish)
border = np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]]))
bg = np.isin(lab, border[border > 0])

# solid = at least 4 px away from the background; the band in between gets matted
dist = ndimage.distance_transform_edt(~bg)
band = (~bg) & (dist <= 4)
solid = (~bg) & ~band
_, (iy, ix) = ndimage.distance_transform_edt(~solid, return_indices=True)
fg = rgb[iy, ix]                                  # nearest solid colour for every pixel

d = 255.0 - fg                                    # how far the solid colour is from white
obs = 255.0 - rgb
alpha = (obs * d).sum(-1) / np.maximum((d * d).sum(-1), 1.0)
alpha = np.clip(alpha, 0.0, 1.0)

out = np.zeros((H, W, 4), np.float32)
out[..., :3] = rgb
out[solid, 3] = 255
out[band, :3] = fg[band]
out[band, 3] = (alpha[band] * 255)
out[bg] = 0
# a faint grey halo from JPEG ringing is not part of the art
out[(out[..., 3] < 12)] = 0

Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), 'RGBA').save(OUT, optimize=True)
a = out[..., 3] > 0
ys, xs = np.where(a)
print('wrote', OUT, 'bbox', xs.min(), xs.max(), ys.min(), ys.max(), 'solid px', int(solid.sum()))
