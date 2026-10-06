## BUG-2989 · 阅读器设置面板换侧及宽窄切换销毁会话
- **报告**：2026-10-06（样式改版审查）
- **真实性**：真实组件生命周期缺陷。新增侧栏切换器引入换侧卸载路径；跨 compact 断点的同类生命周期问题在该次切换器提交前已存在。
- **根因**：固定快照 `1a5424c847a` 的 `fushi/lib/src/reader/reader_desktop_chrome.dart:895` 附近面板与 rail 交换未加 key 的兄弟顺序，宽窄切换又替换侧板/底部 sheet 两棵布局。`fushi/lib/src/reader/reader_settings_side_dialog.dart:118` 的会话 dispose 会释放仍被路由使用的共享 side controller，同时丢失编辑状态。
- **[x] ① 已实现修复** — 面板与 rail 使用稳定 sibling key；每条路由拥有唯一会话 GlobalKey，跨布局保留同一个会话及 controller，只在路由结束销毁。提交见本文件所在修复提交。
- **[x] ② 已增加自动化测试** — `fushi/test/reader/reader_panel_switcher_side_state_test.dart`：双向换侧、1280→420→1280、再次换侧；断言 TextField State、草稿、偏好持久化及无异常。
- **验证结果**：见 [审查报告 HBK-AUDIT-011 及最终验证记录](../reviews/2026-10-06-project-review.md)。
- **备注**：真实阅读器窗口操作、正文 WebView 焦点及设备验收待补，不宣称实机通过。
