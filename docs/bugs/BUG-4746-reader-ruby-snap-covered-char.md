## BUG-4746 · 小说查词：义训 ruby 段内靠后的字（じょうろ鼬 的鼬）点不到
- **报告**：2026-11-16（用户：维护者应用内反馈 ssJjbvbAbs）
- **真实性**：✅ 真 bug。《七つの魔剣が支配するVII》竖排「ここ、じょうろ鼬が巣を作ってるの！」里作者把两个词「じょうろ」「鼬」标进同一个
  `<ruby>じょうろ鼬<rt>ポットウィーゼル</rt></ruby>`。根因 `fushi/lib/src/reader/reader_selection_scripts.dart:3403-3408`
  （修复前，`selectionStartFor`，chj2rZn89F 引入）：命中 ruby 基字时**无条件**把查词起点吸附到该 ruby 基字段首个文本节点、
  偏移 0，假设一个 ruby 段就是一个词。点「鼬」起点被拉回「じ」，最长匹配只得到「じょうろ」，高亮 / 弹窗都落在 じょうろ 上，
  鼬怎么点都查不到。同一假设还让 `selectText` 的同词判据（比归一起点）把「查到じょうろ后再点鼬」当成再点同词、直接取消。
- **[x] ① 已修复** — 吸附改成「先从组首试」：`selectFromPosition` 在吸附时记下被点字在扫描串里的位置（`rubyTapIndex`），
  `buildSelectionPayload` 同时带上从被点字起扫的整份候选 payload（`rubySnap: {tapIndex, selection}`，偏移 / 振假名 / 句子
  都按那个起点算）；宿主 `resolveRubySnapSelection`（`fushi/lib/src/reader/reader_ruby_snap.dart`）先按组首查词，命中长度
  覆盖不到被点字才采用候选，并调 JS `adoptRubySnapTap` 让选区 / 高亮跟随。`tapIndex` 与命中长度
  （`bestLength`，matched 的 UTF-16 长度）统一用 UTF-16，组内前面有扩展区汉字（𩸽）时也不会误判已覆盖。
  `fireTextSelected` 只在外层追加的 `fromHover` / `selectedSeq` / `lyricsCueContext` 同步写进候选，采用后悬停
  仍算悬停、歌词覆盖层不多 eval 一次。同词判据收进 `designatesCurrentSelection`：ruby 命中要求被点字落在已查到的
  词里。小说阅读器（正文 + 歌词覆盖层）走 `_handleTextSelected` 接入，双屏伴屏路由挪到判定之后（按最终选区的
  `sentenceOffset` 发给伴屏，否则伴屏点「鼬」查到的还是「じょうろ」）。
- **[x] ② 已加自动化测试** — `fushi/test/reader/ruby_tail_tap_selection_test.dart`（真 Chrome DOM 跑生产脚本，分页 / 连续两个
  shell：点鼬带候选、采用后高亮恰为「鼬」、再点鼬 = 同词、点组首「じ」不带候选、查到じょうろ后点鼬不是同词、候选的
  sentenceOffset / normalizedOffset 指向被点字、悬停 / 序号 / 歌词 cue 字段同步进候选、𩸽 在前时 tapIndex 是 UTF-16 下标）；
  `fushi/test/reader/reader_ruby_snap_test.dart`（宿主判定：覆盖不到→采用候选并让 JS 换选区、覆盖到（近衛 点衛）→保持吸附、
  无候选不多查、JS 拒绝时保持原选区）。
- **备注 / 待办**：SRS 卡面（`srs_card_face.dart`）与内置浏览器（`web_browser_tab_view.dart`，网页小说 カクヨム / なろう
  ruby 最多）同样用 `selectFromPosition`，但查词走 `SrsCardLookupController`，本轮没接 `rubySnap`：点「鼬」仍吸附到组首
  查「じょうろ」；且因共用 `designatesCurrentSelection`，查到じょうろ后再点「鼬」不再 toggle 取消，而是重新查一遍
  じょうろ（修复前是取消）。这两处宿主待接入 `resolveRubySnapSelection`。真机 / 三种 view mode 肉眼复测未做（本轮只在 headless Chrome 验 DOM 逻辑；
  选择脚本 `ReaderSelectionScripts.source()` 三种模式共用，阅读器 shell 只有分页 / 连续两份，测试两份都跑）。
