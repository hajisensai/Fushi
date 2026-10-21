#!/usr/bin/env python3
"""生成阅读器竖排标点子集字体（BUG-3606）。

产物（入库，运行期 / 测试不依赖本脚本）：
  fushi/assets/fonts/FushiVerticalPunctuation.woff2

为什么要它：竖排 `text-orientation: mixed` 下，「」、。（）等 UAX #50 里标为
Tu / Tr 的标点由浏览器保持直立、靠字体的 `vert` / `vrt2` 替换成竖排字形。Blink
（Android WebView / Chrome / WebView2）在字体没有这条替换时**不会**退回旋转，直接
画横排字形——于是正文字体（用户字体、书自带字体、系统回退字体）缺 `vert` 时，这些
标点横着躺、而 ー …… —— 这类本来就旋转的字符是竖的，同一页方向不一致。阅读器竖排时
把本子集放在正文字体链最前面（`unicode-range` 只覆盖下面这些标点），标点一律取一款
确定带 `vert` 的字形。

只收「上游字体的 vert / vrt2 确实替换了它」的码位：候选里没有被替换的（比如本来就
直立居中、无需竖排形的）不收，避免无谓地换掉正文字体的字形。ー（U+30FC）、……
（U+2026）、‥（U+2025）、——（U+2014）、―（U+2015）、小假名刻意不在候选里：前者在
Blink 里按旋转处理、本来就竖；小假名换字体的观感代价大于偏移的收益。

来源：google/fonts `ofl/notoserifjp/NotoSerifJP[wght].ttf`（SIL OFL 1.1），在
wght=400 实例化后子集化。许可见 fushi/assets/licenses/noto-serif-jp.txt（重跑后把
脚本打印的上游 SHA-256 同步进去）。

用法：
  python fushi/tool/fonts/gen_vertical_punctuation.py --font <NotoSerifJP[wght].ttf>
"""

from __future__ import annotations

import argparse
import hashlib
import os

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

# UAX #50 中 Tu / Tr、竖排要换字形的 CJK 标点与全角符号候选。产物码位变了要同步
# `ReaderVerticalPunctuationFont.codepointRanges`（守卫测试读字体 cmap 校验两者一致）。
CANDIDATES: list[int] = (
    [0x3001, 0x3002]  # 、。
    + list(range(0x3008, 0x3012))  # 〈〉《》「」『』【】
    + list(range(0x3014, 0x3020))  # 〔〕〖〗〘〙〚〛〜〝〞〟
    + [0x3030, 0x30A0]  # 〰 ゠
    + [0xFF01, 0xFF08, 0xFF09, 0xFF0C, 0xFF0E]  # ！（），．
    + [0xFF1A, 0xFF1B, 0xFF1D, 0xFF1F]  # ：；＝？
    + [0xFF3B, 0xFF3D, 0xFF3F]  # ［］＿
    + list(range(0xFF5B, 0xFF61))  # ｛｜｝～｟｠
    + [0xFFE3]  # ￣
)

OUT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..",
    "..",
    "assets",
    "fonts",
    "FushiVerticalPunctuation.woff2",
)


def vert_covered(font: TTFont, codepoints: list[int]) -> list[int]:
    cmap = font.getBestCmap()
    gsub = font["GSUB"].table
    lookups: set[int] = set()
    for record in gsub.FeatureList.FeatureRecord:
        if record.FeatureTag in ("vert", "vrt2"):
            lookups.update(record.Feature.LookupListIndex)
    covered: set[str] = set()
    for index in lookups:
        lookup = gsub.LookupList.Lookup[index]
        for sub in lookup.SubTable:
            if lookup.LookupType == 7:
                sub = sub.ExtSubTable
            mapping = getattr(sub, "mapping", None)
            if mapping:
                covered.update(
                    glyph for glyph, target in mapping.items() if glyph != target
                )
    return [c for c in codepoints if cmap.get(c) in covered]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--font", required=True)
    parser.add_argument("--out", default=OUT)
    args = parser.parse_args()

    with open(args.font, "rb") as handle:
        print("upstream SHA-256:", hashlib.sha256(handle.read()).hexdigest().upper())

    font = TTFont(args.font)
    if "fvar" in font:
        font = instancer.instantiateVariableFont(font, {"wght": 400})
    keep = vert_covered(font, CANDIDATES)
    dropped = [c for c in CANDIDATES if c not in keep]
    print("kept   :", " ".join(f"U+{c:04X}" for c in keep))
    print("dropped:", " ".join(f"U+{c:04X}" for c in dropped))

    options = subset.Options()
    options.layout_features = ["vert", "vrt2"]
    options.flavor = "woff2"
    options.name_IDs = [0, 1, 2, 3, 4, 5, 6, 13, 14]
    options.name_languages = [0x0409]
    options.notdef_outline = True
    options.hinting = False
    options.desubroutinize = True
    subsetter = subset.Subsetter(options)
    subsetter.populate(unicodes=keep)
    subsetter.subset(font)
    for table in ("vhea", "vmtx"):
        if table not in font:
            raise SystemExit(f"subset lost vertical table {table}")
    font.flavor = "woff2"
    font.save(os.path.normpath(args.out))
    print("wrote", os.path.normpath(args.out), os.path.getsize(args.out), "bytes")


if __name__ == "__main__":
    main()
