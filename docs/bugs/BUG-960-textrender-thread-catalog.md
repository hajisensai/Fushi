## BUG-960 · 9nine 的 Luna 线程列表缺少 TextRender
- **报告**：2026-07-21（用户：同一 9nine 会话中，LunaTranslator 能列出 `TextRender`，Hibiki 线程选择器缺少该项）
- **真实性**：✅ 真 bug。LunaTranslator 直接用 LunaHook 的 `ThreadCreate` 回调维护完整线程列表；Hibiki 的 `native/galgame_voice_hook/injector/injector_main.cpp` 原先却把该回调做成空 stub，只能从通过 `LunaShouldWriteLine` 自动赢家/伪影过滤的输出反推候选。9nine 的 `TextRender` 在线程被选中前没有发布行，因此既进不了 `hibiki/lib/src/sync/texthooker_service.dart` 的历史行聚合，也永远无法在 UI 中被选择。
- **[x] ① 已修复** — 提交 `770a263a5` 将共享内存协议升级到 v10：injector 独立发布 Luna `ThreadCreate` 事件，Windows runner/Dart 完整透传事件类型，控制器把发现事件登记到独立线程目录而不伪造空台词。线程选择器现在可先显示 `TextRender · 0xf94600 · 0`，真实输出到达后再累计行数。
- **[x] ② 已加自动化测试** — 新增 `hibiki/test/mining/galgame_text_thread_discovery_guard_test.dart`，并扩展 MethodChannel 解析、会话控制器、线程目录及选择器 widget 测试，覆盖“发现事件不受自动赢家过滤”“0 行可选”“发现事件不进入台词历史”和 IPC 两端结构一致。
- **备注**：Windows Debug 主程序及 x86/x64 Release helper 已构建成功；按用户要求跳过单元测试。当前 9nine 进程若仍加载旧 helper，需在更新构建后重启捕获会话完成最终实机复测。
