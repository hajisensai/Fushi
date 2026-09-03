## BUG-1774 · XAudio2 WMA Hook 覆盖 ADPCM trampoline 导致游戏静音
- **报告**：2026-08-22（用户报告）
- **真实性**：✅ 真 bug。`windows_audio_adapter.inc:1289,1392` 的 `SubmitSourceBuffer` / `FlushSourceBuffers` 在不同 codec voice 上可出现不同 vtable target，旧实现却把 trampoline 写进单个全局 original；后安装者覆盖前者，前一个 detour 随后会调用错误实现。
- **[x] ① 已修复** — `dll_main.cpp:355` 仅为这两个多 target 方法维护各自独立的 target → trampoline 注册表；普通 `HookFn` 保持历史去重语义，避免不同 detour 被错误合并。
- **[x] ② 已加自动化测试** — `hook_original_registry_test.cpp` 验证多 target 发布、重复发布、容量与清除；`adapter_structure_test.py` 锁定两个方法必须按当前 vtable slot 查找 original。
- **备注**：初版修复曾把全 DLL 的 Hook 都迁进一个共享注册表，SGRE 启动后稳定触发 BEX64 `0xc0000005`；真机 A/B 证明精确 HEAD DLL 可稳定运行，而共享表版本约 9 秒崩溃。因此注册表必须按 detour 收窄，不能改变全局 Hook 编排。
