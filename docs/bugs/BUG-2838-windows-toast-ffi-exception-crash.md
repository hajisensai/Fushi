## BUG-2838 · Windows 更新通知 WinRT 代理过期抛 C++ 异常穿 FFI 崩溃
- **报告**：2026-10-01（用户：QQ 反馈「老崩溃，感觉每次跳更新的时候」，附 10 个 `fushi.exe` minidump）
- **真实性**：✅ 真 bug。10 个 dump 里 3 个是本条（另 7 个是 [BUG-2839](BUG-2839-windows-a11y-orphan-semantics-crash.md)）：异常码 `e06d7363`（MSVC C++ 异常），抛出点 `flutter_local_notifications_windows+0x3a13` → `VCRUNTIME140!_CxxThrowException`，异常对象携带 HRESULT `0x800401FD`（`CO_E_OBJNOTCONNECTED`），线程是 Dart 主线程上的 FFI 调用；三个进程都已运行 3.5~7 小时。正好对上「跳更新时崩」：`fushi/lib/src/updates/local_update_notifier.dart` 检测到新版本后调用插件 `show()` 发 toast。
- **[x] ① 已修复** — `ci/patches/hosted/flutter_local_notifications_windows-2.0.1/src/ffi_api.cpp` 与 `plugin.hpp`（由 `ci/apply-patches.sh` 覆盖进 pub-cache）。见本分支提交。
- **[x] ② 已加自动化测试** — `fushi/test/build/windows_toast_ffi_boundary_guard_test.dart`（3 条：补丁目录版本 = lock 解析版本；禁止缓存 notifier / history 与 `stoi`；14 个导出函数体必须整体在 `try { } catch (...)` 内）。变异实测：补丁目录换回上游原文件 → 2 条红；只把一个导出的前置判断挪出 `try` → 1 条红。
- **备注**：Dart 侧 `LocalUpdateNotifier` 的 try/catch 对这类崩溃无效——C++ 异常越过 FFI 边界时运行时直接 `terminate()`，Dart 根本收不到。

### 根因

1. **缓存跨进程 COM 代理**：上游 `init()` 把 `ToastNotificationManager::CreateToastNotifier(aumid)` 返回的 `ToastNotifier` 和 `History()` 存进 `NativePlugin`，进程生命周期内一直复用。通知平台服务（WpnUserService）重启、会话切换或睡眠唤醒后代理断开，之后对它的每次调用都抛 `winrt::hresult_error(CO_E_OBJNOTCONNECTED)`。长时间挂着的进程迟早遇到，下次「有更新」弹通知时就崩。
2. **FFI 导出不捕获异常**：14 个 `extern "C"` 导出都没有 `try/catch`，`winrt::hresult_error`（以及对非数字 tag 的 `std::stoi` 抛出的 `invalid_argument`）直接越过 FFI 边界，进程以 fail-fast 方式终止。

### 修法

- 不再缓存：每次调用现取 notifier / history（`notifierFor()`）。`init` 只试建一次来判断通知是否可用，结果不保留，`isReady` 的含义不变。
- 每个导出整体包在 `try { … } catch (...) { 返回该函数原有的失败值 }` 中：bool 返回 false，`updateNotification` 返回 `failed`，查询类返回 `size=0` + `nullptr`。Dart 侧插件本来就按这些失败值处理（`show` 失败会抛 Dart `Exception`，由 `LocalUpdateNotifier` 捕获），结果只是这次不发通知。
- `std::stoi` 换成带范围检查的 `wcstol`，不是本插件写入的 tag 一律跳过。顺手修了上游 `freeLaunchDetails` 用 `delete` 释放 `new[]` 字符串的问题。

### 验证

- 单独编译插件 DLL（VS2022 x64）：0 警告，14 个导出都在；`flutter build windows --release` 的 C++ 编译和链接全部通过（INSTALL 步骤因 worktree 缺 torrent 预编译 DLL 失败，与本改动无关）。
- Dart FFI 冒烟：补丁版 DLL 上 `init(坏 guid)` 返回 false，`show(坏 xml)` 返回 false，正常调用都成功；同一脚本跑上游原版 DLL，在 `init(坏 guid)` 处进程以 `0xC0000409` 退出。
- 未复现：真实的 `CO_E_OBJNOTCONNECTED` 要重启通知平台服务才能触发，侵入性太大，没有做；这一层的依据是代码结构上不再持有长寿命代理。

### 删除条件

`flutter_local_notifications_windows` 升级到上游已修复缓存与异常边界的版本时，删掉这个补丁目录（版本变了补丁会被跳过，守卫第 1 条会报红提醒）。
