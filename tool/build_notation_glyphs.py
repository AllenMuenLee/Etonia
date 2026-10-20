"""Builds lib/features/editor/ai/notation_glyphs.dart from a single-line SVG
font, by default third_party/ems_readability/EMSReadability.svg.

    python tool/build_notation_glyphs.py

Glyphs are written in NotationFont's grid: capitals and digits run from
y = 0 at the top to y = 10 on the baseline, lowercase x-height sits at
y = 3.8, and descenders reach y = 13. x starts at each glyph's left ink edge.
A stroke smaller than a pen dot becomes a dot (one point).
"""
import os
import re
import sys
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, 'third_party', 'ems_readability', 'EMSReadability.svg')
OUTPUT = os.path.join(ROOT, 'lib', 'features', 'editor', 'ai', 'notation_glyphs.dart')

# Measured from the glyphs, not the font's declared metrics, which differ.
BASELINE = 19.0
CAP = 655.0
X_HEIGHT = 482.0
ASCENDER = 715.0
DESCENDER = -200.0

# Grid positions.
GRID_X_TOP = 3.8
GRID_DEPTH = 3.0

# Handwriting runs narrower than the typeface it came from.
NARROW = 0.86

SCALE = 10 / (CAP - BASELINE)

# The characters NotationFont writes from this font. The rest of its
# characters (some mathematics) stay hand-drawn in notation_font.dart.
CHARACTERS = (
    '0123456789'
    'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    'abcdefghijklmnopqrstuvwxyz'
    '.,:;!?\'"()[]{}|_~#%$&@+-=*×·÷/\\^<>±°'
)

TOKEN = re.compile(r'[MmLlHhVvZz]|-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?')


def parse_path(d):
    """Polylines of an SVG path that uses only straight segments."""
    tokens = TOKEN.findall(d)
    strokes, current, x, y, start = [], None, 0.0, 0.0, (0.0, 0.0)
    i, command = 0, None
    while i < len(tokens):
        if tokens[i].isalpha():
            command = tokens[i]
            i += 1
        relative = command.islower()
        kind = command.upper()
        if kind == 'Z':
            current.append(start)
            x, y = start
            continue
        if kind == 'H':
            x = (x if relative else 0) + float(tokens[i])
            i += 1
        elif kind == 'V':
            y = (y if relative else 0) + float(tokens[i])
            i += 1
        else:
            dx, dy = float(tokens[i]), float(tokens[i + 1])
            i += 2
            x, y = (x + dx, y + dy) if relative else (dx, dy)
        if kind == 'M':
            start = (x, y)
            current = [(x, y)]
            strokes.append(current)
            command = 'l' if relative else 'L'
        else:
            current.append((x, y))
    return strokes


def load(path):
    text = re.sub(r'<!DOCTYPE[^>]*>', '', open(path, encoding='utf-8').read())
    ns = {'s': 'http://www.w3.org/2000/svg'}
    glyphs = {}
    for glyph in ET.fromstring(text).findall('.//s:glyph', ns):
        char = glyph.get('unicode')
        if char is not None and len(char) == 1:
            glyphs[char] = parse_path(glyph.get('d', ''))
    return glyphs


def grid_y(y, lowercase):
    if y < BASELINE:
        return 10 + (BASELINE - y) / (BASELINE - DESCENDER) * GRID_DEPTH
    if lowercase:
        if y <= X_HEIGHT:
            return 10 - (y - BASELINE) / (X_HEIGHT - BASELINE) * (10 - GRID_X_TOP)
        return GRID_X_TOP - (y - X_HEIGHT) / (ASCENDER - X_HEIGHT) * GRID_X_TOP
    g = 10 - (y - BASELINE) * SCALE
    # Little reaches above a capital; what does is kept close.
    return g * 0.4 if g < 0 else g


def single_storey_g(glyphs):
    """A hand's g: the bowl of q, then up to the top of its stem and down,
    so the stroke ends in the tail, which is curled at run time."""
    (stem_bottom, stem_top, *bowl), = glyphs['q']
    return [bowl + [stem_top, stem_bottom]]


def convert(char, strokes):
    lowercase = 'a' <= char <= 'z'
    points = [[(x * SCALE * NARROW, grid_y(y, lowercase)) for x, y in s] for s in strokes]
    points = [s for s in points if s]
    if not points:
        return 0.0, []
    left = min(p[0] for s in points for p in s)
    right = max(p[0] for s in points for p in s)
    out = []
    for stroke in points:
        stroke = [(x - left, y) for x, y in stroke]
        xs = [p[0] for p in stroke]
        ys = [p[1] for p in stroke]
        if max(max(xs) - min(xs), max(ys) - min(ys)) < 1.0:
            # A dot drawn as a tiny outline is a dot.
            stroke = [((max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2)]
        else:
            # Drop repeated points.
            stroke = [p for k, p in enumerate(stroke)
                      if k == 0 or abs(p[0] - stroke[k - 1][0]) + abs(p[1] - stroke[k - 1][1]) > 1e-3]
        out.append(stroke)
    if char in 'ij':
        # The font's dots float high above a hand's.
        out = [[(s[0][0], 2.2)] if len(s) == 1 else s for s in out]
    if char in ',;':
        # The font outlines its comma; a pen flicks it.
        out = [s if len(s) == 1 else _comma(s) for s in out]
    return right - left, out


def _comma(outline):
    middle = (min(p[0] for p in outline) + max(p[0] for p in outline)) / 2
    return [(middle + 0.25, 9.5), (middle + 0.3, 10.5), (middle - 0.35, 11.8)]


def dart_string(char):
    escaped = char.replace('\\', '\\\\').replace("'", "\\'").replace('$', '\\$')
    return "'" + escaped + "'"


def number(value):
    text = f'{value:.2f}'.rstrip('0').rstrip('.')
    return '0' if text in ('-0', '') else text


def main():
    source = sys.argv[1] if len(sys.argv) > 1 else SOURCE
    glyphs = load(source)
    glyphs['g'] = single_storey_g(glyphs)
    missing = [c for c in CHARACTERS if c not in glyphs]
    if missing:
        sys.exit('Font lacks: ' + ''.join(missing))
    lines = [
        '// GENERATED by tool/build_notation_glyphs.py. Do not edit by hand.',
        '//',
        '// Glyphs from EMS Readability by Sheldon B. Michaels and Windell H. Oskay,',
        '// a single-line derivative of Source Sans Pro by Paul D. Hunt, Adobe.',
        '// Licensed under the SIL Open Font License 1.1: see',
        '// third_party/ems_readability/OFL.txt.',
        '',
        '/// Each character\'s advance width and pen strokes in NotationFont\'s',
        '/// grid, a stroke as flat x, y pairs.',
        'const Map<String, (double, List<List<double>>)> notationGlyphs =',
        '    <String, (double, List<List<double>>)>{',
    ]
    for char in CHARACTERS:
        width, strokes = convert(char, glyphs[char])
        body = ', '.join(
            '<double>[' + ', '.join(number(v) for p in s for v in p) + ']' for s in strokes)
        lines.append(f'      {dart_string(char)}: ({number(width)}, <List<double>>[{body}]),')
    lines.append('    };')
    with open(OUTPUT, 'w', encoding='utf-8', newline='\n') as out:
        out.write('\n'.join(lines) + '\n')
    print('wrote', os.path.relpath(OUTPUT, ROOT), len(CHARACTERS), 'glyphs')


if __name__ == '__main__':
    main()
