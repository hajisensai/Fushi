#!/usr/bin/env python3
"""生成 Windows 安装器的 Material Design 3 图像资产（幂等，产物入库）。

用法（仓库根目录）：
    python fushi/windows/installer/generate_md3_assets.py

产物落 fushi/windows/installer/assets/，由 fushi.iss 的 WizardImageFile /
WizardSmallImageFile 引用。改配色或形状后重跑本脚本并提交产物即可——不要手改 PNG。

为什么不复用 app_icon.ico：那份图标至今还是改名前的 **Hibiki 字标**
（fushi/windows/runner/resources/app_icon.ico，实测 256x256 帧上写着 "Hibiki"），
放进 Fushi 安装器等于在安装界面上打旧品牌。这里用与官网 fushi.moe 同一套占位标记
（MD3 圆角方块 + 渐变 + 字母 F），等正式 logo 出来后连同官网一起替换。

配色是 MD3 baseline 主色（primary #6750A4 一族），与 app 内主题同源。
"""

from __future__ import annotations

import os
from typing import Sequence

from PIL import Image, ImageDraw, ImageFont

# ── MD3 baseline tokens ────────────────────────────────────────────────────
PRIMARY = (103, 80, 164)  # #6750A4
PRIMARY_DEEP = (79, 55, 139)  # #4F378B
PRIMARY_CONTAINER = (234, 221, 255)  # #EADDFF
PRIMARY_FIXED_DIM = (208, 188, 255)  # #D0BCFF
ON_PRIMARY = (255, 255, 255)
ON_PRIMARY_CONTAINER = (33, 0, 93)  # #21005D
SURFACE_DARK = (20, 18, 24)  # #141218
ON_SURFACE_DARK = (230, 224, 233)  # #E6E0E9

# 超采样倍数：PIL 没有抗锯齿绘制，圆角/圆形一律放大画再缩回。
SS = 4

# WizardImageFile 基准 164x314（modern 向导），另给 125% / 150% / 200% 三档。
HERO_SIZES: Sequence[tuple[int, int]] = ((164, 314), (192, 386), (246, 492), (328, 628))
# WizardSmallImageFile 基准 55x55，另给常见 DPI 档。
MARK_SIZES: Sequence[int] = (55, 64, 83, 110, 138)
# WizardBackImageFile：Inno 固定按 497:360 拉伸，给一张够大的（250% DPI 档是 1630x1148）。
BACK_SIZE = (1630, 1180)

FONT_CANDIDATES = (
    r'C:\Windows\Fonts\segoeuib.ttf',  # Segoe UI Bold
    r'C:\Windows\Fonts\seguisb.ttf',  # Segoe UI Semibold
    r'C:\Windows\Fonts\arialbd.ttf',
)


def load_font(size: int) -> ImageFont.FreeTypeFont:
    """取第一个可用的粗体字形；一个都没有就退回 PIL 内置位图字体。"""
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def vertical_gradient(size: tuple[int, int], top: tuple[int, int, int],
                      bottom: tuple[int, int, int]) -> Image.Image:
    """自上而下的线性渐变（逐行填充，尺寸小，够用且无依赖）。"""
    width, height = size
    img = Image.new('RGB', (1, height))
    draw = ImageDraw.Draw(img)
    for y in range(height):
        t = y / max(height - 1, 1)
        draw.point(
            (0, y),
            fill=(
                round(top[0] + (bottom[0] - top[0]) * t),
                round(top[1] + (bottom[1] - top[1]) * t),
                round(top[2] + (bottom[2] - top[2]) * t),
            ),
        )
    return img.resize((width, height), Image.NEAREST)


def draw_mark(side: int, dark: bool) -> Image.Image:
    """MD3 圆角方块标记（渐变底 + 白色 F），透明背景，边长 side 像素。"""
    big = side * SS
    canvas = Image.new('RGBA', (big, big), (0, 0, 0, 0))

    top, bottom = (PRIMARY_FIXED_DIM, PRIMARY) if dark else (PRIMARY, PRIMARY_DEEP)
    fill = vertical_gradient((big, big), top, bottom).convert('RGBA')

    # MD3 large shape：圆角半径约边长的 28%。
    mask = Image.new('L', (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, big - 1, big - 1), radius=round(big * 0.28), fill=255)
    canvas.paste(fill, (0, 0), mask)

    glyph_color = (56, 30, 114, 255) if dark else ON_PRIMARY + (255,)
    font = load_font(round(big * 0.62))
    draw = ImageDraw.Draw(canvas)
    box = draw.textbbox((0, 0), 'F', font=font)
    draw.text(
        (big / 2 - (box[0] + box[2]) / 2, big / 2 - (box[1] + box[3]) / 2),
        'F', font=font, fill=glyph_color)

    return canvas.resize((side, side), Image.LANCZOS)


def draw_hero(size: tuple[int, int], dark: bool) -> Image.Image:
    """欢迎页 / 完成页左侧竖图：MD3 tonal 背景 + 装饰圆 + 标记 + 产品名。"""
    width, height = size
    big = (width * SS, height * SS)

    if dark:
        background = vertical_gradient(big, PRIMARY_DEEP, (56, 30, 114))
        halo = (208, 188, 255, 38)
        word_color = (234, 221, 255, 255)
    else:
        background = vertical_gradient(big, PRIMARY_CONTAINER, PRIMARY_FIXED_DIM)
        halo = (255, 255, 255, 90)
        word_color = ON_PRIMARY_CONTAINER + (255,)
    canvas = background.convert('RGBA')

    # 装饰：两枚大圆，MD3 的「形状叠层」语汇，不喧宾夺主。
    decor = Image.new('RGBA', big, (0, 0, 0, 0))
    d = ImageDraw.Draw(decor)
    r1 = round(big[0] * 0.95)
    d.ellipse((-r1 // 3, big[1] - r1, -r1 // 3 + r1 * 2 // 2, big[1] + r1), fill=halo)
    r2 = round(big[0] * 0.55)
    d.ellipse((big[0] - r2 // 2, -r2 // 3, big[0] + r2, -r2 // 3 + r2), fill=halo)
    canvas = Image.alpha_composite(canvas, decor)

    mark_side = round(width * 0.46)
    mark = draw_mark(mark_side, dark=False)
    mark_x = round((width - mark_side) / 2)
    mark_y = round(height * 0.30)

    canvas = canvas.resize((width, height), Image.LANCZOS)
    canvas.paste(mark, (mark_x, mark_y), mark)

    font = load_font(max(round(width * 0.135), 8))
    draw = ImageDraw.Draw(canvas)
    box = draw.textbbox((0, 0), 'Fushi', font=font)
    draw.text(
        (width / 2 - (box[0] + box[2]) / 2, mark_y + mark_side + round(height * 0.035)),
        'Fushi', font=font, fill=word_color)

    return canvas


def draw_back(size: tuple[int, int], dark: bool) -> Image.Image:
    """向导页背景：MD3 surface 底 + 两团极淡的主色晕。

    这是唯一还能把 MD3 主色铺到每一页上的手段：Inno 的内置自定义样式接管了所有
    控件与文字颜色（实测 MainPanel.Color / Font.Color 在样式激活时是空操作），
    只有背景图和图像资产是脚本能定的。因此晕必须够淡——它压在正文文字下面。
    """
    width, height = size
    base = (20, 18, 24) if dark else (254, 247, 255)
    canvas = Image.new('RGB', size, base).convert('RGBA')

    glow = Image.new('RGBA', size, (0, 0, 0, 0))
    d = ImageDraw.Draw(glow)
    tint = PRIMARY_FIXED_DIM if dark else PRIMARY
    alpha = 34 if dark else 30
    # 顶部约 1/4 是页眉带（标题 + 右上角标记）。标记 PNG 由 Inno 合成到
    # WizardSmallImageBackColor 上，那个底色只能是纯色；晕一旦爬进页眉，
    # 标记周围就会露出一块与背景不同色的方块（浅色模式下尤其明显）。
    # 所以两团晕都压在页眉以下，页眉区保持纯 surface 色。
    header = round(height * 0.20)
    r1 = round(width * 0.38)
    d.ellipse((width - r1, header + r1 // 3, width + r1 // 2, header + r1 * 2),
              fill=tint + (alpha,))
    r2 = round(width * 0.34)
    d.ellipse((-r2 // 2, height - r2, r2, height + r2 // 2), fill=tint + (alpha,))
    # 高斯模糊把边缘化掉，避免正文区域出现可见的圆边。
    from PIL import ImageChops, ImageFilter
    glow = glow.filter(ImageFilter.GaussianBlur(radius=width * 0.06))
    # 模糊会把晕重新糊回页眉。用一条竖直渐变遮罩把页眉带压到 0，再在下方渐显——
    # 硬切会在页眉下沿留一条可见横线，渐显不会。
    fade = max(round(height * 0.10), 1)
    ramp = Image.new('L', size, 255)
    ramp_draw = ImageDraw.Draw(ramp)
    for y in range(header + fade):
        ramp_draw.line(
            ((0, y), (width, y)),
            fill=0 if y < header else round(255 * (y - header) / fade))
    glow.putalpha(ImageChops.multiply(glow.split()[3], ramp))

    return Image.alpha_composite(canvas, glow).convert('RGB')


def main() -> None:
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'assets')
    os.makedirs(out_dir, exist_ok=True)

    written: list[str] = []
    for width, height in HERO_SIZES:
        for dark in (False, True):
            name = 'wizard_hero{}_{}x{}.png'.format('_dark' if dark else '', width, height)
            draw_hero((width, height), dark).save(os.path.join(out_dir, name))
            written.append(name)

    for side in MARK_SIZES:
        for dark in (False, True):
            name = 'wizard_mark{}_{}.png'.format('_dark' if dark else '', side)
            draw_mark(side, dark).save(os.path.join(out_dir, name))
            written.append(name)

    for dark in (False, True):
        name = 'wizard_back{}_{}x{}.png'.format(
            '_dark' if dark else '', BACK_SIZE[0], BACK_SIZE[1])
        draw_back(BACK_SIZE, dark).save(os.path.join(out_dir, name))
        written.append(name)

    print('wrote {} files into {}'.format(len(written), out_dir))
    for name in written:
        print('  ' + name)


if __name__ == '__main__':
    main()
