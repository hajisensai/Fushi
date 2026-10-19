"""把抓下来的整页小说 HTML 裁成回归向量（只留小片段、去掉个人信息）。

用法：python -I trim_fixtures.py <原始页目录> <输出 inputs 目录>

- 正文只留前若干段（著作权：向量只需要结构，不需要全文）；含 ruby 的段落额外保留几段。
- 页面骨架（导航、广告位、评论区、上下章链接）原样保留：那正是提取要剔除 / 识别的东西。
- 原始编码保留（晋江是 GB18030，用来测字符集嗅探），只在解码后裁剪再按原编码写回。
- 抓取时不带 cookie，页面里没有登录态；仍把 `redirecthash=` 之类的会话串抹掉。
"""

import io
import os
import re
import sys


def keep_paragraphs(html: str, pattern: str, keep: int, keep_ruby: int = 0) -> str:
    rx = re.compile(pattern)
    out = []
    ruby_kept = 0
    for line in html.split("\n"):
        m = rx.search(line)
        if m:
            n = int(m.group(1))
            if n > keep:
                if keep_ruby and "<ruby" in line and ruby_kept < keep_ruby:
                    ruby_kept += 1
                else:
                    continue
        out.append(line)
    return "\n".join(out)


def scrub(html: str) -> str:
    html = re.sub(r"redirecthash=[0-9a-f]+", "redirecthash=0", html)
    html = re.sub(r"(csrf[-_]?token[\"']?\s*[:=]\s*[\"'])[^\"']+", r"\1x", html, flags=re.I)
    return html


def jjwxc(html: str, keep: int) -> str:
    start = html.index('<div id="paragraph_comment_content">')
    body_start = html.index(">", start) + 1
    end = html.index("<div", body_start)
    parts = html[body_start:end].split("<br><br>")
    trimmed = "<br><br>".join(parts[:keep])
    return html[:body_start] + trimmed + "\n                " + html[end:]


def main() -> None:
    src, dst = sys.argv[1], sys.argv[2]
    os.makedirs(dst, exist_ok=True)

    def read(name: str, enc: str = "utf-8") -> str:
        return io.open(os.path.join(src, name), "rb").read().decode(enc, errors="replace")

    def write(name: str, text: str, enc: str = "utf-8") -> None:
        data = scrub(text).encode(enc, errors="replace")
        io.open(os.path.join(dst, name), "wb").write(data)

    write("syosetu_n9669bk_1.html", keep_paragraphs(read("syosetu.html"), r'<p id="L(\d+)"', 12))
    write(
        "syosetu_n9669bk_10.html",
        keep_paragraphs(read("syosetu_ruby.html"), r'<p id="L(\d+)"', 8, keep_ruby=3),
    )
    write(
        "kakuyomu_1177354054881165840_ep.html",
        keep_paragraphs(read("kakuyomu.html"), r'<p id="p(\d+)"', 16),
    )
    write("jjwxc_2456_2.html", jjwxc(read("jjwxc.html", "gb18030"), 10), "gb18030")


if __name__ == "__main__":
    main()
