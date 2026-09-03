## BUG-1742 · VN 模式下非 sasayaki 书的有声书自动跟随失效
- **报告**：2026-08-19（用户：）
- **真实性**：✅ 真 bug。根因是「VN 把正文搬出 document」与「跟随靠 document.querySelector」的正面冲突。

  **VN 把正文移出 document**：`fushi/lib/src/reader/reader_visual_novel_scripts.dart:950-962`
  `detachChapterSource()` 新建一个**游离**的 `<div>`（`this.sourceRoot`，从不 append 进 document），
  把 `document.body` 的全部子节点搬进去，再 `document.body.replaceChildren()` 清空。此后 document 里
  只有一个 stage，当前屏内容是 `renderScreen`（`:2433-2457`）**克隆**出来的。
  即：不是 shadow DOM / iframe，而是整章正文进了游离节点，document 里任一时刻最多只有当前一屏。

  **跟随路径踩空**：`fushi/lib/src/media/audiobook/audiobook_bridge.dart:206-219`
  `window.__fushiHighlight` 的 `:212 var el = document.querySelector(selector);` +
  `:213 if (!el) return;` —— 目标 cue 不在当前屏 → 返回 null → **静默 no-op**，永远不翻到目标屏。
  即便恰在当前屏，`__fushiRevealTarget`（`:148-165`）依次找 `scrollToRange`/`revealElement`/
  `scrollToTarget`，**VN 三个都没有**，落到 `scrollIntoView`，而 VN stage 是定屏无滚动 → 仍无效果。

  **为什么只有非 sasayaki 书坏**：分叉在 `audiobook_bridge.dart:440-472`。
  `SubtitleRematchCodec.tryDecode(raw)` 能解码（sasayaki）→ 走
  `window.fushiReader.highlightSentenceAudioCue`，VN 实现了它（`:2911-2937`，按 charOffset 找屏 →
  `renderScreen`），**完全不依赖 DOM 里有没有那个元素**，所以正常。
  解不出（纯 SRT/VTT/LRC 合成书，`textFragmentId = '[data-cue-id="N"]'`，见
  `packages/fushi_audio/lib/src/parsers/vtt_parser.dart:147` / `lrc_parser.dart:128` /
  `matching/cues_to_epub.dart:150`）→ 走 `__fushiHighlight` 的 `document.querySelector` → 踩空。

  Dart 侧无 VN 分支：`reader_fushi/audiobook.part.dart` 全文无 vn/VN 命中，
  `_onCueChanged`（`:640-647`）无条件调 `AudiobookBridge.highlight`。

- **[x] ① 已修复** — 提交见本分支。
  - `reader_visual_novel_scripts.dart` 的 host-compat shim 块新增：
    - `vn.contentRoot()` → 返回 `this.sourceRoot`（正文根的唯一正确取法；**不是** `createWalker` 的
      默认根 `this.screen`，那只是当前屏）。
    - `vn.screenIndexForCharOffset(charOffset)` → 从 `restoreToCharOffset` 里提出来的两段式查找
      （先找覆盖该偏移的屏，再取第一个末尾越过它的屏），供跟随与搜索复用。
    - `vn.highlightSelectorCue(selector, reveal)` → 选择器 → `contentRoot()` 找源节点 →
      `contentStream.sourcePositionForNode()` 换算字符偏移 → 屏索引 → `renderScreen(idx, true)`。
      与 sasayaki 的 `highlightSentenceAudioCue` 收敛到同一条链路。`reveal=false` 时不翻屏
      （那是「别打断当前阅读位置」的显式请求）。渲染后在当前屏克隆上打 `.fushi-active`
      （克隆每次渲染重建，所以只能渲染后打、也不必清旧的）。
  - `audiobook_bridge.dart` 的非 sasayaki 分支：优先
    `window.fushiReader.highlightSelectorCue`，无此方法（分页/连续模式）回落 `__fushiHighlight`
    —— 那两个模式行为零变化。

- **[x] ② 已加自动化测试** —
  - `fushi/test/reader/vn_shell_smoke_test.dart` 新增：VN 必须实现全部宿主接口
    （`contentRoot`/`screenIndexForCharOffset`/`highlightSelectorCue`/`scrollToSearchMatch`/
    `clearSearchHighlight`，engine 三 shell 并存时同样带齐）；`contentRoot` 必须返回 `sourceRoot`
    而非 document；选择器跟随必须走「`contentRoot()` → `sourcePositionForNode` →
    `screenIndexForCharOffset` → `renderScreen`」且保留 `reveal=false` 早退。
  - `fushi/test/reader/vn_non_sasayaki_follow_guard_test.dart`（新建）：接线守卫 —— 非 sasayaki
    分支必须优先走 `highlightSelectorCue` 且带 `typeof` 判定；`__fushiHighlight` 回落必须在其 else 分支；
    `cue==null` 的清除路径不受本次改动波及。
  - 验证：`flutter test test/reader/ test/pages/ test/media/ --no-pub` → 8961 passed。

- **备注**：headless 无真 InAppWebView，**逐句翻屏须真机复验**（见
  `docs/agent/integration-testing.md`）。守卫只锁接线与源码不变量。
  与 [[BUG-1743]] 同属「VN 缺宿主接口」这一族，同一 shim 块落地。
  `SASAYAKI_PARITY_PLAN.md` 讲的是上游 Anki handlebar，与 VN 无关，没有 VN↔sasayaki 能力差异清单。
