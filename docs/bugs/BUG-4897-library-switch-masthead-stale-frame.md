## BUG-4897 · 库页从「在线」切回「书架」：首帧大号页头压在旧滚动位置的内容上，点下去约 0.5 秒才切
- **报告**：2026-11-15（用户：拼贴审查设计稿 #manga C2，附录屏）
- **真实性**：✅ 真 bug。根因两处，都在库页视图壳 `MediaLibraryShell`（书架 / 漫画库共用）：
  1. 浮动工具栏状态（显隐、页头大字折叠进度 `mastheadScrollOffset`、`contentUnderTop`）全壳只有一份
     `_chrome`（`fushi/lib/src/pages/implementations/media_library_shell.dart:448` 挂进作用域），切视图时
     `_select` 无条件 `_chrome.resetToTop()`（同文件 `:306`）把它重置成「顶部」。但视图是保活的，书架的
     `ScrollController` 仍停在中段——于是切回首帧：页头按 offset 0 画成展开的大号，内容按旧 offset 画在它
     底下；下一帧书架发来版面通知，controller 才把 offset 改回真实值，页头缩回小号。
  2. 切换只是壳 setState，但 build 里对**每个**访问过的保活视图都重新调 `views[i].builder(...)`（同文件 `:425`），
     生成新的页面 widget，书架整页卡片墙与在线视图都整页重建，切换那一帧被拖长（点下去约 0.5 秒才动）。
- **[x] ① 已修复** — 每个视图各自一份 `FushiFloatingChromeController`（按 `MediaLibraryViewKind` 存，作用域挂当前
  视图那份；滚动 / 版面通知由各视图自己那层喂给自己的 controller），切换只 `show()` 目标视图的工具栏、不再重置；
  视图内容按种类缓存（父级换视图声明 / 壳依赖变化才作废），切换不重建保活视图；切换按 `FushiMotion.short`
  交叉淡入（新视图淡入、刚离开的视图留在台上同步淡出，期间不收指针 / 焦点 / 语义；`fushiMotionDuration`，减弱
  动效下直切）。提交哈希：收尾阶段统一提交后补。
- **[x] ② 已加自动化测试** — `fushi/test/pages/media_library_shell_switch_state_test.dart`（焦点驱动：分区停靠点 +
  方向键切视图；断言切回首帧页头折叠进度 = 书架自己的、内容 offset 不动、首帧在交叉淡入且离开的视图不收指针、淡出结束回到
  Offstage；切换不再调保活视图 builder）。
- **备注**：页头大字高度随「有无二级页签」变化时，内容让位高度经 `FushiHeightReporter` 帧末上报、晚一帧生效
  （`fushi_floating_chrome.dart` 的结构性一帧滞后），本修复范围外，已作为跨线请求提出；切换淡入首帧不透明度为 0，
  该帧不可见。视频库壳 `video_library_shell.dart:177` 有同款 `resetToTop()`，未改。「约 0.5 秒」的根因 2 是沿代码路径推断
  （主页签 `onSelectionChanged` 同步回调、无人为延迟），未在真机上量帧耗时；设备肉眼复测待补。
