## BUG-4217 · 合并 profile 后同一次复习变成两条，FSRS 优化 log loss 从 0.6 涨到 1.6
- **报告**：2026-11-06（用户：RWKV 牌组下 FSRS 影子参数的 log loss 原来约 0.4–0.6，同步之后涨到 1.6 多）
- **真实性**：✅ 真 bug，用户本机 srs.db 只读核对：5849 条评分复习里只有 3658 条不同，多出 2191 条（521 张卡）；每组重复都是一份 11-04、一份 11-05 经同步收到，内容相同、ID 不同。Anki 导入的重复里，每组恰好一份是 `UUIDv5(卡片, anki-revlog/<id>)` 的规则 ID、另一份不是；原生日志的重复是「原 UUIDv7 + 合并兜底的 v5」。参数组记录：10-19 桌面 639 条 log loss 0.61，11-06 手机 4066 条 1.59（版本向量里有两个 `merged-` 写入者）。
- **根因**：`packages/fushi_engine/lib/srs/srs_profile_merge.dart` 第 7 步（复习日志重算 ID）。导入 revlog / 导入锚点只有在「旧 ID 恰好按旧卡片派生」时才按规则换 ID，否则走 `uuidV5(profile-merge/<newUid>/<旧 ID>)` 兜底；旧 profile 本身是更早一次并入的产物时 revlog ID 早已是兜底 ID，验证必不过，同一条 Anki 复习于是按另一条来路得到第二个 ID。原生日志一律兜底，目标集合里已有原 ID 时又多一份。同步与历史选取（`native/fushi_fsrs/src/history.rs` `select`）按 ID 认身份，两份都算有效复习；间隔 0 天的同评分重复（尤其「重来」）让 FSRS 优化 log loss 暴涨。
- **根因（续，审查 PR #3004 时发现）**：
  1. **回归——恢复备份的重放副本与原日志撞 ID**：PR #3004 初版把规则 ID 套到所有带 `ankiRevlogId` 的日志和所有 `importAnchor` 上。恢复备份写出的重放副本（`packages/fushi_srs/lib/src/restore_plan.dart` `_replayOf`）照抄 ankiRevlogId / 种类 / 发生时刻，只换新 ID、新 HLC、extra 记 `replayOf`；它和已被 undo 撤销的原日志算出同一个规则 ID，`seenLogs` 静默只留一份、undo 的 `revokes` 也指过来，这次复习整条消失，核对照样通过、旧 profile 被删。触发：导入 apkg → 恢复到导入前（撤销）→ 恢复到导入后（重放）→ 合并 profile。
  2. **原生日志兜底 ID 与合并路径有关**：`profile-merge/<newUid>/<旧 ID>` 链式合并 A→B→C 得 `fb(C, fb(B, x))`，另一台设备直接 A→C 得 `fb(C, x)`，同一次复习两个 ID。**写入侧不修**（见下「撤回」），由读侧按内容身份合并（BUG-4218，`native/fushi_fsrs/src/history.rs` `EventKey`）。
  3. **修改记录写入者改名同样链式**：`merged-uuidV5(profile-merge/<newUid>/writer/<上一跳名字>)`，A→B→C 与 A→C 名字不同 → dot 不同 → 同一批修改记录两份（用户版本向量里两个 `merged-` 写入者可能即此——**推测**，未从用户库逐条核对这两个写入者的来路）。
  4. **`seenLogs` 静默去重**：两条身份不同的日志映射到同一 ID 时也只留一份，丢数据不报错。
  5. **断言失败会永久卡住同步**：并入标记在 `srsMergeProfileUid` 一开头（`_plan` 之前）写进 `srs_meta`，计划阶段抛 `StateError` 时标记不删；`SrsDbProfileLinker.link` 每次先 `_resumePendingMerges` 重跑这次并入（`srs_profile_link.dart:523` → `:687` 起），以前原样再抛，调度器整轮失败，这台设备的复习同步从此每轮都卡在 link。
- **撤回（审查发现的回归）**：中间版本曾把原生日志 / undo / 重放副本改成按内容派生 `uuidV5(新卡片, profile-merge-log/<HLC>/<kind>)`，想让链式与直接合并同 ID。错：undo 的 `revokes` 目标不在本机旧 profile 里时（同步顺序不保证）只能按旧 ID 兜底，而有这条日志的设备按 HLC 派生——同一条 undo（同 ID）在两台设备上内容不同，`_applyMissing` 按 ID 跳过、先到先得，被撤销的复习可能复活、各设备分歧（`restore_plan.dart` 的撤销本来就会撤别的设备的复习）。已退回按旧 ID 兜底；链式合并的多 ID 副本交给读侧合并。注意按旧 ID 兜底**只在本机看得到 undo 的目标时**才让各设备的 `revokes` 一致——目标是 Anki 原始导入日志（规则 ID）或命中目标沿用（`_IdMap.alias`）时，有目标的设备给的是规则 ID / 目标 ID，没有的设备只能兜底，见下「根因（续 2）」。
- **根因（续 2，审查发现）**：第 7 步给 Anki 原始导入 revlog / 锚点的是规则 ID（`importedRevlog(新卡片, revlog)` / 锚点规则），命中目标沿用的给目标 ID，而 undo 的 `revokes` 目标不在本机旧 profile 里时只能落到 `profile-merge/<newUid>/<旧 ID>` 兜底（`srs_profile_merge.dart` 第 7 步 `fallbackAll` 与第 9 步 `j['revokes'] = ids[l.revokesId!]`）。设备 X 有被撤销的 R、设备 Y 只有 undo U：两台写出同 ID 的 U、`revokes` 不同，`_applyMissing` 按 ID 先到先得，Y 那份先到时被撤销的导入复习复活；兜底 ID 下根本没有日志，读侧按内容身份合并（BUG-4218）也救不回来。原「残留风险」里的目标沿用变体是同一个问题。
- **[x] ① 已修复** — `srs_profile_merge.dart` 第 7 步（`:581` 起）与第 9 步、`_Writers`，`srs_profile_link.dart` `_resumePendingMerges`：
  - 规则 ID 只给自身身份证明是那次导入的日志：revlog 要 origin = anki、`hlc == srsImportedRevlogHlc(ankiRevlogId)`、无 `replayOf`；锚点要 `importAnchor`、origin = anki、`hlc == srsImportAnchorHlc(occurredAt)`、无 `replayOf`（`:599` 起）。
  - 其余日志（原生日志、undo、重放副本）与 undo 的目标、不认识的事件一律按旧 ID 兜底 `uuidV5(profile-merge/<newUid>/<旧 ID>)`（第 7 步 b），与合并前的方案相同，见上「撤回」。
  - **undo 的目标还没同步到就暂缓整个并入**（第 7 步 d，`srs_profile_merge.dart:674` 起）：某条 undo 的 `revokesId` 既不是旧 profile 里的日志、按兜底算出的 ID 也不在目标 uid 下（`_presentIn` 看投影与 `sync2_log_meta`）时，在任何落库之前抛 `SrsProfileMergeDeferred`（`StateError` 子类，带 oldUid / newUid / 缺的旧 ID，`:152`）。并入标记照旧留着，`_resumePendingMerges` 单独接住它（`srs_profile_link.dart:711`）：`where` 标成 `deferred (not a failure)`，同一批缺口每个进程只记一次（`_deferredLogged`），按当前（旧）uid 继续同步——这正是把 R 送进旧 profile 的途径，下一轮重跑就按 R 的内容给出与 X 相同的 `revokes`。兜底 ID 已在目标里（别的设备按兜底并过 R，例如 R 是原生日志、并入前先拉了目标）时不暂缓，`revokes` 正指向那条。
  - 取舍：R 永远不来（所在的段已被清掉、或 undo 撤销的是本集合之外的日志）时并入一直暂缓，这台设备一直留在旧 uid 上同步——不丢数据、同步不停，但两个 profile 的复习数据不互通，且只在错误日志里有一条暂缓记录、没有 UI 提示。宁可不并也不写出各设备分歧的 undo（分歧一旦落进同步集合就改不回来）。用户在冲突弹窗里主动选择合并（`SrsDbProfileLinker.adopt` → `_switchUid`）遇到暂缓时异常照常抛给调用方，标记已写，之后的 link 轮次按上面的方式重试。
  - 目标沿用保留（同一身份 → 目标 ID），`_logIdsByIdentity` 加 `ORDER BY id`，同身份多条时确定取最小 ID（`:738`）；沿用条数经 `SrsProfileMergeResult.aliasedIds` 暴露。
  - 第 9 步：两条旧日志映射到同一新 ID 时，身份（卡片 + 种类 + 评分 + 发生时刻 + HLC + 映射后的 revokes）相同才只并一份，否则抛 `StateError`——在第一次落库前中止，旧 profile 不删（`:697` 起）。
  - 写入者改名从**最初的写入者**派生：新名字 `merged-uuidV5(profile-merge/<newUid>/writer/<最初>)~<最初>`，下一次合并剥出 `<最初>` 再算（`_mergedWriterOrigin` / `_mergedWriterNames`，`:912` 起）；同一旧 profile 里两个写入者剥出同一个最初写入者、或剥完名字等于自己时不剥；最后断言改名一一对应，否则 `StateError`（`:945`）。
  - 断言失败不再卡死同步：`_resumePendingMerges`（`srs_profile_link.dart:683` 起）接住 `srsMergeProfileUid` 的失败，经 `onError`（app 接 `ErrorLogService`，`where` 带 profile / 旧 uid / 新 uid）记下，这一轮跳过这次并入、按 profiles 表当前的 uid 继续同步；标记留着，下一轮照样重试。失败的并入保证旧 uid 的行一行不动（删旧行与核对在同一事务）。并入在改完主库 uid 之后才失败、手里的 store 还是旧 uid 时，按新 uid 重开 store（`:719`）。代价：标记在的每一轮都要重算一次计划（含并入前的有界拉取），并且只进错误日志、没有 UI 提示。
  - 首次修复（PR #3004 原内容，仍保留）：旧 profile 本身是更早一次并入的产物、revlog ID 早已是兜底 ID 时不再验证旧 ID，原导入日志照规则落回同一个 ID；目标里已有同一条复习时沿用目标 ID（`_IdMap.alias`，BUG-4011 同思路）。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/srs_profile_merge_test.dart`：
  - 「同一次复习（Anki revlog / 原生日志）已在目标里或在旧 profile 里有多个 ID：合并后只剩一条」（PR #3004 原用例，加断言 `aliasedIds == 1`）。
  - 「导入 revlog / 锚点被恢复撤销、又被恢复重放：合并后有效历史与卡片状态不变，重放副本没被撤销」：撤销与重放走真实的恢复计划（`srsPlanRevokeLogs` → `srsPlanStateRestore` 的重放档），不手抄副本形状。PR #3004 初版（规则 ID 套到所有带 ankiRevlogId 的日志 / 所有锚点）下红，修复后 6 条、有效历史仍是两条副本、状态与合并前相同。
  - 「链式合并 A→B→C 与直接合并 A→C：写入者名字相同；两条路径的日志副本相遇后有效历史不变」：写入者名字逐条相同；日志 ID 可以不同，有效历史内容与卡片状态相同；把链式那份日志同步进直接那台后（一次复习两个 ID），读侧选出的有效历史与状态仍不变。
  - 「undo 的目标（原生日志）还没同步到：并入暂缓、什么都不写；目标到了再并，两台设备的 undo 逐字段相同」「undo 撤销的 Anki 导入 revlog 还没同步到：并入暂缓；到了以后两台设备的 undo 都撤销规则 ID」：暂缓时 profiles.uid、旧 uid 行数不变、目标下没有日志、标记仍在；把 R 送进旧 profile 后重跑成功，两台设备的 undo `toJson()` 相同，导入那份撤销的是 `importedRevlog(新卡片, revlog)`、有效历史为空。去掉暂缓（变异）后这两条与下面 link 那条红。
  - 「undo 的目标不在旧 profile 里、但已按兜底 ID 在目标里：不暂缓」：并入前经真实只拉不发收到另一台设备并好的 R。
  - 「并入暂缓经 link：不抛、同步照跑、只记一次；目标日志到了下一轮做完并入」。
  - 链式 vs 直接用例加一步：只把链式那份 r2（不带 undo）收进直接那台，r2 不在有效历史里、`revoked` 含链式那份 ID。
  - 「两条不同的旧日志映射到同一个新 ID」「两个旧写入者会改成同一个名字」：各自抛 `StateError`，profiles.uid 与旧 uid 的行不变。
  - 「并入在计划阶段失败：link 不再每轮抛出，记错后按当前 uid 继续同步，标记留着重试」：连跑两次 link 都不抛、各记一次错，之后的同步轮次成功，标记仍在。
- **兼容**：
  - 不改写任何已落进同步集合的事件，新 ID / 新写入者名字只影响以后的合并。
  - 新旧版本混用：同一个旧 profile 由旧版本在一台设备、新版本在另一台设备各自并入同一个新 uid 时，原生日志 / undo 两边都按旧 ID 兜底、ID 相同；Anki 原始导入 revlog 新版本一律按规则、旧版本只在旧 ID 验算吻合时按规则，旧 profile 是更早并入的产物时两边 ID 不同，由读侧按内容身份合并（BUG-4218，旧版本客户端没有这条读侧规则，会照旧多算一份——推测，未实测）；写入者名字新版本是 `merged-<UUIDv5>~<最初>`、旧版本是 `merged-<UUIDv5>`，两边 dot 不同，同一批修改记录会各落一份，除非一边先收到另一边的再并（`_Writers.alias`）。
  - 旧格式 `merged-<UUIDv5>` 剥不出最初的写入者（哈希不可逆），新版本对它按整个名字当最初写入者派生；所以旧版本做过的一跳之后再链式合并，与另一台设备从最初的 profile 直接合并，写入者名字仍不同（只有全程新版本时才与路径无关）。
  - 用旧版本开始、新版本重跑的未完成并入：已落的原生日志按身份被沿用（`_IdMap.alias`）；已落的 `merged-<UUIDv5>` 写入者按同 seq 同 HLC 被 `_Writers.alias` 沿用（旧写入者的修改记录只落了一部分、最大 seq 超过目标里的时沿用不成立，会改成新名字再并一份——推测，概率低，未加测试）。
- **残留风险（推测，未加测试）**：目标沿用取「同一身份 ID 最小的那条」，看的是并入那一刻目标里有什么：X 并入时目标里只有 `fb(M)`、Y 并入时目标里又多了一条同身份、ID 更小的 N，两边给 M 的 ID 不同（原「目标沿用 + undo 先到」变体已由暂缓覆盖：Y 没有 M 时不并）。此时两份 M 内容相同，读侧按内容身份合并（BUG-4218），撤销任一份即整组撤销，不会复活。
- **备注**：已经落进同步集合的重复由读侧按内容身份合并（BUG-4218）；卡片 / 牌组的兜底 ID（`profile-merge/<newUid>/<旧 ID>`）仍与合并路径有关，未改。
