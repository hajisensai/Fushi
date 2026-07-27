## BUG-1178 · restoreAuth 无条件作废已解析地址，每次切页面重跑全候选探测

- **报告**：2026-07-28（用户：互联切页面重新拉取，排查时发现）
- **真实性**：✅ 真 bug。根因在
  `hibiki/lib/src/sync/interconnect_sync_backend.dart:189` —— `_loadConfig` 末尾
  **无条件** `_sessionResolved = false`，而 `_loadConfig` 是 `restoreAuth`
  （同文件 `:270`）的第一步。

  `restoreAuth` 又是每个消费方取 client 的必经之路：
  - `hibiki/lib/src/pages/implementations/reader_history/remote.part.dart:20`
  - `hibiki/lib/src/pages/implementations/home_video_page.dart:467`
  - `hibiki/lib/src/pages/implementations/home_dashboard_page.dart:528`

  且 `InterconnectSyncBackend.instance` 是**单例**，三个页面共享同一个
  `_sessionResolved` / `_ops`。净效果：每切一次页面就把已经探明可达的地址作废一次，
  下一次网络操作要在 `_ensureResolved`（`:218`）里重跑
  `resolveReachableHibikiCandidate`（`:33`）的全候选**串行**探测；https 候选还各要一次
  带指纹钉扎的 TLS 握手（`_pinnedReachabilityProbe`，`:57`）。三个页面之间还互相踩
  ——视频页一 `restoreAuth`，书架页正在跑的会话就被作废。

  这是 [BUG-1175](BUG-1175-interconnect-remote-list-no-cache.md)「切页面重拉」的
  **延迟放大器**：不止多一次清单请求，是多一整轮地址探测再加一次清单请求。

- **[x] ① 已修复** — 会话该不该重来，取决于**配置是否真变**，而不是「有人调了
  restoreAuth」。`_loadConfig` 改为先算 `_sessionSignature(candidates, token)`
  （地址集合 + 钉扎指纹 + 令牌；`deviceName` 是纯展示字段，不进签名），与
  新增字段 `_configSignature` 比对，**只在不同时**才 `_sessionResolved = false`。
  `signOut` 里把 `_configSignature` 归零，保证重新配上同样地址也会重探一次。

  地址失联后的换路由径不受影响——那条路走 `clearCache()`（同文件 `:525`，
  `SyncManager` 重试前调用），与本处正交。

- **[x] ② 已加自动化测试** — 新增
  `hibiki/test/sync/interconnect_session_reuse_test.dart`（6 例，经
  `InterconnectSyncBackend.withProbe` 注入计数 probe）：
  配置未变时连续 `restoreAuth` 不重探 / 令牌变化重探 / 候选地址集合变化重探 /
  钉扎指纹变化重新解析（带指纹的候选绕过注入 probe 走真实 pinned 探测，故改断言
  「确实重新解析而非沿用旧会话」）/ 仅 `deviceName` 变化不重探 / `signOut` 后必重探。

- **备注**：与 [BUG-1175](BUG-1175-interconnect-remote-list-no-cache.md) /
  [BUG-1176](BUG-1176-manga-shelf-fetches-remote-books.md) /
  [BUG-1177](BUG-1177-show-remote-entries-gate-too-late.md) 同一轮排查。
