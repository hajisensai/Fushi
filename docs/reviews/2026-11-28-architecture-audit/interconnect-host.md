# 架构审计：interconnect-host

2026-11-28 只读审计 + 独立反驳核验的原始结论。总方案见 [../../specs/2026-11-28-architecture-redesign.md](../../specs/2026-11-28-architecture-redesign.md)。

## 现状

互联 host 侧的唯一引擎宿主是 FushiSyncServer（packages/fushi_engine/lib/sync/fushi_sync_server.dart 有 2304 行，另有 14 个 part 共 6283 行）。它现在同时跑着两套路由机制。一套是 2026-11-23 新立的 InterconnectModuleTable（interconnect_module.dart），只迁进了 7 个模块，外加服务端的音乐模块。另一套是 _handleRequest 里约 45 条手写 if 分支（fushi_sync_server.dart:1345-1585），书、视频、漫画、有声书、词典、SRS、配对、查词、串流、来源共享等都还在这里。鉴权豁免另有一张 _kPublicRoutes 表（auth.part.dart:194），能力位在 _capabilitiesBase / _capabilitiesDocument 里手拼（pairing.part.dart:610-762），这三处之间没有共享的登记源。可选能力的接法有三种并存：构造参数、约 25 个可变 setter 字段、FushiLibraryHostService 上约 30 个 marker interface（is 类型测试）。真正是否可用又取决于 LocalLibraryHostService 的 21 个可空闭包。app 装配要过三跳：app_model.dart 传约 43 个 factory 给 FushiSyncServerController（fushi_server_controller.dart:101-133），controller 再逐个转进 FushiSyncServer（:851-929）。服务端在 headless_host.dart:543-669 独立再写一遍。两边各自实现了 P2P 挂接、配对落库、凭据加载、onClientUpload 里 token→设备名的反查。引擎的全局宿主钩子也是两份手写的顶层赋值：engine_bindings.dart:118 与 host_bindings.dart:30。信任判据（HTTPS 必需、已配对 peer、「我的设备」、开关）由 6 个以上 handler 各自内联，顺序和错误形态各不相同。中间件算出调用者身份后把结果丢掉，handler 再各自重算，身份编码就有 raw token、sha256 和 HMAC 三种。客户端对 /api/capabilities 有 6 处以上各自取、各自缓存，键名有的走常量、有的写裸字符串。BUG-5101 后来又在 peer_gaps 里叠了一层「每轮缓存」。docs/agent/server-parity-gaps.md 是手工维护的清单，已经与代码漂移：服务端没接 srsSync2Joined，但该文档写的是「其余钩子两边都已接」。

## host-route-registry-split

**路由、鉴权豁免、能力位三份手写清单，模块层只迁了一半，BUG-5298 声称的收紧守卫并不存在**

- 类型：补丁叠补丁；规模 XL；价值 high；不改外部行为
- 核验：部分成立

证据：

- packages/fushi_engine/lib/sync/fushi_sync_server.dart:1345-1585：_handleRequest 里约 45 条 if (reqPath == / startsWith) 手写分支；游戏串流在 :1354-1364 逐条列出 10 个路径，与 game_stream.part.dart 内部的分发重复
- packages/fushi_engine/lib/sync/fushi_sync_server.dart:602-621 与 :1491-1494：InterconnectModuleTable 只装了 7 个模块（漫画 OCR、任务、下载、BT、订阅、助手、章级进度），其余功能仍走上面的 if 链
- packages/fushi_engine/lib/sync/fushi_sync_server/auth.part.dart:194-224 与 :230-266：_kPublicRoutes 用另一套路径谓词（_isPairPath、_isVideoStreamPath + _kVideoStreamSuffixes）重述路由表里已有的路径，新增免 Basic 的流端点要两处同改
- packages/fushi_engine/lib/sync/fushi_sync_server/pairing.part.dart:610-762：能力文档手拼约 40 个键，其中 _videoRemoteService、srsRemoteStoreProvider、_screenOcr、_aiRelayAdvertised 在 _capabilitiesDocument 里另做追加，与路由处的 null 判断各写一遍
- packages/fushi_engine/lib/sync/interconnect_module.dart:9-21：InterconnectHostModule 只有 capabilityKey、routePrefixes 和 handle，没有方法、信任级、TLS 要求、公开流路径的声明，所以迁进来的模块仍要在 _kPublicRoutes（auth.part.dart:204 统一流票）和 handler 里自己补
- docs/bugs/BUG-5298-imusic-legacy-library-modules.md：写着守卫 interconnect_module_layer_test.dart 有「服务器本体无手写前缀分支」的放宽名单；grep 该测试找不到任何放宽名单（packages/fushi_engine/test/sync/interconnect_module_layer_test.dart 只有能力 JSON 快照），这份守卫实际上不存在

机制：新功能有两条接入路：注册模块，或在 _handleRequest 里加 if 并在 _capabilitiesBase 加键。后一条更顺手，没有任何结构挡住。模块接口又缺鉴权和公开路由的声明，模块化以后仍要回去改 auth.part.dart。三张表（分发、豁免、能力位）只靠人工保持一致。

根本方案：把 InterconnectHostModule 扩成声明式端点表：每个模块给出 List<InterconnectRoute>，每条 route 写明 {method 集合, 路径模式, trust: public(ticket 校验器)|anyCredential|pairedPeer|ownerDevice, transport: any|tlsRequired, handler}；能力位由 capability() 给出。FushiSyncServer 只保留三个循环：中间件按 route.trust 判豁免，路由按表分发，能力文档按表拼装。按 BUG-5298 的分期把书、视频、漫画、有声书、词典、聚合、墓碑、标签、作品图谱、在线条目、service-config、profile、source-share、plugin-relay、leaderboard、host-update、screen-ocr、查词/制卡、SRS、AI relay、配对、游戏串流、视频遥控逐个迁成模块，最后删掉 _handleRequest 的 if 链（WebDAV 文件树作为最后的兜底模块）、_kPublicRoutes、_PublicGate、_capabilitiesBase 的手拼段。用两道守卫防止回退：一是源码守卫，禁止 fushi_sync_server.dart 出现 reqPath == / reqPath.startsWith('/api/，迁移期的放宽名单逐类收紧到空（把 BUG-5298 里写的守卫真正落地）；二是 InterconnectModuleTable 构造时校验每条 public route 都带票据校验器。能力 JSON 沿用 _kLegacyCapabilitiesJson 的逐字节快照，保证键序不变。以后新增功能只写一个模块文件，加一行注册。

要动：packages/fushi_engine/lib/sync/interconnect_module.dart；packages/fushi_engine/lib/sync/fushi_sync_server.dart；packages/fushi_engine/lib/sync/fushi_sync_server/*.part.dart；packages/fushi_engine/test/sync/interconnect_module_layer_test.dart

核验说明：已验证：fushi_sync_server.dart 共 2304 行，含 14 个 part；该文件里 `reqPath ==` 和 `reqPath.startsWith` 共出现 65 次。interconnect_module.dart:9-40 的模块接口确实只有 capabilityKey、capability、routePrefixes、handle、streamResolvers 五项，没有方法、信任级、TLS 的声明。auth.part.dart:203-266 的 _kPublicRoutes、_isPairPath、_kVideoStreamSuffixes 是另一套路径谓词。pairing.part.dart 里有 22 处 `_libraryService is`。不成立的部分：审计说「BUG-5298 声称的收紧守卫不存在」。BUG-5298 第 4 行标的是「[ ] ① 未修复」，那句话写的是待做的计划，不是声称已经做完。interconnect_module_layer_test.dart:587-614 也确实有一道守卫「服务器本体不再为已迁进模块层的功能手写分支 / 字段」，它是禁用名单（只覆盖已迁移的 7 类），不是放宽名单。所以真实情况是：守卫只防已迁移的功能回退，不防新增 if 分支。审计的结论方向对，证据表述错了。

方案风险：1）迁移时，同一路径前缀下「功能关着回 404、不掉进 WebDAV 树」的语义要逐条保留（interconnect_module.dart:18-20 写明了这条有意设计）。WebDAV 做兜底模块时，前缀冲突检测必须把它排除在外。2）方案说要沿用能力 JSON 的逐字节快照，但这份快照目前只覆盖已迁移的部分，迁移前要先扩成整张能力表的快照。3）若把 public route 统一为「必须带票据校验器」：配对 POST（_isPairPath）本身就是免凭据的引导入口，没有票据，需要单独留一个 bootstrap 信任级，否则这条约束会把配对挡掉。

修正后的方案（以此为准）：按原方案做，补三条：一，证据改为「现有守卫只是已迁移功能的禁用名单，缺一条禁止出现任何 `reqPath ==` 或 `reqPath.startsWith('/api/` 的通用守卫」；二，trust 枚举增加 `pairingBootstrap`（无凭据，由配对码或限流保护）；三，动迁之前先把 /api/capabilities 全表做成逐字节快照测试，WebDAV 兜底模块不参与前缀冲突检测。

## caller-identity-trust-gates

**调用者身份和信任区判据在各 handler 里重算，TLS、peer、「我的设备」、开关的门手写 6 份以上，顺序和错误形态各不相同**

- 类型：缺单一登记源；规模 L；价值 high；改持久化 / wire
- 核验：成立

证据：

- packages/fushi_engine/lib/sync/fushi_sync_server/auth.part.dart:36-44 与 :50-86：中间件 _validateAuth 校验通过后不把身份放进 request.context；catch (_) { return false; } 把凭据提供方（DB）故障吞成 401「凭据无效」
- packages/fushi_engine/lib/sync/fushi_sync_server/source_share.part.dart:21-37：先判 host==null 回 404，再判 TLS 403、peer 403、开关、owner；sync_state.part.dart:356-366 与 leaderboard_link.part.dart:17-22 则是先 TLS、peer，后判 404。同类门的顺序相反，客户端无法统一区分「不支持」和「需 HTTPS」
- packages/fushi_engine/lib/sync/fushi_sync_server/plugin_relay.part.dart:14-27：_pluginRelayGate 照抄来源共享的门；game_stream.part.dart:26-40 的注释里直接写着「The repo already forces HTTPS for ... service-config and profile-transfer」，又手写了一遍
- 同一个调用者身份有三种编码：fushi_sync_server.dart:1636-1641 _pairedIdentity 返回 raw token（SRS 长轮询）；:1713 视频遥控和 game_stream.part.dart:43 用 sha256(password) 内联；:361 _credentialFingerprint 也是 sha256，但走另一条入口
- fushi/lib/src/models/app_model.dart:1363、:1379、:1390：同一个 isOwnerDevicePeer 闭包注入三次（排行榜、来源共享、插件中继），每次请求走 interconnect_owner_devices.dart:131-137，即读 2 个偏好加全表扫 paired_peers；而引擎的 _CredentialSnapshot 已经缓存了 peerId→token
- packages/fushi_server/lib/src/headless_host.dart:977-996 与 fushi/lib/src/sync/fushi_server_controller.dart:621-640：两边 onClientUpload 各自拿 raw peerToken 反查 paired_peers 求设备名。服务端每次 PUT 全表扫且不去品牌前缀，app 带缓存和「认不得就重读」补丁，并调 interconnectPeerDisplayName，结果不一致

机制：中间件只回答「放不放行」，不产出「你是谁、什么信任级」，于是每个需要更高信任的 handler 都从 Authorization 头重新解码、重新比对。「我的设备」本是配对凭据的属性，却被做成每个 host 接口上的方法，由装配方注入。

根本方案：引擎新增 sealed InterconnectCaller：SharedToken | LegacyPeer(peerId) | PairedPeer(peerId, deviceName, ownerDevice, keyFingerprint) | TicketHolder(issuer)。中间件用 _CredentialSnapshot（扩成 peerId→{token, deviceName, owner, fingerprint}，owner 标记一并进快照，配对或吊销时由 invalidatePeerTokenCache 统一失效）解析一次，放进 request.context。凭据源抛错时回 503 加日志，不再降成 401。信任要求由 finding host-route-registry-split 的 route.trust 和 route.transport 声明，框架按固定顺序判门：不支持 404、TLS 403 https_required、peer 403 paired_peer_required、owner 403 not_owner_device，开关由模块回 403 disabled，统一 JSON 形态 {error}。删掉 InterconnectLeaderboardLinkHost、InterconnectSourceShareHost、InterconnectPluginRelayHost 上的 isOwnerDevicePeer，删掉 app_model 里三份注入，删掉 _pairedIdentity、两处 sha256 内联，以及 _sourceShareError、_pluginRelayError、_leaderboardLinkError、_interconnectProfileDenied 四套错误工厂。onClientWrite / onClientUpload 改成收 InterconnectCaller，两边的 paired_peers 反查一并删除。以后新端点只声明 trust 级，handler 内不允许出现 _validatePeerAuth 或 _basicPassword，用源码守卫钉住。

要动：packages/fushi_engine/lib/sync/fushi_sync_server/auth.part.dart；packages/fushi_engine/lib/sync/fushi_sync_server/{source_share,plugin_relay,leaderboard_link,sync_state,game_stream,video}.part.dart；packages/fushi_engine/lib/sync/interconnect_owner_devices.dart；packages/fushi_engine/lib/sync/interconnect_{source_share,plugin_relay,leaderboard_link}.dart；fushi/lib/src/models/app_model.dart；fushi/lib/src/sync/fushi_server_controller.dart；packages/fushi_server/lib/src/headless_host.dart

核验说明：已验证：auth.part.dart:50-81 的 _validateAuth 只返回 bool，`catch (_) { return false; }` 把凭据快照（DB）的异常吞掉了。source_share.part.dart:20-37 的判门顺序是 host==null→404、TLS、peer、开关、owner；sync_state.part.dart:354-366 是先 TLS、peer，后判 404，错误体为纯文本（「HTTPS required for service config」），来源共享回的则是 JSON code。两者顺序相反、形态也不同，属实。app_model.dart:1363、1379、1390 三次注入同一个 isOwnerDevicePeerToken；interconnect_owner_devices.dart:131-140 每次调用读 owner 集合、指纹，再全表扫 paired_peers，属实。两边 onClientUpload 的分叉也属实：headless_host.dart:977-996 每次全表扫，不调 interconnectPeerDisplayName；fushi_server_controller.dart:621-640 带缓存、认不得就重读，并调 interconnectPeerDisplayName。

方案风险：1）这条会改 wire：统一判门顺序和 JSON 错误形态后，现有客户端（含老版本）对 service-config 和 profile 的纯文本 403、404 判别可能失效。按「Never break userspace」，要么保留旧端点原有的状态码与 body，只给新端点用统一形态，要么先确认客户端只认状态码。2）401 改 503：要确认客户端对 503 不会走「重新配对 / 清凭据」分支。若有分支把非 200 一律当认证失败，需同步修改。3）方案把 owner 标记放进 _CredentialSnapshot，只在「配对或吊销时 invalidatePeerTokenCache」失效，这样会漏失效。「我的设备」标记由 fushi_server_controller.dart:1257 setOwnerDevicePeer、sync_settings_schema/interconnect.part.dart:1881、服务端 admin_api.dart:687 单独切换，设备钥匙指纹也会单独变（setDeviceKeyFingerprint）。这几处现在不调 invalidate，因为现状是每次请求都现读。直接套用方案，会出现取消「我的设备」后来源共享 / 插件中继仍放行的越权。4）owner 判定还要求已验签的指纹（owner_devices.dart:137），进快照时必须一并带上。

修正后的方案（以此为准）：InterconnectCaller 和统一判门照方案做，补三点：一，快照的失效入口要覆盖 setOwnerDevicePeer、setDeviceKeyFingerprint、吊销、配对，最好由 InterconnectOwnerDeviceStore 写入后直接通知 server 推进代际，不靠各调用方记得调 invalidate；二，已有端点保留原状态码与 body（或先让客户端兼容两种形态后再切换），新端点用统一 {error}；三，401 改 503 前先核对客户端对 503 的处理。

## capability-from-type-test

**能力位靠 is XxxHost 类型测试，实现类却一口气 implements 30 个接口，真实可用性藏在 21 个可空闭包里，能力位会报假**

- 类型：成类 bug；规模 XL；价值 high；不改外部行为
- 核验：成立

证据：

- packages/fushi_engine/lib/sync/local_library_host_service.dart:173-203：_LocalLibraryHostBase implements 约 30 个 marker interface，app 和服务端用的是同一个类（headless_host.dart:1086），所以 pairing.part.dart:667-754 的 `_libraryService is VideoMetadataHost / TagSyncHost / VideoDiscShareHost ...` 在生产环境恒为 true，形同常量
- local_library_host_service.dart 构造器有 21 个可空闭包或目录（importPdfBookFromFile、onLocalAudioImported、isProfileTransferEnabled、exportActiveProfileJson、onlineMangaReader ...）；能力位为 true 而闭包为 null 时，端点抛 UnsupportedError（local_library_host_service/sync_state.part.dart:19-22、:33-35）
- 补丁痕迹：pairing.part.dart:677-680 为 PDF 单独加了 acceptsPdfBooks getter（local_library_host_service.dart:413）；sync_state.part.dart:6-14 用「三者缺一即不可用」的手写判空打补丁；能力位 'videoSubtitleBackfill' 写成 lib && videoSubtitleBackfill != null（pairing.part.dart:744），又是另一种形态
- docs/bugs/BUG-2815-server-local-audio-host.md：服务端没接 localAudio 三件闭包，能力位照报，上传传完才抛 UnsupportedError。这正是这个机制造成的真实 bug

机制：「实现了接口」和「装配了依赖」是两回事：前者是编译期常量，后者是运行时可空。能力位读的是前者，端点行为取决于后者。每个功能都要额外手写一个 acceptsX 或判空 getter 来弥补，漏写一处就报假能力。

根本方案：把 FushiLibraryHostService 这个总接口拆成按功能的库模块：VideoMetadataModule、PdfImportModule、ProfileTransferModule、LocalAudioModule、DiscShareModule 等，都实现 InterconnectHostModule。每个模块的构造参数全部 required、不可空；依赖不全就不构造，装配方传 null 模块。于是「有没有这个模块」就是能力位，键不出现或为 false，404 自然一致。LocalLibraryHostService 退化成共享的 DB 与锁上下文，供各模块注入；删除 fushi_library_host_service.dart 里全部 marker interface、_LocalLibraryHostBase 的 implements 长表、acceptsPdfBooks 及各类判空 getter，以及 pairing.part.dart 里约 25 个 is 测试。能力 JSON 通过快照测试保持逐字节不变。守卫：模块构造参数中出现可空 Function 视为违规（lint 或源码守卫）。以后新增能力只写一个模块，依赖不齐就不注册。

要动：packages/fushi_engine/lib/sync/fushi_library_host_service.dart；packages/fushi_engine/lib/sync/local_library_host_service.dart；packages/fushi_engine/lib/sync/local_library_host_service/；packages/fushi_engine/lib/sync/fushi_sync_server/pairing.part.dart；fushi/lib/src/models/app_model.dart；packages/fushi_server/lib/src/headless_host.dart

核验说明：已验证：local_library_host_service.dart:173-203 的 _LocalLibraryHostBase implements 约 30 个接口；app_model.dart:1397 和 headless_host.dart:1086 用的都是 LocalLibraryHostService，所以 pairing.part.dart 里 22 处 is 测试在生产中恒为 true。补丁形态属实：pairing.part.dart:678 的 acceptsPdfBooks、:751 的 `lib && videoSubtitleBackfill != null`、sync_state.part.dart:8-14 的「三者缺一」判空，以及 :19 以后在闭包为 null 时抛 UnsupportedError。BUG-2815 已修，它是这个机制造成的历史实例，证据成立。

方案风险：1）「依赖不全就不构造」只适合装配期就确定的依赖。像 isProfileTransferEnabled、onlineMangaReader 的开关、各类偏好开关，是运行时状态，仍需要 capability() 现算，不能折算成「模块存在与否」。否则用户在设置里切开关后，能力位要等互联重启才更新，这是用户可见的回归。2）能力位现在有「键存在但为 false」和「键不出现」两种语义，客户端的三态回退（老 host / 声明关）依赖这一区分。改成「不构造就不出现键」，会把原来的 false 变成缺键，必须靠快照逐键保留原有形态。3）测试里的 FushiLibraryHostService fake 大量依赖这些 marker interface，拆分后要随之改写。

修正后的方案（以此为准）：模块分两层：装配期依赖用 required 不可空参数，不齐就不注册；运行时开关保留在 capability() 里现算。迁移时用全表能力快照逐键保留「false」与「缺键」的原形态。

## host-assembly-nullable-hooks

**app 与服务端两处装配：43 个可空 factory 三跳转发，加 25 个可变 setter，null 同时表示「不适用」「没接」「忘了」，parity 文档手工维护并已漂移**

- 类型：app / 服务端各写一套；规模 L；价值 high；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/sync/fushi_server_controller.dart:101-133 构造器约 43 个可空 factory，:134-165 逐个存字段，:851-929 再逐个转给 FushiSyncServer；源头在 fushi/lib/src/models/app_model.dart:1330-1400。新增一个钩子要改 FushiSyncServer、controller 参数、字段、转发、app_model 共 5 处，再加 headless_host.dart:543-669 一处
- packages/fushi_engine/lib/sync/fushi_sync_server.dart:799-955：onPairRequest、onClientWrite、leaderboardLinkHost、sourceShareHost、pluginRelayHost、srsRemoteStoreProvider、srsSync2Joined、aiRelaySettings、aiRelayClientFactory、hostId、videoSubtitleBackfill、hostSelfUpdater 等都是公有可变字段，启动后也可以改，没有完整性检查
- packages/fushi_server/lib/src/headless_host.dart:607-669 没设 srsSync2Joined（fushi_sync_server.dart:1433-1439 因此回 404），也没设 aiRelayClientFactory；docs/agent/server-parity-gaps.md 的表里没有 srsSync2Joined，下文还写着「The other hooks are wired on both sides」，文档已与代码不符
- 同一个 BUG 类：docs/bugs/BUG-2815（服务端漏接本地音频）、docs/bugs/BUG-5160（app 的 tick 驱动上传策略，服务端没有对应物）都是「某一侧装配漏了，静默降级」

机制：装配点是两个各自手写的长参数列表，引擎对每个钩子只认「null = 关」，编译器和测试都不会提示「这一侧还没决定这个钩子」。parity 清单只能靠人记，所以必然漂移。

根本方案：在引擎里定义不可变的 FushiHostAssembly（record 或 class），每个钩子都是 required 字段，类型为 sealed HostSlot<T>：Provided(T) | NotApplicable(String reason) | NotYetWired(String trackingDoc)。FushiSyncServer 只接这一个对象，删掉全部可变 setter（运行期确实要变的 P2P 地址等改走 finding host-lifecycle-runtime-fork 的 runtime）。FushiSyncServerController 不再转发 43 个 factory，app_model 直接构造 AppHostAssembly(...) 交给它；服务端构造 ServerHostAssembly(...)。新增钩子时两处装配都编不过，必须显式选 Provided / NotApplicable / NotYetWired。再写一个测试遍历两份 assembly 的非 Provided 槽位，生成 server-parity-gaps.md 的「Host hooks」表（与入库版本 diff，不同即红），手工表退役。

要动：packages/fushi_engine/lib/sync/fushi_sync_server.dart；fushi/lib/src/sync/fushi_server_controller.dart；fushi/lib/src/models/app_model.dart；packages/fushi_server/lib/src/headless_host.dart；docs/agent/server-parity-gaps.md

核验说明：已验证：fushi_server_controller.dart 构造器里有 srsSync2Joined（:129）和 aiRelaySettings（:131），:927-929 转发给 FushiSyncServer；fushi_sync_server.dart:868 是公有可变字段 `bool Function()? srsSync2Joined;`，:1433-1439 在它为 null 时回 404。packages/fushi_server/lib 里 grep 不到 srsSync2Joined 和 aiRelayClientFactory，只设了 aiRelaySettings（headless_host.dart:666）。docs/agent/server-parity-gaps.md:28 写「The other hooks are wired on both sides」，表里没有 srsSync2Joined，文档漂移属实。

方案风险：1）HostSlot.NotYetWired 必须与 parity 文档的生成测试绑在一起，否则会退化成新一种「null」。2）P2P 地址、hostId 等运行期确实会变的字段要先分出来，改走 runtime，再冻结 assembly，否则要靠可变字段打补丁。3）srsSync2Joined 在服务端到底是「不适用」还是「漏接」需要先查清。服务端按 server-srs spec 会跑 srsSync2Round，看起来应接（推测），这一点由拍板或 spec 决定，不能由生成器猜。

## host-lifecycle-runtime-fork

**host 生命周期在 app 与服务端各写一份：P2P 挂接、配对落库、凭据加载、启动前置逐字复制，又各自打了不同的竞态补丁**

- 类型：app / 服务端各写一套；规模 L；价值 medium；不改外部行为
- 核验：成立

证据：

- packages/fushi_server/lib/src/headless_host.dart:720-789 与 fushi/lib/src/sync/fushi_server_controller.dart:1091-1136：_serializeP2p 逐字相同，_attachP2p / _detachP2p 结构相同。app 版在 attach 中途三次重读 isInterconnectP2pEnabled 并比 identical(_server, server)（:1106-1118），属于防开关竞态的守卫补丁；服务端版没有这些守卫，竞态语义两边不一致
- headless_host.dart:954-974 与 fushi_server_controller.dart:1208-1236：_persistPairedPeer 两份。服务端走 InterconnectOwnerDeviceStore.recordPairing，app 走 _repo.setPeerDeviceKeyFingerprint + setOwnerDevicePeer 两次调用。服务端还在 :969 重复 invalidatePeerTokenCache，而引擎已在 pairing.part.dart:525 调过
- headless_host.dart:999-1004 与 fushi_server_controller.dart:1241-1246：_loadPairedPeerCredentials 逐字相同
- 启动前置也是两份：TLS 身份加载（fushi_server_controller.dart:838 / headless_host.dart:374）、pruneDeadInterconnectFileBox（:946 / :674），两边各自调用

机制：FushiSyncServer 只是一个 HTTP 处理器，配对持久化、凭据源、P2P 隧道、TLS 身份这些都基于同一张 FushiDatabase 表和同一组冻结偏好键，却交给宿主实现。两个宿主各抄一份，后来一侧修了竞态，另一侧没跟上。

根本方案：在 fushi_engine 新增 InterconnectHostRuntime：持有 FushiSyncServer、配对持久化（直接写 paired_peers 与 InterconnectOwnerDeviceStore，供 onPeerPaired 和凭据源使用）、TLS 身份、file-box prune，以及 P2P。P2P 用期望状态对账模型：desired = {p2pEnabled, relayUrls}，由宿主推送；runtime 串行执行 reconcile()，每步检查 generation 号，以此替代散落的「再读一次开关」。宿主只提供三样：配置源（app 读 SyncRepository，服务端读 yaml）、配对审批 UI（弹窗或 pending 列表）、HostAssembly。删掉 controller 和 headless_host 里的 _serializeP2p、_attachP2p、_detachP2p、_persistPairedPeer、_loadPairedPeerCredentials 及其重复的 invalidate。以后改 P2P 或配对逻辑只改 runtime 一处，两端自动一致。

要动：packages/fushi_engine/lib/sync/(new) interconnect_host_runtime.dart；packages/fushi_engine/lib/sync/interconnect_p2p.dart；fushi/lib/src/sync/fushi_server_controller.dart；packages/fushi_server/lib/src/headless_host.dart

核验说明：已验证：headless_host.dart:714-716 的注释自述与 app 侧 `FushiServerController._serializeP2p` 是同一形态，:720 _serializeP2p、:738 _attachP2p、:780 _detachP2p 与 fushi_server_controller.dart:1091 起的实现平行。_persistPairedPeer（headless :954、controller :1208 附近）和 _loadPairedPeerCredentials（headless :999、controller :1241）两份。headless_host.dart:969 的 invalidatePeerTokenCache 与 pairing.part.dart:525 重复，属实。app 版在 attach 里有重读开关的竞态守卫，服务端没有，这一条我没有逐行比对（推测成立）。

方案风险：InterconnectHostRuntime 放进 fushi_engine 要守住包边界：不能依赖 SyncRepository（它在 fushi/），只能用 FushiDatabase 和 InterconnectOwnerDeviceStore。TLS 身份与冻结偏好键要沿用原名不改。配对审批 UI 在 app 是弹窗，在服务端是 pending 列表，回调签名要能容纳异步审批。

## capabilities-client-schema

**能力位没有共享 schema：服务端手拼 Map，客户端 6 处以上各取各缓存、裸字符串取键，又叠了每轮缓存补丁**

- 类型：镜像状态；规模 L；价值 medium；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/sync/interconnect_sync_backend.dart:1180、:3427、:4152、:4355：4 份各自 GET /api/capabilities 的实现，各带一对 _xxxCapabilityScope / _xxxCapability 缓存字段（3415-3418、4150、4352-4353），全部不带 ETag
- fushi/lib/src/sync/interconnect_host_channel.dart:477-575 另有一套带 ETag 重验的 _CapabilitiesSlot；fushi/lib/src/media/music/server/interconnect_music_client.dart:902 自己再探一次；fushi/lib/src/sync/sync_orchestrator/peer_gaps.part.dart:11-19 为 BUG-5101「每轮多读能力表」又叠了一层 report 级缓存
- 键名分叉：服务端写 kDiscShareCapability（disc_share_routes.dart:34），客户端 interconnect_sync_backend.dart:4374 写裸字面量 'discShareV1'；:3423 'videoSubtitleDefault' 和服务端 pairing.part.dart:708 都是裸字面量，没有常量
- interconnect_sync_backend.dart 里「老 host」出现 56 次：每个能力都手写自己的「缺键 / false / 404」三态回退；peer_gaps 的 liveLibraryCapabilityState（fushi_library_host_service.dart:264）只覆盖其中一部分

机制：能力位只是一张无类型的 JSON Map，服务端按功能手拼，客户端按功能手读。没有共享的描述对象，也没有按 host 唯一的缓存，所以每加一个功能就多一份 fetch 和缓存，性能问题出来后只能在上层补缓存。

根本方案：在 fushi_engine 定义 InterconnectCapability<T> 描述对象（键、所属分组、解码函数、缺省三态），由各模块导出（与 finding host-route-registry-split 同一个注册表）。服务端能力文档由表生成；客户端有一个 HostCapabilities 类型化视图（caps.has(kDiscShare) / caps.state(kX) 返回 supported | declaredOff | undeclared）。按 host 只有一个缓存，落在 InterconnectHostChannel 现有的 ETag slot 上（304 重验很便宜）。InterconnectSyncBackend、music client、manga OCR client、peer_gaps 一律从它取。删掉 interconnect_sync_backend.dart 的 4 份 fetch、6 个缓存字段、peer_gaps 的 _roundHostCapabilities，以及所有 hostSupportsX 方法体。守卫：仓库里字面量 '/api/capabilities' 只允许出现在 channel 和服务端注册表；decoded['liveLibrary'] 这类裸 Map 访问用源码守卫禁止。

要动：packages/fushi_engine/lib/sync/interconnect_module.dart；packages/fushi_engine/lib/sync/fushi_sync_server/pairing.part.dart；fushi/lib/src/sync/interconnect_host_channel.dart；fushi/lib/src/sync/interconnect_sync_backend.dart；fushi/lib/src/sync/sync_orchestrator/peer_gaps.part.dart；fushi/lib/src/media/music/server/interconnect_music_client.dart

核验说明：已验证：interconnect_sync_backend.dart:1183、:3436、:4161、:4365 有四份各自 GET /api/capabilities 的实现；interconnect_host_channel.dart:537 另有一份，interconnect_music_client.dart:902 再自探一次。键名分叉属实：服务端用常量 kDiscShareCapability（disc_share_routes.dart:34），客户端在 :4375 写裸字面量 'discShareV1'；'videoSubtitleDefault' 在 :3354、:3423 和 pairing.part.dart:708 都是裸字面量。peer_gaps 的每轮缓存与「老 host」出现 56 次这两点没有复核。

方案风险：若统一走 ETag slot，须确认老 host（无 ETag、甚至无该端点、返回 404/405）的三态语义不变。InterconnectCapability 描述对象放在 fushi_engine，客户端从 fushi/ 引用，这个依赖方向合规。

## engine-global-host-bindings

**引擎宿主钩子是全局可变顶层变量，app 与服务端各写一份手工赋值清单，漏装要到运行时才炸**

- 类型：守卫代替结构；规模 M；价值 medium；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/engine_bindings.dart:118-151：installEngineHostBindings 逐行给约 18 个全局变量赋值（fushiDebugPrint、engineLog、enginePaths、ffmpegPlatformBackendProvider、ocrSessionFactoryBuilder、aacsDecryptionAvailable ...）
- packages/fushi_server/lib/src/host_bindings.dart:30-62：installServerHostBindings 另写一份约 12 项，并非同一组。注释 :39-40 自述「不装的话代下载的有声书在对齐落盘时抛 StateError」，说明漏装只能在运行时暴露
- fushi/lib/src/engine_bindings.dart:109-116：入口必须调 installEntryPointHostBindings，由 test/build/entry_point_host_bindings_guard_test.dart（BUG-4940）用源码守卫钉住。这个守卫在兜「必须装齐」这一本该由类型保证的不变量

机制：引擎通过顶层可写变量做依赖注入，每个变量各有默认值或者没有。新增一个钩子时编译器不会提示两个宿主去装，只能靠守卫测试检查入口有没有调 install，检查不到装没装齐、装没装对。

根本方案：在 fushi_engine 定义 EngineHostBindings 类，全部 required 字段；确实可缺省的项用 sealed Provided / NotApplicable 表达，例如 aacsDecryption、pdfTextSections 在服务端为 NotApplicable。新增唯一入口 installEngine(EngineHostBindings b)，内部一次写入并冻结，重复安装直接报错。app 构造 AppEngineBindings，服务端构造 ServerEngineBindings；以后新增钩子时两端都编不过，必须显式选择。原来散落的顶层可写变量改为私有，只保留只读访问器；BUG-4940 的源码守卫退化成「入口调用了 installEngine」这一条，不再兜底完整性。

要动：packages/fushi_engine/lib/foundation/engine_platform_hooks.dart；fushi/lib/src/engine_bindings.dart；packages/fushi_server/lib/src/host_bindings.dart；fushi/test/build/entry_point_host_bindings_guard_test.dart

核验说明：已验证：engine_bindings.dart:109-155 逐行给全局变量赋值，并调用若干 installXxx；host_bindings.dart:30-65 另写一份，项目集合不同（服务端用 ffmpegPathOverride、AudiobookStorage.documentsRootResolver 等，app 用 evictImageCacheForFile、aacsDecryptionAvailable 等）。:38-39 的注释自述漏装会在运行时抛 StateError。BUG-4940 守卫只钉入口有没有调用 install。

方案风险：1）有些钩子是进程级单例，并要求在首次使用前装好（ffmpegPathOverride 必须早于首个 resolveFfmpegBackend）。「一次写入并冻结、重复安装报错」会与测试里反复覆盖钩子的做法冲突，需要提供仅供测试用的 reset。2）后台 isolate（OCR、ASR）各自有入口，也要调用 installEngine，冻结语义需按 isolate 理解。3）asr_core 的钩子属于另一个包，EngineHostBindings 不能把它吞进 fushi_engine（ASR 算法在上游仓库），应保留独立的 AsrHostBindings。

修正后的方案（以此为准）：EngineHostBindings 只覆盖 fushi_engine 自有的钩子，ASR 另设 AsrHostBindings，两者由宿主的入口函数一起装。提供 `@visibleForTesting resetEngineBindings()`。每个 isolate 入口都显式调用 installEngine。

## 核验补充（审计漏掉的）

- 「我的设备」标记的写入点不会通知互联 server：fushi_server_controller.dart:1257、sync_settings_schema/interconnect.part.dart:1881、packages/fushi_server/lib/src/admin/admin_api.dart:687 各自调 setOwnerDevicePeer。现在安全，只是因为 interconnect_owner_devices.dart:131 每次请求都现读。任何缓存化重构（包括审计自己提出的 InterconnectCaller 快照）都要先给 InterconnectOwnerDeviceStore 加写入后的变更通知，否则会出现越权。
- 同类门的错误形态已经是 wire 契约：sync_state.part.dart:356-360 回纯文本 403/404，source_share.part.dart:25-35 回 JSON code。客户端按哪种形态判别「不支持 / 需 HTTPS」，审计没有查，统一前要先核对客户端解析点。
- 现有的 interconnect_module_layer_test.dart:587-614 只是已迁移功能的禁用名单。新增手写 `reqPath ==` 分支不会被任何守卫拦下，新功能今天照样可以绕开模块层，这才是模块化半途停滞的结构原因。
