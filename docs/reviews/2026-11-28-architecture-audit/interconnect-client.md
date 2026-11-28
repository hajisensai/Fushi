# 架构审计：interconnect-client

2026-11-28 只读审计 + 独立反驳核验的原始结论。总方案见 [../../specs/2026-11-28-architecture-redesign.md](../../specs/2026-11-28-architecture-redesign.md)。

## 现状

互联 client 侧同步目前以 SyncOrchestrator.run()（sync_orchestrator.dart:1125-1540，外加 17 个 part 共 3883 行）为唯一编排，里面用 `isInterconnect` 把云通道与互联通道两条流水线手工交织在一起；每个数据种类各写一个 `_syncXxxLive` 与（部分有的）`_syncXxxCloud`，各自手写拉取、合并、推送门槛和老 host 降级。InterconnectSyncBackend（5195 行）继承云盘的 SyncBackend 文件箱接口，又直接挂 70 来个按端点写的 get/put 方法，自带选路、退避和 WebDavOps 传输。新的共享传输 InterconnectHostChannel 和 InterconnectPostTransport 只覆盖了其余功能 client，同步后端没有迁过去。进度类数据有三套三方判定（书 live、播放位置 live、云 resolveProgressSync）和两个几乎逐行相同的 IO 类（InterconnectBookProgressSync / InterconnectPlaybackPositionSync）。BUG-3367/3528/3537/4431/4432/4434 每条都是在一份副本上修完、再移植到另一份。能力探测在后端里有 4 条各自缓存的 `GET /api/capabilities` 路径，再加一条响应头学习路径；能力键在 host 与 client 两侧各写一遍字符串字面量。host 身份在同一个会话里同时按两套口径计算：词典按 URL 伪 id，基线按凭据哈希。备份合并引擎用 SQL 把合集、作品图谱、标签、阅读位置的合并语义又写了一遍，和同步内核各自演进。聚合（统计 / 收藏）是唯一已经做成「通道无关内核 + 注入 IO」的种类，可以当成其余种类的模板。

## sync-kind-registry-missing

**没有同步种类登记表：编排器按 isInterconnect 手工交织两条通道，每个种类 live / cloud 各写一套**

- 类型：缺单一登记源；规模 XL；价值 high；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/sync/sync_orchestrator.dart:1149 `final bool isInterconnect = b is InterconnectSyncBackend;`，之后在 1162、1204、1244、1392、1462-1481、1485-1497 反复按它分叉，同一种类在两个分支里分别调 _syncXxxLive 和 syncXxx / _syncXxxCloud
- fushi/lib/src/sync/sync_orchestrator/media_links.part.dart:13-41（live）与 :50-107（cloud）：同一种类两套完整流程；online_library.part.dart:8-40 与 :46-109 同构
- fushi/lib/src/sync/sync_orchestrator/tags.part.dart:13-36 只有 live 版，云通道干脆不同步标签；video_metadata.part.dart:12-55 同样只有 live。种类覆盖靠人记，没有表能看出哪条通道漏了哪类
- fushi/lib/src/sync/interconnect_sync_backend.dart:257-276：InterconnectSyncBackend extends SyncBackend 并 with 文件箱 mixin；:1203-1246 实现了云盘式 updateProgressFile / updateStatsFile / updateAudioBookFile，而 host 从不读回这些文件
- fushi/lib/src/sync/sync_manager.dart:923-932 `_fileBoxIsClientOwned` 特例：为互联在云书阶段里产生的『永久幻象冲突』打的补丁
- grep `is InterconnectSyncBackend` 在 fushi/lib/src/sync 下共 25 处（sync_compare_dialog.dart 297/311/370/409/1074/1153/1186/1203/1207/1238/1493 等）：UI 和裁决层也按通道类型分叉

机制：互联是后来塞进云盘 SyncBackend 抽象的：通道差异没有被建模成两种 Channel 实现，而是用运行时类型判断分散在编排器、比较弹窗、裁决器和 SyncManager 里。数据种类没有一等公民的描述对象，『有哪些种类、各走哪条通道、依赖谁、开关是什么、老 host 怎么降级』全部隐含在 run() 的语句顺序和注释里。新增一个种类就得改 run()、轻量路径、比较弹窗、peer gap 枚举、后端 get/put，漏掉任何一处就是一个通道缺口，tags 没有云版就是现成的例子。

根本方案：在 packages/fushi_engine/lib/sync/kinds/ 新建纯 Dart 的 `SyncKind` 描述表（sealed：ManifestKind / RegisterKind / AggregateKind / BlobKind），每项声明 id、开关键、dependsOn、所需能力位，以及对 `SyncChannel` 的两种绑定。`SyncChannel` 是新的窄接口，取代 SyncBackend 在互联上的继承：LiveHostChannel（host 权威单份）和 FileStoreChannel（云盘按设备分文件）。app 侧的 SyncOrchestrator.run() 只按描述表拓扑序遍历 `kinds.where(enabledFor(channel))`，删掉全部 `isInterconnect` 分叉和 `is InterconnectSyncBackend` 判断。InterconnectSyncBackend 不再 extends SyncBackend、不再实现文件箱 mixin，SyncManager 书阶段只服务 FileStoreChannel，`_fileBoxIsClientOwned` 一并删除。以后新增一个种类，只在描述表里加一项，再写它的 Manifest / Register 适配。守卫：一个单测枚举描述表，断言每个 kind 对两种 channel 要么有绑定、要么在表里显式标注 `unsupportedOn(channel, reason)`，不允许默认缺失。

要动：fushi/lib/src/sync/sync_orchestrator.dart；fushi/lib/src/sync/sync_orchestrator/；fushi/lib/src/sync/interconnect_sync_backend.dart；fushi/lib/src/sync/sync_manager.dart；fushi/lib/src/sync/sync_compare_dialog.dart；fushi/lib/src/sync/sync_backend.dart；packages/fushi_engine/lib/sync/

核验说明：证据属实。sync_orchestrator.dart:1149 `final bool isInterconnect = b is InterconnectSyncBackend;`，1452-1468 同一阶段两个分支各调 _syncXxxLive 和 syncXxx/_syncXxxCloud；`is InterconnectSyncBackend` 在 sync/ 下按文件计：sync_compare_dialog 9、orchestrator 4、auto_trigger 3、book_change_gate / baseline_scope / sync_manager 各 1。interconnect_sync_backend.dart:257-276 extends SyncBackend 并 with SyncBackendFileTrioMixin 等，1203-1246 实现了 updateProgressFile/StatsFile/AudioBookFile。sync_manager.dart:923-932 的 `_fileBoxIsClientOwned` 注释自己写着「host 从不读回」「永久幻象」，确实是补丁。tags 只有 live 版（tags.part.dart:3「互联 live 通道」），云分支 1465-1467 没有 tags。需要补一句：云通道并不是完全没有标签，合集清单带 additive 的 tagNames（collection_manifest.dart:136/170/237，docs/specs/2026-07-14-collection-tags-plan.md Phase 4），缺的是书 / 视频 / 游戏等宿主的标签。

方案风险：① InterconnectSyncBackend 的 SyncBackend 身份不只服务文件箱，也是资产层：PendingMineRelay.run(b) 注释写「云与互联同走资产层（__pending_mines__ 命名空间）」（sync_orchestrator.dart:1484 附近），putJsonAsset / 资产命名空间、内容文件上传也挂在这层。直接删掉继承会漏掉这些调用点，SyncChannel 必须把资产层建模进去。② host 侧已有一张部分登记表 HostManifestKind（packages/fushi_engine/lib/sync/host_manifest_bodies.dart:35-44：collections/tags/mediaLinks），方案没提到。client 描述表另起一份就又成了两份单一源，应该和 host 共用。③ 守卫用「unsupportedOn(channel, reason)」显式标注，合理。

修正后的方案（以此为准）：SyncKind 描述表放在 fushi_engine，并让 host 的 HostManifestKind 与路由分派也从这张表派生，host 与 client 共用一份。SyncChannel 拆成两部分：同步语义（LiveHost / FileStore）和资产层（AssetStore，云与互联都实现，供 PendingMineRelay、内容文件、__collections__ 命名空间使用）。只把文件箱三件套从互联上拿掉，资产层保留。

## manifest-kind-kernel

**清单类种类（合集 / 标签 / 作品图谱 / 在线条目）的拉-合并-推流程被逐种逐通道复制，推送门槛口径各异**

- 类型：缺单一登记源；规模 L；价值 high；用户可见
- 核验：部分成立

证据：

- fushi/lib/src/sync/sync_orchestrator/tags.part.dart:18-33 与 media_links.part.dart:18-38：GET → null 记 peer gap → 锁内 apply + loadLocal → `!covers(remote, local)` 才 POST，逐行同构
- fushi/lib/src/sync/sync_orchestrator/collections.part.dart:20-77：推送门槛换成 `outcome.merged.canonicalJson() != remote.canonicalJson()`；online_library.part.dart:24-34 又换成 `local.canonicalJson() != ownCanonical`。三种『该不该推』的判据
- fushi/lib/src/sync/sync_orchestrator/media_links.part.dart:50-107、online_library.part.dart:46-109、sync_orchestrator.dart:1703-1797（合集云版）：『列命名空间 → 按前缀过滤 → _retainManifestMirror → 逐份读 → 记 ownCanonical → apply → 内容变了才 put』被抄了 3 遍（book_change.part.dart:36-67 是第 4 份）
- fushi/lib/src/sync/interconnect_sync_backend.dart:2536-2668：getRemoteCollection/Tag/MediaLinkManifest 与 putRemote*Manifest 每种各写一份 buildRequest + Content-Type + checkStatus + fromJson，只有路径和类型不同
- fushi/lib/src/sync/sync_orchestrator/collections.part.dart:33-39 合集直接调 `report.notePeerGap(...)`，其余种类走 `_notePeerGapLive`（peer_gaps.part.dart:34-61）：同一降级规则也已经分叉

机制：每个清单种类的『编解码 + 本地 apply + 覆盖判定』本来已经是纯函数（applyTagManifest、tagManifestCovers、CollectionSyncEngine.merge…），但没有统一接口把它们收成一个类型参数化的内核，编排逻辑和 IO 逻辑只能每种复制一份。每次修一个通用问题（镜像缓存 jHQpTfjrNB、取消检查点、坏清单跳过、空清单不建文件）都要逐份去补；online_library 有 `_checkpoint()` 和 SyncCancelledException 透传，media_links 云版没有，就是漂移的证据。

根本方案：在 fushi_engine/lib/sync/kinds/manifest_kind.dart 定义 `abstract interface class ManifestKind<M>`：id、endpointPath、fileStem、fromJson、canonicalJson、`Future<int> applyRemote(db, M)`、`Future<M> loadLocal(db)`、`bool needsPush({M? remote, M? ownPublished, M local})`、可选的 baseline 钩子（给合集用）。再写一个通用 `ManifestSyncRunner<M>`，分两种 channel 绑定：LiveHostChannel 走 GET（条件请求）→ 锁内 apply → needsPush → POST；FileStoreChannel 走按设备分文件的列举、镜像、折叠、回写。tags / media_links / online_library / collections 四个 part 文件和后端里 8 个 get/put 方法都被这个 runner 加上每种约 30 行的 descriptor 取代后删除。云通道自动获得标签同步。新增一个清单种类只写一个 ManifestKind 实现并登记进描述表。守卫：runner 的契约测试对表里每个 ManifestKind 跑同一组用例（坏清单、空清单、取消、老 host 404）。

要动：fushi/lib/src/sync/sync_orchestrator/tags.part.dart；fushi/lib/src/sync/sync_orchestrator/media_links.part.dart；fushi/lib/src/sync/sync_orchestrator/online_library.part.dart；fushi/lib/src/sync/sync_orchestrator/collections.part.dart；fushi/lib/src/sync/sync_orchestrator.dart；fushi/lib/src/sync/interconnect_sync_backend.dart；packages/fushi_engine/lib/sync/

核验说明：重复属实：tags.part.dart:18-33 与 media_links.part.dart:18-38 同构；三种推送判据（covers / merged≠remote / local≠ownCanonical）确实存在；collections.part.dart:35 直接调 report.notePeerGap，其余走 _notePeerGapLive（peer_gaps.part.dart:35），已分叉。漂移证据也成立，而且比审计说的更严重：online_library.part.dart:36/80/103 显式透传 SyncCancelledException，tags.part.dart:33-35 与 media_links.part.dart:37-39、104-106 却是裸 `catch (e)`，交给 _noteDimensionError，而后者只重抛 SyncPeerUnreachableError（sync_orchestrator.dart:869-872）。不成立的部分是方案标 changesPersistenceOrWire=false，同时又声称「云通道自动获得标签同步」：这要在云的 __collections__ 命名空间新增 tags-<deviceId>.json 一类文件，是新的云端持久化格式，也是用户可见行为。

方案风险：① 云通道加标签同步属于功能扩展，会改变用户可见行为并新增云端文件格式，按 CLAUDE.md「方案取最优」应先列取舍问用户，不能夹带在重构里。② 合集带基线（nextBaseline 预取、竞态修复，collections.part.dart:24-27）和 runExclusiveWithSyncStateApply 窄锁（BUG-2717），runner 必须把「锁内只包本地步骤、网络在锁外」做成内核不变量，不能留给 descriptor 自选。③ host 侧对 tags 也有三处 apply（host_manifest_bodies.dart:208、local_library_host_service/sync_state.part.dart:328、fushi_sync_server/sync_state.part.dart），方案只收 client 侧，host 侧的重复漏掉了。

修正后的方案（以此为准）：ManifestKind<M> 与 runner 照原方案做，但要满足：(a) runner 统一负责错误边界，SyncCancelledException / SyncAuthError 一律透传；(b) 锁边界由 runner 固定；(c) host 端的 GET/POST 处理（HostManifestBodyCache、后台 isolate 编解码）也用同一个 ManifestKind 描述。云端标签同步单列一条拍板项，未拍板前在描述表里标 unsupportedOn(fileStore)。

## register-three-way-kernel

**进度类三方同步（待确认行、前置条件、抬戳、比较后写入）有三份实现，修一个 bug 要移植到每份**

- 类型：补丁叠补丁；规模 L；价值 high；不改外部行为
- 核验：部分成立

证据：

- fushi/lib/src/sync/interconnect_book_progress_sync.dart:400-423 decide（基线 + pending 提升）与 interconnect_playback_position_sync.dart:377-395 decide：同一算法两份，后者注释原话是『与书籍版 InterconnectBookProgressSync.decide 同理（BUG-3528）』
- interconnect_book_progress_sync.dart:447-512 pushLocal 与 interconnect_playback_position_sync.dart:485-553 pushLocal：trustedStoredSyncStamp → +1 抬戳 → capFutureSyncStamp → 记 pending → 带 expected 的 PUT → 非 confirmed 删 pending → 比较后写入 → recordBaseline，逐步相同；后者注释『BUG-3367 的书籍版补上了同一套防护』
- fushi/lib/src/sync/sync_manager.dart:903-911 云通道用第三个判定 `resolveProgressSync(local, remote, base)`，基线是时间戳；live 书版基线是位置（resolveBookProgressThreeWay，fushi_library_host_service.dart:1771），播放位置又是一份 resolvePlaybackPositionThreeWay（:2720 附近）
- docs/bugs/BUG-3367-…md 写明『与 BUG-2506 同类、修书籍进度时没覆盖到播放位置』；BUG-3528 / 3537 / 4431 / 4432 / 4434 的修复描述都同时列出 book 与 playback 两份文件分别改
- 两个类的方法表几乎一一对应：bind / storageDimensionForTest / localX / remoteX / baseline / decide / syncOne / recordBaseline / pushLocal / _dropPending / applyRemote / alignSynced / _writeLocalIfUnchanged（interconnect_book_progress_sync.dart:87-637 对照 interconnect_playback_position_sync.dart:160-721）

机制：『单值寄存器的跨设备三方同步』这个协议从没被抽成一个类型参数化的内核，每种值（书位置三元组、播放毫秒、章级状态、云文件名时间戳）各自实现一遍 IO 和状态机。协议的每一次加固（丢失确认、盲写、换 host、毒戳、比较后写入）都只能逐份移植，漏移植就成了下一个 BUG。

根本方案：在 fushi_engine/lib/sync/register/ 建 `RegisterSyncKernel<V>`：纯状态机，输入 (local, remote, base, pending)，输出动作；IO 通过 `RegisterStore<V>`（本地读、比较后写、基线和 pending 读写、按 hostPin 作用域）与 `RegisterRemote<V>`（读、带 expected 前置条件的 PUT 回执）注入；`V` 实现 `RegisterValue`（stamp、sameValue、tieBreak）。InterconnectBookProgressSync、InterconnectPlaybackPositionSync、InterconnectMangaChapterSync 退化成各约 60 行的 Store / Remote 适配，三份 decide / pushLocal / alignSynced 删除。云通道的 `resolveProgressSync` 和文件箱也改成 FileStoreChannel 上的 RegisterRemote 实现，共用同一个内核，同一批防护自动覆盖云。以后新增一种可续读的数据（例如新媒体类型的位置），只写 V 和两个适配。守卫：内核对 BUG-3528/3537/4431/4432/4434 的场景各有一条表驱动测试，所有 RegisterKind 共用一套。

要动：fushi/lib/src/sync/interconnect_book_progress_sync.dart；fushi/lib/src/sync/interconnect_playback_position_sync.dart；fushi/lib/src/sync/interconnect_manga_chapter_sync.dart；fushi/lib/src/sync/sync_manager.dart；fushi/lib/src/sync/sync_orchestrator/books.part.dart；packages/fushi_engine/lib/sync/fushi_library_host_service.dart

核验说明：live 两份的重复属实：interconnect_book_progress_sync.dart（665 行）与 interconnect_playback_position_sync.dart（992 行）的 decide / pushLocal / 比较后写入逐步对应。resolveBookProgressThreeWay 在 fushi_library_host_service.dart:1771，播放位置版在 :2720 一带，注释写「同口径」。FushiDatabase 在 fushi_engine，内核放 engine 不违反分层。夸大的部分是「云通道也共用同一内核，同一批防护自动覆盖云」：云走文件名时间戳（sync_manager.dart:903-911 resolveProgressSync），WebDAV / 云盘文件箱没有带 expected 前置条件的 PUT 回执，BUG-4431 的 confirmed / superseded 状态机在云上没有对应的原语，不可能自动覆盖。

方案风险：① 云 RegisterRemote 只能实现「读 + 无条件写」，内核必须把前置条件写当成可选能力（与老 host 兼容层 _legacyLiveStamp 同属一类），不能假设所有 channel 都有。② 书位置是三元组、基线按位置比较，云版基线是时间戳，基线语义不同；统一后若改了云基线存法，就会触碰冻结的基线表维度（progressBaselineDimensionOf），要显式保持原维度键。③ 漫画章级同步（interconnect_manga_chapter_sync.dart）要逐项核对是否同构，审计没给证据。

修正后的方案（以此为准）：RegisterSyncKernel<V> 先只覆盖互联 live 的书 / 播放位置 / 章级三份，RegisterRemote 声明 supportsPreconditionedWrite。云通道作为不支持前置条件写的 RegisterRemote 接进来，只复用判定、毒戳与基线部分；基线维度键与存法保持原样不迁。

## capability-registry

**host 能力探测有 5 条路径、各自缓存，能力键在 host 与 client 两侧各写一遍字面量**

- 类型：缺单一登记源；规模 M；价值 high；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/sync/interconnect_sync_backend.dart:1180 _readHostCapabilities（按轮读）、:3427-3450 _liveLibraryCapabilities（缓存字段名叫 _subtitleDefaultCapabilityScope，挪作公用）、:4154-4176 hostSupportsVideoClipExport（自己再 GET 一次、自己缓存）、:4358-4380 hostSupportsDiscShare（同上）：四次独立的 GET /api/capabilities
- interconnect_sync_backend.dart:4743-4757 _putLive 还从响应头学一份『新式 PUT 契约』能力并单独缓存，是第五条
- fushi/lib/src/sync/interconnect_host_channel.dart:460-520 已有进程级、ETag 重验、在途合并的能力缓存（BUG-5603，注释说『所有能力探测都走这里』），同步后端却一条都没接
- packages/fushi_engine/lib/sync/disc_share_routes.dart:34 已定义 `kDiscShareCapability = 'discShareV1'`，client 在 interconnect_sync_backend.dart:4375 仍写字面量 'discShareV1'；fushi_sync_server/pairing.part.dart:670/683/708 host 写 'videoMetadata' / 'mediaLinks' / 'videoSubtitleDefault'，client 在 sync_peer_gap.dart:31/48 与 interconnect_sync_backend.dart:3354/3423 又写一遍
- 老 host 降级逐端点手写：interconnect_sync_backend.dart 里 `statusCode == 404` 出现 34 次

机制：能力位没有类型化的单一定义：host 端在 pairing.part.dart 里拼 Map 字面量，client 端每个功能按需写字符串去读，每加一个能力就多一个 hostSupportsX 方法和一份缓存。『老 host 降级』于是有两种判据，读能力位或撞 404，各端点自己选。

根本方案：在 fushi_engine/lib/sync/capabilities.dart 定义 `enum HostCapability { tags('tags', since: …), mediaLinks(...), discShare('discShareV1'), … }`：host 的 /api/capabilities 由这个枚举加上 `bool Function(LibraryService)` 生成，取代 pairing.part.dart 里的手写 Map；client 侧只有一个 `HostCapabilities` 值对象（由 InterconnectHostChannel.capabilities() 产出、按 host 缓存），`caps.has(HostCapability.x)` 返回 supported / declaredOff / undeclared 三态。删除后端里 4 个私有缓存、所有 hostSupportsX 方法和零散字面量。SyncKind 描述表声明 requiredCapability，peer gap 由编排器按三态统一记录，SyncPeerGapDimension 枚举并入描述表，collections 的直调分叉随之消失。新增能力只在枚举加一项。守卫：在 fushi_engine 加测试，断言 host 生成的 JSON 键集合等于枚举 wire 值集合；再加一条源码守卫，禁止 lib/ 下出现 'liveLibrary' 段的字面量读取。

要动：packages/fushi_engine/lib/sync/fushi_sync_server/pairing.part.dart；packages/fushi_engine/lib/sync/；fushi/lib/src/sync/interconnect_sync_backend.dart；fushi/lib/src/sync/sync_peer_gap.dart；fushi/lib/src/sync/sync_orchestrator/peer_gaps.part.dart；fushi/lib/src/sync/interconnect_host_channel.dart

核验说明：已验证：interconnect_sync_backend.dart:1180 _readHostCapabilities、:3427 _liveLibraryCapabilities（缓存字段名 _subtitleDefaultCapabilityScope，:3417）、:4154 hostSupportsVideoClipExport、:4358 hostSupportsDiscShare，各自发一次 GET /api/capabilities。:4743-4757 _putLive 从响应头学 kLiveWriteHeader。interconnect_host_channel.dart:460-520 已有带 ETag 和在途合并的能力缓存（BUG-5603），注释写「所有能力探测都走这里」，但后端里 InterconnectHostChannel 出现 0 次。:4375 写字面量 'discShareV1'，而 engine 的 disc_share_routes.dart:34 已有 kDiscShareCapability，host 也已在用（pairing.part.dart:729）。'statusCode == 404' 共 34 处。

方案风险：① 三态里的 undeclared 要覆盖「连 /api/capabilities 都没有的老 host」（_readHostCapabilities 对 404/405 返回 null），这类 host 只能靠端点 404 降级，Endpoint.on404 不能整体删。② 响应头学习（kLiveWriteHeader）是每次写入时的契约协商，带「200 空体 = host 降级，清缓存」这种逐响应语义，不宜并进能力表缓存，应作为 channel 的响应元数据单独保留。③ 能力表有 ETag 重验但不设有效期，后端若在一轮 sweep 内多次查询，要按轮做快照，免得同一轮里判据不一致。

修正后的方案（以此为准）：按原方案做，补两点：Endpoint 保留 on404 兜底，只用于 caps 为 undeclared 时；写入契约头作为 channel 的 per-response 协商，不进 HostCapability 枚举。

## interconnect-transport-triplicate

**互联 client 有三套传输 / 选路 / 超时实现，同步后端（最大的那个）没迁到共享通道**

- 类型：缺单一登记源；规模 XL；价值 high；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/sync/interconnect_host_channel.dart:1-20 文件头：『此前每个互联功能 client 各自复制一份传输层…这里把这些收成一份』；但 grep InterconnectHostChannel 在 interconnect_sync_backend.dart 中 0 次
- fushi/lib/src/sync/interconnect_sync_backend.dart:940-1000 _resolveSession：自己 rankInterconnectCandidates → resolveReachableFushiCandidate 串行探测 → 自建 WebDavOps；:434-437 自有退避常量；:340-383 自有 _sendBounded / _readBodyBounded
- fushi/lib/src/sync/interconnect_post_transport.dart:219 第三套：另调 interconnectRankedCandidates 逐台尝试（查词 / 制卡 / 词典目录 / 串流用）
- interconnect_sync_backend.dart 内 `_ops!.buildRequest(` 60 次、`await _ensureResolved();` 73 次：每个端点手写同一段样板

机制：共享通道是在已有大量功能 client 之后才引入的，按『新的接新的』推进，同步后端这个 5195 行的单例因为同时承担云 SyncBackend 接口而迁不动，只好保留自己的会话解析和传输。结果钉扎、超时、错误分型、选路缓存作废规则有三份，修 BUG-4278 这类问题要逐份补。

根本方案：以 InterconnectHostChannel 作为互联唯一的传输层，把 InterconnectPostTransport 的语义（查词短超时、资产独立预算）收成 channel.send 的 `RequestBudget` 参数后删掉这个类。InterconnectSyncBackend 拆成按域的薄 endpoint 客户端（LibraryEndpoints、VideoEndpoints、ProgressEndpoints…），统一以 `channel.json<T>(Endpoint<T>)` 发请求；`Endpoint<T>` 声明 method、path、decode、`on404: missingAs<T>(capability)`，取代 34 处手写 404 分支和 60 处 buildRequest 样板。会话解析、退避、钉扎只在 channel 里有一份。守卫：源码守卫禁止 fushi/lib/src/sync 下除 interconnect_host_channel.dart 外的文件 new HttpClient / http.Client，或调 rankInterconnectCandidates。

要动：fushi/lib/src/sync/interconnect_sync_backend.dart；fushi/lib/src/sync/interconnect_post_transport.dart；fushi/lib/src/sync/interconnect_host_channel.dart；fushi/lib/src/sync/fushi_remote_lookup_client.dart；fushi/lib/src/sync/fushi_remote_mining_client.dart；fushi/lib/src/sync/remote_dictionary_catalog_service.dart

核验说明：已验证：interconnect_sync_backend.dart 里 InterconnectHostChannel 出现 0 次；`_ops!.buildRequest(` 60 处，`await _ensureResolved();` 73 处；:975-990 自建 _sessionOps(WebDavOps)。interconnect_host_channel.dart:321 interconnectRankedCandidates 与 :620 是共享选路；interconnect_peer_addresses.dart:412 rankInterconnectCandidates 另有入口（:141）。

方案风险：① 后端还承担 WebDAV 式内容 / 资产上传（uploadContentFile、uploadJson、deleteFile），channel 要提供流式上传和大体积预算，不能只有 json<T>。② 后端是进程级单例，又实现 RemoteBookClient、RemoteVideoClient 等约 15 个接口，被播放、封面、碟片分享等大量非同步调用点注入使用。拆成按域 endpoint 客户端时，这些接口的实现方和注入点都要迁，审计 touches 没列（视频 / 封面 / 书源消费端）。③ 依赖 host-identity 一条先定下「channel 绑定一台 host」的模型，两条需要排序。

修正后的方案（以此为准）：先让后端内部改走 InterconnectHostChannel 发请求（保留对外接口不变），再按域拆分并迁移 Remote* 接口的实现方；传输层的源码守卫等迁完再启用。

## host-identity-recipes

**无 hostId 的老条目有 5 种身份口径，同一会话里同时算两种；单例会话按『谁先答』可能中途换 host，靠 pin / serial / 异常层层补**

- 类型：成类 bug；规模 L；价值 high；改持久化 / wire
- 核验：部分成立

证据：

- fushi/lib/src/sync/interconnect_sync_backend.dart:984 `_activeHostIdentity = remoteDictionaryHostIdOf(chosen)`（老条目 = URL 伪 id，见 sync_repository.dart:189-194），紧接着 :988 `_scopeIdentityOf(chosen)`（老条目 = 凭据哈希，见 :5011-5023 interconnectScopeIdentityOf）：同一台 host、同一次解析，词典和基线认的身份不同
- fushi/lib/src/sync/interconnect_host_channel.dart:42-66 InterconnectHostRef.legacyUrl：第三种（持久 URL 锚点）
- fushi/lib/src/sync/video_remote_client.dart:73 `peer.hostId ?? '${peer.url}|${peer.fingerprintSha256}'`（再拼 token 哈希）：第四种；fushi/lib/src/sync/remote_book_source_host.dart:37 `identity: hostId ?? baseUrl`：第五种
- 会话换 host 的补丁链：interconnect_sync_backend.dart:660 checkHostPin、:693-704 _pinned zone、:5066 InterconnectHostPin（带 serial）、:5122 InterconnectHostChangedException；sync_orchestrator/books.part.dart:604 在逐条循环里接这个异常收尾（BUG-4434）
- docs/bugs 中 hostId 相关 17 份、『按 URL』9 份

机制：hostId 是后加的，老配对行没有，系统从没对存量行做一次性的身份补全，于是每个需要『这是哪台 host』的消费者各自发明降级口径。另一方面，进程级单例 InterconnectSyncBackend 的会话按候选竞速选路，可能落到另一台 host；基线作用域问题只能事后用 pin、serial、异常检测，而不是让一轮同步从结构上就绑定一台 host。

根本方案：引入唯一的 `HostIdentity` 值类型（fushi_engine 纯 Dart），一次性迁移：没有 hostId 的 FushiClientUrl 行按『同一配对凭据归一台』合成一个稳定的本地 hostId 写回行里，持久化名不变，只是补值。之后所有消费者只用 `HostIdentity.of(row)`，删除 remoteDictionaryHostIdOf 的 URL 分支、InterconnectScopeIdentity.credential、InterconnectHostRef.legacyUrl、coverCacheNamespace 与 remote_book_source_host 的自造口径。会话模型改成显式绑定：同步一轮 = `for (HostIdentity h in pairedHosts) runSweep(channelFor(h))`，channel 只在 h 的地址组内选路、永远不跨 host。InterconnectHostPin、serial、InterconnectHostChangedException、_pinned zone 随之删除。守卫：源码守卫禁止 `hostId ??` 与 `.hostId == null` 出现在 HostIdentity 之外。

要动：fushi/lib/src/sync/interconnect_sync_backend.dart；fushi/lib/src/sync/sync_repository.dart；fushi/lib/src/sync/interconnect_host_channel.dart；fushi/lib/src/sync/sync_baseline_scope.dart；fushi/lib/src/sync/video_remote_client.dart；fushi/lib/src/sync/remote_book_source_host.dart；fushi/lib/src/models/app_model.dart

核验说明：口径分裂属实：interconnect_sync_backend.dart:984 用 remoteDictionaryHostIdOf（老条目取 URL 伪 id，sync_repository.dart:189-194），:988 用 _scopeIdentityOf（老条目取凭据哈希，:5011-5023）；video_remote_client.dart:73 与 remote_book_source_host.dart:37 又各有一套。不成立的部分是根本方案「合成本地 hostId 写回行里、持久化名不变只补值」：这不是无害补值，会破坏已经持久化的、按旧口径作键的数据。

方案风险：① remote_dictionary_metadata 与 profile 键按 URL 伪 id 归档（sync_repository.dart:189 注释；profile_repository.dart:690 remoteDictionaryHostIdOfProfileKey；配置导出靠 isRemoteDictionaryPseudoHostId 剔地址），换成合成 id 后这些行全部成孤儿。② 基线表按凭据哈希分槽（BUG-4434），换口径会让全部条目首轮判冲突。③ 合成 id 不等于 host 真实的 hostId：之后这条地址一旦学到真实 hostId（升级 host、改走 https），同一台 host 又分成两个身份。注释写明明文 http 地址从不学习 hostId。④「for h in pairedHosts runSweep」把现有的单 host 会话改成对所有配对 host 逐台同步，属于用户可见的行为与范围扩大，必须上拍板台。⑤ coverCacheNamespace 换口径会让磁盘封面缓存整体失效（可接受，但要写明）。

修正后的方案（以此为准）：身份统一成 HostIdentity 值类型，内部仍分两种来源：hostId，或凭据作用域（仅限确实学不到 hostId 的老条目）。已有的 URL 伪 id 键、凭据哈希基线键不做重写，只做读时归一。连上 host 时若能拿到真实 hostId（pairing / capabilities 公布），在一个事务里把行补上真实 hostId，并迁移词典元数据、profile 键与基线槽；不自造 id。显式按 host 绑定会话可以做，但「多 host 逐台同步」单列为拍板项。

## sweep-plan-as-code

**sweep 阶段顺序、依赖和轻量路径写死在语句顺序与注释里；编排器靠一串布尔形参和占位目录表达『只跑某几类』**

- 类型：守卫代替结构；规模 L；价值 medium；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/sync/sync_orchestrator.dart:1449-1468 用注释维护顺序依赖：『在线源条目放在合集之前』『标签紧跟合集之后』『作品图谱…同样要在合集落地之后』『刮削元数据紧跟合集之后』；:1188-1193『书进度 live 紧跟书内容之后（反馈 kM-Gb_Xnu-）』是事后调过的顺序
- sync_orchestrator.dart:1586-1603 runCollectionsOnly 把合集 / 标签 / 作品图谱的顺序与通道分叉再抄一遍（云分支不含标签）
- sync_orchestrator.dart:875-900 构造器有 11 个 syncXxx 布尔形参；sync_auto_trigger.dart:1427-1445 与 :1709-1730 逐个传 false，并以 `Directory.systemTemp` 占位满足必填参数（注释写『仅为满足构造器形参』）
- sync_orchestrator.dart:1239-1243 注释：书阶段曾是唯一没有 try/catch 的阶段，一抛后续全断；每个阶段各自包 try/catch 与 SyncAuthError / SyncCancelledException 透传（online_library.part.dart:35-38 有，tags.part.dart:34 没有）

机制：编排是命令式脚本，阶段的错误边界、取消检查点、进度上报、开关判断、依赖顺序都由每个阶段自己写，或靠人在 run() 里排对位置。轻量路径和显式传输只能另写入口、复制一段顺序，再用『其余全传 false』的构造技巧伪装成 sweep 的子集。

根本方案：在 SyncKind 描述表（见 sync-kind-registry-missing）里声明 `dependsOn` 与 `phase`，由 `SyncPlan.build(kinds: selection, channel)` 拓扑排序出阶段列表。`SyncStageRunner` 统一负责错误边界（SyncAuthError / SyncCancelledException 透传，其余记进 report）、`_checkpoint`、阶段计时 mark 和进度事件。run()、runCollectionsOnly、runAssetTransferOnly 都退化为 `execute(SyncPlan.of(...))`，构造器的 11 个布尔开关换成一个 `Set<SyncKindId> enabled`（由 ChannelSyncFlags 产出），各个 *LiveForTest 入口和占位目录参数删除。新增一个阶段只在描述表里写 dependsOn。守卫：计划构建时检测依赖环，缺失依赖直接抛错；单测断言每条轻量计划都是完整计划的拓扑子序列。

要动：fushi/lib/src/sync/sync_orchestrator.dart；fushi/lib/src/sync/sync_orchestrator/；fushi/lib/src/sync/sync_auto_trigger.dart；packages/fushi_engine/lib/sync/

核验说明：已验证：sync_orchestrator.dart:1452-1468 的顺序依赖全靠注释维护（「在线源条目放在合集之前」「标签紧跟合集之后」）。sync_auto_trigger.dart:1713-1717 用 Directory.systemTemp 占位，注释写「仅为满足构造器形参」。各阶段错误边界不一致：online_library 透传 SyncCancelledException，tags / media_links 没有（见 manifest-kind-kernel）。

方案风险：①「每条轻量计划都是完整计划的拓扑子序列」这个断言成立的前提是，云删除墓碑扫描结果 cloudTombstoneScan 这类跨阶段数据流（书阶段前读、删除阶段消费，sync_orchestrator.dart:1475-1477）也建模成阶段产物，否则 dependsOn 表达不了。② PendingMineRelay 阶段「真要碰远端时才公布阶段名」（onRemoteWork），进度事件不能由 StageRunner 一律在开始时发，要允许延迟公布。

修正后的方案（以此为准）：SyncPlan 的阶段声明除 dependsOn 外，再声明类型化的阶段产物（如 CloudTombstoneScan），StageRunner 负责传递；进度事件支持「延迟公布」。

## backup-merge-reimplements-sync

**备份合并引擎用 SQL 把合集 / 作品图谱 / 标签 / 阅读位置的合并语义重写一遍，与同步内核各自演进**

- 类型：缺单一登记源；规模 L；价值 medium；不改外部行为
- 核验：部分成立

证据：

- fushi/lib/src/sync/backup_merge_engine.dart:41-63 类头：『Conflict resolution mirrors the existing sync semantics』，只有收藏句子『delegated to AggregateMergeService』，其余是手写 SQL 镜像
- backup_merge_engine.dart:985-1219 _mergeMediaCollections（约 235 行 SQL），而同步走 CollectionSyncEngine.merge + applyCollectionLocalChanges（sync_orchestrator/collections.part.dart:52-64）
- backup_merge_engine.dart:1945-2035 _mergeMediaLinks 自建 collectionIdMap / gameIdMap 并处理 v159 confirmed_by；同步走 applyMediaLinkManifest（media_links.part.dart:31）
- backup_merge_engine.dart:1330-1362 _mergeReaderPositions 用裸 `s.updated_at > reader_positions.updated_at` 比较，没有同步侧 trustedStoredSyncStamp / capFutureSyncStamp 的毒戳防护（interconnect_book_progress_sync.dart:458-466）。推测（未复现）：带未来戳的备份合并后会永久压住真实进度，再经同步扩散

机制：同步侧的合并内核以『清单对象』为输入，备份侧以『ATTACH 的另一份 DB』为输入，两者之间没有『从 DB 物化成清单』的适配层，备份只能把每条合并规则用 SQL 再写一遍。此后同步内核每次修语义（墓碑、整理器合集、AI 确认、毒戳），备份都要单独追，没追上的就是静默分歧。

根本方案：给每个 ManifestKind / RegisterKind 增加 `loadFrom(DbView)`，DbView 可以是主库，也可以是 ATTACH 的备份 schema。备份的 merge 模式改成：对描述表里每个可合并的 kind 执行 `kind.applyRemote(db, kind.loadFrom(backupView))`，用与互联、云完全相同的内核落地。BackupMergeEngine 只保留真正属于备份的部分：内容行 push-only 并集、ID 重映射、设备本地表排除。_mergeMediaCollections / _mergeMediaLinks / _mergeTagsAndMappings / _mergeReaderPositions 删除。新增一个可同步种类就自动参与备份合并。守卫：一条测试枚举描述表，断言每个 kind 都被备份合并覆盖，或在表里显式标注 `notInBackup`。

要动：fushi/lib/src/sync/backup_merge_engine.dart；fushi/lib/src/sync/backup_service.dart；packages/fushi_engine/lib/sync/

核验说明：重复属实：backup_merge_engine.dart:1330-1362 的 _mergeReaderPositions 用裸 `s.updated_at > reader_positions.updated_at` 比较，没有毒戳防护（未来戳可能压住真实进度，推测，未复现）。但审计说「除收藏外都是手写 SQL」不准确：study segments 在 :1706 注释里写明与 AggregateMergeService 语义一致、只是写成 SQL；收藏句在 :1857 直接调纯函数。审计说聚合是模板，这一点成立。

方案风险：① 备份合并有 _fillMissingOnly 模式（:1349）和墓碑屏蔽（TODO-1195，`_blockedBookKeysSubquery`），以及双侧 book_uid 换键（_srcBookUidRekey，v82），同步内核的 applyRemote 都没有这些语义，kind.applyRemote 要扩出 fillMissingOnly / 墓碑屏蔽参数。② CollectionSyncEngine.merge 依赖本机基线，备份没有共同祖先，套用同步语义会把备份里缺失的成员当成删除。必须用「无基线 = 只并集」模式，这本身就是一处新语义，要单测。③ 在 ATTACH 的库上物化清单（3k 合集 / 85k 成员）再走 Dart 合并，比 SQL 慢，备份合并要放在后台 isolate。

修正后的方案（以此为准）：先做最小的根因修复：reader_positions 合并改用同步侧的 trustedStoredSyncStamp / capFutureSyncStamp 口径。kind.loadFrom(DbView) 的统一化作为第二步，内核显式支持 baseline=none（只并集）、fillMissingOnly、墓碑屏蔽三种参数；每种 kind 迁过去时都和现有 SQL 结果做对照测试，再删 SQL。

## 核验补充（审计漏掉的）

- 错误边界已经出现真实漂移：fushi/lib/src/sync/sync_orchestrator/tags.part.dart:33-35、media_links.part.dart:37-39 与 :104-106 是裸 `catch (e)` 交给 _noteDimensionError，而 sync_orchestrator.dart:869-872 的 _noteDimensionError 只重抛 SyncPeerUnreachableError。这几个阶段里的 SyncCancelledException / SyncAuthError 会被记成维度错误、吞掉，online_library.part.dart:36/80/103 则会透传。取消要拖到下一个 _checkpoint 才生效，凭据失效被记成普通错误（影响程度是推测，未复现）。
- host 侧同样有登记表与合并的重复，审计只看了 client：packages/fushi_engine/lib/sync/host_manifest_bodies.dart:35-44 自有 HostManifestKind 枚举；tags 的 host 侧 apply 有 3 处（host_manifest_bodies.dart:208、packages/fushi_engine/lib/sync/local_library_host_service/sync_state.part.dart:328、fushi_sync_server/sync_state.part.dart:84 一带的合集合并）。app 当 host 和独立 server 当 host 各一套。SyncKind 描述表应同时驱动 host 路由与后台 isolate 编解码，否则只是把重复从 client 挪到两端之间。
- InterconnectSyncBackend 同时实现约 15 个 Remote* 接口（interconnect_sync_backend.dart:262-276：RemoteBookClient、RemoteVideoClient、RemoteDiscShareSource、RemoteCoverFetcher、SourceShareRemote…），是播放、封面、碟片分享、来源共享的共用注入对象。同步重构与这些功能 client 的生命周期绑在同一个进程级单例上，单例换 host（BUG-4434 的 pin / serial）同时影响正在播放的远端视频。审计把它只当成同步问题来看。
