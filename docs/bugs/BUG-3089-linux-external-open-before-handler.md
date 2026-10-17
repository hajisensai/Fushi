## BUG-3089 · Linux 二次启动参数在 Dart 处理器注册前到达被静默丢弃、首帧前 present 出黑窗
- **报告**：2026-10-09（审查 `1be1a2b7^..f84a2186` Linux 补缺提交时发现）
- **真实性**：✅ 真 bug（范围比审查描述窄，已实测校正）。runner 用 `fl_method_channel_invoke_method(..., nullptr, nullptr, nullptr)` 转交参数（`fushi/linux/runner/my_application.cc:143`，修前），Dart 的处理器要到 `FushiReaderApp.initState`（`fushi/lib/main.dart:920`）才注册。处理器注册前到达的消息由 framework 的 `ChannelBuffers` 暂存，但每个通道默认只留 **1 条**，更早的被挤掉——首启加载期间连续两次「用 Fushi 打开」，第一个文件丢失（最小 Flutter Linux app + 本 runner 实测：修前 file1 丢、file1b 到达）。另外首帧前 `gtk_window_present`（`:147`）会把还没画过的 FlView 显示成一块黑窗。
- **[x] ① 已修复**（见本分支提交）— runner 在 `external_video_channel` 上挂方法处理器：Dart 发 `externalOpenReady` 之前到达的参数排进 `pending_external_args`，收到后按序冲出；之后直接发。`first_frame_cb` 置 `first_frame_shown`，`present_main_window` 首帧前不 present（首帧到了模板自己会 show）。Dart 在 `setMethodCallHandler(_handleExternalVideoChannel)` 之后调用 `LinuxExternalOpenChannel.notifyHandlerReady`。
- **[x] ② 已加自动化测试** —
  - 源码守卫 `fushi/test/native/linux_single_instance_guard_static_test.dart`：ready 前排队、ready 冲出并清空、命令行路径不再直接 invoke、首帧标志、Dart 侧 ready 在注册处理器之后。
  - 单测 `fushi/test/platform/desktop/linux_external_open_channel_test.dart`。
  - 替身 E2E（不入库）：处理器延迟 2s 注册期间连续两次二次启动，修后 file1、file1b 都按序到达。
- **备注**：Windows 同一通道有同类问题（`windows/runner/flutter_window.cpp` WM_COPYDATA 直接 `InvokeMethod`，同样受 `ChannelBuffers` 1 条容量限制），本任务只改 Linux，Windows 另行处理。
