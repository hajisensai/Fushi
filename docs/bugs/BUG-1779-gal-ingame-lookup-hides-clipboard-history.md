## BUG-1779 · 游戏浮窗查词不应显示复制历史入口
- **报告**：2026-08-23（用户：）
- **真实性**：✅ 真 bug。`fushi/assets/popup/global_lookup_host.js` 的瞬态 root shell 原先无条件创建 `global-lookup-history`。前两轮误把截图入口当作离屏 `galCard`：新截图证明实际复现是点击原生“游戏台词浮窗”后的顶层查词卡，该调用按设计复用 desktop HWND/route，所以 route 与物理窗口身份都无法区分它与普通全局查词。
- **[x] ① 已修复** — 给 `GlobalLookupController.lookupText` 增加来源能力位 `allowClipboardHistory`，游戏台词浮窗与游戏内查词调用显式传 false；该值随每次完整 `renderStack` payload 进入 host，同步移除入口并阻断历史渲染。普通全局查词、剪贴板瞬态查词和持久面板传/默认 true，后续普通查词会恢复入口。原生 `galCard` HWND 仍保留强制 false 的第二层保护。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/global_lookup_host_test.mjs` 增加 BUG-1779 守卫，覆盖 route 门控、原生 galCard 门控，以及真实复现分支“desktop route + 游戏台词浮窗 payload=false”，并验证后续普通 desktop payload 恢复入口。
- **备注**：按用户要求跳过所有测试；仅随最新 Windows Debug 构建打包验证。
