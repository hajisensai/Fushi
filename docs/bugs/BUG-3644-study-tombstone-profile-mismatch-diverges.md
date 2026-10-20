## BUG-3644 · study-tombstone-profile-mismatch-diverges
- **报告**：2026-10-21（用户：QQ 群报「电脑下书 → 平板看完并同步统计 → 电脑删书后电脑上统计没了，只有平板有」）
- **真实性**：✅ 真 bug（条件触发）。先沿真实路径排除了「删书本身删统计」：删书默认不勾「同时删除统计数据」时，DB / 聚合同步 / 统计展示层都不丢该书的段（复现测试两端都还在 5000 字；展示层逐页核过，没有按在库过滤的地方）。能落到代码上的路径是：**两端 Profile 名字不同 + 删过这本书的统计**（删书时勾选，或在统计页删该书）。根因 `packages/fushi_engine/lib/sync/aggregate_sync_service.dart` `_applyStudySegments`：段名字对不上回退进激活 Profile，碑名字对不上直接丢弃——不对称。电脑把平板的段收进自己的 `Default`、删统计立的碑只带 `Default`，到平板（`默认`）被丢弃；平板的段照常上行，又被电脑的碑挡在门外，两端永久分叉。
- **[x] ① 已修复** — 落地回退时记设备本地别名「对端名字 → 本机 Profile」（`kStudyProfileNameAliasesPrefKey`，`FushiDatabase.addStudyProfileNameAliases`），导出与上行过滤时该 Profile 的碑按别名再发一份（`_tombstoneRecordsOf`）；别名已是本机某 Profile 名时不发。保留 v105「名字对不上的碑丢弃」——只是把碑补成对端认得的名字，不越权压别的 Profile。已分叉的存量下一轮自愈（别名对全快照记）。别名键登记进 `ProfileKeys` / `SyncRepository.deviceLocalPrefKeys` 排除表。
- **[x] ② 已加自动化测试** — `fushi/test/sync/study_tombstone_profile_alias_test.dart`（删书不删统计两端都留 / 名字不同删统计后两端收敛 / 存量分叉自愈 / 同名精确对上不记别名、EN 的碑不压平板 JP）。
- **备注**：群里另一条「平板看不到电脑之前的数据」与 Profile 名回退同源可能（名字不同的段落进激活 Profile，切到别的 Profile 就看不见），未单独复现。
