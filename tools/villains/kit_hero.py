# kit_hero.py TD BUILTIN VID BASE NAME SHEET.png - a hero sheet in the completion kit's layout (48x40 cells, 19 rows x 4 ways)
# becomes variant VID of game set BASE: the sheet laid over the game's set (only the pixels that differ ship) + its frame boxes
import sys, json, numpy as np
from PIL import Image
sys.path.insert(0, __file__.rsplit('/', 1)[0])
import sprite_sheet_kit as K
TD, BI, VID, BASE, NAME, SHEET = sys.argv[1:7]; VID, BASE = int(VID), int(BASE); C = 64
OX, OY = 14, 30          # the feet in a kit cell (matched against base Goku)
sh = K.load_sheet(SHEET)
base = np.array(Image.open(TD + '/sprites/set_%d.png' % BASE).convert('RGBA'))
nmax = max(len(sh.frames[a][k]) for a in sh.rows for k in range(4))
W, H = max(base.shape[1], nmax * C), max(base.shape[0], 21 * 4 * C)
made = np.zeros((H, W, 4), np.uint8); made[:base.shape[0], :base.shape[1]] = base
src = open(__file__.replace('kit_hero.py', 'recipes.py')).read().split('\ncolors = json.load(')[0]
_argv = sys.argv; sys.argv = ['x', TD, '/tmp', BI, 'x']; g = {}; exec(src, g); sys.argv = _argv
render, bbox = g['render'], g['bbox']
bj = json.load(open(TD + '/sprites/set_%d.json' % BASE))
cands = []          # every frame of the game's set (as itself and mirrored), cut to its picture
for s0, sl in enumerate(bj['slots']):
    for f0 in range(len(sl)):
        for mir in (False, True):
            r = {'from': [s0, f0], 'ops': [['mirror']] if mir else []}
            c = render(r, base); x0, y0, x1, y1 = bbox(c)
            if c[:, :, 3].any(): cands.append((r, c[y0:y1, x0:x1], x0, y0))
def best_recipe(cell64):
    # the game frame this picture was made from: the most pixels the same, lined up by a corner of the picture
    if not cell64[:, :, 3].any(): return None
    x0, y0, x1, y1 = bbox(cell64); P = cell64[y0:y1, x0:x1]; h, w = P.shape[:2]; best = (0, None)
    for r, Q, qx, qy in cands:
        qh, qw = Q.shape[:2]
        for ax, ay in ((0, 0), (w - qw, 0), (0, h - qh), (w - qw, h - qh)):
            ox0, oy0 = max(0, ax), max(0, ay); ox1, oy1 = min(w, ax + qw), min(h, ay + qh)
            if ox1 <= ox0 or oy1 <= oy0: continue
            a1 = P[oy0:oy1, ox0:ox1]; a2 = Q[oy0 - ay:oy1 - ay, ox0 - ax:ox1 - ax]
            same = ((a1[:, :, 3] > 0) & (a2[:, :, 3] > 0) & (np.abs(a1[:, :, :3].astype(int) - a2[:, :, :3].astype(int)).sum(2) == 0)).sum()
            if same > best[0]:
                best = (same, {'from': r['from'], 'ops': r['ops'] + [['shift', int(x0 + ax - qx), int(y0 + ay - qy)]]})
    return best[1] if best[0] >= 0.3 * (P[:, :, 3] > 0).sum() else None
want = made.copy(); frames = {}; make = {}
_js, _im, PLAN, _tags = g['plan'](BASE)      # the hero's own made poses (flying: the kit's row 12 is not a flight)
anchor = bj['slots'][0][0]
for d in range(4):
    sl = 4 * 12 + d; recs = PLAN[(12, d)]
    make[str(sl)] = recs
    made[sl * C:(sl + 1) * C] = 0; want[sl * C:(sl + 1) * C] = 0
    for f, r in enumerate(recs):
        c = render(r, base); made[sl * C:(sl + 1) * C, f * C:(f + 1) * C] = c; want[sl * C:(sl + 1) * C, f * C:(f + 1) * C] = c
    frames[str(sl)] = [{'x': int(anchor['x']), 'y': int(anchor['y']), 'w': C, 'h': C} for _ in recs]
for a in sh.rows:
    for k in range(4):
        s = 4 * a + k; lst = sh.frames[a][k]
        if not lst or a == 12: continue
        want[s * C:(s + 1) * C] = 0
        recs = []
        for f, c in enumerate(lst):
            want[s * C:s * C + K.CH, f * C:f * C + K.CW] = c
            c64 = np.zeros((C, C, 4), np.uint8); c64[:K.CH, :K.CW] = c
            recs.append(best_recipe(c64))
        if all(r is not None for r in recs):
            make[str(s)] = recs
            made[s * C:(s + 1) * C] = 0
            for f, r in enumerate(recs): made[s * C:(s + 1) * C, f * C:(f + 1) * C] = render(r, base)
        frames[str(s)] = [{'x': -OX, 'y': -OY, 'w': K.CW, 'h': K.CH} for _ in lst]
ma = made[:, :, 3] > 0; wa = want[:, :, 3] > 0
diff = wa & (~ma | (np.abs(made[:, :, :3].astype(int) - want[:, :, :3].astype(int)).sum(2) > 0)); er = ma & ~wa
ov = np.zeros_like(made); ov[diff, :3] = want[diff, :3]; ov[diff, 3] = 255; ov[er, 3] = 128
Image.fromarray(ov).save(BI + '/sprites/overlay_%s.png' % NAME, optimize=True)
colors = json.load(open(BI + '/colors.json'))
colors['variants'] = [v for v in colors['variants'] if int(v.get('id', 0)) != VID]
colors['variants'].append({'id': VID, 'base': BASE, 'name': NAME.upper().replace('_', ' '), 'hue': 0, 'sat': 1.0, 'val': 1.0, 'swaps': {},
                           'canvas': [W, H], 'make': make, 'overlay': 'overlay_%s.png' % NAME, 'frames': frames})
json.dump(colors, open(BI + '/colors.json', 'w'), indent=1)
print(NAME, 'rows rebuilt from the game', len(make), 'frames per row up to', nmax, 'canvas', W, H, 'drawn', int(diff.sum()), 'erased', int(er.sum()))
