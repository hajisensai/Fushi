## BUG-4134 · 外部窗口挖矿两行台词只有第二行能查（金色ラブリッチェ）
- **报告**：2026-10-22（反馈 J3zttJxLJu，关联 RQ-iLM0Dml；Windows，app 3.0.0+19763，金色ラブリッチェ日语版，外部窗口挖矿；附录屏，日志无任何 gal 行）
- **真实性**：⚠️ 现象成立（录屏逐帧核过：两行台词悬停时只有第二行的字出现游戏内黄色悬停高亮，第一行没有；单行台词「え？ ああ、ちょっとね」悬停高亮与查词卡都正常），根因**未定**，未改代码。
  - **AI 总结「外部窗口查词只把 `lines.last` 喂给命中层」对录屏现象不成立**：只有 attached 校准表面吃 Dart 的 `lines.last`（`fushi/lib/src/lookup/gal_hook_text_overlay_controller.dart:1320` `attachedSourceText`，命中再以 `latest.text != hit.sourceText` 收口，`:2627`）。attached 表面把 sourceText 从正文框**第 0 行**起排版（`fushi/windows/runner/attached_text_surface_window.cpp` `RebuildClusters` → `attached_text_layout::Build`）：若引擎把两行拆成两条 hook 文本、sourceText 只剩第二行，命中框会落在**第一行的屏幕位置**（悬停第一行查到第二行的字），而不是「第一行查不到、第二行能查」。录屏里的高亮是游戏线程内绘制的（引擎 native 渲染面 provider 的 `fushiLookupReport` 形态），文本来自引擎渲染面而非 `lines.last`。
  - 与录屏吻合的候选（未证实）：KiriKiri native provider 的活句判定 `native/galgame_hook/hook/adapters/kirikiri_adapter.inc:1694` `fushiLookupActiveSentenceState` 要求 `slot.activeEntry === entry`——一个消息层槽只有一个 activeEntry；若引擎把一句两行画成两个 entry，前一个会被判 -1、在悬停循环里以「V」标记跳过，只剩后一行可命中。前提是本作走的是 KiriKiri provider，尚未确认（引擎未 probe）。
  - 按 `docs/agent/galgame-hooking.md`「0. 硬规则」，改 native 引擎 adapter 必须先在原始启动路径建身份 / 时序台账、只修第一个未通过边界并做引擎级判据；本机无样本，故不改。
- **[ ] ① 未修复** — 根因未定。
- **[ ] ② 未加自动化测试** — 同上。
- **备注**：定位所需：① `tool/galhook.ps1 probe` 引擎识别（是否 KiriKiri / KAG 变体）与 exe 架构；② 停在两行台词上时的工作台截图（一条带换行还是相邻两条）；③ 游戏工作台导出的 hook 诊断（含 `gal-overlay: attachedReady=… mode=…` 那行，分清走的是 attached 表面还是 native provider）；④ 若是 KiriKiri provider，开坐标探针（traceOn）悬停第一行，看是否出现「V」标记。
