## BUG-5195 · mine-notice-chrome-placement
- **报告**：2026-11-22（用户：视频的制卡提示「硬避开了播放顶栏」，顶栏收起后照样空着那段；漫画有声模式的制卡提示和播放底栏重叠）
- **真实性**：✅ 真 bug。两处位置都是写死的数，不知道页面 chrome 此刻在不在、有多高：
  - 视频：`fushi/lib/src/pages/implementations/video_fushi/volume_osd.part.dart:429`（develop 953439347f）OSD / 制卡结果卡 `top: _videoButtonBarHeight + 8 * _videoUiScale` 恒定，不看 `_videoControlsVisible`；`:461` 同口径，右上角角标、字幕转文字进度卡照抄同一个数。
  - 底部 toast：`fushi/lib/src/utils/misc/fushi_toast.dart:332` `_toastBottomOffset` 恒为桌面 50 / 移动端安全区 + 96；漫画有声模式的播放条连同页码滑条比它高，卡片压在栏上。小说 / PDF 阅读器底栏、首页 / 收藏 / 音乐等用 `FushiChromeReveal` 的底栏同类。
- **[x] ① 已修复** — 新增 `fushi/lib/src/utils/misc/notice_placement.dart`：chrome 显隐组件（`FushiChromeReveal` up/down、`MangaChromeReveal`）把自己包进 `FushiNoticeObstacle`，按显隐进度登记全局矩形；toast 每次重建按当前登记用纯函数 `noticeBottomOffset` 让到 chrome 上沿 + 12，栏进退场时按进度插值、收起后回到默认底距。只认 `TickerMode` 开着的页面（被盖住的页面不算）。视频顶栏是 media_kit 内部控件包不进来，`_followTopChrome` 用同一纯函数 `noticeTopOffset` + 合成的顶栏矩形，随 `_videoControlsVisible` 同速过渡；OSD、制卡结果队列、循环标记、制卡队列角标、字幕转文字进度卡全部改走它。同一 PR 里制卡提示整体重做（词条首行、可见标题、重复改青色、深色色调、分档停留与悬停停表、处理中原地变结果、连续结果叠放、失败卡展开详情、查看队列 / 仍要添加），见 PR 描述。
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/notice_placement_test.dart`（纯函数表测 + 真实 `FushiChromeReveal` 底栏登记后结果卡不与栏相交、栏收起后回落）；`fushi/test/pages/video_osd_card_created_alignment_guard_test.dart`（顶部浮层走 `_followTopChrome` / `noticeTopOffset`，写死的「顶栏高 + 8」不许回来）。
- **备注**：视频页按 BUG-931 守卫不能 import toast，所以纯函数与登记表单独放在 `utils/misc/notice_placement.dart`。
