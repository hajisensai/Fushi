## BUG-3360 · 首页继续区视频作品海报文件不在时直接显示占位，不回落到集封面
- **报告**：2026-10-14（用户：反馈 5CTpiVJ7-v，Windows，「横屏视频自适应没了而且封面不显示」，截图首页「继续」主角卡与横滑卡的视频画成「图标 + 名字」占位）
- **真实性**：✅ 真 bug，两部分同源于 abf7b5ff9d（10-09 统一 2:3 竖卡）。
  - 封面不显示：`fushi/lib/src/pages/implementations/home_dashboard_page.dart:2229`（`path: posterPath ?? video.coverPath`）只认一个候选：合集主封面路径非空就用它，文件不在（换盘 / 清缓存 / 刮削改过路径）也不回落；这一集没抽帧时也不借同合集其它集的封面——而视频页合集卡（`home_video_page.dart` `_collectionRowCoverProvider`）是「自有封面存在才用，否则借成员」。
  - 横屏自适应没了：同一提交把「继续」主角卡（`home_dashboard_widgets.dart` `HomeContinueHero` 固定 `coverWidth * 1.5` 竖槽）与横滑卡（`_buildContinueCard` 固定 `coverHeight * 2/3` 宽）钉死成 2:3，没有竖版海报、只有每集截图的视频也被裁进竖卡。用户 2026-10-14 拍板：「卡片比例跟着实际用到的图走」，覆盖该提交对无海报视频的行为；有海报的作品保持竖卡。
- **[x] ① 已修复** —
  - d8830baef6：纯函数 `dashboardVideoCoverPath`（海报 → 本集封面 → 同合集其它集封面，取第一张磁盘上真存在的，成员惰性探测、找到即停）。
  - 8de5a8023c：`_videoCoverImage` 取回退链实际选中的那张图（远端取 host 封面），`HomeCoverOrientationProbe` 与封面渲染共用同一 provider，按解码出的真实宽高比判横竖（`homeCoverIsLandscape`：> 1 横，否则竖；首帧前 / 失败按竖）。横卡 16:9、宽为竖卡 1.5 倍（`homeContinueCoverSize`），横槽内截图完整显示；主角卡同理（宽封顶卡宽一半）。横滑行每张卡贴行底对齐，标题仍在同一条线；尺寸切换走 `AnimatedContainer` + `FushiMotion`（墨水屏 / 减弱动态效果归零），MD3 与 Apple 共用同一几何。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_dashboard_page_test.dart`：海报文件不在时回落到集封面且不画占位；`dashboardVideoCoverPath` 四条单测；横滑行只有横版截帧的视频是 16:9 横卡、宽 1.5 倍书卡、底边对齐；主角卡只有横版截帧 → 16:9 槽、作品竖版海报 → 2:3 槽；`homeCoverIsLandscape` / `homeContinueCoverSize` 单测。源码守卫 `fushi/test/pages/continue_cover_portrait_guard_test.dart` 同步为「渲染收在 `_coverImage`、横竖由探测决定、不许回退成按媒体类型写死的 16:9 宽度常量」。
- **备注**：无截图外的证据能 100% 确认用户机器上走的是哪一个空缺分支（海报文件缺失 / 集封面未抽帧）；两条都已被回落链覆盖。
