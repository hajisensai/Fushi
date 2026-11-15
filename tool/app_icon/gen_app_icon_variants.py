"""生成应用图标的深色 / 着色 / 单色主题变体（反馈 HsUdOMa5eq）。

浅色主图标（薰衣草底 + 投影的兔子）保持不变，本脚本只从同一张插画
tool/app_icon/fushi_bunny_source.png 派生各平台的「系统外观」变体：

- iOS / iPadOS 18+：AppIcon.appiconset 改为 Single Size（Xcode 14+ 由 1024 自动出全尺寸），
  并加 appearance=luminosity 的 dark（透明底，系统铺深色底）与 tinted（不透明灰度，
  系统按用户色调着色）两张 1024 图。Apple 只在 Single Size 模式支持外观变体。
- macOS 26+：Icon Composer 包 macos/Runner/AppIcon.icon（icon.json + Assets/），
  浅色填充 #E6E2F6、深色填充 system-dark；着色 / 透明外观由系统按图层自动派生。
  老 macOS 继续用 Assets.xcassets/AppIcon.appiconset（两者同名 AppIcon，Xcode 26
  在 26+ 取 .icon，旧系统取 appiconset）。
- Android 13+ 主题图标：drawable/ic_launcher_monochrome.xml（只取 alpha 的单色剪影，
  眼睛镂空），与 ic_launcher_foreground 同构图（108dp 画布、兔子落在 72dp 安全区）。
  深色模式背景色写在 values-night/colors.xml（手写，不由本脚本生成）。

在仓库根重跑（换 logo 时）：

    python -I tool/app_icon/gen_app_icon_variants.py

依赖 opencv-python、numpy、Pillow。
"""
from __future__ import annotations

import json
import os

import cv2
import numpy as np
from PIL import Image

_HERE: str = os.path.dirname(os.path.abspath(__file__))
_ROOT: str = os.path.normpath(os.path.join(_HERE, "..", ".."))
_APP: str = os.path.join(_ROOT, "fushi")

SRC: str = os.path.join(_HERE, "fushi_bunny_source.png")
IOS_SET: str = os.path.join(
    _APP, "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset"
)
IOS_ANY: str = "Icon-App-1024x1024@1x.png"
IOS_DARK: str = "Icon-App-1024x1024-dark.png"
IOS_TINTED: str = "Icon-App-1024x1024-tinted.png"
MAC_ICON: str = os.path.join(_APP, "macos", "Runner", "AppIcon.icon")
MAC_LAYER: str = "fushi_bunny.png"
ANDROID_RES: str = os.path.join(_APP, "android", "app", "src", "main", "res")
ANDROID_FG: str = os.path.join(
    ANDROID_RES, "drawable-xxxhdpi", "ic_launcher_foreground.png"
)
ANDROID_MONO: str = os.path.join(ANDROID_RES, "drawable", "ic_launcher_monochrome.xml")

CANVAS: int = 1024
# 与浅色主图标同构图：插画的白色主体在 1024 画布上的包围盒
# （由 Icon-App-1024x1024@1x.png 实测：x 26..997，y 185..840）。
ANY_WHITE_BBOX: tuple[int, int, int, int] = (26, 185, 997, 840)
# 浅色主图标的薰衣草底 #E6E2F6（sRGB）。
LIGHT_FILL_SRGB: tuple[int, int, int] = (0xE6, 0xE2, 0xF6)


def _white_bbox(rgba: np.ndarray) -> tuple[int, int, int, int]:
    white = (rgba[..., :3].min(axis=2) >= 250) & (rgba[..., 3] > 250)
    ys, xs = np.nonzero(white)
    return int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())


def bunny_on_transparent() -> Image.Image:
    """把插画按浅色主图标的构图放到 1024 透明画布上（无投影、无底色）。"""
    src = Image.open(SRC).convert("RGBA")
    sx0, sy0, sx1, _ = _white_bbox(np.array(src))
    ax0, ay0, ax1, _ = ANY_WHITE_BBOX
    scale = (ax1 - ax0 + 1) / (sx1 - sx0 + 1)
    w, h = round(src.width * scale), round(src.height * scale)
    scaled = src.resize((w, h), Image.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.alpha_composite(
        scaled, (round(ax0 - sx0 * scale), round(ay0 - sy0 * scale))
    )
    return canvas


def tinted_from(bunny: Image.Image) -> Image.Image:
    """着色变体：不透明灰度，黑底上亮主体（系统按亮度映射用户色调）。"""
    black = Image.new("RGBA", bunny.size, (0, 0, 0, 255))
    black.alpha_composite(bunny)
    return black.convert("L")


def write_ios(bunny: Image.Image) -> None:
    bunny.save(os.path.join(IOS_SET, IOS_DARK), optimize=True)
    tinted_from(bunny).save(os.path.join(IOS_SET, IOS_TINTED), optimize=True)
    # 旧 All Sizes 的逐尺寸 PNG：Single Size 下不再引用，留着会让 actool 报
    # unassigned child。只删本 set 里的 Icon-App-*，保留 1024 主图与新变体。
    keep = {IOS_ANY, IOS_DARK, IOS_TINTED, "Contents.json"}
    for name in os.listdir(IOS_SET):
        if name not in keep and name.startswith("Icon-App-"):
            os.remove(os.path.join(IOS_SET, name))

    def entry(filename: str, appearance: str | None) -> dict[str, object]:
        e: dict[str, object] = {}
        if appearance is not None:
            e["appearances"] = [{"appearance": "luminosity", "value": appearance}]
        e.update(
            {
                "filename": filename,
                "idiom": "universal",
                "platform": "ios",
                "size": "1024x1024",
            }
        )
        return e

    contents = {
        "images": [
            entry(IOS_ANY, None),
            entry(IOS_DARK, "dark"),
            entry(IOS_TINTED, "tinted"),
        ],
        "info": {"author": "xcode", "version": 1},
    }
    _write_json(os.path.join(IOS_SET, "Contents.json"), contents)


def _srgb_to_display_p3(rgb: tuple[int, int, int]) -> tuple[float, float, float]:
    def lin(c: float) -> float:
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

    def enc(c: float) -> float:
        c = min(max(c, 0.0), 1.0)
        return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055

    r, g, b = (lin(v / 255.0) for v in rgb)
    # 线性 sRGB → 线性 Display P3（同 D65 白点）。
    pr = 0.8224621 * r + 0.1775380 * g + 0.0000000 * b
    pg = 0.0331941 * r + 0.9668058 * g + 0.0000000 * b
    pb = 0.0170827 * r + 0.0723974 * g + 0.9105199 * b
    return enc(pr), enc(pg), enc(pb)


def write_macos(bunny: Image.Image) -> None:
    os.makedirs(os.path.join(MAC_ICON, "Assets"), exist_ok=True)
    bunny.save(os.path.join(MAC_ICON, "Assets", MAC_LAYER), optimize=True)
    r, g, b = _srgb_to_display_p3(LIGHT_FILL_SRGB)
    icon = {
        "fill-specializations": [
            {"value": {"solid": f"display-p3:{r:.5f},{g:.5f},{b:.5f},1.00000"}},
            {"appearance": "dark", "value": "system-dark"},
        ],
        "groups": [
            {
                "layers": [
                    {
                        "glass": False,
                        "image-name": MAC_LAYER,
                        "name": "fushi_bunny",
                        "position": {
                            "scale": 1,
                            "translation-in-points": [0, 0],
                        },
                    }
                ],
                "shadow": {"kind": "neutral", "opacity": 0.5},
                "translucency": {"enabled": False, "value": 0.5},
            }
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }
    _write_json(os.path.join(MAC_ICON, "icon.json"), icon)


def write_android_monochrome() -> None:
    """主题图标单色层：同 gen_notification_icon.py 的剪影算法（去投影、眼睛镂空），
    但保持 ic_launcher_foreground 的原位置（108dp 视口，不重新居中缩放）。"""
    im = np.array(Image.open(ANDROID_FG).convert("RGBA")).astype(np.int32)
    alpha = im[..., 3]
    lum = (im[..., 0] * 299 + im[..., 1] * 587 + im[..., 2] * 114) // 1000
    body = (alpha > 200).astype(np.uint8) * 255
    body = cv2.morphologyEx(body, cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))
    n, lab, stats, _ = cv2.connectedComponentsWithStats(body)
    big = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    body = (lab == big).astype(np.uint8) * 255
    body = cv2.morphologyEx(body, cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8))

    dark = ((lum < 110) & (alpha > 200)).astype(np.uint8) * 255
    dark = cv2.morphologyEx(dark, cv2.MORPH_OPEN, np.ones((7, 7), np.uint8))
    n, lab, stats, _ = cv2.connectedComponentsWithStats(dark)
    holes = np.zeros_like(dark)
    bys = np.nonzero(body)[0]
    ear_line = bys.min() + 0.35 * (bys.max() - bys.min())
    for i in range(1, n):
        if stats[i, cv2.CC_STAT_AREA] < 120:
            continue
        if stats[i, cv2.CC_STAT_TOP] < ear_line:
            continue
        holes[lab == i] = 255
    holes = cv2.dilate(holes, np.ones((5, 5), np.uint8))
    mask = cv2.bitwise_and(body, cv2.bitwise_not(holes))

    scale = 108.0 / mask.shape[1]
    contours, _ = cv2.findContours(mask, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_NONE)
    parts: list[str] = []
    for c in contours:
        if cv2.contourArea(c) < 60:
            continue
        c = cv2.approxPolyDP(c, 1.2, True)
        pts = [(p[0][0] * scale, p[0][1] * scale) for p in c]
        parts.append(
            "M%.2f,%.2f" % pts[0] + "".join("L%.2f,%.2f" % p for p in pts[1:]) + "Z"
        )
    xml = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<!-- Android 13+ 主题图标（themed icon）单色层：启动图标兔子的剪影（眼睛镂空）。\n"
        "     启动器只取 alpha 并按壁纸取色着色。与 ic_launcher_foreground 同构图\n"
        "     （108dp 画布、主体在 72dp 安全区内）。由\n"
        "     tool/app_icon/gen_app_icon_variants.py 生成，换 logo 后重跑。 -->\n"
        '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    android:width="108dp"\n'
        '    android:height="108dp"\n'
        '    android:viewportWidth="108"\n'
        '    android:viewportHeight="108">\n'
        "    <path\n"
        '        android:fillColor="@android:color/white"\n'
        '        android:fillType="evenOdd"\n'
        '        android:pathData="' + "".join(parts) + '" />\n'
        "</vector>\n"
    )
    with open(ANDROID_MONO, "wb") as f:
        f.write(xml.encode("utf-8"))


def _write_json(path: str, data: object) -> None:
    text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    with open(path, "wb") as f:
        f.write(text.encode("utf-8"))


def main() -> None:
    bunny = bunny_on_transparent()
    write_ios(bunny)
    write_macos(bunny)
    write_android_monochrome()
    print("ok")


if __name__ == "__main__":
    main()
