## BUG-3078 · 视频库导入动作挤窄页签条后选中项不可见
- **报告**：2026-10-07（用户录屏，CC 交接任务 1）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/video_library_shell.dart:260` 的页签与动作槽共用顶栏；导入页登记三按钮后，`fushi/lib/src/utils/components/fushi_floating_chrome.dart:1048` 的动作宽度动画持续挤窄页签。原 `fushi/lib/src/utils/components/library_section_tabs.dart:433` 只更新溢出提示，未在 viewport 改变后重新定位选中段；TabBar 切换时计算的旧滚动终点因而失效。
- **[x] ① 已修复** — 共享页签组件跟踪横向 viewportDimension，布局完成后按实际选中段几何重新居中；idle/post-frame 直接执行，避免无下一帧时回调悬空。重定目标也会终止旧滚动 activity；无关重建保留用户手动横滑位置。动效复用共享时长并响应减弱动态效果。提交 `c93bfe4af3`（`fix(ui): keep selected library tab visible when toolbar resizes`）。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/library_section_tabs_selected_visible_test.dart`：同帧/晚一帧/420ms 连续挤窄与放宽、首帧、RTL、静止缩窄、减弱动态效果、旧 activity 恰经过新目标、手动滚动后无关重建。旧代码对照运行 11 条，6 条几何断言失败（exit 1）；修复后 12 条回归、相邻组件及 M3E/token 静态守卫合计 109 条通过（exit 0）；全量 analyze 无问题（exit 0）。
- **备注**：交接留下的 widget 渲染像素位于 `.codex-test/video-tab-visible/{before,after}.png`，已人工查看：旧版导入完全离屏，修复版导入完整显示。Android 原路径补验受基础设施阻塞：真机已断开；现成模拟器可用，但本机唯一重任务槽被另一工作区的旧 SDK 守卫长期占用（零输出、无 tester 子进程），本次排队未能进入执行。设备/模拟器验收执行数 0、无新增截图，不能宣称完整设备验收；诊断与清理证据见 `.codex-test/video-tab-visible/android-validation.md`。临时 Gradle 已按字节还原。
