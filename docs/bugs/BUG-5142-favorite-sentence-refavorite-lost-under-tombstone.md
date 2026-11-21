## BUG-5142 · 同键收藏句合并只留最早 createdAt：删了重收藏后遇到墓碑会被整条压掉
- **报告**：2026-11-22（PR #4065 / BUG-5081 审查时沿代码路径发现，未见用户报告）
- **真实性**：✅ 代码路径推演确认（未写复现测试）。`AggregateMergeService.mergeFavoriteSentences` 同内容键只留 createdAt 更早的那条作身份（`packages/fushi_engine/lib/sync/aggregate_merge_service.dart:248`，BUG-5081 之后颜色另取较新时钟，但 createdAt 仍是旧行的），随后 `_arbitrateFavorites` 拿合并后的 createdAt 和删除墓碑比（`packages/fushi_engine/lib/sync/aggregate_sync_service.dart:910`，`_writeFavoriteSentences` 同律）。时序：设备 A 收藏（t1）→ 删（墓碑 t_d）→ 重收藏（t2 > t_d，本机清掉墓碑）；设备 C 还留着 t1 那行、没收到墓碑；设备 B 收到过墓碑。服务端先并 A 与 C（同键，身份取 t1），再并 B 的墓碑：t1 < t_d → 整条被压掉，`latestCreated` 也只看到 t1，墓碑继续存活。重收藏丢失。修前（BUG-5081 之前）同样如此，不是 #4065 引入的。
- **[ ] ① 未修复** — 方向：墓碑判据要看同键里**最新**一次收藏的时刻，而不是合并后身份行的 createdAt（例如先按墓碑过滤两侧再求并集，或合并行额外保留同键最新 createdAt 供仲裁）；需同时改 `_arbitrateFavorites` 与 `_writeFavoriteSentences` 两处并保持参数顺序无关、逐字节收敛。
- **[ ] ② 未加自动化测试** — 应加在 `fushi/test/sync/` 的聚合同步层：三方时序（旧行 + 重收藏行 + 墓碑）任意合并顺序下重收藏都保留。
- **备注**：BUG-5081 的颜色时钟只解决颜色；本条是身份 / 删除仲裁的问题，单独登记。
