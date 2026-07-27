## BUG-1146 · 字幕 <rt> 注音被拼进正文，污染查词/制卡 sentence/字数统计

- **报告**：2026-07-27（用户：审查 galgame 注音 PR 时顺带发现的既有真 bug）
- **真实性**：✅ 真 bug。根因 `packages/hibiki_audio/lib/src/parsers/strip_html_tags.dart:15`（修复前）——
  `stripHtmlTags` 只有一条无差别规则 `text.replaceAll(RegExp('<[^>]+>'), '')`：**删标签、留内容**。
  对样式标签（`<i>` / `<b>` / `<c.className>`）这是对的，但注音标注元素 `<rt>` / `<rp>` / `<rtc>`
  的内容**不是正文**，于是 VTT/SRT 里的 `<ruby>震<rt>ふる</rt></ruby>` 被拼成 `震ふる`。

  受影响的是三个字幕解析入口（都共享这一个函数）：
  - `packages/hibiki_audio/lib/src/parsers/srt_parser.dart:122`
  - `packages/hibiki_audio/lib/src/parsers/vtt_parser.dart:136`
  - `packages/hibiki_audio/lib/src/parsers/lrc_parser.dart:98`

  产出的 `AudioCue.text` 是查词 / 制卡 sentence / 字数统计的唯一坐标系，所以污染是一路向下的：
  `震ふる` 会作为句子被查词、被写进 Anki 卡片、并被计入阅读字数。

  **同仓已有正确口径，唯独字幕侧没跟上**：EPUB 侧 `hibiki/lib/src/epub/epub_book.dart:92`
  `_removeRubyAnnotations` 用 `querySelectorAll('rt, rp, rtc')` 逐个 `remove()`（丢注音、留基准）。
  本条把字幕侧并进**同一元素集合**。

  口径边界，别说过头：
  - 阅读器 JS `isFurigana()`（`reader_selection_scripts.dart:400`、`reader_pagination_scripts.dart:931`）
    只 `closest('rt, rp')`、**不含 `rtc`**。这是既有差异（BUG-711 已记录），本条不动 JS；合法 HTML 里
    `<rtc>` 总包着 `<rt>`，实际结果收敛，但不能写成「与 JS 一致」。
  - EPUB 侧是 `package:html` **真 DOM 解析**，字幕侧只有一行纯文本、只能用**正则近似**。两者因此只在
    良构输入上等价；畸形输入上本实现保证的是「整体不匹配 → 退回旧行为、不吞正文」，不是逐字等价。

- **[x] ① 已修复** — `packages/hibiki_audio/lib/src/parsers/strip_html_tags.dart`：在通用标签剥离
  之前先整段丢弃注音标注元素（`_rubyAnnotationPattern`），只留 ruby base；`<ruby>` / `<rb>` 外壳
  标签仍由通用模式删掉、内容保留。

  一条规则同时覆盖两种闭合形态，不为「缺 `</rt>`」单开分支：
  - 显式闭合 `<rt>ふる</rt>`（WebVTT 要求闭合）；
  - 隐式闭合 `<ruby>震<rt>ふる</ruby>`（HTML 允许省略 `</rt>`，由 `</ruby>` 收尾）。

  做法是把注音内容定义成「开标签之后、下一个 ruby 家族标签之前的所有字符」，可选地连同自己的
  闭合标签一起吃掉。认不出的残缺形式退回旧行为（宁可多留一个假名，也不吃掉正文）。

  开标签的属性段是 `(?:[^<>/]|/(?!>))*` 而**不是** `[^>]*`——后者会跨越 `<`，让缺 `>` 的
  `<ruby>漢<rt かん</ruby>の話` 借 `</ruby>` 的 `>` 凑成「合法」开标签，随后内容组把正文「の話」
  一路吃光（→ `漢`）；自闭合 `a<rt/>b` 同理会吞掉 `b`（→ `a`）。这两条形态在 TTML / XHTML 派生
  字幕里真实存在，且比旧行为更糟（旧行为分别是 `漢の話` / `ab`）。现写法让它们整体不匹配、
  退回通用模式，兑现上面那句承诺；两条形态各有一条负向测试守着。

- **[x] ② 已加自动化测试** —
  - `packages/hibiki_audio/test/parsers/strip_html_tags_ruby_test.dart`：纯函数形态矩阵，12 条正向
    （显式/隐式闭合、`<rp>` 回退括号、mono-ruby 逐字注音、`<rtc>` 容器、`<rb>` 外壳、大小写混合、
    带属性、夹在正文中间、一行多 ruby、行尾裸 `<rt>`、与样式标签混排）+ 4 条负向护栏
    （增强 LRC 词级时间标签 `<MM:SS.xx>`、VTT `<c.className>`/`<i>`、形近标签 `<rtl>`/`<rpc>`、
    无标签直通）+ 2 条**吞正文**守护（开标签缺 `>`、自闭合 `<rt/>`；把开标签属性段改回 `[^>]*`
    这两条即转红）。
  - `hibiki/test/media/audiobook/subtitle_ruby_strip_test.dart`：端到端断言 `AudioCue.text`，
    srt / vtt / lrc 三个真实解析路径各一条，外加 `markup.plainText` 与 `text` 同坐标系断言。

- **覆盖范围（如实记，别当成「全仓统一」）**：本条改的是共享的 `stripHtmlTags`，因此
  `SrtParser` / `VttParser` / `LrcParser` 三条路径（外挂 srt/vtt/lrc + 绝大多数内嵌轨）自动生效。
  **以下两条字幕路径不跟着变**，仍是旧行为：
  - `packages/hibiki_audio/lib/src/parsers/ass_parser.dart:253` 的 `AssParser` **不调用**
    `stripHtmlTags`（ASS 原生用 `{\...}` override 而非 HTML 标签）。内嵌轨经 ffmpeg 转成 `.ass`
    的那部分（`hibiki/lib/src/media/video/video_subtitle_source.dart:254,278,312`）若源里带 HTML
    ruby，读音仍会留在正文。
  - YouTube 字幕自带独立正则（`hibiki/lib/src/media/video/youtube_source_resolver.dart:283,308`，
    `RegExp(r'<[^>]+>')`，且 `markup` 恒为 null），等价于旧行为。

  这两条要不要并进同一口径是独立决策（需各自的真实样本），本条不夹带。

- **备注**：本条只修「注音不进正文」。**没有**把注音抬成可渲染的旁注区间——字幕渲染层
  （`SubtitleMarkup` / video 字幕绘制）目前无 ruby 绘制能力，产出无人消费的区间属于投机。
  另外 `hibiki/lib/src/utils/misc/ruby_markup.dart` 的 `RubyMarkupText`（galgame 浮窗注音，
  未合并分支）不能被本包复用：包依赖方向是 `hibiki → hibiki_audio`，反向依赖不成立。
  若将来字幕渲染要显示振假名，应在 `parseSubtitleMarkup` 内部一趟扫描里产出 ruby 区间
  （区间天然与 `plainText` 对齐），而不是在 `stripHtmlTags` 之后补一层偏移修正。
