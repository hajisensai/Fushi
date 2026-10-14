## BUG-3330 · 手柄「按住临时倍速」变成点按切换，长按也只算一次点按
- **报告**：2026-10-14（反馈 #m32Z1LFu2u，Android，截图显示动作绑在手柄 X 上）
- **真实性**：✅ 真 bug。键盘通道早已是按住语义（`_handleHoldSpeedKey` + `resolveHoldSpeedKeyTransition`），手柄通道没有松开沿：`fushi/lib/src/pages/implementations/video_fushi_page.dart:7458`（修复前）`_handleVideoGamepadNativeKey` 只接 `KeyDownEvent`，Android 的 `KeyUpEvent` 被丢；桌面轮询 `GamepadFrameProcessor.processFrame`（`fushi/lib/src/shortcuts/gamepad_service.dart:1091`）只发按下沿。于是手柄派发到 `toggleHoldSpeed`（:7240，注释自认「手柄没有可靠的松开事件管线，退化成翻转」）。
- **[x] ① 已修复** — 状态机泛化为设备无关的 `resolveHoldSpeedTransition<T>`（键盘版委托它）；手柄按下 `videoHoldSpeed` 走 `_handleHoldSpeedGamepadEdge(press)`，松开沿来自 Android 原生 `KeyUpEvent` 与桌面新的 `GamepadButtonReleaseIntent`（`GamepadFrameProcessor.onButtonRelease`：按钮 / 扳机 / D-pad 的松开沿，断连 `reset()` 时把仍按着的全部释放，防倍速卡住）。`toggleHoldSpeed` 只剩没有松开沿的入口（鼠标侧键、屏幕自定义按钮）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_gamepad_input_semantics_test.dart`（手柄状态机 + 三个入口接线守卫）、`fushi/test/shortcuts/gamepad_frame_processor_test.dart`（group `release edges (onButtonRelease)`）。
- **备注**：桌面上把按住倍速绑到 A 仍无法「按住」——A 在桌面轮询里的长按语义是 long-press（在松开时判定），其松开沿紧跟点按发出，不会卡住，只是一闪而过。未在真机手柄上复测（缺口）。
