## BUG-908 · LAN 局域网同步服务器健壮性欠账（token 膨胀 / PROPFIND 同步阻塞 / 写无互斥）
- **报告**：2026-07-19（守卫审计批）
- **真实性**：✅ 真 bug（沿真实代码路径逐条核实）。三条独立缺陷，根因链见下。
- **[x] ① 已修复** — 见下方修复（a/b/d 三处）
- **[x] ② 已加自动化测试** — `hibiki/test/sync/hibiki_sync_server_hardening_test.dart`
- **备注**：单文件 `hibiki/lib/src/sync/hibiki_sync_server.dart`。真机复测局域网同步/WebDAV 原始路径待做。

### 现象
LAN 同步服务器（`HibikiSyncServer`）三处健壮性欠账，均非功能可见崩溃、而是资源/并发隐患：
- (a) 词音频查词 token 只增不减：只 POST 查词不 GET 取文件的调用者会让 token 表无界堆积（内存膨胀，慢速 DoS）。
- (b) 大目录 PROPFIND 在事件循环上做成百上千次同步 stat，卡住整个 server。
- (d) 并发 PUT/DELETE/MKCOL 同一路径无互斥，互相踩（截断/半写/删了又建的竞态）。

### 根因
**(a) 音频 token 无 prune 无 cap**
- POST 侧 `_handleAudioLookup`（`hibiki/lib/src/sync/hibiki_sync_server.dart:860`，`:877` 写入
  `_remoteAudioTokens[id]=...`）既不 prune 也无数量上限。
- prune 只在 GET 侧 `_handleAudioFile`（`:886` 调 `_pruneAudioTokens`）触发；只 POST 不 GET 的
  调用者永远等不到它。
- `_pruneAudioTokens`（`:2123`）只按 5 分钟 TTL `removeWhere`，**无数量 cap**——即便 GET 也被调，
  TTL 内高频签发仍能撑爆。对照 pair session 已有 `_enforcePairSessionCap`（`:2143`）+ `_maxPairSessions`。

**(b) PROPFIND 逐项同步 stat 阻塞**
- `_handlePropfind`（`:2190`）枚举已用异步 `dir.list()`（`:2212`），但逐项 stat 仍同步：根类型判定
  `FileSystemEntity.typeSync`（`:2193`）、子项长度 `(child as File).lengthSync()`（`:2216`）、单文件
  长度 `file.lengthSync()`（`:2231`）。大目录 = 成百上千次阻塞 syscall 串在事件循环上。

**(d) WebDAV 并发写无互斥**
- WebDAV 分发 `switch (method)`（`:525`）直调 handler，写类 `_handlePut` / `_handleDelete` /
  `_handleMkcol` 之间无任何 semaphore/mutex/lock/queue。并发 PUT/DELETE 同一路径无序，
  `openWrite` 截断 + 另一路径同时删/建 → 半写/竞态。

### 修复
**(a)** 仿 pair session：新增数量上限 `_maxAudioTokens = 128` + `_enforceAudioTokenCap()`（TTL prune
后仍达上限时按 `createdAt` 淘汰最旧者）。POST 侧签发前先 `_pruneAudioTokens()` 再 `_enforceAudioTokenCap()`，
使插入后总数恒 `<= _maxAudioTokens`。测试钩子 `remoteAudioTokenCount`。

**(b)** 三处同步 stat 全改异步：`typeSync` → `await FileSystemEntity.type(fsPath)`；两处 `lengthSync()`
→ `(await file.stat()).size`。均在 `Future<shelf.Response> _handlePropfind` / `await for` 循环内正确
`await`，不打乱 XML 组装顺序。

**(d)** 新增按路径串行闸门 `_serializeDavWrite<T>(String fsPath, Future<T> Function() action)` +
`Map<String, Future<void>> _davWriteChain`。每路径一条链式 future：新写取当前链尾 `prev`、把自己的
完成 future 挂成新链尾、`await prev` 后执行 `action`、`finally` 里 complete 自己并在仍是链尾时摘除
（防 map 无界增长）。分发层 PUT/MKCOL/DELETE 三 case 包进闸门；读操作（PROPFIND/GET/HEAD）不入闸。
**防死锁**：只 await 单一路径上的前驱、绝不在持有一把锁时去取另一把（当前 WebDAV 分发无 MOVE/COPY
双路径操作），故无锁序死锁；与 `start()` 注释（`:275`）里 BUG-035 的 bootstrap 死锁语境正交。

### 测试
`hibiki/test/sync/hibiki_sync_server_hardening_test.dart`：
- (a) 行为单测：固定时钟（TTL 清不掉任何 token，收束只能来自 cap）下狂发 300 次 POST /api/lookup/audio，
  断言 `server.remoteAudioTokenCount <= 128`。
- (b) 源码扫描守卫：断言 `_handlePropfind` 区间不再含 `lengthSync` / `typeSync`，且已出现
  `await FileSystemEntity.type(` 与 `.stat()).size`。
- (d) 源码扫描守卫：断言 PUT/MKCOL/DELETE 分发都经 `_serializeDavWrite`，且 helper 是按路径链式串行实现。
