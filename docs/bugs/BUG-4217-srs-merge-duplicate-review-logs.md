## BUG-4217 · 合并 profile 后同一次复习变成两条，FSRS 优化 log loss 从 0.6 涨到 1.6
- **报告**：2026-11-06（用户：RWKV 牌组下 FSRS 影子参数的 log loss 原来约 0.4–0.6，同步之后涨到 1.6 多）
- **真实性**：✅ 真 bug，用户本机 srs.db 只读核对：5849 条评分复习里只有 3658 条不同，多出 2191 条（521 张卡）；每组重复都是一份 11-04、一份 11-05 经同步收到，内容相同、ID 不同。Anki 导入的重复里，每组恰好一份是 `UUIDv5(卡片, anki-revlog/<id>)` 的规则 ID、另一份不是；原生日志的重复是「原 UUIDv7 + 合并兜底的 v5」。参数组记录：10-19 桌面 639 条 log loss 0.61，11-06 手机 4066 条 1.59（版本向量里有两个 `merged-` 写入者）。
- **根因**：`packages/fushi_engine/lib/srs/srs_profile_merge.dart` 第 7 步（复习日志重算 ID）。导入 revlog / 导入锚点只有在「旧 ID 恰好按旧卡片派生」时才按规则换 ID，否则走 `uuidV5(profile-merge/<newUid>/<旧 ID>)` 兜底；旧 profile 本身是更早一次并入的产物时 revlog ID 早已是兜底 ID，验证必不过，同一条 Anki 复习于是按另一条来路得到第二个 ID。原生日志一律兜底，目标集合里已有原 ID 时又多一份。同步与历史选取（`native/fushi_fsrs/src/history.rs` `select`）按 ID 认身份，两份都算有效复习；间隔 0 天的同评分重复（尤其「重来」）让 FSRS 优化 log loss 暴涨。
- **根因（续，审查 PR #3004 时发现）**：
  1. **回归——恢复备份的重放副本与原日志撞 ID**：PR #3004 初版把规则 ID 套到所有带 `ankiRevlogId` 的日志和所有 `importAnchor` 上。恢复备份写出的重放副本（`packages/fushi_srs/lib/src/restore_plan.dart` `_replayOf`）照抄 ankiRevlogId / 种类 / 发生时刻，只换新 ID、新 HLC、extra 记 `replayOf`；它和已被 undo 撤销的原日志算出同一个规则 ID，`seenLogs` 静默只留一份、undo 的 `revokes` 也指过来，这次复习整条消失，核对照样通过、旧 profile 被删。触发：导入 apkg → 恢复到导入前（撤销）→ 恢复到导入后（重放）→ 合并 profile。
  2. **原生日志兜底 ID 与合并路径有关**：`profile-merge/<newUid>/<旧 ID>` 链式合并 A→B→C 得 `fb(C, fb(B, x))`，另一台设备直接 A→C 得 `fb(C, x)`，同一次复习两个 ID。
  3. **修改记录写入者改名同样链式**：`merged-uuidV5(profile-merge/<newUid>/writer/<上一跳名字>)`，A→B→C 与 A→C 名字不同 → dot 不同 → 同一批修改记录两份（用户版本向量里两个 `merged-` 写入者即此）。
  4. **`seenLogs` 静默去重**：两条身份不同的日志映射到同一 ID 时也只留一份，丢数据不报错。
- **[x] ① 已修复** — `srs_profile_merge.dart` 第 7 步（`:579` 起）与第 9 步、`_Writers`：
  - 规则 ID 只给自身身份证明是那次导入的日志：revlog 要 origin = anki、`hlc == srsImportedRevlogHlc(ankiRevlogId)`、无 `replayOf`；锚点要 `importAnchor`、origin = anki、`hlc == srsImportAnchorHlc(occurredAt)`、无 `replayOf`（`:596` 起）。重放副本、undo、原生日志一律走内容兜底。
  - 内容兜底与路径无关：`uuidV5(新卡片, profile-merge-log/<hlc.encode()>/<kind>)`（`:626` 起）；日志 HLC 在合并中不变，一个 HLC 只属于一个事件。只有旧 profile 里不存在的日志 ID（undo 目标不在本地）与不认识的事件仍按旧 ID 兜底。
  - 目标沿用保留（同一身份 → 目标 ID），`_logIdsByIdentity` 加 `ORDER BY id`，同身份多条时确定取最小 ID（`:753`）；沿用条数经 `SrsProfileMergeResult.aliasedIds` 暴露。
  - 第 9 步：两条旧日志映射到同一新 ID 时，身份（卡片 + 种类 + 评分 + 发生时刻 + HLC + 映射后的 revokes）相同才只并一份，否则抛 `StateError`——在第一次落库前中止，旧 profile 不删（`:704` 起）。
  - 写入者改名从**最初的写入者**派生：新名字 `merged-uuidV5(profile-merge/<newUid>/writer/<最初>)~<最初>`，下一次合并剥出 `<最初>` 再算（`_mergedWriterOrigin` / `_mergedWriterNames`，`:85`、`:99`、`:926` 起）；同一旧 profile 里两个写入者剥出同一个最初写入者、或剥完名字等于自己时不剥；最后断言改名一一对应，否则 `StateError`（`:959`）。
  - 首次修复（PR #3004 原内容，仍保留）：旧 profile 本身是更早一次并入的产物、revlog ID 早已是兜底 ID 时不再验证旧 ID，原导入日志照规则落回同一个 ID；目标里已有同一条复习时沿用目标 ID（`_IdMap.alias`，BUG-4011 同思路）。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/srs_profile_merge_test.dart`：
  - 「同一次复习（Anki revlog / 原生日志）已在目标里或在旧 profile 里有多个 ID：合并后只剩一条」（PR #3004 原用例，加断言 `aliasedIds == 1`）。
  - 「导入 revlog / 锚点被恢复撤销、又被恢复重放：合并后有效历史与卡片状态不变，重放副本没被撤销」：修复前合并后只落 4 条日志（两条副本被吞、有效历史为空），修复后 6 条、有效历史仍是两条副本、状态与合并前相同。
  - 「链式合并 A→B→C 与直接合并 A→C：日志 ID 与写入者名字相同」：修复前第一条日志 ID 就不同，修复后日志 ID 与 `x/*` 修改记录的写入者逐条相同。
- **兼容**：不改写任何已落进同步集合的事件，新 ID / 新写入者名字只影响以后的合并。用旧版本开始、新版本重跑的未完成并入：已落的原生日志按身份被沿用（`_IdMap.alias`）；已落的 `merged-<UUIDv5>` 写入者按同 seq 同 HLC 被 `_Writers.alias` 沿用（旧写入者的修改记录只落了一部分、最大 seq 超过目标里的时沿用不成立，会改成新名字再并一份——推测，概率低，未加测试）。
- **备注**：已经落进同步集合的重复（读侧只按 ID 去重，`native/fushi_fsrs/src/history.rs` `select`）不在本次范围（用户确认数据无所谓）；卡片 / 牌组的兜底 ID（`profile-merge/<newUid>/<旧 ID>`）仍与合并路径有关，未改。
