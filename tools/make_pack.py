# packs folders into one file the game unpacks on Android in one pass:
# [8 bytes: index length][index JSON: [{"p": path, "s": size, "h": hash}, ...]][the files' bytes, in index order]
# (each file's hash in the index: any change to the data changes the index, and the game unpacks it again by itself)
import hashlib, json, os, struct, sys
root, out = sys.argv[1], sys.argv[2]
names = []
for top in sys.argv[3:]:
    for d, dirs, files in os.walk(os.path.join(root, top)):
        dirs.sort()
        for f in sorted(files):
            if f.startswith("._") or f == ".DS_Store":
                continue
            names.append(os.path.relpath(os.path.join(d, f), root).replace(os.sep, "/"))
def _h(n):
    with open(os.path.join(root, n), "rb") as f:
        return hashlib.sha1(f.read()).hexdigest()[:16]
index = [{"p": n, "s": os.path.getsize(os.path.join(root, n)), "h": _h(n)} for n in names]
head = json.dumps(index).encode()
os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
with open(out, "wb") as o:
    o.write(struct.pack("<Q", len(head)))
    o.write(head)
    for n in names:
        with open(os.path.join(root, n), "rb") as f:
            o.write(f.read())
print(len(names), "files,", os.path.getsize(out), "bytes")
