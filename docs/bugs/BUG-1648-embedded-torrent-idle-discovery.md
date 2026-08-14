## BUG-1648 · 已完成任务恢复后 DHT 常驻导致网关周期性高延迟
- **报告**：2026-08-14（Windows 用户）。用户在 Fushi 空闲时观察到网关
  `192.168.137.229` 的正常延迟约 `1–5 ms`，随后出现一次「请求超时」及
  `95 ms` 峰值；另一轮在 `1–4 ms` 基线上出现连续 `15 ms` 与一次超时。
- **真实性**：✅ 真 bug。截图本身只能证明媒体界面变化与延迟在时间上相邻；沿真实
  torrent 恢复链确认，已完成计划也会触发 fastResume、创建默认开启 DHT 的
  libtorrent session，而完成后的 session 没有空闲发现生命周期，直到 AppModel
  退出才关闭。根因见
  `fushi/lib/src/models/app_model.dart:3889-3953`、
  `fushi/lib/src/media/torrent/embedded_torrent_host.dart:194-230,831-834`。
- **[x] ① 已修复** — session 恢复阶段显式以 `enableDht:false` 创建；宿主新增
  discovery demand 状态机，只在有未完成下载、允许做种任务或同步 add/resume 临时
  wake 时按用户配置开启 DHT/LSD/UPnP/NAT-PMP，空闲后立即幂等收回。实现见本分支
  `embedded_torrent_host.dart`、`embedded_torrent_backend.dart`、`app_model.dart`。
- **[x] ② 已加自动化测试** —
  `fushi/test/media/torrent/embedded_torrent_idle_discovery_test.dart`（11 个 fake FFI
  行为用例）及 `embedded_torrent_lazy_session_test.dart`（启动恢复初始 DHT 静默守卫）；
  定向验证 `PASSED - 17 tests ran`，全量 `flutter analyze --no-pub` 为 `No issues found`，
  Windows Debug `--no-pub` 增量构建成功。
- **备注**：本条是 [BUG-1053](BUG-1053-embedded-torrent-dht-always-on.md) 的
  后续生命周期缺口，不是同一条启动期回归。歌词/媒体浮层的重复绘制有独立的性能
  优化空间，但它不产生 DHT UDP 流量，也不足以单独解释网关 ICMP 超时，故不列为
  本条根因。

### 现象与复现

1. Windows 上曾使用内置 torrent 完成一个下载并留下对应的计划 JSON 与
   `<infohash>.resume`，保持默认「上传/做种关闭」和 DHT 开启。
2. 重启 Fushi；此时没有 `downloading` 计划，用户也没有主动开始新下载。
3. 先运行 `arp -a` 确认当前局域网网关地址，再运行 `ping -t <网关地址>`。用户截图中
   目标为 `192.168.137.229`，基线约 `1–5 ms`，空闲期间会看到延迟突升乃至请求超时。
4. 对照关闭 Fushi，或在相同任务与网络条件下禁用内置 session 的 DHT/发现流量；周期性
   峰值随后台发现停止而消失。验收时同时记录 Fushi PID 的 UDP 端点/网络字节，避免只凭
   媒体浮层切歌时刻反推因果。

截图右上角的带封面媒体条只作为时间标记：Fushi 的 Windows 原生浮动歌词窗口没有封面
渲染，标准本地有声书切句也不会下载封面。它与 ping 峰值同帧不等于它造成丢包。

### BUG-1053 留下的边界

BUG-1053 已把「能力探测」与「真实 session」拆开：
`startAnimeDownloadService` 只准备路径，第一次真正需要下载后端时才调用
`_ensureEmbeddedTorrentHost()`，从未创建过任务的空闲用户因此不会绑定 6881 或启动
DHT（`app_model.dart:3372-3431,3519-3525`）。

后续 fastResume 恢复又引入了第二个入口：

- `AnimeDownloadPlan` 的终态包括 `statusImported` / `statusFailed`
  （`anime_download_plan.dart:78-85`），但 `_refreshAnimeDownloadPlanIds()` 把
  `store.loadAll()` 的**所有**计划 ID 都收入恢复真相源，没有区分是否仍需下载/做种
  （`app_model.dart:3889-3901`）。
- `_restoreEmbeddedTorrentSession()` 只检查「计划 ID 存在且同名 `.resume` 存在」，便
  调用 `_ensureEmbeddedTorrentHost()`；已完成计划同样满足条件
  （`app_model.dart:3924-3953`）。
- `EmbeddedTorrentHost.open()` 创建监听 `0.0.0.0:6881`、`enableDht=true` 的 session，
  再加载 resume（修复前 `embedded_torrent_host.dart:194-230` 的默认参数与调用链）。配置默认也启用 DHT/LSD/
  UPnP/NAT-PMP，而默认 `uploadEnabled=false`
  （`anime_download_config.dart:9-38`）。也就是说，完成种子很快会因上传策略暂停，
  但 session 级 DHT 发现仍然运行，没有任何有效工作需要这些 UDP 探测。
- 宿主只有 AppModel `dispose()` 才调用 `EmbeddedTorrentHost.dispose()`；后者保存 resume
  后关闭 session（`app_model.dart:5522-5528`、
  `embedded_torrent_host.dart:831-834`）。任务从下载中转为完成、恢复结果全部空闲、
  或用户关闭做种，都不会同步关闭发现协议。

因此 BUG-1053 的「从未有任务不启动」成立，但「曾有任务、启动时恢复后已经没有有效发现
工作」仍会让 DHT 常驻，重新出现同一种网关周期性高延迟。

### 修复方案

把「宿主/session 为 fastResume 与任务控制而存在」和「当前是否需要 peer 发现」拆成两个
生命周期，不能靠延迟、重试或吞异常掩盖：

1. 从真实 torrent 状态与上传/做种策略推导 discovery demand：存在尚未完成且未被用户
   暂停的下载，或存在策略明确允许继续做种的完成任务时，才需要 DHT/LSD/端口映射；
   只有已完成且策略禁止上传的恢复任务时必须判为空闲。
2. 复用现有 session settings 原语切换 DHT、LSD、UPnP、NAT-PMP；空闲时全部关闭，恢复
   有效下载/做种工作时按用户配置重新开启。保留宿主与 fastResume 状态，避免为了省流量
   销毁 session 后破坏断点续传、显式暂停或后续恢复。
3. 在启动恢复完成、每轮 torrent 状态/上传策略扫描、任务完成/删除以及设置变化后同步
   discovery demand；同一状态必须幂等，不得每 tick 重复下发相同 native 设置。
4. 做种时限使用 fastResume 导出的累计做种时长；老 DLL 缺该字段时把完成起点原子落盘，
   重启也不能重新计时。torrent 状态读取使用可区分“成功为空”与“读取失败”的三态入口，
   失败时保留最近可靠状态，不能误关活跃磁力所需的 DHT；延迟 restore 同样配对 wake。
5. 外接 qBittorrent 路径保持不变；用户显式关闭 DHT/LSD/端口映射时不得被 workload
   状态擅自重新打开。

本分支落点：`EmbeddedTorrentHost.applySessionSettings()` 保存用户意图并经过
`_desiredNetworkDiscoveryState()` 门控，`reconcileNetworkDiscoveryState()` 只在目标变化时
下发 FFI（`embedded_torrent_host.dart:451-549`）；backend 在同步 native add 前后配对
`beginNetworkWake` / `endNetworkWake`，移除后重算
（`embedded_torrent_backend.dart:97-132,209-217`）；暂停、恢复及上传策略 sweep 也在真实
状态变化边界重算。AppModel 创建 host 时先传 `enableDht:false`
（`app_model.dart:3413-3434`），堵住恢复与门控接管之间的启动窗口。

### 验收

- 自动化：假 session 恢复一个已完成种子、默认 `uploadEnabled=false` 后，断言 DHT/LSD/
  UPnP/NAT-PMP 全关；重复 sweep 不重复下发。
- 自动化：存在未完成下载时按用户配置开启发现；下载转完成且不允许做种时关闭；新增下载
  或用户明确允许做种后可重新开启。
- 自动化：用户配置关闭某项发现协议时，即使有活跃任务也保持关闭；用户暂停、fastResume
  剪枝、resume 保存与外接 qBittorrent 既有行为不回归。
- 自动化：跨 fastResume 已达到做种时限的任务不得重新开启 discovery；add 成功后一次状态
  读取失败不得被当成空 session，也不得立即关闭 DHT；老 DLL fallback 重启与延迟 restore
  首次读取失败也须保持同一不变量。
- Windows 真机：只恢复已完成任务、没有活跃下载时，连续运行 `arp -a` +
  `ping -t <网关>`，并同步观察 Fushi PID UDP 端点/网络字节；不再出现由 Fushi DHT
  周期突发对应的 timeout/`95 ms` 峰，退出 Fushi 前后的延迟分布无显著阶跃。
- Windows 真机：新建一个确实需要 DHT 的磁力任务后仍能发现 peer 并下载；任务完成且默认
  不做种后，发现流量随生命周期收敛，不要求退出应用。
