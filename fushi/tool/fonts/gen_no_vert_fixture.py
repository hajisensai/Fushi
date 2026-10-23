#!/usr/bin/env python3
"""生成竖排标点渲染测试的夹具字体 `fushi/test/reader/fixtures/no_vert_cjk.woff2`。

一款**没有** OpenType `vert` 的 CJK 字体：Noto Serif JP（SIL OFL 1.1）在 wght=400
实例化后子集化，并去掉全部排版表（GSUB / GPOS / GDEF）与竖排度量（vhea / vmtx），
模拟「用户字体 / 书自带字体缺 vert」。`vertical_punctuation_render_harness.mjs` 用它
证明阅读器竖排时「」ー 等仍画成竖排字形（BUG-3606，反馈 mTof77pMTe）。

用法：
  python fushi/tool/fonts/gen_no_vert_fixture.py --font <NotoSerifJP[wght].ttf>
"""

from __future__ import annotations

import argparse
import os

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

# 测试页正文「床に」「命令」、探针「 ー，以及空格。
TEXT = " 、。「」『』に令命床ー"

OUT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..",
    "..",
    "test",
    "reader",
    "fixtures",
    "no_vert_cjk.woff2",
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--font", required=True)
    parser.add_argument("--out", default=OUT)
    args = parser.parse_args()

    font = TTFont(args.font)
    if "fvar" in font:
        font = instancer.instantiateVariableFont(font, {"wght": 400})

    options = subset.Options()
    options.layout_features = []
    options.drop_tables += ["GSUB", "GPOS", "GDEF", "vhea", "vmtx", "VORG"]
    options.flavor = "woff2"
    options.name_IDs = [0, 1, 2, 3, 4, 5, 6, 13, 14]
    options.name_languages = [0x0409]
    options.notdef_outline = True
    options.hinting = False
    subsetter = subset.Subsetter(options)
    subsetter.populate(text=TEXT)
    subsetter.subset(font)
    for table in ("GSUB", "vhea", "vmtx"):
        if table in font:
            raise SystemExit(f"fixture still has {table}")
    font.flavor = "woff2"
    font.save(os.path.normpath(args.out))
    print("wrote", os.path.normpath(args.out), os.path.getsize(args.out), "bytes")


if __name__ == "__main__":
    main()
