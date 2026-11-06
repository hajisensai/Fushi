## BUG-4131 · video-settings-tab-switch-entrance-replay
- **报告**：2026-11-05（开发者自报：应用内反馈 Zc-iEbsImS，Windows 3.3.0-debug.23866）——第一次打开播放器侧边栏，从「播放」进「画质增强」，滑到位以后页面又刷新一次（列表闪一下重建）。
- **真实性**：✅ 真 bug。`fushi/lib/src/media/video/video_quick_settings_sheet.dart` 原 :126 `_categorySwitched` 初值 false，原 :330 把它当分类页 `FushiEntranceScope.enabled`；切页时 TabBarView 先把新页（enabled=false，直接显示）滑进来，TabController 只在**落定后**通知（原 :151-155），`_selectSubPage`（原 :212-217）这时才 setState 把 `_categorySwitched` 翻成 true——`FushiEntranceScope.didUpdateWidget` 见 enabled 变化即重开窗口、generation+1，已经看得见的整页（`FushiStaggeredEntrance(index: 1)` 包着整页内容）从透明重播一次进场。开关只翻一次，所以只有「第一次」切页闪。
- **[x] ① 已修复** — 去掉「落定后翻开关」：面板首帧后（post-frame，不 setState）置 `_firstFrameShown`，每个分类页用 `_CategoryPageEntrance` 在**挂载时**把是否进场定死（`late final`），之后 rebuild 不再改。首开那页不放（由面板外壳滑入承担动效），之后新挂载的页照常错峰进场，已可见的页不会再被重播。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_settings_tab_switch_entrance_test.dart`：真实面板首次从「播放」点「画质增强」，逐帧记录新页进场包装的最小透明度，一旦完全显示后再变透明即失败。
- **备注**：Windows 桌面上肉眼复测未做（本轮无 GUI 巡检）。
