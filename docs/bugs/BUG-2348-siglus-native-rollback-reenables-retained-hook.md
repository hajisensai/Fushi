## BUG-2348 · Siglus NativeEcx 安装回滚后回退重启残留 Hook
- **报告**：2026-09-07（引擎适配整合审查）
- **真实性**：✅ 真 bug。`native/galgame_hook/hook/adapters/siglus_message_capture.inc` 的 `InstallSiglusMessageHookGroup` 先启内层、后启外层；外层失败时，回滚保留曾启用的内层 trampoline，却以普通失败放行同一 MinHook registry 的回退。`text_render_adapter.inc` 的 `InstallSiglusExactTextAt` 通过 `dll_main.cpp` 的 `HookFn` 接受 `MH_ERROR_ALREADY_CREATED` 并启用原记录，但没有自己的 original。内层原本由他人创建时也会走到同一错误回退。
- **[x] ① 已修复** — NativeEcx 回滚后内层记录仍保留，或创建内层明确发生所有权冲突时，发布 ownership unavailable；文本安装调用者在普通 fallback 前退出。保留运行中的 trampoline 生命周期，不借用他人的入口，也不修改通用 `HookFn`。
- **[x] ② 已加自动化测试** — `siglus_message_capture_test.cpp` 直接调用生产安装组，覆盖“内层已启、外层失败”和“他人已创建内层”两条路径，断言 blocked。前者在修复前退出 `-1073740791`，修复后退出0（3165项检查）。`adapter_structure_test.py` 额外检查生产调用者在普通 fallback 前处理 blocked，并约束回调不做阻塞工作。
- **备注**：此缺陷来自尚未安装到游戏的本轮整合代码。首轮分发虽两架构82/82通过，仍因审查发现该缺口未安装；修复后重新构建验证。不声称游戏中制造过安装故障。
- **根因位置**：`native/galgame_hook/hook/adapters/siglus_message_capture.inc:224` → `native/galgame_hook/hook/adapters/text_render_adapter.inc:246` → `native/galgame_hook/hook/dll_main.cpp:367`。
