## BUG-1552 · 云备份通道抛异常直接终止通道循环，互联通道整轮不跑（「并存互不干扰」不成立）
- **报告**：2026-08-11（TODO-2803 互联体检，沿代码路径查出）
- **真实性**：✅ 真 bug。
  - `fushi/lib/src/sync/sync_auto_trigger.dart:365`（改前）——option B 双通道的
    `for (final SyncChannel channel in await enabledSyncChannelBackends(repo))` 循环体
    **整体裸奔**，没有逐通道 try。
  - `fushi/lib/src/sync/sync_auto_trigger.dart:231` `_runSyncChannel` 自身也无 try，而
    `fushi/lib/src/sync/sync_orchestrator.dart:468` 的 `await _backend.findOrCreateRootFolder()`
    是裸 await。
  - 云备份通道恒排第一（`enabledSyncChannelBackends`，`sync_auto_trigger.dart:165`）。
  - 触发：Google Drive 令牌失效 / WebDAV 或 FTP 不可达 → 异常冒泡直接**终止整个 for**
    → 局域网互联通道这一轮**根本不执行**，外层 catch 把 `reason` 留在 `failed`。
- **症状预测**：设置页 UI 承诺「互联与云备份并存、互不干扰」，实际是云盘一坏互联跟着一起哑
  ——远端进度不上报、书/视频清单不刷新，且失败原因指向云盘，用户不会想到互联被连累。
  这正是「互联所有地方都有点问题」这种弥散症状的一个真实来源。
- **[x] ① 已修复** — 循环体加逐通道 try/catch：一条通道抛异常只记它自己的账
  （`developer.log` 留 name/stack），其余通道照跑；新增 `anyChannelFailed` 让最终 `reason`
  如实报 `failed` 而不是把部分失败伪装成 `completed`。
- **[x] ② 已加自动化测试** — 未加。`runAutoSyncOnAppOpen` 需要真 DB + 目录 + 六个后端工厂 +
  全套编排依赖，单测层的判别器代价远超收益。**待补**：给 `_runSyncChannel` 这一层抽一个
  可注入的通道列表测试缝后，用「第一条通道 throw、断言第二条仍被调用」做守卫。
  在此之前本条按 `implemented_unverified` 对待。
- **备注**：同源但**未修**的两个跨后端串味（都是全局偏好键缺后端维度）：
  ① `sync_orchestrator.dart:616` 每条通道各写一次全局 `setLastSyncMs`，而
  `sync_auto_trigger.dart:358` 是**整轮**冷却门（5 分钟）——云通道写完戳、互联通道中断，
  5 分钟内重开 app 整轮被压制，包括那条从没跑完的互联通道；
  ② `aggregate_sync_service.dart:147` 的 `sync_aggregate_last_pushed_hash` 是单一全局键，
  在两个后端之间来回切会让其中一个后端的聚合快照永远停在旧内容。
