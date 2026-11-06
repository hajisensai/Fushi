## BUG-4219 · 配对后红屏：弹窗关闭动画期间输入框控制器已被释放
- **报告**：2026-11-06（用户：samutw；服务端 Anki 路径真机检查时在模拟器上撞到）
- **真实性**：✅ 真 bug。当前 develop（`efeb28a7dd`）debug 包在 Android 模拟器上复现：互联手输地址配对，PIN 弹窗点「继续」即整屏红（`framework.dart:6281 '_dependents.isEmpty'`）。应用错误日志里的**第一条**是 `A TextEditingController was used after being disposed`（`_AnimatedState.didUpdateWidget` 给已释放的控制器加监听），手输地址弹窗点 OK 时也出现一次。根因：调用方自建控制器交给弹窗，`await showAppDialog` 一返回就 `dispose()`，而弹窗此刻还在播关闭动画、输入框仍在重建；构建期异常拖垮元素树，随后 InheritedElement 失活时仍有依赖者 → 红屏。
  - `fushi/lib/src/sync/sync_settings_schema/interconnect.part.dart:486`（手输地址）、`:2700`（PIN）
  - `fushi/lib/src/sync/sync_settings_schema/interconnect_link.part.dart:223`（粘贴配对链接）
  - 同一错误写法还在：`custom_theme_page.dart:699`（导入主题）、`texthooker_page.dart:1384-1385`（粘贴 Hook Code）、`video_shader_dialog.dart:253`（着色器链接）
- **[x] ① 已修复** — 控制器一律归弹窗自己的 State，`State.dispose`（路由真正移除时）才释放：互联三个输入框共用新的 `_InterconnectTextPromptDialog`（外观不变）；导入主题 → `_ThemeImportDialog` 返回解析好的主题、由调用方应用；Hook Code → `_HookCodePasteDialog` 返回 `(code, label)`；着色器链接 → 现成的 `showFushiTextInputDialog`。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_pair_prompt_dispose_test.dart`（真实 PIN / 粘贴链接弹窗：输入 → 确认 / 取消 → 放完关窗动画，断言无异常、返回值正确；旧代码 3 条全红，报的正是「used after being disposed」）；`fushi/test/build/dialog_local_controller_dispose_guard_test.dart`（源码扫描：函数内自建控制器 + await 弹窗 / 底部弹层 + 同函数 dispose 即红；旧树报出上面全部 7 处）。`m3e_design_system_static_test` 的导入主题用例改为读 `_ThemeImportDialogState`。
- **备注**：修复后同一模拟器、同一路径复测：手输地址 → 确认设备 → PIN → 配对成功，显示「Connected」，无红屏，应用错误日志 0 条 FlutterError。
