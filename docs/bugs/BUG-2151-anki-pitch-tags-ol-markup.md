## BUG-2151 · Anki 卡片音标黑框巨大且无分隔符 —— popup.js 产出 `<ol>`，Lapis `#pitch-tags` 样式契约是 `ul`
- **报告**：2026-09-05（用户：截图一张英语卡「这个卡怪怪的」）
- **真实性**：✅ 真 bug。根因是同一仓库两端的列表标记契约对不上：
  - 产出端 `fushi/assets/popup/popup.js:1590`（`constructPitchPositionHtml`）与 `:1606`
    （`constructPhoneticTranscriptionsHtml`）的返回语句，修复前是 `` `<ol>${items}</ol>` ``；
  - 消费端 `packages/fushi_anki/lib/src/lapis_note_type.dart:1197`（`.pitch ul, #pitch-tags ul`
    的 list 归一）与 `:1212/:1218`（`・` 分隔符）修复前**只写了 `ul`**。
  - 日语卡看不出来：`lapis_note_type.dart:322` 的 `handlePitches` 能从字段里解析出数字/假名
    声调时会整个重建 `#pitch-tags`（它建的是 `<ul>`，见 `:458`）。英语 IPA 既无数字也无假名，
    `:380` 的 `if (pitches.length < 1) return;` 提前返回，框里留的就是制卡侧原样写进去的
    `<ol>`。
- **可见症状**（用户截图逐条对上浏览器默认 `ol` 样式）：
  - 黑框比文字高出一大截 → `<ol>` 默认 `margin-block: 1em` 被裹进 `#pitch-tags` 的
    `display: inline-block`（`lapis_note_type.dart:1171`）；
  - 框内左侧一大块空白 → `<ol>` 默认 `padding-inline-start: 40px`；
  - 两条音标之间没有 `・` → `#pitch-tags ul > li:not(:last-child)::after` 命不中 `ol`。
- **[x] ① 已修复** — 两端一起改：
  - 产出端 popup.js 三镜像（`assets/popup/`、`assets/browser_extension/vendor/`、
    `tools/browser-extension/vendor/`）改出 `<ul>`，与同文件里频率表 `constructFrequencyHtml`
    的 `<ul>` 一致（`<ol>` 只留给真正有序的释义义项列表）；
  - 消费端 Lapis CSS 的两条规则同时点名 `ul` 和 `ol`。**这一半不是补丁而是向后兼容**：
    存量卡片字段里存的就是 `<ol>`，那批卡已经躺在用户的 Anki 里、改不了，CSS 不认下来
    就是放着它们继续错版。
- **[x] ② 已加自动化测试** — `fushi/test/anki/lapis_pitch_tag_list_markup_test.dart`
  两头都锁：制卡 builder 必须产出 `<ul>` 且不得出现 `<ol>`；`LapisNoteType.css` 的
  `list-style: none` 规则与 `content: "・"` 规则的选择器必须同时含 `#pitch-tags ul` 与
  `#pitch-tags ol`。变异实测：把两端各改回原样，4 条用例全红。
  既有 `fushi/test/anki/phonetic_transcriptions_mining_test.dart` 里写死 `<ol>` 的断言同步改。
- **备注**：与 BUG-2152（同一张卡上音标重复两遍）是两个独立缺陷，分开修。
