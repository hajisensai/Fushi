## BUG-2442 · 首页活动时间轴的视频缩略用横版槽，竖版海报被缩成模糊小条
- **报告**：2026-09-10（用户：截图报「右边的不对」「竖排视频海报，显示成横排了」，指首页右侧「活动」时间轴）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/home_dashboard_page.dart:2578`（`_activityLeading` 的 video 分支）：视频活动条写死 `SizedBox(width: 68, height: 40)` + `landscapeSlot: true`，而同一列表的书与游戏分支都是 `40×56` 竖版槽。刮削（MAL/TMDB）写进 `video_books.cover_path` 的是 2:3 竖版海报，进横槽后被 `PortraitCoverImage._mismatch` 判为不合槽 → 模糊垫底 + `BoxFit.contain`，海报只剩中间一小条（截图里「薬屋のひとりごと」几条即是纯蓝糊块）。同一列表里书是竖版、视频是横版，也让时间轴左缘参差。
- **[x] ① 已修复** — 消掉这个媒体类型特例：视频活动条改用与书/游戏同样的 `40×56` 竖版槽、去掉 `landscapeSlot: true`（回到用户 2026-07-24 拍板的「统一竖版」）。横版截帧进竖槽仍由 `PortraitCoverImage` 的槽向自适应垫底，BUG-1299 的行为不受影响。提交：`b8c34f407f`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_dashboard_page_test.dart`（「点继续区视频卡/活动条直接续播」用例）：原钉 `68×40` 的断言改钉 `40×56`，并新增反向断言 `68×40` 槽 `findsNothing`（不得回退横版槽）。变异实测：把生产代码改回 `68×40`，该用例红（`Found 0 widgets`），断言非空壳。
- **备注**：`PortraitCoverImage` 与 BUG-1299 的横槽自适应逻辑本身没问题，问题只在活动条选错了槽向；`video_episode_rail.dart` / 合集详情单集缩略图的 `landscapeSlot: true` 是真横版槽（16:9 单集截帧），保持不变。
