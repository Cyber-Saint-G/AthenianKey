import sys, os, numpy as np
from PIL import Image, ImageOps, ImageFilter
src_dir, out_dir = sys.argv[1], sys.argv[2]
LAYERS = [(5, .34, .54), (14, .48, .70), (30, .62, .84)]     # (θόλωμα σε CSS px, αρχή, πλήρες) όπως πριν στο CSS
CSS_H = 784                                                  # ύψος φόντου σε κινητό (118svh)
def smooth(x): x = np.clip(x, 0, 1); return x * x * (3 - 2 * x)
for k, box, q in [('athens', (1600, 2400), 80), ('zakynthos', (1600, 2400), 80), ('crete', (2800, 1600), 76)]:
    im = ImageOps.exif_transpose(Image.open(f'{src_dir}/{k}.jpg')).convert('RGB'); im.thumbnail(box, Image.LANCZOS)
    W, H = im.size; scale = H / CSS_H
    out = np.asarray(im, dtype=np.float32)
    y = (np.arange(H) / (H - 1))[:, None, None]
    for sig, a, b in LAYERS:
        bl = np.asarray(im.filter(ImageFilter.GaussianBlur(sig * scale)), dtype=np.float32)
        m = smooth((y - a) / (b - a))
        out = out * (1 - m) + bl * m
    p = f'{out_dir}/bg-{k}.jpg'
    Image.fromarray(np.clip(out, 0, 255).astype(np.uint8)).save(p, quality=q, optimize=True, progressive=True)
    print(k, (W, H), os.path.getsize(p) // 1024, 'KB')
