## BUG-280 · 歌词模式查完一个词无法继续查下一个
- **报告**：2026-06-15（用户：）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/audiobook/lyrics_mode_html.dart:195`（旧 `#lc` 用 DOM `'click'` 事件触发查词）。
  - 歌词页查词靠 `#lc` 的 `click` 监听 → `hoshiSelection.selectText`。`click` 只在「pointerdown→pointerup 全程未被宿主层认领」时由浏览器合成。
  - 当一个查词弹窗已可见时，`hibiki/lib/src/pages/base_source_page.dart:373-385` 会铺一层全屏 `Positioned.fill` 的 translucent `GestureDetector`（`onTap: clearDictionaryResult`，关弹窗）。它在手势竞技场里认领这次点按 → WebView 拿不到合成 `click` → 查完一个词后再点下一句只把弹窗关掉、不发起新查词（用户感知「无法连续查」）。
  - 对照：阅读器正文连续查词正常，因为它走自绘的 `touchend` / `pointerup`（`{passive:false}`）原始指针监听（`reader_hibiki_page.dart` 的 `_buildReaderSetupScript`），不依赖合成 `click`，即使弹窗屏障在场，WebView 仍能拿到原始指针流并发起查词。
- **[x] ① 已修复** — `hibiki/lib/src/media/audiobook/lyrics_mode_html.dart`：把 `#lc` 的查词触发从 DOM `'click'` 改成原始 `pointerup` / `touchend`（`{passive:false}`）+ 小位移门控（拖动滚动不误触发），对齐阅读器正文机制，使弹窗屏障在场时 WebView 仍能拿到点按并连续查词。中键/侧键「点句 seek」的 `mousedown` 监听不变。提交：（见报告）。
- **[x] ② 已加自动化测试** — `hibiki/test/media/audiobook/lyrics_mode_html_test.dart`：新增「lyrics tap uses raw pointer/touch (not synthesized click) for lookup」守卫，断言 `#lc` 用 `pointerup`/`touchend` 触发查词、不再用 `'click'`、且 `{passive: false}` 注册；并更新原「current cue tap」用例到新机制。
- **备注**：JS 运行时的「弹窗在场仍能连续查」需真机/真模拟器复测（host 无法跑 WebView + Flutter 手势屏障交互）。CSS/JS 生成器层守卫已覆盖触发机制改写。
