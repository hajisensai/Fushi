## BUG-1138 · gal 台词浮窗/剪切板文字窗把注音标记当正文显示，污染查词与字数
- **报告**：2026-07-27（用户：截图 WITCH ON THE HOLY NIGHT，浮窗显示 `今もピリピリと空気を<rふる>震</r>わせている。`，游戏本体是把 `ふる` 渲染在「震」上方）
- **真实性**：✅ 真 bug。根因不是渲染，而是**全链路从来没有注音标记这一层**：
  - LunaHook 侧只做重复/伪影过滤（`native/galgame_hook/include/luna_text_selector.h:33`），不认注音标记；
  - `hibiki/windows/runner/voice_hook_reader.cpp:308` 只截断不改写；
  - Dart 第一落点 `hibiki/lib/src/mining/galgame_audio_source.dart:1259` 原样构造 `GalHookedLine`；
  - 唯一的正文改写是 `hibiki/lib/src/sync/texthooker_service.dart:457` 的 `trim()`。
  于是原始标记一路进 `entry.text`，而 `entry.text` 同时是**浮窗显示串、点字查词 `wordFromIndex` 的输入、制卡 sentence、字数统计输入**（`gal_hook_text_overlay_controller.dart:302/325/546`、`gal_hook_mining_coordinator.dart:164`、`gal_hook_session_controller.dart:2416`）。
  三处可见后果：① 浮窗显示原始标记；② 点到 `<`/`r`/`ふ` 等标记字符时分词从标记切起，查出垃圾；③ `countGalgameChars`（`galgame_char_count.dart:48`）把注音假名按 CJK 逐码点计入阅读字数，字数虚高。
  剪切板链路同理：`desktop_lookup_service.dart` 的文本未经任何标记处理即进透明文字窗、悬浮面板与 `clipboard_history.content`。
- **[x] ① 已修复** — 新增纯函数解析器 `hibiki/lib/src/utils/misc/ruby_markup.dart`（`parseRubyMarkup` → `RubyMarkupText{text, spans}`，抄字幕侧 `parseSubtitleMarkup` 的「正文不加不减 + 旁路下标区间」范式，坐标单位改用 **UTF-16 code unit** 以对齐 DirectWrite `HitTestPoint`）。
  - 剥离点选在**文本成为下游唯一坐标系之前**：gal hook 在 `texthooker_service.dart` 的 `appendLine`，剪切板在 `desktop_lookup_service.dart` 的 `_queueLookupRequest`（三个来源共同收口，且必须先于按字素截断，否则截断会把标记拦腰切断）。放到显示层剥会让 `gal_hook_text_overlay_controller.dart:541` 的 `entry.text != text` 守卫恒真，点字直接弹「行不可用」。
  - native 渲染复用既有 `HitTestTextRange`（与高亮背景框同一套几何）在基准字上方画小号假名，并用 `SetLineSpacing` 加高行盒让位：`text_` 里不含任何注音字符，**点字 index / 高亮 range / dim range 三个既有契约零改动**。`rubySpans` 缺省即完全走老路径，逐像素与今天一致。
  - 支持语法：`<rふる>震</r>`（截图实例 / BGI 系）、`<ruby>震<rt>ふる</rt></ruby>`（含 `<rb>`/`<rp>`/`<rtc>`）、`｜震《ふる》`、裸 `震《ふる》`、`震[ふる]`。歧义形式（裸 `《》`、`[かな]`）要求「注音全假名 + 前面紧挨汉字串」；认不出的标记一律原样保留，绝不猜着删。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/utils/ruby_markup_test.dart`（28 项）：语法矩阵、误伤防御（`<red>`、`《LONDON》`、`[2026/07/27]`）、混排偏移、`rebase` 偏移守恒。
  - `hibiki/test/sync/ruby_markup_pipeline_test.dart`（10 项）：两条链路上 `entry.text` / `request.text` 确为纯基准文本且区间对齐、无注音时零变化、`copyWith` 不丢注音、字数口径修正。
  - `hibiki/test/build/overlay_ruby_render_guard_test.dart`（4 项）：C++ 无法在 Dart 测试里执行，故在源码层锁死「复用 HitTestTextRange 不自建排版」「`text_` 不含注音、`CharIndexAt` 仍直回 `textPosition`」「无注音时不走任何注音分支」「两通道解包 + 越界区间丢弃 + 缺省参数」。
- **备注**：
  - **行为变化（有意）**：注音假名不再计入 `charsDelta`，历史阅读字数统计会有一处小幅断层——这是口径修正，不是回归。
  - app 内悬浮面板 / 瞬态卡本轮只拿到剥干净的文本，**不渲染振假名**（它们是 Flutter 侧另一套渲染，仓库已有 `RubyTextData`/`RubyText` 可复用）；本轮范围按用户所述限定在 gal 弹窗与剪切板弹窗两个 native 浮窗。
  - 顺带发现的**另一个既有真 bug（本轮未夹带）**：字幕侧 `packages/hibiki_audio/lib/src/parsers/strip_html_tags.dart:15` 只删标签保留内容，VTT/SRT 里的 `<ruby>震<rt>ふる</rt></ruby>` 会被拼成 `震ふる` 污染 `plainText`、进而污染查词与制卡。应另立条目按同一 `RubyMarkupText` 结构修。
  - native 振假名的**像素观感未经真机验收**：本机可跑的 Windows 离屏 itest 取不到原生覆盖窗截图（见 `docs/agent/integration-testing.md`），且没有该游戏样本。Dart 侧契约与 C++ 编译已验证，渲染效果需用户在真实浮窗上目视确认。
