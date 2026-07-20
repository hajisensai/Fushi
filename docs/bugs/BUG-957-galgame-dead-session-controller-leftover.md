## BUG-957 · 旧 GalgameSessionController 死代码残留致查词面板 galgame 制卡出口失效
- **报告**：2026-07-21（PR#295 落地审查 M7，fable5）
- **真实性**：✅ 真 bug（代码路径核验）。根因 `hibiki/lib/src/pages/implementations/home_dictionary_page.dart:82`：启动路径全量切到 `GalHookSessionController` 后，旧 `GalgameSessionController` 全仓无调用点，但该处仍按其永远 inactive 的会话状态分支——查词面板 galgame 制卡出口静默失效、双控制器残留，违反「删减合并不留死代码」纪律。
- **[ ] ① 未修复** — 修法方向：查词面板分支改读 GalHookSessionController，删除旧控制器。
- **[ ] ② 未加自动化测试** — 源码守卫：GalgameSessionController 无引用即删；widget 测试断言 hook 会话激活时查词面板制卡出口可用。
- **备注**：
