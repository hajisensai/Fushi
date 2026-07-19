## BUG-875 · Galgame helper 已注入但 ready 信号过晚导致 engine_attach_failed
- **报告**：2026-07-19（用户：anemoi 捕获工作台显示 `helper_missing`，部署 helper 后变为 `engine_attach_failed`）
- **真实性**：✅ 真 bug。`native/galgame_voice_hook/hook/dll_main.cpp:2053-2112` 的 `HookWorker` 原先在共享内存契约校验后，先同步执行 MinHook、Siglus、文本和 KiriKiri 探测，最后才 `SetEvent`。anemoi PID 19616 中 DLL 与 marker 均已出现，但 injector 等不到 ready 而超时退出并释放共享内存，Hibiki 因此误判附着失败。
- **[x] ① 已修复** — `b4dd7bcfe32c5789b130081a350a955fed976bdb`：新增 `SignalReady`，在 `hooked=1` 后、`MH_Initialize` 与所有引擎探测前通知 injector，使其先进入 hold 保住 IPC，再异步完成重型 hook 安装。
- **[x] ② 已加自动化测试** — `hibiki/test/mining/galgame_voice_hook_ready_guard_test.dart` 固定契约校验 → `hooked` → ready → MinHook 的顺序；另通过 x86 Release native 编译与 `hibiki_siglus_ovk_test`。
- **备注**：旧 DLL 已加载进用户当前 anemoi PID 19616，Windows 不能在进程内热替换；需保存进度并重启游戏后，使用新构建的 x86 helper 复测原始路径。worktree bootstrap 的 pub-cache 补丁阶段因本机 WSL 不可用失败，但本次目标 Flutter 测试、x86 C++ 构建和 CTest 均已独立通过。
