## BUG-4369 · 歌词模式插图缩略图的新插图红点看过也不消失
- **报告**：2026-11-08（开发者自提，反馈 VaaRL9s3Tg：「左下角只要不是封面就有红点，我都放大看了不应该还有红点」）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/audiobook/lyrics_player/lyrics_illustration_view.dart:694`（修前）提示点唯一条件是 `shown != null`——插图位只要不是封面就画点，与注释「换上了还没看过的插图」矛盾；`LyricsIllustrationController`（`lyrics_illustrations.dart:356-530`，修前）只有 `_reached` / `_shown` / `_cardOpen`，没有「已看过」状态，打开大图（`showLyricsIllustrationViewer` → `showAt`）或插图卡展示完自动收起（`closeCard`）都不会清点。不回封面的入口（`returnToCover: false`）看完大图后插图位留着插图，于是点一直在。
- **[x] ① 已修复** — 控制器新增「已看过」状态（按插图 `key` 记的集合，生命周期跟控制器 = 一次歌词模式会话，不持久化）：`markSeen(index)` / `isSeen(index)` / `shownUnseen`；`showLyricsIllustrationViewer` 打开即 `markSeen(start)`，大图翻页 `_onPageChanged` 同步 `markSeen`；`closeCard`（弹卡完整展示后到点收起 / 停留结束）把当前插图记为看过。提示点改为只在 `shownUnseen` 时画，出现 / 消失用 `AnimatedSwitcher`（`fushiMotionDuration(FushiMotion.short)`，淡入 + 缩放）。换上新插图时该图未看过，点重新出现。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/lyrics_illustrations_test.dart` 组「LyricsIllustrationController 已看过（新插图提示点）」（markSeen 后已看过、换新插图又未看过、翻页记看过、卡自动收起记看过、✕ 不算看过、重新 load 保留）；`fushi/test/media/audiobook/lyrics_illustration_view_test.dart`「竖屏：打开大图看过后提示点消失，换上新插图再出现」。
- **备注**：测试未在本分支运行，统一在合并后验证。
