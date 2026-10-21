# villain_overlay.py TD BUILTIN SID NAME ART.png ROWMAP_JSON
# ROWMAP: {"art_row": [slot, "mirror_of_art_row" or null]} - the user's drawn rows (art sheet: 64px cells, 7 frames per row)
# writes builtin/sprites/overlay_<name>.png (only the pixels that differ from what the app builds from the game file)
import sys, json, numpy as np
from PIL import Image
TD, BI, SID, NAME, ART, RM = sys.argv[1:7]
SID = int(SID)
src = open(__file__.replace('villain_overlay.py', 'recipes.py')).read().split('\ndef plan(')[0]
sys.argv = ['x', TD, '/tmp', BI, 'x']; g = {}; exec(src, g)
render = g['render']; bbox = g['bbox']; C = 64
colors = json.load(open(BI + '/colors.json')); st = colors['sets'][str(SID)]
base = np.array(Image.open(TD + '/sprites/set_%d.png' % SID).convert('RGBA'))
rows = max(int(k) for k in st['make']) + 1
H, W = max(base.shape[0], rows * C), max(base.shape[1], 7 * C)
made = np.zeros((H, W, 4), np.uint8); made[:base.shape[0], :base.shape[1]] = base
for k, lst in st['make'].items():
    s = int(k); made[s * C:(s + 1) * C] = 0
    for f, r in enumerate(lst): made[s * C:(s + 1) * C, f * C:(f + 1) * C] = render(r, base)
art = np.array(Image.open(ART).convert('RGBA'))
want = made.copy()

def row_frames(r, n, front):
    # the drawn frames, lined up on the first one (head and chest - the front end - stay put; flames and tail move)
    fr = [art[r * C:(r + 1) * C, f * C:(f + 1) * C].copy() for f in range(n)]
    if front:
        ref = fr[0][:, :, 3] > 0
        cols = slice(0, 30) if front == 'left' else slice(C - 30, C)
        for f in range(1, n):
            m = fr[f][:, :, 3] > 0
            best = max(((np.roll(np.roll(m, dy, 0), dx, 1)[:, cols] & ref[:, cols]).sum(), dx, dy) for dx in range(-4, 5) for dy in range(-4, 5))
            fr[f] = np.roll(np.roll(fr[f], best[2], 0), best[1], 1)
    return fr

for ar, spec in json.loads(RM).items():
    slot, mir, front = (spec + [None])[:3]
    srow = int(mir) if mir is not None else int(ar)
    n = len(st['frames'].get(str(slot), [])) or 4
    fr = row_frames(srow, n, front)
    if mir is not None:
        # mirrored round ONE line for every frame (each frame round its own outline made him jump about)
        xs = np.nonzero(np.any(np.stack([c[:, :, 3] > 0 for c in fr]), axis=(0, 1)))[0]
        x0, x1 = xs.min(), xs.max() + 1
        out = []
        for c in fr:
            o = np.zeros_like(c); o[:, x0:x1] = c[:, x0:x1][:, ::-1]; out.append(o)
        fr = out
    for f in range(n):
        want[slot * C:(slot + 1) * C, f * C:(f + 1) * C] = fr[f]
ma = made[:, :, 3] > 0; wa = want[:, :, 3] > 0
diff = wa & (~ma | (np.abs(made[:, :, :3].astype(int) - want[:, :, :3].astype(int)).sum(2) > 0)); er = ma & ~wa
ov = np.zeros_like(made); ov[diff, :3] = want[diff, :3]; ov[diff, 3] = 255; ov[er, 3] = 128
Image.fromarray(ov).save(BI + '/sprites/overlay_%s.png' % NAME, optimize=True)
st['overlay'] = 'overlay_%s.png' % NAME
json.dump(colors, open(BI + '/colors.json', 'w'), indent=1)
print(NAME, 'size', W, H, 'drawn px', int(diff.sum()), 'erased', int(er.sum()))
Image.fromarray(want[50 * C:52 * C, :4 * C]).save('/tmp/ov_check.png')
