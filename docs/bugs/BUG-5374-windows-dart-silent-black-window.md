## BUG-5374 · Windows 缩窗后主窗口黑屏冻结，平台线程空闲而 Dart 不回应，旧看门狗量不到
- **报告**：2026-11-24（用户：有声书阅读器里查词弹窗关不掉，调整窗口大小后 fushi 黑屏）
- **真实性**：✅ 真现象，**根因未定位**。现场取证（进程 pid 186528，卡死后保留）：主窗口内容纯深色 `#0d1117`，窗口框架能缩放；本地监听的 3 个端口（4818 / 7659 / 38765）连得上但不回话；平台线程两次取栈都停在 `GetMessageW`（空闲），外部对主窗 `SetWindowPos` 却会一直卡住；CPU 空闲。即「平台线程空闲、窗口消息本应照常，Dart 事件循环却不运转」。旧看门狗（`hang_watchdog.cpp`）只量「主线程不泵消息」，此情形下不触发（崩溃目录里最近的 hang 转储早于事故）。已排除：弹窗几何（`resolvePopupRect` / `anchorPopupTopLeft`）缩窗时不抛异常；缩窗闸门 `child_resize_gate.h` 的 BUG-2462 路径与此现场对不上（尚无证据）。引擎无符号，转储里主线程栈只到 `flutter_windows` 内部。
- **[ ] ① 根因未修（仅先加检测取证）** — 新增「Dart 失联」检测：Dart 侧 `dart_heartbeat.dart` 每秒经 `app.fushi/window` 发 `dartHeartbeat`，runner `hang_watchdog.cpp` 在主线程仍泵消息而心跳连续静默 ≥10 s 时抓 `hang-*.dmp` 并写 `hang_watchdog.log`（每进程 ≤2 份；首次心跳前不布防；主线程自己停泵的情形仍走原路径，不重复抓）。下次复现留下可分析的 dump 与日志，据此再修根因。提交哈希见 PR。
- **[x] ② 测试** — `fushi/test/utils/dart_heartbeat_test.dart`（心跳定时器行为 + Dart / runner / 看门狗接线源码守卫）；`hang_watchdog.cpp` 已用 MSVC `/Zs` 语法检查通过。
- **备注**：根因修复待下次复现取到 dump（诊断区「崩溃转储」的 `hang-*.dmp`，`hang_watchdog.log` 里含 `dart heartbeat silent`）。**未做**：真机复现原始失败路径（有声书弹窗 + 缩窗）；本条 ① 只是取证手段，不代表黑屏已修好。
