"""Render every Etonia animation: PNG frames, sprite sheet, animated WebP, a GIF preview, and
the 256 px frames the app bundles (`<out>/ui/<name>/<name>_NN.png`).

Usage: python tool/etonia_rig/export.py [out_dir] [width] [animation ...]

Layers come from build_layers.py (run prepare_source.py + build_layers.py first when the
drawing changes).  Frames render in parallel.
"""
import json
import shutil
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
import rig  # noqa: E402
import animations  # noqa: E402
from animations import ANIMATIONS, FPS  # noqa: E402

UI_WIDTH = 256


def spread(total, n):
    """Split `total` into n integer durations that add up exactly."""
    return [round((k + 1) * total / n) - round(k * total / n) for k in range(n)]


def on_white(im):
    bg = Image.new('RGBA', im.size, (255, 255, 255, 255))
    bg.alpha_composite(im)
    return bg.convert('RGB')


def render_frame(job):
    name, i, size = job
    fn, n = ANIMATIONS[name]
    return name, i, rig.render(fn(i, n), size=size)


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else 'assets/animations/etonia_loops')
    width = int(sys.argv[2]) if len(sys.argv) > 2 else 512
    only = sys.argv[3:] or list(ANIMATIONS)
    height = round(rig.CANVAS_H * width / rig.CANVAS_W)
    ui_size = (UI_WIDTH, round(rig.CANVAS_H * UI_WIDTH / rig.CANVAS_W))
    out.mkdir(parents=True, exist_ok=True)

    jobs = [(name, i, (width, height)) for name in only for i in range(ANIMATIONS[name][1])]
    frames = {name: [None] * ANIMATIONS[name][1] for name in only}
    with ProcessPoolExecutor() as pool:
        for name, i, im in pool.map(render_frame, jobs, chunksize=2):
            frames[name][i] = im

    manifest = {'fps': FPS, 'frame_size': [width, height], 'ui_frame_size': list(ui_size),
                'canvas': [rig.CANVAS_W, rig.CANVAS_H],
                'run_step_px': animations.RUN_STEP,
                'run_travel_per_loop_px': animations.RUN_TRAVEL_PER_LOOP, 'animations': {}}
    for name in only:
        n = ANIMATIONS[name][1]
        ms = spread(round(1000 * n / FPS), n)
        d = out / name
        if d.exists():
            shutil.rmtree(d)
        d.mkdir()
        ui = out / 'ui' / name
        if ui.exists():
            shutil.rmtree(ui)
        ui.mkdir(parents=True)
        for i, f in enumerate(frames[name]):
            f.save(d / f'{name}_{i:02d}.png', optimize=True)
            small = f.convert('RGBa').resize(ui_size, Image.LANCZOS).convert('RGBA')
            small.save(ui / f'{name}_{i:02d}.png', optimize=True)
        sheet = Image.new('RGBA', (width * n, height), (0, 0, 0, 0))
        for i, f in enumerate(frames[name]):
            sheet.paste(f, (i * width, 0))
        sheet.save(out / f'{name}_sheet.png', optimize=True)
        frames[name][0].save(out / f'{name}.webp', save_all=True, append_images=frames[name][1:],
                             duration=ms, loop=0, lossless=True, minimize_size=False)
        white = [on_white(f) for f in frames[name]]
        white[0].save(out / f'{name}_preview.gif', save_all=True, append_images=white[1:],
                      duration=[round(m / 10) * 10 for m in ms], loop=0, optimize=False, disposal=2)
        manifest['animations'][name] = {
            'frames': n, 'duration_ms': sum(ms), 'sheet': f'{name}_sheet.png',
            'webp': f'{name}.webp', 'frames_dir': name, 'ui_dir': f'ui/{name}',
        }
        print(name, 'done', n, 'frames')
    json.dump(manifest, open(out / 'manifest.json', 'w'), indent=2)


if __name__ == '__main__':
    main()
