# 生成 DC-only 封面哈希的编码变体样本（一次性工具，产物入库）：
#   python test/gen_cover_dc_fixtures.py        （需要 Pillow + numpy）
# 写出 test/cover_vectors/dc/*.jpg：jpeg-js 编码器只出 baseline 4:4:4、不带 DRI，覆盖不到
# 4:2:0 / 4:2:2 / 灰度 / DRI+RSTn / progressive，这些用 libjpeg（Pillow）编。cover_hash.test.js
# 拿 jpeg-js 完整解码的逐像素 dHash 当参照，断言 DC-only 结果的汉明距离 ≤ 2。
import os
import numpy as np
from PIL import Image

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'cover_vectors', 'dc')


def natural(w, h, seed):
    """类封面自然图：斜向渐变 + 彩色圆斑 + 噪点（与 gen_cover_fixtures.mjs 同风格）。"""
    r = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)
    img = np.stack([xx / w * 200, yy / h * 180, (xx + yy) / (w + h) * 120 + 40], axis=-1)
    for _ in range(6):
        bx, by = r.random() * w, r.random() * h
        rad = 10 + r.random() * w * 0.4
        col = r.random(3) * 255
        k = np.clip(1 - np.hypot(xx - bx, yy - by) / rad, 0, 1)[..., None]
        img = img * (1 - k) + col * k
    img += (r.random((h, w, 1)) - 0.5) * 40
    return Image.fromarray(np.clip(np.round(img), 0, 255).astype(np.uint8), 'RGB')


def save(name, im, **kw):
    im.save(os.path.join(OUT, name), 'JPEG', **kw)


os.makedirs(OUT, exist_ok=True)
save('baseline_420_q80.jpg', natural(212, 300, 11), quality=80, subsampling=2)
save('baseline_422_q75_odd.jpg', natural(211, 299, 12), quality=75, subsampling=1)
save('baseline_gray_q85.jpg', natural(150, 97, 13).convert('L'), quality=85)
save('baseline_420_dri.jpg', natural(213, 301, 14), quality=80, subsampling=2, restart_marker_blocks=5)
save('baseline_444_dri_rows.jpg', natural(300, 169, 15), quality=90, subsampling=0, restart_marker_rows=1)
save('progressive_420.jpg', natural(200, 300, 16), quality=80, subsampling=2, progressive=True)
save('progressive_444_dri.jpg', natural(300, 200, 17), quality=85, subsampling=0, progressive=True,
     restart_marker_blocks=4)
save('progressive_gray.jpg', natural(120, 180, 18).convert('L'), quality=80, progressive=True)
# 宽 < 72 或高 < 64：小图精确路径（亮度完整 IDCT），含 4:2:0 交织。
save('small_strip_420.jpg', natural(300, 40, 19), quality=80, subsampling=2)
save('small_gray_odd.jpg', natural(37, 53, 20).convert('L'), quality=90)
