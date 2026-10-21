#!/usr/bin/env python3
"""
sprite_sheet_kit.py  -  complete "Legacy of Goku II"-style player sprite sheets.

Needs only Python 3 + Pillow + numpy  (pip install pillow numpy).

The sheets this kit reads/writes have a fixed layout:
  * one ROW per action (default 19 rows: actions 0-9, 11-14, 16-20; actions 10 and 15 are unused)
  * each row has 4 DIRECTION blocks: down, up, left, right
  * each block has N frame CELLS (N is the same for all 4 blocks: Goku N=7, Tien N=12)
  * a cell is 48x40 px at 1x; the sprite's feet sit at y=38, a 16-wide sprite starts at x=14
Two file flavours are accepted:
  * "raw"     : 1x, transparent background          (e.g. goku_base_full_spritesheet_raw.png, 1344x760)
  * "labeled" : 3x, dark background, labels on left  (e.g. goku_base_full_spritesheet.png,     4474x2460)
Both are auto-detected by load_sheet().

Typical use (see AI_INSTRUCTIONS.md):
    from sprite_sheet_kit import *
    goku = load_sheet('goku_base_full_spritesheet_raw.png')
    tien = load_sheet('tien_full_spritesheet_raw.png')
    print(report(tien, goku))                           # what is missing / borrowed
    print(color_families(goku)); print(color_families(tien))
    cmap = {**ramp_map(G['orange/brown'], T['green']), ...}   # build per family
    new  = head_swap(goku, tien, cell(goku,'victory','down',1), 'down', cmap)
    zoom(new, 'check.png')                              # LOOK at it before using it
    set_action(tien, 'victory', 'down', [cell(tien,'idle','down',0), new])
    save_sheet(tien, 'tien_out', title='TIEN')          # writes tien_out.png + tien_out_raw.png
"""
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from collections import Counter

# ----------------------------------------------------------------------------- layout
ACTION_NAMES = {0: 'idle', 1: 'walk', 2: 'hurt', 3: 'knocked down', 4: 'power up', 5: 'ki blast',
                6: 'combo', 7: 'punch', 8: 'dash / kick', 9: 'transform', 10: 'action 10', 11: 'victory',
                12: 'action 12', 13: 'action 13', 14: 'action 14', 15: 'action 15', 16: 'special melee',
                17: 'halo', 18: 'special energy A', 19: 'special energy B', 20: 'climb / other'}
ALIASES = {'dash': 8, 'kick': 8, 'ssj': 9, 'transform': 9, 'special melee': 16, 'melee': 16,
           'special a': 18, 'special energy a': 18, 'beam a': 18, 'special b': 19, 'special energy b': 19,
           'beam b': 19, 'climb': 20, 'lying': 12, 'sleep': 12}
DEFAULT_ROWS = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 16, 17, 18, 19, 20]
DIRS = ['down', 'up', 'left', 'right']
CW, CH = 48, 40                      # cell size at 1x
LAB_S, LAB_LW, LAB_TH, LAB_GAP = 3, 330, 150, 24   # labeled-sheet geometry
LAB_BG = [(32, 27, 52), (27, 23, 45), (22, 18, 36)]

def act_id(a):
    if isinstance(a, int): return a
    k = a.lower().strip()
    if k in ALIASES: return ALIASES[k]
    for i, n in ACTION_NAMES.items():
        if n == k: return i
    raise KeyError('unknown action %r' % a)

def dir_id(d):
    return d if isinstance(d, int) else DIRS.index(d.lower())

# ----------------------------------------------------------------------------- load / save
class Sheet:
    """frames[action_id][dir_id] = list of 48x40 RGBA numpy arrays"""
    def __init__(self, frames, rows, n):
        self.frames, self.rows, self.n = frames, rows, n

def _empty():
    return np.zeros((CH, CW, 4), np.uint8)

def load_sheet(path, rows=None):
    im = Image.open(path).convert('RGBA'); a = np.array(im); H, W = a.shape[:2]
    rows = rows or DEFAULT_ROWS
    labeled = a[..., 3].min() == 255          # no transparency -> labeled 3x sheet
    if not labeled:
        if W % (4 * CW) or H % CH: raise ValueError('raw sheet size %dx%d is not a multiple of 4*48 x 40' % (W, H))
        n = W // (4 * CW); grid = a
        if H // CH != len(rows): raise ValueError('sheet has %d rows but %d action ids given' % (H // CH, len(rows)))
        def get(r, k, i):
            x = (k * n + i) * CW; return grid[r * CH:(r + 1) * CH, x:x + CW].copy()
    else:
        S = LAB_S
        n = round((W - LAB_LW - 3 * LAB_GAP - 40) / (4 * CW * S))
        nr = round((H - LAB_TH - 30) / (CH * S))
        if nr != len(rows): raise ValueError('labeled sheet has %d rows but %d action ids given' % (nr, len(rows)))
        bg = np.zeros((H, W), bool)
        for c in LAB_BG: bg |= (a[..., 0] == c[0]) & (a[..., 1] == c[1]) & (a[..., 2] == c[2])
        b = a.copy(); b[bg] = 0
        def get(r, k, i):
            x = LAB_LW + k * (n * CW * S + LAB_GAP) + i * CW * S; y = LAB_TH + r * CH * S
            return b[y:y + CH * S:S, x:x + CW * S:S].copy()      # nearest-neighbour 3x -> 1x
    frames = {}
    for r, aid in enumerate(rows):
        frames[aid] = []
        for k in range(4):
            lst = [get(r, k, i) for i in range(n)]
            while lst and lst[-1][..., 3].max() == 0: lst.pop()   # drop trailing empty cells
            frames[aid].append(lst)
    return Sheet(frames, list(rows), n)

def save_sheet(sh, out_prefix, title='CHARACTER', rows=None):
    """writes <out_prefix>_raw.png (1x transparent) and <out_prefix>.png (3x labeled), same layout as input"""
    rows = rows or [a for a in sh.rows if any(sh.frames.get(a, [[]] * 4)[k] for k in range(4))]
    n = max(len(sh.frames[a][k]) for a in rows for k in range(4))
    raw = np.zeros((len(rows) * CH, 4 * n * CW, 4), np.uint8)
    for r, a in enumerate(rows):
        for k in range(4):
            for i, c in enumerate(sh.frames[a][k]):
                x = (k * n + i) * CW; raw[r * CH:(r + 1) * CH, x:x + CW] = c
    Image.fromarray(raw).save(out_prefix + '_raw.png')
    S = LAB_S; Wr, Hr = 4 * n * CW, len(rows) * CH
    W = LAB_LW + Wr * S + LAB_GAP * 3 + 40; H = LAB_TH + Hr * S + 30
    im = Image.new('RGBA', (W, H), LAB_BG[2] + (255,)); dr = ImageDraw.Draw(im)
    def font(sz):
        for f in ('DejaVuSans-Bold.ttf', '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', 'arialbd.ttf', 'Arial Bold.ttf'):
            try: return ImageFont.truetype(f, sz)
            except Exception: pass
        return ImageFont.load_default()
    dr.text((30, 24), title, font=font(52), fill=(255, 190, 40))
    for k in range(4): dr.text((LAB_LW + k * (n * CW * S + LAB_GAP) + 8, LAB_TH - 44), DIRS[k], font=font(30), fill=(170, 200, 255))
    big = Image.fromarray(raw).resize((Wr * S, Hr * S), Image.NEAREST)
    for r, a in enumerate(rows):
        y = LAB_TH + r * CH * S
        dr.rectangle([20, y + 2, W - 20, y + CH * S - 2], fill=LAB_BG[r % 2] + (255,))
        dr.text((30, y + CH * S // 2 - 26), ACTION_NAMES[a], font=font(30), fill=(255, 255, 255))
        dr.text((30, y + CH * S // 2 + 8), 'slots %d-%d' % (a * 4, a * 4 + 3), font=font(22), fill=(140, 140, 170))
    for k in range(4):
        x0 = LAB_LW + k * (n * CW * S + LAB_GAP)
        blk = big.crop((k * n * CW * S, 0, (k + 1) * n * CW * S, Hr * S)); im.alpha_composite(blk, (x0, LAB_TH))
    im.convert('RGB').save(out_prefix + '.png')
    return out_prefix + '.png', out_prefix + '_raw.png'

# ----------------------------------------------------------------------------- access
def cell(sh, action, direction, i=0):
    return sh.frames[act_id(action)][dir_id(direction)][i].copy()

def get_action(sh, action, direction):
    return [c.copy() for c in sh.frames[act_id(action)][dir_id(direction)]]

def set_action(sh, action, direction, cells, mirror_right=True):
    """set a direction's frame list. Setting 'left' also sets 'right' as the mirror (unless mirror_right=False)."""
    a, d = act_id(action), dir_id(direction)
    if a not in sh.frames: sh.frames[a] = [[], [], [], []]; sh.rows = sorted(set(sh.rows) | {a})
    sh.frames[a][d] = [c.copy() for c in cells]
    if d == 2 and mirror_right: sh.frames[a][3] = [mirror(c) for c in cells]

def mirror(c):
    """mirror a cell left<->right keeping the sprite anchored (cells are symmetric around x=22 for 16-wide sprites)"""
    m = c[:, ::-1].copy(); out = _empty(); out[:, :CW - 4] = m[:, 4:]; return out

def pad(cells, n):
    cells = list(cells)
    while len(cells) < n: cells.append(cells[-1])
    return cells

# ----------------------------------------------------------------------------- analysis
def _h(c): return hash(c.tobytes())

def report(sh, ref=None):
    """lists, per action, unique frames per direction and which other action it duplicates (= borrowed)."""
    lines = []
    for a in sorted(ACTION_NAMES):
        if a not in sh.frames or not any(sh.frames[a]):
            if ref is not None and a in ref.frames and any(ref.frames[a]): lines.append('%-18s MISSING (reference has it)' % ACTION_NAMES[a])
            continue
        hs = [_h(c) for k in range(4) for c in sh.frames[a][k]]
        dup = []
        for b in sh.frames:
            if b == a: continue
            hb = set(_h(c) for k in range(4) for c in sh.frames[b][k])
            ov = sum(h in hb for h in hs) / len(hs)
            if ov > 0.5: dup.append('%s %d%%' % (ACTION_NAMES[b], ov * 100))
        u = ' '.join('%d/%d' % (len(set(_h(c) for c in sh.frames[a][k])), len(sh.frames[a][k])) for k in range(4))
        rf = ''
        if ref is not None and a in ref.frames:
            rf = '  (reference: %s)' % ' '.join(str(len(set(_h(c) for c in ref.frames[a][k]))) for k in range(4))
        lines.append('%-18s unique/total %-22s %s%s' % (ACTION_NAMES[a], u, ('SHARES frames with ' + ', '.join(dup)) if dup else 'own frames', rf))
    return '\n'.join(lines)

def colors(c):
    m = c[..., 3] > 0; return Counter(tuple(int(v) for v in p) for p in c[m][:, :3])

def palette(sh):
    cnt = Counter()
    for a in sh.frames:
        for k in range(4):
            for c in sh.frames[a][k]: cnt.update(colors(c))
    return cnt

# ----------------------------------------------------------------------------- colour mapping
def color_families(sh_or_cells, min_count=3):
    """Group the colours used by a sheet (or list of cells) into hue families ("ramps"), each sorted dark->light.
    Returns {family_name: [rgb, ...]}. Print it, then build a colour map with ramp_map()."""
    import colorsys
    cnt = Counter()
    if isinstance(sh_or_cells, Sheet): cnt = palette(sh_or_cells)
    else:
        for c in sh_or_cells: cnt.update(colors(c))
    fam = {}
    for col, n in cnt.items():
        if n < min_count: continue
        r, g, b = [v / 255 for v in col]; h, s, v = colorsys.rgb_to_hsv(r, g, b)
        if v < 0.12: name = 'black'
        elif s < 0.18: name = 'grey/white'
        else:
            hue = h * 360
            name = ('red' if hue < 12 or hue >= 340 else 'orange/brown' if hue < 40 else 'yellow' if hue < 70 else
                    'green' if hue < 160 else 'cyan' if hue < 200 else 'blue' if hue < 260 else 'purple' if hue < 300 else 'pink')
            if name in ('orange/brown', 'red', 'pink') and s < 0.55 and v > 0.6: name = 'skin'
            elif name == 'orange/brown' and s >= 0.95: name = 'orange'
        fam.setdefault(name, []).append(tuple(int(x) for x in col))
    return {k: sorted(v, key=lambda c: 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2]) for k, v in fam.items()}

def ramp_map(src_ramp, dst_ramp):
    """map a dark->light list of colours onto another by relative brightness position (lengths may differ)"""
    out = {}
    for i, c in enumerate(src_ramp):
        j = round(i * (len(dst_ramp) - 1) / max(1, len(src_ramp) - 1)); out[tuple(c)] = tuple(dst_ramp[j])
    return out

def learn_color_map(src, dst, pairs):
    """ONLY when dst was drawn on src's exact skeleton (same pose pixels): overlay the frames listed in
    pairs=[(action, direction, index), ...] and take the most common dst colour under each src colour."""
    co = {}
    for a, k, i in pairs:
        s, d = cell(src, a, k, i), cell(dst, a, k, i)
        m = (s[..., 3] > 0) & (d[..., 3] > 0)
        for p, q in zip(map(tuple, s[m][:, :3]), map(tuple, d[m][:, :3])):
            co.setdefault(p, Counter())[q] += 1
    return {tuple(int(x) for x in p): tuple(int(x) for x in c.most_common(1)[0][0]) for p, c in co.items()}

def recolor(c, cmap, rows=None):
    """apply {rgb: rgb}. rows=(r0,r1) limits it to a horizontal band (e.g. only boots)."""
    out = c.copy(); r0, r1 = rows or (0, CH)
    for y in range(r0, r1):
        for x in range(CW):
            if out[y, x, 3]:
                t = tuple(int(v) for v in out[y, x, :3])
                if t in cmap: out[y, x, :3] = cmap[t]
    return out

def nearest_palette(c, pal):
    """snap every pixel to the closest colour of `pal` (list of rgb) - keeps the sheet on a legal GBA palette"""
    P = np.array(list(pal), np.int32); out = c.copy(); m = out[..., 3] > 0
    px = out[m][:, :3].astype(np.int32)
    idx = ((px[:, None, :] - P[None]) ** 2).sum(-1).argmin(1); out[m, :3] = P[idx]; return out

# ----------------------------------------------------------------------------- head swap
def _bbox(c):
    ys, xs = np.nonzero(c[..., 3]); return (ys.min(), ys.max(), xs.min(), xs.max()) if len(ys) else None

def head_box(sh, direction, head_rows=13):
    """the head = top `head_rows` rows of the character's IDLE frame for that direction"""
    c = cell(sh, 'idle', direction if direction != 'right' else 'left', 0)
    y0 = _bbox(c)[0]; return c, y0, y0 + head_rows

def find_head(frame, src_sheet, direction, head_rows=13):
    """template-match the source character's idle head inside `frame`; returns (dy, dx) offset vs the idle pose"""
    tmpl, y0, y1 = head_box(src_sheet, direction, head_rows)
    T = tmpl[y0:y1]; pts = [(r + y0, x) for r in range(T.shape[0]) for x in range(CW) if T[r, x, 3]]
    best = None
    for dy in range(-12, 16):
        for dx in range(-14, 15):
            s = 0
            for r, x in pts:
                rr, xx = r + dy, x + dx
                if 0 <= rr < CH and 0 <= xx < CW and frame[rr, xx, 3]:
                    s += 2 if (frame[rr, xx, :3] == tmpl[r, x, :3]).all() else 0.3
                else: s -= 0.5
            if best is None or s > best[0]: best = (s, dy, dx)
    return best   # (score, dy, dx); a low score means the head was not found (e.g. lying down) -> check by eye

def head_swap(src_sheet, dst_sheet, frame, direction, cmap=None, head_rows=13, clear_colors=None, override=None):
    """Turn a frame of the source character (e.g. Goku) into the destination character:
       1. find the source head, 2. erase it (plus connected hair), 3. recolour the body with cmap,
       4. paste the destination's idle head at the same offset.  Mirror 'left' results for 'right'."""
    d = 'left' if direction == 'right' else direction
    if direction == 'right': frame = mirror(frame)
    score, dy, dx = override or find_head(frame, src_sheet, d, head_rows)
    st, sy0, sy1 = head_box(src_sheet, d, head_rows)
    dt, dy0, dy1 = head_box(dst_sheet, d, head_rows)
    out = frame.copy()
    hair = clear_colors
    if hair is None:   # colours that belong to the source head = head colours not present in the source torso
        torso = colors(st[sy1:]); hair = set(colors(st[sy0:sy1])) - set(torso)
        hair |= {(0, 0, 0)}
    region = np.zeros((CH, CW), bool)
    for r in range(sy0, sy1 + 1):
        for x in range(CW):
            if st[r, x, 3]:
                for a in (-1, 0, 1):
                    for b in (-1, 0, 1):
                        rr, xx = r + dy + a, x + dx + b
                        if 0 <= rr < CH and 0 <= xx < CW: region[rr, xx] = True
    skin_head = set(colors(st[sy0:sy1]))
    for rr, xx in zip(*np.nonzero(region)):
        if out[rr, xx, 3] and tuple(out[rr, xx, :3]) in skin_head: out[rr, xx] = 0
    changed = True        # flood away hair pixels touching the erased area (spiky hair sticks out of the template)
    while changed:
        changed = False
        for rr in range(0, min(CH, sy1 + dy + 2)):
            for xx in range(CW):
                if out[rr, xx, 3] and tuple(out[rr, xx, :3]) in hair and region[max(0, rr - 1):rr + 2, max(0, xx - 1):xx + 2].any():
                    out[rr, xx] = 0; region[rr, xx] = True; changed = True
    if cmap: out = recolor(out, cmap)
    for r in range(dy0, dy1):
        for x in range(CW):
            if dt[r, x, 3]:
                rr, xx = r + dy, x + dx
                if 0 <= rr < CH and 0 <= xx < CW: out[rr, xx] = dt[r, x]
    out = fill_holes(out)
    return mirror(out) if direction == 'right' else out

def fill_holes(c, passes=2):
    """fill transparent pixels that are surrounded (>=3 of 4 neighbours) by sprite pixels"""
    out = c.copy()
    for _ in range(passes):
        a = out[..., 3] > 0
        for y in range(1, CH - 1):
            for x in range(1, CW - 1):
                if not a[y, x]:
                    nb = [out[y + dy, x + dx] for dy, dx in ((0, 1), (1, 0), (0, -1), (-1, 0)) if a[y + dy, x + dx]]
                    if len(nb) >= 3:
                        col = Counter(tuple(n[:3]) for n in nb).most_common(1)[0][0]
                        out[y, x, :3] = col; out[y, x, 3] = 255
    return out

# ----------------------------------------------------------------------------- hand editing
def paste(base, part, dy=0, dx=0):
    """paste non-transparent pixels of `part` (a cell or a crop) onto base, shifted"""
    out = base.copy(); h, w = part.shape[:2]
    for y in range(h):
        for x in range(w):
            if part[y, x, 3] and 0 <= y + dy < CH and 0 <= x + dx < CW: out[y + dy, x + dx] = part[y, x]
    return out

def erase(c, y0, y1, x0, x1):
    out = c.copy(); out[y0:y1, x0:x1] = 0; return out

def paint(c, rows, legend, r0, c0, mirror_x=None):
    """ASCII pixel painting. legend maps a char to an RGB tuple; '.' = leave as is, ' ' = leave, '_' = erase.
       mirror_x=column -> also paint the mirror image around that column (for symmetric front poses)."""
    out = c.copy()
    for i, line in enumerate(rows):
        for j, ch in enumerate(line):
            if ch in '. ': continue
            for col in ([c0 + j] + ([2 * mirror_x - (c0 + j)] if mirror_x is not None else [])):
                y = r0 + i
                if 0 <= y < CH and 0 <= col < CW:
                    if ch == '_': out[y, col] = 0
                    else: out[y, col, :3] = legend[ch]; out[y, col, 3] = 255
    return out

def grid(c, legend=None, rows=None):
    """text dump of a cell: each pixel as a 1-char code (auto legend printed). Use it to plan paint()."""
    cols = sorted(colors(c), key=lambda t: sum(t))
    codes = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
    legend = legend or {codes[i]: col for i, col in enumerate(cols)}
    inv = {v: k for k, v in legend.items()}
    r0, r1 = rows or (0, CH)
    txt = ['legend: ' + '  '.join('%s=%s' % (k, v) for k, v in legend.items())]
    txt.append('    ' + ''.join(str(x % 10) for x in range(CW)))
    for y in range(r0, r1):
        txt.append('%3d ' % y + ''.join(inv.get(tuple(int(v) for v in c[y, x, :3]), '?') if c[y, x, 3] else '.' for x in range(CW)))
    return '\n'.join(txt)

# ----------------------------------------------------------------------------- previews
def zoom(cells, path, scale=8, bg=(60, 60, 70), cols=8):
    """save a zoomed preview of one cell or a list of cells - always LOOK at results before saving the sheet"""
    if isinstance(cells, np.ndarray): cells = [cells]
    rows = (len(cells) + cols - 1) // cols; W = min(len(cells), cols)
    im = Image.new('RGBA', (W * (CW + 2) * scale, rows * (CH + 2) * scale), bg + (255,))
    for i, c in enumerate(cells):
        t = Image.fromarray(c).resize((CW * scale, CH * scale), Image.NEAREST)
        im.alpha_composite(t, ((i % cols) * (CW + 2) * scale, (i // cols) * (CH + 2) * scale))
    im.convert('RGB').save(path); return path

def preview_action(sh, action, path, scale=5):
    a = act_id(action); cells = []
    for k in range(4): cells += sh.frames[a][k] + [_empty()]
    return zoom(cells, path, scale, cols=max(1, max(len(sh.frames[a][k]) for k in range(4)) + 1))

if __name__ == '__main__':
    import sys
    if len(sys.argv) >= 2:
        s = load_sheet(sys.argv[1]); ref = load_sheet(sys.argv[2]) if len(sys.argv) > 2 else None
        print('cells per direction:', s.n); print(report(s, ref))
    else:
        print(__doc__)
