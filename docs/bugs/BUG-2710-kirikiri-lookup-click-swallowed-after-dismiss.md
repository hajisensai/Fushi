## BUG-2710 · KiriKiri 游戏内查词关卡后，下一次点字被当作关闭再吞一次
- **报告**：2026-09-26（千恋＊万花光盘版原版宿主验收时观察到）
- **真实性**：✅ 现象真，⚠️ 根因未定。Fushi itest 宿主 `launchoff SenrenBanka.exe`，同一句「そろそろ着きますけど、どこで止めますか？」上连续四次点击：① 点「ろ/着」边界 → 出卡（「ろ」），lookup `hits=1 frames=2`；② 卡片打开时点「着」→ 关卡（设计如此：`fushiLookupLeftClickHook` 卡外点击只关不推进），`frames=3`；③ 卡已关，点「着」中心 → **既没出卡也没推进**，`hits=1 frames=3` 均不变；④ 再点「着」→ 出卡「着きま…」，`hits=2 frames=5`。四次点击宿主台词列表都停在同一句（不推进这一条始终成立）。第三击被吞，推测是关卡后 `fushiLookupCardVisible()` 要等宿主应答 cancel 帧才清，期间的点字仍按「关卡」消费（`native/galgame_hook/hook/adapters/kirikiri_adapter.inc` `fushiLookupLeftClickHook` 的 `popupTransaction || fushiLookupCardVisible()` 分支）。与本轮 BUG-2708 的改动无关，原有行为。
- **[ ] ① 未修复** — 涉及 hook ↔ 宿主的卡片可见性应答时序（IPC），需先抓 ② ③ 之间 CardSeq / cancel 应答的时间线再定。
- **[ ] ② 未加自动化测试** —
- **备注**：只影响「关卡后立刻查同一句里的下一个词」的第一次点击；不会推进剧情。
