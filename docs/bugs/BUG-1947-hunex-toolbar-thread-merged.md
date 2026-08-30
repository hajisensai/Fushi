## BUG-1947 · HUNEX 顶部控制栏线程被并入剧情台词
- **报告**：2026-08-30（用户：Wight）
- **真实性**：✅ 真 bug。WoH 1.0 的现场文本 ring 显示，剧情与顶部控制栏都来自 Luna `typemoon` hook，但分别稳定写入两个不同 `threadId`；Fushi 的消费期同-face兜底忽略 `ThreadParam.ctx`，因此在用户选中剧情线程后又把控制栏说明行合并进工作台。LunaTranslator 按完整 ThreadParam 精确选择线程，不会发生这次重新合并。
- **[x] ① 已修复（`fixed`）** — native 对 `typemoon` 事件发布 `exact thread context` 标志，Dart 消费期在精确 `threadId` 命中后即拒绝同-face兄弟线程；其他 Luna 引擎仍保留 BUG-1159 所需的同-face兼容。策略只依赖 Luna 的语义 hook 名，不依赖 WoH 文件名、EXE hash、RVA、文本长度或日文控制栏内容黑名单。
- **[x] ② 已加自动化测试** — native 策略测试钉住只有 `typemoon` 启用精确上下文，聚焦 CTest 1/1 通过；Dart 消费测试覆盖剧情/控制栏实时隔离、控制栏线程可单独选择，以及切换线程后的历史回捞仍不混入同-face控制栏，聚焦 Flutter test 11/11 通过。按约定未跑全量测试。
- **构建身份**：双架构 helper 分发与安装脚本已完成，x64 archive `2cab452a…55a392`、x86 archive `7d0328bc…a2bd38`。包含本次 Dart 消费改动的完整 runner 位于 `fushi/build_codex/windows/x64/runner/Debug/fushi.exe`，SHA-256 `A2AA7DA9…2B86437`；配套 kernel `C7328342…DB98F5`，并已通过 manifest/源码指纹校验装入上述双架构 helper。
- **现场验收**：2026-08-30 对上述 runner 与 `WoH.exe` 做了干净重启、附着并选中剧情线程。工作台先只收到 `簡潔な答えに、山城は感心して眉を上げた。`；把鼠标移到游戏顶边实际呼出控制栏后，实时台词仍为 1 条且未出现控制说明；随后推进剧情，`彼女が怒っているのは見てとれたが、…` 正常作为第 2 条进入同一 `typemoon` 线程。控制栏兄弟线程未重新并入，现场验收通过。
