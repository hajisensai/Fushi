## BUG-843 · 顶部阅读进度毛玻璃pill压住正文首行
- **报告**：2026-07-16（用户：顶部进度挡字，没开悬浮阅读进度，翻页模式，全端都有）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:1360`（旧 `_infoStripHeight = _infoFontSize * 1.5`）与 `hibiki/lib/src/pages/implementations/reader_hibiki/chrome.part.dart:1779`（pill `EdgeInsets.symmetric(vertical: 3)`）。
  - 顶部进度预留高走单一真相源 `topProgressReserve(infoStripHeight: _infoStripHeight)`（`reader_chrome_floating.dart:43`），挤压且显示时预留 `_infoStripHeight`；该预留经 JS `setChromeInsets` → CSS `--chrome-top-inset` 下压正文 padding-top，pill 则以 `Positioned(top: _stableTopInset)` 覆盖在预留区。铁律：pill 视觉高必须 ≤ 预留高，正文才不会被压。
  - BUG-547 / TODO-1136（commit `41b945272`「悬浮阅读进度加毛玻璃背景」）给 pill 包了 `ClipRRect > BackdropFilter > Container(padding: vertical 3)`，pill 实高 = 文字行盒（真机字体约 14~16px）+ 上下 6px 内边距 ≈ 20~22px，**但该 commit 没同步上调 `_infoStripHeight`**（仍 18px）。于是挤压模式（未开悬浮进度、翻页/连续皆然）下 pill 高出预留 2~4px，盖住正文首行。纯布局常量失配，与平台/时序无关，故全端稳定复现。
  - headless 测试字体（Ahem）行盒恰等字号、不溢出 em 盒，复现不出真机字体高度溢出（与本仓库多处「headless 测不出」同源）。
- **[x] ① 已修复** — 把顶部进度的字号 / pill 内边距 / 预留高提到公共真相源 `reader_chrome_floating.dart`：`kTopProgressFontSize=12`、`kTopProgressPillVerticalPadding=3`、`kTopProgressStripHeight = kTopProgressFontSize*1.5 + 2*kTopProgressPillVerticalPadding = 24`。`reader_hibiki_page.dart` 的 `_infoFontSize`/`_infoStripHeight` 与 `chrome.part.dart` 的 pill 内边距均改引这些常量——pill 高与预留高从此共享同一批常量，杜绝再漂移。提交见下。
- **[x] ② 已加自动化测试** — `hibiki/test/reader/reader_top_progress_reserve_test.dart`：确定性算术不变量守卫（预留高 ≥ 行盒估计 + pill 双边内边距、且确由字号与内边距推导）+ widget 实测 pill 高度 ≤ 预留。已硬验证：把预留退回旧值 18 时三处断言失败（`Expected ≥24, Actual 18`），还原即绿。
- **备注**：悬浮态（`top_progress_floating` 开）预留恒 0、pill 浮在正文上自动收起属设计内，不受影响；本修复只影响挤压且显示进度时多下压 6px 正文区（正确代价）。caret/焦点环/弹窗避让均沿用同一 `_readerTopOffset`，随之一致，无破坏。
