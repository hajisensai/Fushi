## BUG-4351 · ASS 卡拉 OK 歌词（同一 \pos 多条事件）被竖排成多行、光晕残影；渲染活动集只按 125ms 刷新
- **报告**：2026-11-08（开发者自提，反馈 WWUuaXulfG，Windows 3.3.0-debug.24651，截图：BanG Dream 英文字幕轨作副字幕，顶部歌词「la,」/ 黄色光晕行 / 红色「Lalalalala lalalalalala」上下叠成几行）
- **真实性**：✅ 真 bug。副字幕与主字幕同走 Flutter overlay 自绘（`secondary-sid` 只在远端内嵌轨回落时解码不画），不是 mpv 渲染问题。
  - 根因 1（叠行）：`fushi/lib/src/media/video/video_subtitle_overlay.dart:1748`（develop 704f8c6）`_groupMainCuesByPosition` 按位置键分组，`\pos` 相同、Layer 相同的多条同时事件进同一个组，`_positionCueGroup` 把组内 cue 放进一个 `Column` 竖排堆叠再整体落到 `\pos`。libass 对显式定位事件不做碰撞（`detect_collisions = !explicit`），同一 `\pos` 的整行底字、逐音节高亮 / 光晕拷贝原地叠画成一行卡拉 OK；overlay 却把它们排成上下好几行（离场 cue 还留隐形占位撑住槽位）。主、副字幕同一条路径，只是这次的卡拉 OK 轨在副字幕槽。
  - 根因 2（「刷新率」/ 残影）：`fushi/lib/src/media/video/video_player_controller.dart:4010` 渲染活动集只由 125ms tick 重算（`:4005` 位置事件只发布位置），而 `\fad` / `\move` / `\t` / `\k` 动画逐帧读时钟。几十毫秒一条的逐音节 / 逐帧特效事件按 8 Hz 取样：新事件最多晚 125ms 上屏，结束的事件最多多留 125ms。
- **[x] ① 已修复** — 显式定位（`\pos`，尊重样式时含 `\move`）事件各自成组（分组键追加 cue 身份序号），同位原地叠画、按 Layer + 事件序绘制；新增 `isExplicitlyPositionedCue`。控制器在 libmpv 每次推位置时按 `subtitleClockMs` 无副作用地重算渲染活动集（`_syncRenderActivityToClock`，副字幕 / 绘图 / 主字幕渲染集），代表 cue、句尾暂停、循环、进度保存、seek 宽限仍归 tick。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_explicit_pos_overlay_test.dart`（同一 `\pos` 顶锚 / 底锚两条事件原地叠画；无 `\pos` 同锚点对白仍竖排；位置更新即重算副 / 主渲染集）。测试未在本分支运行，统一在合并后验证。
- **备注**：没有拿到原片源的 ASS 文件，叠行机制是按截图形态 + 代码路径推出的（同 `\pos` 多事件进 Column 堆叠正好产生「底字 / 光晕 / 单音节」上下错开的三行）；需拿原片 + 英文字幕轨复测。另：副字幕被强制置顶 / 置底的锚点组（无 `\pos`）按 Layer 拆成多组后各自独立让位（BUG-4123 的 `_CueCollisionStack`，每组自己的让位线），多层特效理论上可能被让成上下错位，本次未改，待有样本再看。
