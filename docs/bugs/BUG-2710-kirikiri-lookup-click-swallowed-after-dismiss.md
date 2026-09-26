## BUG-2710 · KiriKiri 游戏内查词关卡后，下一次点字被当作关闭再吞一次
- **报告**：2026-09-26（千恋＊万花光盘版原版宿主验收时观察到）
- **真实性**：✅ 现象真，⚠️ 根因未定。Fushi itest 宿主 `launchoff SenrenBanka.exe`，同一句「そろそろ着きますけど、どこで止めますか？」上连续四次点击：① 点「ろ/着」边界 → 出卡（「ろ」），lookup `hits=1 frames=2`；② 卡片打开时点「着」→ 关卡（设计如此：`fushiLookupLeftClickHook` 卡外点击只关不推进），`frames=3`；③ 卡已关，点「着」中心 → **既没出卡也没推进**，`hits=1 frames=3` 均不变；④ 再点「着」→ 出卡「着きま…」，`hits=2 frames=5`。四次点击宿主台词列表都停在同一句（不推进这一条始终成立）。第三击被吞，推测是关卡后 `fushiLookupCardVisible()` 要等宿主应答 cancel 帧才清，期间的点字仍按「关卡」消费（`native/galgame_hook/hook/adapters/kirikiri_adapter.inc` `fushiLookupLeftClickHook` 的 `popupTransaction || fushiLookupCardVisible()` 分支）。与本轮 BUG-2708 的改动无关，原有行为。
- **排查进展（2026-09-26 晚）**：
  - 原推测不成立：TJS 的 `fushiLookupCancelCurrent` → `fushiLookupDismissNow` 会**同步**把 `fushiLookupCardSeq` 清 0（`kirikiri_adapter.inc` `fushiLookupDismissNow`），而且直连路由（BUG-1882）下 TJS 只在位图路由的 `fushiLookupApply` 里写 CardSeq，直连时它恒为 0。第二击在直连下根本到不了 TJS：宿主系统级鼠标钩子先把它成对吞掉（`fushi/windows/runner/low_level_mouse_hook.cpp` `ShouldConsumeGameClientClick`）并 `Hide()` 关卡。
  - 静态排除：第三击 `hits` 不变，说明注入侧 `PublishHit` 根本没发生；TJS / C++ / Dart 三层的 submit fence 都吞不掉一次**新**的 submit（`fushiLookupReport` 无去重，`PublishKirikiriLookupHit` 只按 `processed_submit_seq` 去重）。
  - 真机排除宿主层：给宿主加了点击状态诊断（`HandleGlobalClick` / `Hide` / `Reveal` 各记一行 `hibiki_glookup.log`，钩子把「是否吞了这一击」编进 lparam），在 CLANNAD Steam（Siglus，同一套直连卡 + 系统钩子）上按原序列四连击：第二击 `consumed=1 showing=1` → `lookup hide notify=1`，第三击钩子已解绑、落给游戏，**正常出卡**（`hits=1→2 frames=3→5`）。所以「钩子绑定比卡片活得久」这条宿主层候选不成立，问题在 **KiriKiri 注入侧**，不是跨引擎共性。
  - 注入侧诊断已就位：`PublishKirikiriLookupHit` 对每笔 TJS submit 记一行 `lookup.submit seq=… published=… reject=…`（`%TEMP%ushi_galhook.log`），注册表记下 `PublishHit` 七种拒绝中的哪一种（`geometry_provider_registry.h` `last_hit_reject`）。下一轮 KiriKiri 复现时，第三击有没有产生 submit、在哪道门被拒，一次就能分清。
  - 阻塞：本机已没有 KiriKiri 样本（千恋光盘版按流程测完已删，Limelight / 9-nine 已不在 D 盘）。
- **[ ] ① 未修复** — 待 KiriKiri 样本复现，按上面的注入侧诊断定位第三击丢在 TJS（`fushiLookupLeftClickHook` 返回 true 却不 report）还是 C++（`PublishHit` 拒绝）。
- **[ ] ② 未加自动化测试** — 真机回归已进验收命令：`gal_realgame_driver_itest` 的 `accept4` 第 ⑥ 步 `relookup_after_dismiss`（关卡后再点同一字形必须再次出卡）。根因定位后再补离线层测试。
- **备注**：只影响「关卡后立刻查同一句里的下一个词」的第一次点击；不会推进剧情。
