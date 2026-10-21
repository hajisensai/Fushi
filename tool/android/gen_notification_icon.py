"""从启动图标前景生成 Android 状态栏 / 通知小图标 ic_stat_fushi.xml。

Android 渲染 smallIcon 只取 alpha 通道：彩色图标会被剪影成一团（BUG：状态栏
出现「反相」黑块），所以必须是单色白矢量。本脚本把
drawable-xxxhdpi/ic_launcher_foreground.png 的不透明区（去投影）描成路径，
眼睛镂空，输出 evenOdd 单路径 vector。换 logo 后在仓库根重跑：

    python -I tool/android/gen_notification_icon.py [preview.png]

依赖 opencv-python、numpy、Pillow。
"""
import os
import sys

import cv2
import numpy as np
from PIL import Image

_RES = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "..", "fushi", "android", "app", "src", "main", "res",
)
SRC = os.path.join(_RES, "drawable-xxxhdpi", "ic_launcher_foreground.png")
OUT_XML = os.path.join(_RES, "drawable", "ic_stat_fushi.xml")
PREVIEW = sys.argv[1] if len(sys.argv) > 1 else None
MODE = "eyes"

im = np.array(Image.open(SRC).convert("RGBA")).astype(np.int32)
alpha = im[..., 3]
lum = (im[..., 0] * 299 + im[..., 1] * 587 + im[..., 2] * 114) // 1000
body = ((alpha > 200)).astype(np.uint8) * 255
body = cv2.morphologyEx(body, cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))
# 只保留最大连通块（去掉投影残渣）
n, lab, stats, _ = cv2.connectedComponentsWithStats(body)
big = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
body = (lab == big).astype(np.uint8) * 255
body = cv2.morphologyEx(body, cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8))

dark = ((lum < 110) & (alpha > 200)).astype(np.uint8) * 255
# 去掉细虚线/须状线：开运算后只留块状特征（眼、嘴、耳尖）
dark = cv2.morphologyEx(dark, cv2.MORPH_OPEN, np.ones((7, 7), np.uint8))
n, lab, stats, _ = cv2.connectedComponentsWithStats(dark)
holes = np.zeros_like(dark)
bys = np.nonzero(body)[0]
ear_line = bys.min() + 0.35 * (bys.max() - bys.min())
for i in range(1, n):
    a = stats[i, cv2.CC_STAT_AREA]
    if a < 120:
        continue
    # 耳尖的暗色块挖掉后耳朵只剩细环，读不出兔耳；只镂空眼睛
    if stats[i, cv2.CC_STAT_TOP] < ear_line:
        continue
    holes[lab == i] = 255
holes = cv2.dilate(holes, np.ones((5, 5), np.uint8))
if MODE == "eyes":
    mask = cv2.bitwise_and(body, cv2.bitwise_not(holes))
else:
    mask = body

ys, xs = np.nonzero(mask)
x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
w, h = x1 - x0 + 1, y1 - y0 + 1
# 24dp 视口里内容区 22dp（状态栏图标 1dp 留白）
scale = 22.0 / max(w, h)
ox = (24 - w * scale) / 2 - x0 * scale
oy = (24 - h * scale) / 2 - y0 * scale

contours, _ = cv2.findContours(mask, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_NONE)
parts = []
for c in contours:
    if cv2.contourArea(c) < 60:
        continue
    c = cv2.approxPolyDP(c, 1.2, True)
    pts = [(p[0][0] * scale + ox, p[0][1] * scale + oy) for p in c]
    d = "M%.2f,%.2f" % pts[0] + "".join("L%.2f,%.2f" % p for p in pts[1:]) + "Z"
    parts.append(d)

xml = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    "<!-- Fushi 状态栏 / 通知小图标：启动图标海兔的单色剪影（眼睛镂空）。\n"
    "     Android 只取 alpha 通道渲染 smallIcon，彩色图会被剪影成一团，\n"
    "     所以这里必须是纯白单色。由 tool/android/gen_notification_icon.py 从\n"
    "     drawable-xxxhdpi/ic_launcher_foreground.png 生成，换 logo 后重跑。 -->\n"
    '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
    '    android:width="24dp"\n'
    '    android:height="24dp"\n'
    '    android:viewportWidth="24"\n'
    '    android:viewportHeight="24">\n'
    "    <path\n"
    '        android:fillColor="@android:color/white"\n'
    '        android:fillType="evenOdd"\n'
    '        android:pathData="' + "".join(parts) + '" />\n'
    "</vector>\n"
)
data = xml.encode("utf-8")
with open(OUT_XML, "wb") as f:
    f.write(data)
print("contours", len(parts), "chars", len("".join(parts)))
if PREVIEW is None:
    sys.exit(0)

# 预览：把矢量路径重新栅格化到 24/48/96 px
canvas = []
for px in (24, 48, 96):
    s = px / 24.0
    img = np.zeros((px, px), np.uint8)
    polys = []
    for c in contours:
        if cv2.contourArea(c) < 60:
            continue
        c = cv2.approxPolyDP(c, 1.2, True)
        polys.append(np.array([[(p[0][0] * scale + ox) * s * 16, (p[0][1] * scale + oy) * s * 16] for p in c], np.int32))
    big_img = np.zeros((px * 16, px * 16), np.uint8)
    # evenOdd：逐个 XOR
    for p in polys:
        t = np.zeros_like(big_img)
        cv2.fillPoly(t, [p], 255)
        big_img ^= t
    img = cv2.resize(big_img, (px, px), interpolation=cv2.INTER_AREA)
    canvas.append(cv2.resize(img, (192, 192), interpolation=cv2.INTER_NEAREST))
prev = np.hstack(canvas)
Image.fromarray(prev).save(PREVIEW)
