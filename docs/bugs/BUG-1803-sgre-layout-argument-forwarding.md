## BUG-1803 · SGRE 查词 detour 丢失布局参数导致游戏控制码不转义
- **报告**：2026-08-24（用户：查词后游戏把 `\\n`、`%p-1;─%p;─` 等控制串直接画出来，必须走游戏本身转义）
- **真实性**：✅ 真 bug。旧实现 detour UserHook1 `0x328e0` 并重新转发内部布局调用，介入了游戏解析控制串的路径；同时查词侧自行执行 `LunaNormalizeMagesControls`，两边都不具备游戏原生解析器的完整语义。
- **[x] ① 已修复** — `native/galgame_hook/hook/adapters/sgre_lookup.inc:221` 完全停止 detour UserHook1，改在游戏解析完成后的 draw 边界旁路复制字形；原函数只按原始 `this` 调用，查词不再修改或重放游戏文本（本提交）。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/adapter_structure_test.py:39` 明确禁止 `g_sgre_text_layout_original`、`LunaNormalizeMagesControls` 和 Luna-ready 门重新进入 SGRE lookup sensor；结构测试通过（本提交）。
- **备注**：过滤版运行时控制串不外露仍需用户在原失败场景复核；当前仅证明新路径不再接触 UserHook1。
