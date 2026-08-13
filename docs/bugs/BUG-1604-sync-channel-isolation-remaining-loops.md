## BUG-1604 · 合集同步与退出书同步的通道循环仍无逐通道隔离：云通道抛异常，互联通道整轮不跑
- **报告**：2026-08-14（用户报「互联所有地方都有点问题」，TODO-2803 互联体检第⑤条的遗留部分）
- **真实性**：✅ 真 bug。BUG-1552 只修了四条通道循环里的一条（app-open sweep），
  BUG-1573 补了第二条（`runManualFullSync`），另外两条原样存活：
  - `fushi/lib/src/sync/sync_auto_trigger.dart:847`（改前）`_runCollectionsSync` 的
    `for (final SyncChannel channel in await enabledSyncChannelBackends(repo))` 循环体
    **无逐通道 try**，只有 `:879` 外层一个 `catch (e) { developer.log(...) }`。
  - `fushi/lib/src/sync/sync_auto_trigger.dart:949`（改前）`_runAutoSync` 的 per-book
    通道循环同形，只有 `:994` 外层 catch。
  - 云备份通道**恒排第一**（`enabledSyncChannelBackends`）。触发：Google Drive 令牌
    失效 / WebDAV 或 FTP 不可达 → `backend.restoreAuth(repo)` 或
    `orchestrator.runCollectionsOnly()` / `manager.syncBook()` 抛裸 `SocketException`
    → 异常冒出 for → **局域网互联通道这一轮根本不执行**。
  - 附带记账缺陷：per-book 循环的 `channelsRun++` 在 `syncBook` **之前**，抛异常的通道
    也被计成「跑过」。
- **症状预测**：设置页 UI 承诺「互联与云备份并存、互不干扰」，实际云盘一坏互联跟着哑。
  合集维度：手机上新建的合集在桌面一直不出现（合集是双端都在改的维度，漏一轮即不一致）。
  退出书维度：对端续读位置停在旧处——而退出书是「读到哪」最主要的写入时机。两处的失败
  原因都指向云盘，用户不会想到互联被连累，于是表现为弥散的「互联所有地方都有点问题」。
- **[x] ① 已修复** — 两条循环各加逐通道 try/catch，与 app-open sweep 同一范式：一条通道
  抛异常只记它自己的账（`developer.log` 带 name/stack + `interconnect=` 身份），其余通道
  照跑；`anyChannelFailed` 让最终 `reason` 如实报 `failed` 而不是把部分失败伪装成
  `completed`；per-book 的 `channelsRun++` 移到 `syncBook` 成功之后。
  提交：见本条 PR。
- **[x] ② 已加自动化测试** — `fushi/test/sync/sync_channel_isolation_test.dart`（4 例）。
  **顺带还掉 BUG-1552 ② 的欠账**：该条当时写明「未加测试，待补——给通道列表抽一个可注入
  的测试缝后，用『第一条通道 throw、断言第二条仍被调用』做守卫」，正因为缝没抽，同一个
  结构缺陷才在另外两条循环里存活至今。本次新增
  `sync_auto_trigger.dart` 的 `debugSyncChannelsOverride`（`@visibleForTesting`，生产恒
  null）+ `runAutoSyncForBookForTest` 可 await 入口，注入假通道后即可守。
  断言落在「第二条通道的 `restoreAuth` 有没有被调到」——它精确等价于「循环有没有被第一条
  通道的异常掐断」，且无需拉起 orchestrator/SyncManager。
  **变异实测**：在两个 catch 末尾各插一句 `rethrow` 还原缺陷，两条守卫精确变红
  （`Expected: true, Actual: <false>`）；撤销探针后复绿，探针零残留。
- **备注**：TODO-2803 审计的六条实锤中，①③④⑥ 与②已由 BUG-1576/1578/1579/1580/1566 在
  2026-08-12 修掉，第⑤条的这两条循环是最后的遗留。四条通道循环至此全部具备逐通道隔离。
