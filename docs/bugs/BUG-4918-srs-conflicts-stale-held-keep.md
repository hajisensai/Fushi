## BUG-4918 · 冲突页处理失败后列表不重读、处理中按钮仍可点：扣住的删除反复报 no such conflict
- **报告**：2026-11-19（应用内反馈 d6njR3G6zE，macOS 3.4.0-debug.29093：「互联无法批量操作，单条操作也非常卡」）
- **真实性**：✅ 真 bug。反馈日志 2026-11-18 19:38～19:43 里 `SrsConflicts.keep` 对同两条冲突（`03449883…`、`43973553…`）连报 15 次
  `SrsCoreException(-1): no such conflict <id>: Query returned no rows`，同一 ID 跨度一分多钟，2026-11-19 10:37 又有 3 次。
  内核 `native/fushi_fsrs/src/store/sync2/mod.rs:2443` `sync2_conflict_target` 与列表 `sync2_conflicts`（:2402）读的是同一张表、同一过滤，
  所以报这个错只可能是页面上那条已经不在库里了（前一次点击已处理 / 另一台设备处理后同步过来）。页面侧两处让它停不下来：
  1. `fushi/lib/src/pages/implementations/srs/srs_conflicts_page.dart:387`（旧 `_resolveHeld`，其余 `_resolve` / `_mergeDuplicates` / `_bulkResolve` 同构）：
     写成功后才 `await _reload()`；写抛错时直接跳出，**不重读**，那条过时的冲突一直留在列表上，每点一次「保留」就再报一次，用户看到的是点了没反应。
  2. 同文件按钮回调经 `srsRunLogged` 即发即忘，处理期间按钮照常可点；一次处理要等写入（同步在跑时排在 `core:apply` 后面，日志里 busy 77.8 s）
     加整页 O(n) 重读（每条冲突逐个 `cardDetail` / `note`）完成后条目才消失，这期间每多点一下就对同一条冲突再排一次写，后排的全部撞上 no such conflict。
     另外并发的多次 `_reload` 先发后到时，旧结果会把已处理的条目画回来。
- **[x] ① 已修复** — 页面所有处理（信任 / 拒绝设备、扣住的删除、重复笔记、设置冲突、批量处理）统一走 `_act`：同一时刻只跑一次、期间按钮禁用；
  跑完无论成败都 `bumpSrsRevision` + 重读（失败照常交 `srsRunLogged` 记录，不吞）；写成功后先从页面上拿掉处理完的条目（`_dropResolved`），
  不等整页重读；`_reload` 加代次，只有最新一次读的结果落到页面上。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_conflicts_held_delete_test.dart`（MD3 / Apple 各一遍）：
  「连点「保留」：处理中按钮禁用，只写一次、不报 no such conflict」；「列表里的冲突已在别处解决：点「保留」报错后整页重读，那条从列表消失」。
- **备注**：同一反馈里的其余几项本条未做：① 「等你决定的笔记」标题全是「—」——内核 `store/caches.rs:750` 的 `sort_field` 对删除态笔记仍按首字段算，
  按代码看删除不会清空字段，「—」的成因需要用户库数据才能定（首字段本身为空 / 笔记类型缺失 / gen4 缓存路径），没有证据不猜着改；
  ② 待裁决笔记的「全部保留 / 全部删除」批量入口与 BUG-4374 当初的设计相反，属功能取舍，交拍板；
  ③ 整页重读仍是每条冲突一次往返，合成一条批量读命令是性能重构，另行处理；
  ④ 大量「删除 + 并发修改」是否是 BUG-3797 类误判回归，同样需要用户库数据核查。
