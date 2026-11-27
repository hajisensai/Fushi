## BUG-5577 · Windows 构建门 `fushi_windows_printwindow_helper_gate` 在构建负载下偶发失败，整个 Release 构建因此失败
- **报告**：2026-11-27（本机 `flutter build windows --release`，worktree 刚 bootstrap 后的第二次构建：`MSB8066: Custom build for ... fushi_windows_printwindow_helper_gate.rule exited with code 1`）
- **真实性**：✅ 真问题（偶发）。同一个 `runner/native_tests/Release/fushi_windows_printwindow_helper_test.exe` 构建后单独连跑 4 次全部 exit 0（打印 `printwindow helper lifecycle: IPC, timeout cleanup, and retry passed`）。构建日志没有抓到 `Check` 的失败文案，所以不知道是哪一条断言失败。可疑点在 `fushi/windows/runner/tests/window_capture_printwindow_helper_test.cpp`：等待时间都是写死的短超时，包括探测窗口就绪 2000 ms、`g_helper_seen` 1000 ms、超时后的 helper 进程退出 1000 ms、`g_target_hang_finished` 2000 ms，还有目标窗口故意卡住的 `Sleep(1400)`。机器在 MSBuild 并行编译时满载，这些墙钟等待可能等不到。这个门挂在 `add_dependencies(${BINARY_NAME} ...)` 上，是本机 Release 构建的硬依赖（`fushi/windows/runner/CMakeLists.txt:698-703`）。
- **[ ] ① 未修复** — 方向：断言改成等事件或状态，不用墙钟窗口；如果必须给上限，就拉长到秒级，并且和被测的 PrintWindow 超时参数挂钩，不单独写死。失败时把 `Check` 文案写到 stderr，并让 MSBuild 显示出来，以后能看出是哪一步。
- **[ ] ② 未加自动化测试** — 修的时候在门测试里加一个负载场景：同时起几个满载线程，跑 N 次都必须通过。
- **备注**：这次重跑构建时它通过了，所以没有挡住出包。
