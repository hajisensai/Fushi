## BUG-1053 · 空闲也常驻 libtorrent/DHT（6881），整机网络周期性高延迟
- **报告**：2026-07-24。用户原话：「每隔一段时间会造成高延迟，**没开 hibiki 互联**，给 hibiki 关了就不会出现了」。
- **真实性**：✅ 真 bug，且在用户机上**实测取证**（见下）。根因 `hibiki/lib/src/models/app_model.dart` `startAnimeDownloadService`（旧行 2979-2985）。与「互联」无关——用户排除互联的直觉是对的，真凶是内置 torrent 引擎。
- **[x] ① 已修复** — 见「修复」。
- **[x] ② 已加自动化测试** — `hibiki/test/media/torrent/embedded_torrent_lazy_session_test.dart`（源码守卫：启动路径不得建 session、后端工厂走懒建、就绪判定走能力探测、探测里不得建 session、`open()` 全 AppModel 只剩一个调用点）。
- **备注**：真机复测（开着 Hibiki 不下载任何东西 → `Get-NetTCPConnection/Get-NetUDPEndpoint -OwningProcess <hibiki pid>` 应无 6881）待做。

### 证据（用户机上运行中的 hibiki.exe，2026-07-24）
```
PID 96756  hibiki.exe
TCP Listen  0.0.0.0:6881 / 192.168.1.30:6881 / 127.0.0.1:6881 / 198.18.0.1:6881
UDP Listen  192.168.1.30:6881 / 127.0.0.1:6881 / 198.18.0.1:6881
```
6881 是 BitTorrent 默认端口；**UDP 6881 = DHT**。用户当时没有任何下载任务，也没配过外接
qBittorrent。DHT 会持续向全球随机节点收发小 UDP 包（routing table 刷新是突发式的，正对上
「每隔一段时间」），把家用路由器的 NAT / conntrack 表撑满，于是同机其它连接排队 → 整机延迟
飙升；关掉 Hibiki，表项老化后恢复正常。

### 根因
`AppModel.startAnimeDownloadService()` 在 **app init 里无条件 fire-and-forget 调用**，其中：

```dart
if (_supportsEmbeddedTorrent()) {          // = 任意桌面平台
  _embeddedTorrentHost = EmbeddedTorrentHost.open(...);   // ← 建 libtorrent session
  _applyEmbeddedTorrentLimits(...);                        // ← enableDht 默认 true
}
```

三个事实叠起来才成灾：
1. `EmbeddedTorrentHost.open` 不是「准备一下」，它**创建 libtorrent session**：
   `listenInterfaces = '0.0.0.0:6881'`、`enableDht = true`（`embedded_torrent_host.dart` 默认参数）。
2. 门控只有 `_supportsEmbeddedTorrent()`（Windows/macOS/Linux 恒真），**完全没看用户是否有
   下载任务、是否选了内置后端**。`QbConnectionConfig.backend` 默认 `auto`，桌面 resolve 成
   `embedded`，所以「用户选内置后端」这个条件即使加上也是恒真。`EmbeddedTorrentHost` 的类
   doc 写的是「app 启动时（桌面、**且用户选内置后端**）open 一次」——实现与自己的契约不符。
3. `AnimeDownloadService._tickOnce` 本来就有「没有等待中的计划就不建连接」的早退，所以
   **服务层面确实是空转的**；真正常驻烧网络的是那个已经开着的 session 本身。启动注释里写的
   「未配置 qb 时每 tick 直接返回，无网络开销」只覆盖了 tick，没覆盖 session。

顺带解释了为什么与「互联」无关：互联（`sync_server_enabled` / `sync_interconnect_enabled`）
走的是自己的 HTTP server + mDNS，跟 6881 没关系。

### 修复
把「**内置引擎是否可用**」（能力）与「**是否已开一个 libtorrent session**」（资源）拆成两件事：

- `embedded_torrent_host.dart` 新增 `static bool probeAvailable({String? libraryPath})`：
  只 `EmbeddedTorrentEngine.open`（加载 DLL）、**不建 session、不绑端口、不碰网络**，结果静态
  缓存（`DynamicLibrary` 本来也卸载不掉）。附 `resetAvailabilityProbeForTesting`。
- `app_model.dart`：
  - `startAnimeDownloadService` 只记下 `_embeddedTorrentSavePath`，**不再 open**；
  - 新增 `EmbeddedTorrentHost? _ensureEmbeddedTorrentHost()`（幂等懒建 + 建好即铺资源限制）；
  - `_torrentBackendFor` 在解析出内置后端时才调懒建——这正是「真的要用下载后端」那一刻，
    而 `_tickOnce` 的「无计划不建连接」早退保证空闲用户永远走不到；
  - `isEmbeddedTorrentReady` 改为能力探测（`_embeddedTorrentHost != null || probeAvailable()`），
    这样下载对话框/下载页的「内置引擎就绪」不再逼着启动去开 session。

行为不变的部分：有下载任务时照常用内置引擎；DLL 缺失照常回退外接 qb；session 一旦建起来，
限速/DHT/上传策略等设置照旧即时生效。session 本来就不做断点续传恢复（无 resume data），
所以懒建不会让「重启后续传」变差——那本来就没有。

### 未做（本轮范围外）
- **空闲时回收 session**：现在建起来之后活到 app 结束。更彻底的做法是「所有种子完成/移除后
  关掉 session」，但要考虑做种策略（`setUploadPolicy` / 做种时长上限）的语义，另立跟进。
- **DHT 是否该默认开**：即使真在下载，DHT 对纯 tracker 种子收益有限却噪声很大。设置里已有
  `enableDht` 开关（`video_setting_torrent_dht`），默认值是否要翻成关，需用户定。
