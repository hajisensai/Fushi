"""生成 tests/fixtures/lyrics/samples/ 下的歌词样本（每种 §5.1 格式至少一个）。

样本按字节入库（tests/.gitattributes 把 fixtures/** 标成 binary）；改样本后重跑本脚本，再用
`FUSHI_MUSIC_UPDATE_GOLDEN=1 cargo test --test lyrics` 刷新 golden 并人工审 diff。

    python -I native/fushi_music/tests/fixtures/lyrics/generate.py
"""

import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "samples")
os.makedirs(OUT, exist_ok=True)


def write(name: str, data: bytes) -> None:
    with open(os.path.join(OUT, name), "wb") as f:
        f.write(data)


def text(name: str, s: str, encoding: str = "utf-8", crlf: bool = False) -> None:
    if crlf:
        s = s.replace("\n", "\r\n")
    write(name, s.encode(encoding))


# 行级 LRC：Shift_JIS + CRLF（编码探测路径）、offset、一行多时间戳、同时间戳译文、间奏。
text(
    "line.lrc",
    "[ti:夜に駆ける]\n[ar:YOASOBI]\n[offset:+200]\n"
    "[00:01.00]沈むように溶けてゆくように\n[00:01.00]As if sinking, as if melting\n"
    "[00:05.50][00:20.00]二人だけの空が広がる夜に\n"
    "[00:09.00]\n[00:12.30]騒がしい日々に笑えない君に\n",
    encoding="shift_jis",
    crlf=True,
)
# 增强 LRC（A2 词级）。
text(
    "enhanced.lrc",
    "[00:10.00]<00:10.00>Never <00:10.40>gonna <00:10.90>give <00:11.30>you <00:11.60>up<00:12.20>\n"
    "[00:12.50]<00:12.50>Never <00:12.90>gonna <00:13.40>let <00:13.70>you <00:14.00>down<00:14.80>\n",
)
# ESLyric 逐字 LRC。
text(
    "eslyric.lrc",
    "[00:03.00]夜[00:03.30]に[00:03.50]駆[00:03.90]け[00:04.20]る[00:04.80]\n"
    "[00:05.00]君[00:05.40]の[00:05.60]声[00:06.30]\n",
)
# SRT：多行 cue 第二行当翻译、内联标签。
text(
    "lines.srt",
    "1\n00:00:01,000 --> 00:00:03,500\n<i>沈むように</i>\n像沉没一般\n\n"
    "2\n00:00:04,000 --> 00:00:06,000\n{\\an8}溶けてゆくように\n\n",
)
# WebVTT：cue 内时间戳、<v> 声部、<ruby>。
text(
    "cues.vtt",
    "WEBVTT\n\nNOTE 样本\n\n1\n00:00:01.000 --> 00:00:03.000 align:center\n"
    "<v Ikura>沈む<00:00:01.800>よう<00:00:02.400>に\n\n"
    "00:00:03.500 --> 00:00:05.000\n<v Ayase><ruby>夜<rt>よる</rt></ruby>に駆ける\nRunning into the night\n",
)
# SAMI：两种语言 class。
text(
    "lyrics.smi",
    "<SAMI>\n<HEAD><STYLE TYPE=\"text/css\"><!--\n.JPCC { Name: Japanese; lang: ja-JP; }\n.ENCC { Name: English; lang: en-US; }\n--></STYLE></HEAD>\n"
    "<BODY>\n<SYNC Start=1000><P Class=JPCC>沈むように<P Class=ENCC>As if sinking\n"
    "<SYNC Start=4000><P Class=JPCC>&nbsp;\n"
    "<SYNC Start=5000><P Class=JPCC>溶けてゆくように<br>二人だけの空\n</BODY>\n</SAMI>\n",
)
# 纯文本（无时间）。
text("plain.txt", "沈むように溶けてゆくように\n\n二人だけの空が広がる夜に\n")
# TTML（AMLL 方言）：声部、逐音节、和声、翻译、罗马音、ruby。
text(
    "amll.ttml",
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" '
    'xmlns:tts="http://www.w3.org/ns/ttml#styling" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xml:lang="ja">'
    '<head><metadata><ttm:agent type="person" xml:id="v1"><ttm:name type="full">Ikura</ttm:name></ttm:agent>'
    '<ttm:agent type="group" xml:id="v2000"/></metadata></head>'
    '<body dur="00:20.000"><div begin="00:01.000" end="00:20.000">'
    '<p begin="00:01.000" end="00:04.000" ttm:agent="v1" itunes:key="L1">'
    '<span begin="00:01.000" end="00:01.400">沈</span><span begin="00:01.400" end="00:01.800">む</span>'
    '<span begin="00:01.800" end="00:02.600">よう</span><span begin="00:02.600" end="00:04.000">に</span>'
    '<span ttm:role="x-bg"><span begin="00:03.000" end="00:04.200">(ah)</span></span>'
    '<span ttm:role="x-translation" xml:lang="zh-CN">像沉没一般</span>'
    '<span ttm:role="x-roman">shizumu you ni</span></p>'
    '<p begin="00:05.000" end="00:07.000" ttm:agent="v2000">'
    '<span tts:ruby="container" begin="00:05.000" end="00:06.000"><span tts:ruby="base">夜</span>'
    '<span tts:ruby="text">よる</span></span><span begin="00:06.000" end="00:07.000">に</span> '
    '<span begin="00:06.500" end="00:07.000">&amp;</span></p>'
    "</div></body></tt>\n",
)
# Lyricify Syllable：左右声部 + 和声。
text(
    "song.lys",
    "[ti:夜に駆ける]\n[1]沈(1000,400)む(1400,400)よう(1800,800)に(2600,1400)\n"
    "[4](ah)(3000,1200)\n[2]夜(5000,1000)に(6000,1000)\n",
)
# QRC 明文（XML 包装）。
text(
    "song.qrc",
    '<?xml version="1.0" encoding="utf-8"?>\n<QrcInfos>\n<QrcHeadInfo SaveTime="0" Version="100"/>\n'
    '<LyricInfo LyricCount="1">\n<Lyric_1 LyricType="1" LyricContent="[ti:夜に駆ける]\n'
    '[1000,3000]沈(1000,400)む(1400,400)よう(1800,800)に(2600,1400)\n'
    '[5000,2000]夜(5000,1000)に(6000,1000)\n"/>\n</LyricInfo>\n</QrcInfos>\n',
)
# YRC（网易云）：JSON 元数据行 + 逐字行。
text(
    "song.yrc",
    '{"t":0,"c":[{"tx":"作词: "},{"tx":"Ayase"}]}\n'
    "[1000,3000](1000,400,0)沈(1400,400,0)む(1800,800,0)よう(2600,1400,0)に\n"
    "[5000,2000](5000,1000,0)夜(6000,1000,0)に\n",
)
# KRC（酷狗加密）：krc1 + 16 字节异或 + zlib；明文带 [language:] 翻译 / 罗马音。
import base64
import json

lang = json.dumps(
    {
        "content": [
            {"language": 0, "type": 0, "lyricContent": [["shi", "zu", "mu", "yo", "u", "ni"], ["yo", "ru", "ni"]]},
            {"language": 0, "type": 1, "lyricContent": [["像沉没一般"], ["在夜里"]]},
        ],
        "version": 1,
    },
    ensure_ascii=False,
).encode()
krc_plain = (
    "﻿[id:$00000000]\n[ar:YOASOBI]\n[ti:夜に駆ける]\n[language:"
    + base64.b64encode(lang).decode()
    + "]\n[1000,3000]<0,400,0>沈<400,400,0>む<800,800,0>よう<1600,1400,0>に\n"
    "[5000,2000]<0,1000,0>夜<1000,1000,0>に\n"
).encode("utf-8")
KEY = bytes([64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105])
packed = zlib.compress(krc_plain)
write("song.krc", b"krc1" + bytes(b ^ KEY[i % 16] for i, b in enumerate(packed)))
# ASS 卡拉 OK：\k \kf \ko、注音、templater 产物、罗马字样式。
text(
    "karaoke.ass",
    "[Script Info]\nScriptType: v4.00+\n\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize\nStyle: Kanji,Arial,40\nStyle: Romaji,Arial,30\n\n"
    "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
    "Comment: 0,0:00:00.00,0:00:00.00,Kanji,,0,0,0,template syl,{\\pos($x,$y)\\t(0,$dur,\\1c&H0000FF&)}\n"
    "Comment: 0,0:00:01.00,0:00:04.00,Kanji,,0,0,0,karaoke,{\\k40}沈|しず{\\kf40}む{\\ko80}様|よう{\\k140}に\n"
    "Comment: 0,0:00:01.00,0:00:04.00,Romaji,,0,0,0,karaoke,{\\k40}shi{\\k40}zu{\\k40}mu{\\k80}you{\\k140}ni\n"
    "Dialogue: 0,0:00:01.00,0:00:04.00,Kanji,,0,0,0,fx,{\\pos(100,50)\\t(0,400,\\1c&H0000FF&)}沈\n"
    "Comment: 0,0:00:05.00,0:00:07.00,Kanji,,0,0,0,karaoke,{\\k100}夜|よる{\\k50}に{\\k50}#\n",
)
# UltraStar：BPM / GAP、对唱 P1 / P2、金音符、~ 延长。
text(
    "ultrastar.txt",
    "#TITLE:Yoru ni Kakeru\n#ARTIST:YOASOBI\n#LANGUAGE:Japanese\n#BPM:300\n#GAP:1000\n"
    "P1\n: 0 8 60 shi\n: 8 8 62 zu\n* 16 16 64 mu\n- 40\n"
    "P2\n: 80 20 60 yo\n: 100 10 60 ~\nF 110 10 0  ru\nE\n",
)


# MIDI / .kar（Soft Karaoke 文本事件）：tpq 480、120 BPM。
def vlq(v: int) -> bytes:
    out = [v & 0x7F]
    v >>= 7
    while v:
        out.append((v & 0x7F) | 0x80)
        v >>= 7
    return bytes(reversed(out))


def meta(delta: int, ty: int, data: bytes) -> bytes:
    return vlq(delta) + bytes([0xFF, ty]) + vlq(len(data)) + data


trk0 = meta(0, 0x51, bytes([0x07, 0xA1, 0x20])) + meta(0, 0x2F, b"")
events = [
    (0, b"@KMIDI KARAOKE FILE"),
    (0, b"@TYoru ni Kakeru"),
    (480, b"\\Shi"),
    (240, b"zu"),
    (240, b"mu"),
    (480, b"/yo"),
    (240, b"ru"),
]
trk1 = b"".join(meta(d, 0x01, t) for d, t in events) + meta(0, 0x2F, b"")
# 再塞一个音符事件（running status）验证非 meta 事件能跳过。
trk1 = vlq(0) + bytes([0x90, 60, 100]) + vlq(10) + bytes([60, 0]) + trk1
smf = b"MThd" + struct.pack(">IHHH", 6, 1, 2, 480)
for trk in (trk0, trk1):
    smf += b"MTrk" + struct.pack(">I", len(trk)) + trk
write("song.kar", smf)

print("samples written to", OUT)
