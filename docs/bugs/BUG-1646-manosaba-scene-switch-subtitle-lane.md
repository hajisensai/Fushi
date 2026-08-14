## BUG-1646 · 魔法少女的魔女审判切换场景后字幕线程断开
- **报告**：2026-08-14（用户：本地实机反馈）
- **真实性**：✅ 真 bug。`native/galgame_hook/hook/adapters/unity_adapter.inc:329` 原先把 Naninovel 的临时 `RevealableText` 组件指针混入线程 ID；载入其他场景后组件被重建，已选线程停在旧指针，新字幕进入另一候选线程。
- **[x] ① 已修复** — `native/galgame_hook/hook/adapters/unity_adapter.inc:284` 为已知场景稳定的 Naninovel 对话源使用引擎级线程身份，同时继续把真实组件地址保留在事件元数据中。Fresh build 还暴露 Unity 6 在 HookWorker 调用 `il2cpp_class_get_method_from_name` 会进入 Boehm GC；`native/galgame_hook/hook/adapters/unity_adapter.inc:714` 改为枚举已发布的方法元数据，避免启动 GC 崩溃。
- **[ ] ② 未加自动化测试** — 用户明确要求本轮跳过所有测试；未运行或新增自动化测试，以真实 Windows 游戏的 Release 多场景回放作为当前验证门。
- **备注**：旧 DLL 实机复现为已选线程计数停在 8，而新场景组件另起候选并收到 2 条。修复后 RelWithDebInfo 同一选择跨三场景从 4→8→14；最终 Release 同一选择跨场景从 5→10，组件元数据地址变化但无需重选，并继续出现 `game_resource` 音频。游戏 1.1.2，Unity 6000.0.48f1；证据账本位于 `.codex-test/manosaba-multiscene-evidence.json`，未保存截图或台词正文。
