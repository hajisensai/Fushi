## BUG-4175 · 合并 profile 后同一次复习变成两条，FSRS 优化 log loss 从 0.6 涨到 1.6
- **报告**：2026-11-06（用户：RWKV 牌组下 FSRS 影子参数的 log loss 原来约 0.4–0.6，同步之后涨到 1.6 多）
- **真实性**：✅ 真 bug，用户本机 srs.db 只读核对：5849 条评分复习里只有 3658 条不同，多出 2191 条（521 张卡）；每组重复都是一份 11-04、一份 11-05 经同步收到，内容相同、ID 不同。Anki 导入的重复里，每组恰好一份是 `UUIDv5(卡片, anki-revlog/<id>)` 的规则 ID、另一份不是；原生日志的重复是「原 UUIDv7 + 合并兜底的 v5」。参数组记录：10-19 桌面 639 条 log loss 0.61，11-06 手机 4066 条 1.59（版本向量里有两个 `merged-` 写入者）。
- **根因**：`packages/fushi_engine/lib/srs/srs_profile_merge.dart` 第 7 步（复习日志重算 ID）。导入 revlog / 导入锚点只有在「旧 ID 恰好按旧卡片派生」时才按规则换 ID，否则走 `uuidV5(profile-merge/<newUid>/<旧 ID>)` 兜底；旧 profile 本身是更早一次并入的产物时 revlog ID 早已是兜底 ID，验证必不过，同一条 Anki 复习于是按另一条来路得到第二个 ID。原生日志一律兜底，目标集合里已有原 ID 时又多一份。同步与历史选取（`native/fushi_fsrs/src/history.rs` `select`）按 ID 认身份，两份都算有效复习；间隔 0 天的同评分重复（尤其「重来」）让 FSRS 优化 log loss 暴涨。
- **[x] ① 已修复** — 第 7 步（`srs_profile_merge.dart:537` 起）：导入 revlog / 锚点一律按新卡片套规则，不再验证旧 ID；规则与兜底之后，目标里已有同一条复习（映射后卡片 + 种类 + 评分 + 发生时刻 + HLC）而 ID 不同的，沿用目标 ID（`_logIdsByIdentity` / `_IdMap.alias`，与修改记录的 BUG-4011 同一思路）；旧 profile 内本就重复、映射到同一新 ID 的日志只并一份。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/srs_profile_merge_test.dart`「同一次复习（Anki revlog / 原生日志）已在目标里或在旧 profile 里有多个 ID：合并后只剩一条」：修复前同一卡 5 条日志（红），修复后 2 条且重跑不落新事件。
- **备注**：只修以后的合并；已经落进同步集合的重复不在本次范围（用户确认数据无所谓）。
