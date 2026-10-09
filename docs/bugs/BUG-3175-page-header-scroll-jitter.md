## BUG-3175 · 页头随滚动收起来回跳
- **报告**：2026-10-09（用户：Android 顶栏会来回跳、太容易触发）
- **真实性**：✅ 真 bug。`fushi/lib/src/utils/components/fushi_floating_page_chrome.dart` 的 `FushiScrollAwayController.handleNotification` 没有滞回：`UserScrollNotification` 一报 reverse 就收起、一报 forward 就叫出。手指拖动总带几 px 的来回抖动，每次抖动都翻转一次用户滚动方向 → 一次滑动里页头收起 / 弹出来回跳。首页外壳的 `FushiFloatingChromeController`（`fushi_floating_chrome.dart`）早有 24px 同向累计滞回，二者口径不一。
- **[x] ① 已修复**（`03bc68c7e7`）— 页头收起改为同向累计滞回（`toggleDistance = 24`，与外壳同值）：只累计用户发起的位移（拖动 / 惯性 / 滚轮，程序滚动不计），反向即清零重攒；收起仍要求离顶 > `revealZone`，回到顶部恒显示。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_scroll_away_gesture_test.dart`「拖动中的几 px 来回抖动不会让页头来回跳（滞回）」；原有两条（拖过 reveal zone 收起、程序滚动不收起）保持通过。
- **备注**：用户的视频附件无法播放，未在真机取证；按代码路径确认抖动来源后修复。
