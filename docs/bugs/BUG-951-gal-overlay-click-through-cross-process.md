## BUG-951 · Hook 浮窗鼠标穿透 HTTRANSPARENT 跨进程不生效存疑须真机验证
- **报告**：2026-07-21（PR#295 落地审查 H2，fable5）
- **真实性**：⚠️ 待真机验证（静态可疑）。疑点 `hibiki/windows/runner/floating_lyric_window.cpp:617-622`：穿透仅靠 WM_NCHITTEST 返回 `HTTRANSPARENT`，Win32 契约中它只在同线程窗口间下传，对另一进程的游戏窗口不生效（层窗口 ~2% alpha 体表命中测试不透明），穿透模式下点击可能被浮窗吞掉而非落到游戏。
- **[ ] ① 未修复** — 若真机复现：正解是穿透态切 `WS_EX_TRANSPARENT`（或体表 alpha=0），而非 HTTRANSPARENT。
- **[ ] ② 未加自动化测试** — 真机手动验收（浮窗开穿透后点击游戏正文区能触达游戏）。
- **备注**：核心特性验证项，列入 Windows 真机验收清单。
