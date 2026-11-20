## BUG-4906 · 旧整包备份覆盖恢复到已打开过的新 profile：备份的盐没进新集合，卡片与复习日志脱钩、界面 0 张
- **报告**：2026-11-20（SRS gen4 第六波 R0 Windows 实测 e1-replace 发现，证据 `docs/specs/2026-11-15-srs-gen4-r0-windows.md` §4.6；
  归属本来划给 G11-4 / G9 导入与身份，R0 复核轮按「实测出缺陷就按根因修」在分支 `pr/srs-gen4-w6-r0-windows` 上修）。
- **真实性**：✅ 真 bug。
  - 实测：v3.3.0 整包备份（6 卡 / 12 条复习日志）在新版本 release 上「覆盖」恢复，`srs4.db` 里 6 张卡全部 `hidden=1`、`queue new`、
    `reps 0`，卡片 ID 是按不带盐的模板重新派生的，对不上 `log_ix` 与 `alias_ix`；`salt_ix` 只有本机 profile uid，没有备份的 uid；
    界面卡片总数 0。
  - 根因：`native/fushi_fsrs/src/store/gen4/cmd/backup.rs` `land`（修前 `:641` 起）认领走 `collection_adopt_with`，本机 profile 已打开过
    （空集合，目录名 = 本机 uid 大于备份 uid）→ `identity.rs:637` `rebind_empty` 换绑，结论 `AdoptOutcome::Bound`；`cmd/identity.rs:410`
    在 `Bound` 之后只写本机身份的初始盐（`ensure_self`）与换绑丢掉的本机盐（`carry`）。`Bound` 的设计是对方的盐随对方的操作到
    （位置、`.fushisrs` 第 2 版的流里都有 `Salts` 操作），而协议 3 备份副本里**没有任何 `Salts` 操作**：清单里的备份盐
    （`manifest_of` → `legacy::salts`）只用于身份确认，从没写进新集合。缺这个盐，带 profile 盐的内置实体（默认模板 / 字段等）
    ID 归不到规范 ID。没打开过的 profile（`a_protocol_3_backup_lands_exactly_like_the_migration`）恰好因为本机 uid = 备份 uid、
    `ensure_self` 写的初始盐就是它而没暴露。
- **[x] ① 已修复**（分支 `pr/srs-gen4-w6-r0-windows`）— `cmd/backup.rs` `land`：认领结论是 `bound` 时，在身份核对之后、`import_backup`
  之前由本机另写一条 `Salts` 声明备份 profile 的盐（已过身份确认闸），与迁移第 6 步本机身份写初始盐同口径；写盐的函数是
  `cmd/identity.rs` 原 `carry_salts`，改名 `declare_salts` 供两处共用。**没有**改成在 `collection_adopt_with` 的 `Bound` 分支一律写
  调用方给的盐：那样位置认领 / `.fushisrs` 第 2 版也会多写一条本机 `Salts`，实测打破 4 条既有测试（`identity_tests`
  `profiles_bind_to_their_own_collections_and_an_unbound_one_joins_first`、`profile_data_tests` 两条、`sync_relay_tests`
  `devices_converge_after_a_join` 的 `canonical_ids` 两台设备不再一致），只有自身不带 `Salts` 的旧备份输入需要本机代为声明。
- **[x] ② 已加自动化测试** — `native/fushi_fsrs/src/store/gen4/cmd/backup_tests.rs`
  `a_protocol_3_backup_replacing_a_fresh_profile_keeps_its_salts_and_cards`：协议 3 备份（profile P）确认读进已打开过的全新 profile Q →
  `bound`，`collection_info` 的盐含 P 与 Q，`cards` / `notes` / `log_ix` 派生行与直接迁移同一份库逐行相同。变异实测：去掉修复
  （注释 `declare_salts` 那一行）这条红（`backup_tests` 13 过 1 败），只去掉盐断言时卡片 / 日志行比对同样红；还原后工作区干净。
- **备注**：R0 实测里的复现数据 `D:/fushi-r0/A/old-backup.zip`（本机，不入库）。修后在 release 上重跑了 e1-replace（同一个 `fushi.exe` 换上
  修复后的 `fushi_fsrs.dll`）：6/6 卡、12/12 条日志逐条一致、卡片 ID 与迁移路径相同（R0 文档 §4.6）。
