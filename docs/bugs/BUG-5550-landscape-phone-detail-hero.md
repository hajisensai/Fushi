## BUG-5550 · 横屏手机：详情页背景带占七成高度，标题与主按钮被挤出首屏
- **报告**：2026-11-26（用户：横屏手机外壳修复（PR #4522）之后，要求把阅读器 / 播放器 / 有内容的库与详情页也查一遍）
- **真实性**：✅ 真 bug。Android 模拟器横屏（914×411 dp）书详情 / 视频作品详情：有横版背景图时背景带约占视口 72%，书名落在屏幕下沿，「继续阅读」整个在首屏外；视频详情「开始观看」只露出一半。根因 `fushi/lib/src/media/detail/media_poster_detail.dart:671`（`_artBandHeight` 宽式按 `maxViewportFraction: 0.72` + `minArt: 220` 给带高，只看比例、不看首屏还剩多少给标题块）。横屏手机宽 ≥720 走宽式，桌面的比例上限原样套在 411 高的窗口上。顺带：1280×800 桌面窗口主按钮也已经超出窗口底 6 px。
- **[x] ① 已修复** — 背景带（含页头让位）统一再夹一个首屏上限 `_bandFirstScreenCap` = 视口高 − `kMediaPosterDetailFirstScreenReserve`（240，一行大标题 + 作者 / 原名 + 进度或续播行 + 主按钮与间距），至少留够页头一行；宽式海报随之缩，保证海报上沿仍落在背景带里、不把带子重新撑高。窄式 / 竖屏手机 / ≥1000 高的桌面窗口不受影响（比例上限更紧）。
- **[x] ② 已加自动化测试** — `fushi/test/media/detail/media_poster_hero_first_screen_test.dart`（914×411 主按钮整个在首屏；800 高桌面主按钮也在首屏；1000 高桌面背景带照旧 720）。修前跑红（主按钮底 496 > 411、806 > 800）。设备巡检脚本 `fushi/integration_test/landscape_phone_content_sweep_itest.dart`（书架 / 视频库 / 两种详情 / 阅读器三种 view mode + 底栏 + 快速设置 / 播放器，MD3 + 玻璃）。
- **备注**：同一轮巡检里阅读器三种 view mode（paginated / continuous / vn）的顶底栏、快速设置侧栏在横屏手机上正常，未改。
