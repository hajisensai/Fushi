# 「手机让电脑下」：下载执行设备（2026-09-21）

## 问题

用户问「现在能不能手机上让电脑下」，并对「在下载后端里加一个 Fushi 互联后端（类似
外接 qB）」的做法存疑：太底层，想再全局一点。

## 决策：不加「互联后端」，加「执行设备」这一层

下载**后端**回答的是「用什么引擎下」（内置 libtorrent / 外接 qBittorrent）。「让电脑
下」回答的是「在哪台设备上下」。后者在前者之上：手机只说「让 X 下这个」，X 自己决
定用什么引擎。把它塞成一个后端会让手机去关心电脑的引擎配置，正是要避免的。

这一层在 2026-09-08 无头服务端设计（`2026-09-08-fushi-server-headless-design.md`
§3.3「下载 = 改变 host 的库」）里已经定了并落地了一半：

- 协议：引擎 `/api/downloads`（list / add / cancel / retry / delete），能力位
  `/api/capabilities.downloads = {supported, backend, kinds}`，接口 `HostDownloadHost`。
- 手机端：手动添加任务弹窗的「下载到：本机 / <设备>」下拉、下载中心任务 tab 混排
  host 任务、订阅的「运行位置」。
- 缺口：**只有无头 `fushi_server` 实现了 host 侧**（`ServerDownloadHost`）。app 当
  host 时 `FushiSyncServerController` 构造 server 没传 `downloads` / `subscriptions`
  / `hostJobs`，对端探到的能力位里没有它们，「下载到 电脑」根本不出现。

不再往上抽一层「通用远程任务」：`/api/jobs` 已经是那一层（ASR 走它），而下载刻意
没并进去——任务是「算完拿回产物」，下载是「改变 host 的库」，生命周期与消费方式不
同。「全局」体现在 UI 词汇统一为「在哪台设备上跑」，不是再抽象。

## 本次改动

### host 侧（app 当 host）

- `fushi/lib/src/sync/app_download_host.dart`：`AppDownloadHost implements
  HostDownloadHost`，把对端交来的磁链投进本机已在跑的 `VideoDownloadPipelineService`
  （同一条管线、同一张 `video_download_jobs`，对端的任务出现在本机下载中心）。全部
  按闭包现取：管线是 fire-and-forget 起的，host 可能先绑上端口。`subscriptions` 面
  同一组闭包，每次调用重建一份无状态的 `PipelineSubscriptionHost`。
- `PipelineSubscriptionHost`（原 `fushi_server` 的 `ServerSubscriptionHost`）下沉到
  `packages/fushi_engine/lib/sync/subscriptions/`，app 与无头端共用；落点 / 落地源
  闭包改为 `FutureOr`（app 解析落点要先落安装 id）。
- `FushiSyncServerController` 新增 `hostJobsFactory` / `downloadsFactory` /
  `subscriptionsFactory`；`AppModel` 一并挂上 ASR 通用任务（`AsrHostJobRunner`，
  服务工厂与转录弹层同一份）。守卫 `test/sync/app_host_downloads_wiring_guard_test.dart`
  钉住这三处接线。
- `AppModel.readyVideoDownloadBackend`：下载页「添加任务」、发现页推送与 host 能力
  位共用的唯一就绪判据（`torrentBackendReady` 只是它的 bool 视图）。

### 协议

- `/api/downloads` POST 新增可选 `discoveryKind`（`novel` / `manga` / `audiobook` /
  `game`）：非视频域交给 host 按域入库；能力位 `kinds` 宣告 host 收哪些。app 当 host
  报全部五个域（有发现导入执行器）；无头 `fushi_server` 只报 `video`，收到非视频域
  按 400 拒。字段存在即支持，老客户端 / 老 host 互不影响。

### 客户端（手机端）

- 偏好 `download_execution_host`（`PreferencesRepository.downloadExecutionHostUrl`，
  设备本地键）：空 = 本机，否则是已配对 host 的地址。设置位置：**下载中心 › 设置 ›
  「下载执行设备」**下拉（本机 / 每台已配对 host），只在配对过 host 时渲染。
- `resolveDownloadExecution(appModel)`（`media/downloads/download_execution_target.dart`）：
  偏好为 host 且探得到 → `Remote`；探不到 → `Unreachable`（**不**退回本机，用户点名
  的设备连不上要如实报）；未设 → `Local`。
- 四个入口都问它：
  - 手动添加任务弹窗：偏好命中的 host 作为「下载到」默认值；非视频域按 host 的
    `kinds` 放行。
  - 发现页种子 / 番剧对话框通用磁链（`pushGenericMagnet`）：远端时整条磁链交 host，
    带 `discoveryKind`；新增 `remoteQueued` / `remoteUnreachable` /
    `remoteKindUnsupported` / `remoteMagnetOnly` 四个结果。
  - 资源搜索页（`VideoDiscoveryResourceSearchPage` / `VideoResourceSearchSurface`）：
    与订阅页「运行位置」同一范式的「下载到」下拉；没有本地管线时不列本地落地源，
    下拉只剩 host。索引器没给磁链时用 infoHash 造一条（`magnetUriFromInfoHash`），
    两者都没有的候选如实报「只接受磁力链接」。
  - 下载中心远端任务段：优先展示偏好指定 host 的任务。
- `InterconnectDownloadClient`：`probeUrl(url)`（点名探测，不退而求其次）、
  `probeAll()`、`HostDownloadTarget.kinds` / `supportsKind`。

## 边界（有意不做）

- **`.torrent` 文件与单文件选择不走远端**：host 只收磁链（既有约束）。
- **番剧对话框的计划推送仍只走本机**：它的 Jimaku 字幕意图 / 暂停 / 计划追踪都绑在
  本机后端上，只有通用磁链一栏走远端。
- **iOS 手机**：`StoreRestrictedCapability.downloads` 把整个下载中心连入口一起藏
  了，「让电脑下」严格说手机自己不下载，但入口共用；是否单独放开是合规判断，
  留给仓库所有者。Android 手机不受影响。
- **手机端浏览 / 播放电脑下完的内容**走既有远程库路径（`/api/library/videos` +
  `/stream`），不新加协议。

## 验证

- `test/sync/app_download_host_test.dart`：对真实 `FushiSyncServer` 挂
  `AppDownloadHost`，用真实 `InterconnectDownloadClient` 走能力位 → 点名探测 → 投
  磁链 → 本机 `video_download_jobs` 出现按域入库 / 视频两种行；未就绪 / 管线没起
  时 supported=false、投递 409。
- `test/sync/host_download_routes_test.dart`：`discoveryKind` 校验。
- `test/pages/video_resource_search_remote_download_test.dart`：资源搜索页「下载到」
  下拉的三种默认态 + 提交走远端回调。
- `test/media/torrent/magnet_utils_test.dart`：`magnetUriFromInfoHash` 往返。
- 未真机验证：手机 ↔ Windows app 真实配对后的端到端（本机只有一台设备）。
