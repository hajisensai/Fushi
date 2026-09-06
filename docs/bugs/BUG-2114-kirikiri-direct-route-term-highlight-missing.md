## BUG-2114 · KiriKiri 直连路由下被查整词不高亮，只亮点击的单字
- **报告**：2026-09-04（ceshi 批量适配 · KiriKiri Z `tenshi_sz.exe` 真机：单击「好」弹卡「好き」，台词里只有「好」一个字亮蓝，「き」不亮；Shift 悬浮「多」弹卡「多分」同样只亮「多」。验收要求是「点击后被查的整个词在台词里保持高亮」，SGRE 已由 BUG-2087 做到）
- **真实性**：✅ 真 bug。BUG-2087 让 host 在直连卡片呈现后追加 `kLookupFrameHighlightOnly` 帧，KiriKiri 适配器也消费它——但 `PresentKirikiriLookupFrame` 的高亮分支 `if (g_lookup_card_shown) ApplyKirikiriLookupHighlight(...)`，而直连路由（BUG-1882：WebView2 卡片直接贴在游戏客户区）下 TJS 卡片层从不 visible，`g_lookup_card_shown` 恒 false；TJS 侧 `fushiLookupApplyHighlight` 又以 `card.visible && CardSeq != 0` 为门。两道门都是位图路由时代「卡片就是 TJS 层」的假设，直连下整词高亮帧被静默吃掉，只剩 hover 那一个字。
- **[x] ① 已修复** — `kirikiri_adapter.inc`：高亮分支去掉 `g_lookup_card_shown` 门（高亮帧本身就是 host「此刻有卡」的证据，dismiss 帧走 `HideKirikiriLookupCard → fushiLookupDismiss → ClearHover` 一并擦除）；TJS `fushiLookupApplyHighlight` 去掉 `card.visible/CardSeq` 门，只要求命中 entry 存在且 `highlightLen > 0`。
- **[x] ② 已加自动化测试** — 真机复验记录在台账（同一直连会话截图：整词区间高亮）。结构性测试：`tests/kirikiri_lookup_source_guard_test.py` 既有规则仍全绿（TJS 回执仍只含整数）。
- **备注**：hover 高亮与整词高亮共用 `fushiLookupPaintHighlight` 同一层；卡片打开期间鼠标再移到别的字会改画 hover 字格，与 SGRE 行为一致。
