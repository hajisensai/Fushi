## BUG-1991 · 字幕轨入口误开底部字幕调整抽屉而非右侧设置栏
- **报告**：2026-08-31（用户：点击「字幕轨」后面板跑到画面底部，预期仍是右侧设置栏）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/video_fushi_page.dart:7025` 的统一设置入口在收到 `initialCategory: 'subtitle'` 时，专门改派 `_VideoSidePanelKind.subtitleAdjust`；因此字幕轨按钮、右键菜单和字幕加载入口都会绕开右侧 `_VideoSidePanelKind.settings`，落入底部抽屉。
- **[x] ① 已修复** — 移除字幕分类的容器分流，保留 `initialCategory: 'subtitle'`，统一由右侧设置栏打开并直达字幕分类（本分支提交）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_controls_cleanup_guard_test.dart` 锁定 `_showPlayerSettings` 使用 `settings`，禁止字幕分类条件分流及 `subtitleAdjust` kind。
- **备注**：代码路径与源码守卫已覆盖；Windows 真机点击与视觉位置复测待 PR CI / 设备验收。
