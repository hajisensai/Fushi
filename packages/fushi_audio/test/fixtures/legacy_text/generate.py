# 重新生成本目录的本地编码字幕夹具：python generate.py（在本目录下跑）。
#
# 对白是为测试自己写的句子（不是任何作品的字幕），覆盖真实字幕里常见的形态：ASS 头与
# 覆盖标签、全角标点、半角片假名、带圈数字、音符、间隔号。每个夹具配一份
# `<名字>.expected.txt`（UTF-8）作为解码后的期望文本。
#
# 编码用 Python 自带 codec，解码的被测对象是 Rust 的 encoding_rs（WHATWG 映射表）：两套
# 互相独立的实现。所以这里只用两边映射一致的字符——EUC-JP 不放 `～` / `①`，Big5 不放
# `—`（两边映射不同，或 Python 的 codec 不收）。
#
# 行尾一律 LF：仓库 .gitattributes 是 `* text=auto eol=lf`，CRLF 的夹具会在提交时被改写。
import os

HERE = os.path.dirname(os.path.abspath(__file__))

ASS_HEAD = (
    "[Script Info]\n"
    "Title: legacy text fixture\n"
    "ScriptType: v4.00+\n"
    "PlayResX: 1920\n"
    "PlayResY: 1080\n"
    "\n"
    "[V4+ Styles]\n"
    "Format: Name, Fontname, Fontsize, PrimaryColour, Bold, Italic, Alignment, MarginL, MarginR, MarginV, Encoding\n"
    "Style: Default,MS Gothic,48,&H00FFFFFF,0,0,2,10,10,10,128\n"
    "\n"
    "[Events]\n"
    "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
)

JA = [
    "おはよう、今日はいい天気ですね。",
    "{\\an8}♪～ 夜空に星が瞬いている ～♪",
    "えっ…本当に？　信じられないよ！",
    "ｱﾘｶﾞﾄｳ、助かった。",
    "「約束だよ」――彼女はそう言って笑った。",
    "第１２話　表示能力のテスト①",
    "ソフトウェアの予定表を確認します。",
    "明日は雨が降るかもしれない。",
]

JA_EUC = [
    "おはよう、今日はいい天気ですね。",
    "♪ 夜空に星が瞬いている ♪",
    "えっ…本当に？　信じられないよ！",
    "「約束だよ」彼女はそう言って笑った。",
    "ソフトウェアの予定表を確認します。",
    "明日は雨が降るかもしれない。",
]

ZH_HANS = [
    "早上好，今天天气真不错。",
    "～ 夜空中的星星在闪烁 ～",
    "诶……真的吗？简直不敢相信！",
    "“约好了哦”——她这样说着笑了。",
    "乔治·华盛顿与托马斯·杰斐逊",
    "明天也许会下雨。",
]

ZH_HANT = [
    "早安，今天天氣真不錯。",
    "夜空中的星星在閃爍",
    "欸…真的嗎？簡直不敢相信！",
    "「約好了喔」她這樣說著笑了。",
    "喬治·華盛頓與湯瑪斯·傑佛遜",
    "明天也許會下雨。",
]


def stamp(i, sep):
    return "%02d:%02d:%02d%s" % (i // 3600, i // 60 % 60, i % 60, sep)


def ass(lines, count):
    out = [ASS_HEAD]
    for i in range(count):
        out.append(
            "Dialogue: 0,%s,%s,Default,,0,0,0,,%s\n"
            % (stamp(i * 3, ".00")[1:], stamp(i * 3 + 2, ".50")[1:], lines[i % len(lines)])
        )
    return "".join(out)


def srt(lines, count):
    out = []
    for i in range(count):
        out.append(
            "%d\n%s --> %s\n%s\n\n"
            % (i + 1, stamp(i * 3, ",000"), stamp(i * 3 + 2, ",500"), lines[i % len(lines)])
        )
    # 末尾只留一个换行：`git diff --check` 把文件尾的空行当空白错误。
    return "".join(out).rstrip("\n") + "\n"


FIXTURES = [
    # 名字, 文本, codec。ja_cp932.ass 故意做到 8 KB 以上，走后台 isolate 那条路。
    ("ja_cp932.ass", ass(JA, 240), "cp932"),
    ("ja_eucjp.srt", srt(JA_EUC, 24), "euc_jp"),
    ("zh_gbk.srt", srt(ZH_HANS, 24), "gbk"),
    ("zh_big5.srt", srt(ZH_HANT, 24), "cp950"),
]

for name, text, codec in FIXTURES:
    data = text.encode(codec)
    with open(os.path.join(HERE, name), "wb") as f:
        f.write(data)
    with open(os.path.join(HERE, name + ".expected.txt"), "wb") as f:
        f.write(text.encode("utf-8"))
    print(name, len(data), "bytes")
