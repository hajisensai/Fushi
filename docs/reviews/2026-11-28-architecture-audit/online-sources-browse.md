# 架构审计：online-sources-browse

2026-11-28 只读审计 + 独立反驳核验的原始结论。总方案见 [../../specs/2026-11-28-architecture-redesign.md](../../specs/2026-11-28-architecture-redesign.md)。

## 现状

在线源有三类宿主：漫画（Mihon）和视频（Aniyomi）共用一个 MihonRuntime，桌面是 Java sidecar（desktop_mihon_runtime.dart，1196 行），Android 是原生 MihonChannelHandler；状态在 Drift 的 manga_extension* 表里，按 media_kind 分片。小说（LNReader）是另一套：headless WebView 运行时，状态是自己手写的 JSON 文件（lnreader_manager.dart，775 行）。源浏览页在 2026-09-27 已收成一份（OnlineSourceBrowsePage 配 OnlineSourceCatalog 适配器），但扩展仓库页、已装源段、仓库增删改、批量安装 / 一键更新、更新探针仍是 Mihon 和 LNReader 各写一套，修复常常只落在一边。AI 操作目录 ctl_online_routes.dart（2215 行）按种类 switch，把浏览页的取数顺序又写了一遍，因为 OnlineSourceCatalog 把数据和 Widget 混在一起，复用不了。合规判据本身是单一真相源（StoreRestrictedCapability），iOS 上没发现散落的 Platform.isIOS；但「合规门 × 宿主平台门」要在每个消费端手工拼，而且只有视频和小说有组合门、漫画没有。源偏好有两个真相源：Drift 和宿主存储（JVM xml / Android SharedPreferences），两端同步语义不一致，Android 每次调用都同步写盘。内置浏览器的状态大多集中在 3049 行的 FushiWebBrowserPageState：前台标签页每次进度变化都让整个外壳 rebuild。浏览器扩展的设置项在 JS 和 Dart 各手写一份，靠正则解析 JS 的守卫测试兜一致。广告拦截已经下沉到 Rust（fushi_web_core），结构合理，不报。

## online-host-twin-stacks

**Mihon 与 LNReader 的扩展管理（仓库 / 目录 / 安装 / 更新 / 已装源）是两套平行实现，修复只落一边**

- 类型：缺单一登记源；规模 XL；价值 high；用户可见
- 核验：部分成立

证据：

- fushi/lib/src/media/manga/mihon/mihon_extensions_page.dart:1091-1220 的 _bulkInstall / _updateAll / _runBulk，与 fushi/lib/src/media/novel/online/lnreader_extensions_section.dart:219-330 逐行同构（同一批 i18n key、同一套 confirmExtensionBulk / runExtensionBulkWithProgress / showExtensionBulkReport）；LNReader 版 _bulkInstall 在 targets 为空时少了 mounted 判断，已经开始分叉
- fushi/lib/src/media/novel/online/lnreader_manager.dart:388-394 的 normaliseStoreUrl 只有 Uri.tryParse，而 Mihon 的 mihon_extension_store_client.dart:11,649-651 走 normalizeUrlInput（全角句点，BUG-1804）和 github_mirrors（BUG-1875）；这两条修复都没进小说仓库
- fushi/lib/src/models/app_model.dart:2204-2220 只给 mangaExtension / animeExtension 登记更新探针，fushi/lib/src/updates/update_feed_service.dart:356-358 也只有这两种；LNReader 插件没有更新提醒，也没有自动更新
- 同一机制在 bug 记录里一再出现：BUG-3786（LNReader 卸载会清数据，Mihon 不清，两边语义不一致）、BUG-4364（同一个非懒建问题要在 mihon_installed_sources_section.dart:612,623 和 lnreader_installed_sources_section.dart:310,323 各改一次）、BUG-5042（只有 LNReader 的 UI 不看 stateError）
- fushi/lib/src/media/manga/mihon/mihon_manager.dart:212-451（addStore / refreshStores / editStoreUrl / removeStore）与 lnreader_manager.dart:396-441（addStore / editStore / removeStore / refreshStores）是同一组能力，两套 API

机制：浏览页阶段 2 只把「源浏览」抽成了 OnlineSourceCatalog，「扩展生态管理」这一层没有跨宿主的契约。每个宿主自带 Manager、扩展页和已装源段，UI 直接依赖具体的 Manager 类型，所以任何修复和新能力（URL 归一化、镜像、卸载语义、错误态、更新探针）都要在 N 处各写一遍，漏一处就成为下一条 bug。

根本方案：在 fushi/lib/src/media/online/host/ 下新建宿主无关的契约 OnlineSourceHost，暴露：stores（增 / 改 / 删 / 刷新，统一经 engine 的 normalizeUrlInput 和 github_mirrors 归一化与取索引）、catalog（ExtensionCatalogEntry：id / 名称 / 语言 / 版本 / 图标 / nsfw / storeUrl / 下载量）、installed（InstalledSourceEntry）、install / uninstall({clearData}) / setEnabled / setPinned / reorder / hasUpdate / installMany(isCancelled)，再加一条 loadError 状态流。MihonManager(kind) 和 LnReaderManager 实现这个接口，宿主特有的步骤（签名信任提案、APK 预览）作为可选能力接口挂上去，模仿现有的 ChallengeMihonRuntime 这种 is-能力写法。UI 收成一份泛型 OnlineExtensionsPage<Host> 和一份 InstalledOnlineSourcesSection<Host>，删掉 lnreader_extensions_section.dart、lnreader_installed_sources_section.dart，以及 mihon_extensions_page.dart / mihon_installed_sources_section.dart 里的通用部分（只留预览 / 签名 UI 作扩展点）。更新探针按宿主注册表遍历（UpdateFeedKind 加 novelExtension）。以后新增一个宿主只需实现 OnlineSourceHost 并在注册表登记一行。守卫：UI 层禁止 import 具体 Manager。

要动：fushi/lib/src/media/manga/mihon/mihon_extensions_page.dart；fushi/lib/src/media/manga/mihon/mihon_installed_sources_section.dart；fushi/lib/src/media/manga/mihon/mihon_manager.dart；fushi/lib/src/media/novel/online/lnreader_extensions_section.dart；fushi/lib/src/media/novel/online/lnreader_installed_sources_section.dart；fushi/lib/src/media/novel/online/lnreader_manager.dart；fushi/lib/src/models/app_model.dart；fushi/lib/src/updates/update_feed_service.dart

核验说明：两套平行实现基本属实。lnreader_manager.dart:388-394 的 normaliseStoreUrl 只用了 Uri.tryParse，而 Mihon 那边在 mihon_extension_store_client.dart:11-12,649-651 走 normalizeUrlInput 和 github_mirrors，两边确实分叉了（已验证）。更新探针只登记了 mangaExtension / animeExtension（app_model.dart:2204-2220，update_feed_service.dart:356-358），已验证。LNReader 其实有 hasUpdate（lnreader_manager.dart:548），只是没进 UpdateFeed，所以「没有更新提醒和自动更新」这句成立，但它不是缺了这个能力。BUG-3786 / 4364 / 5042 都确有其文件。不成立的一条：『LNReader 版 _bulkInstall 在 targets 为空时少了 mounted 判断，已经开始分叉』。lnreader_extensions_section.dart:219-231 从入口到用 context 之间没有 await，同步路径不需要 mounted 判断，这不是 bug，也不算分叉证据。

方案风险：1）两种宿主的信任模型本质不同。Mihon 有 APK 签名信任和预览；LNReader 没签名，卸载时可以选清数据（BUG-3786 的语义是有意的）。接口里的 uninstall({clearData}) 和 install 要按能力分开，不能为了凑统一把 Mihon 的签名确认流程塞进可选能力后被绕过。2）UpdateFeedKind 加 novelExtension 时，kUpdateNotificationBaseIds 是跨版本稳定的通知 id 表（update_feed_service.dart:350-358，9101-9105），新值只能追加，不能重排；update_feed 表里存的 kind 名也要保持不变。3）『UI 层禁止 import 具体 Manager』这条守卫会撞上 ops / 获取后端 / 阅读器等非 UI 的直接消费方，范围得写清楚。

修正后的方案（以此为准）：保留 OnlineSourceHost 契约这个方向，但分成三层能力：通用（stores / catalog / installed / enable / pin / reorder / hasUpdate / installMany / loadError）、Mihon 专属（签名信任提案 / APK 预览，安装前必须经过它，契约上做成 install 的必经前置，而不是可有可无的挂件）、LNReader 专属（卸载时清插件存储的开关）。仓库 URL 归一化下沉到 engine 的 normalizeUrlInput 加 github_mirrors 这一个函数，两边共用。UpdateFeedKind.novelExtension 追加在末尾，通知 id 取新值 9106，不动现有值。守卫只限 pages/ 与 media/*/ 下的 *_page.dart / *_section.dart。

## source-prefs-dual-truth

**源偏好有两个真相源（Drift 与宿主存储），两端同步语义分叉，Android 每次调用和每张页图都同步写盘**

- 类型：镜像状态；规模 M；价值 high；改持久化 / wire
- 核验：部分成立

证据：

- fushi/lib/src/media/manga/mihon/mihon_manager.dart:1444-1460 contextForSource 每次都调 _readPersistedPreferences（:1481-1486 查 manga_source_preferences 表），列表、搜索、取流、更新探针每次调用都要查一次库
- fushi/android/app/src/main/kotlin/app/fushi/reader/mihon/MihonPreferenceBridge.kt:91-114 的 apply → writeSnapshot：只要快照非空就无条件 editor.commit()（同步写盘）
- fushi/android/app/src/main/kotlin/app/fushi/reader/mihon/MihonChannelHandler.kt:281-283（每次 invoke）和 :486-488（fetchPageImage，每张页图）都会调 applyPreferences
- 桌面走另一种语义：BUG-3520 的修复在 sidecar 里加了 HostPreferenceSnapshot 台账，「Drift 变了才写」，扩展自己写的值可以保留；Android 仍是「每次请求 Drift 覆盖」。BUG-3520 备注里明写「记为两端语义差异」未改，BUG-4177 又在 Android 偏好回读上出过一次错

机制：偏好真值在 Dart 的 Drift，但扩展只读宿主本地存储，所以每次调用都要把整份快照推过桥。「什么时候写、谁赢」分别在 JVM overlay 和 Android 桥里各实现了一次，没有共享。快照也没有版本号，宿主只能每次比对或者每次写，热路径（逐页取图）上就是每张图一次 DB 读加一次同步写盘（这是代码路径推断，没有实测数据）。

根本方案：Drift 仍然是唯一真值，宿主存储降为带版本号的缓存。MihonManager 在内存里为每个源维护「偏好快照 + revision」，setPreference 或还原备份时 revision+1，contextForSource 直接取内存缓存，不再每次查库。桥协议只带 revision，宿主记着已应用的 revision，相同就跳过，不同再要整份快照并按 HostPreferenceSnapshot 的台账规则写入。把 HostPreferenceSnapshot 移进 third_party/m_extension_server/overlay 里 Android 和桌面共编的那份源码（anime ABI 已经是共编模式），删掉 MihonPreferenceBridge.writeSnapshot 的无条件写。以后改语义只改这一个 Kotlin 文件，同一份 JVM 单测两端都覆盖。

要动：fushi/lib/src/media/manga/mihon/mihon_manager.dart；fushi/lib/src/media/manga/mihon/mihon_bridge_runtime.dart；fushi/android/app/src/main/kotlin/app/fushi/reader/mihon/MihonPreferenceBridge.kt；fushi/android/app/src/main/kotlin/app/fushi/reader/mihon/MihonChannelHandler.kt；third_party/m_extension_server/overlay/server/src/main/kotlin/mextensionserver/impl/HostPreferenceSnapshot.kt

核验说明：证据属实。contextForSource 每次都 await _readPersistedPreferences，也就是每次查一次 Drift（mihon_manager.dart:1444-1490）。Android 的 writeSnapshot 只要快照非空就无条件 editor.commit()（MihonPreferenceBridge.kt:107-113）。invoke 和 fetchPageImage 都会调 applyPreferences（MihonChannelHandler.kt:282,486）。BUG-3520 第 6 行明写『记为两端语义差异，本次未改』。两项需要纠正：『anime ABI 已共编』成立，android/app/build.gradle:83-85 把 overlay/server/src/main/kotlin 编进了 Android，所以 HostPreferenceSnapshot.kt 本来就已经在 overlay 共编目录里，不需要再『移进』；性能影响没有实测，属推断。

方案风险：给桥协议加 revision 属于 wire 变更，Android 原生和桌面 sidecar 两端要同版本发出，不过两端都随 app 打包，没有外部兼容负担。内存缓存要覆盖每一条改 Drift 偏好的路径，比如备份还原、清除源数据（SourceDataHandler 会连台账一起清）、卸载扩展，否则缓存过期，Drift 就不再永远能送达，等于重新引入 BUG-3520 那类问题。另外 Android 改用 HostPreferenceSnapshot 的台账语义会改变扩展自写值的行为，BUG-3520 写着无 Robolectric 测试、无真机验证，需要真机验。

修正后的方案（以此为准）：Android 的 MihonPreferenceBridge.writeSnapshot 直接改调已经共编的 HostPreferenceSnapshot，台账放在同名 SharedPreferences 里，两端用同一套『Drift 变了才写』的语义。Dart 侧在 MihonManager 内存里按 (package, sourceId) 缓存快照，在 setPreference / 备份还原 / 清源数据 / 卸载这些路径上统一失效，失效钩子挂在数据库写偏好的那一个 DAO 方法上，不在各调用点手动失效。revision 是可选优化：台账本身已经让重复写变成纯比较、不落盘，可以先不改 wire。

## ops-reimplements-catalog

**AI 操作目录按种类 switch 重写了一遍浏览页的取数流程；OnlineSourceCatalog 混了 Widget，复用不了**

- 类型：缺单一登记源；规模 L；价值 high；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/media/online/online_source_browse_page.dart:88-126：OnlineSourceCatalog<T> 同时有 prepare / fetch（数据）和 editFilters(BuildContext) / buildCover / openDetail（UI）
- fushi/lib/src/ops/ctl_online_routes.dart:735-775 的 searchSource 按 OnlineCtlKind 分支，直接调 manager.runtime.search / getFilters，注释写着「与源浏览页 prepare + fetch 同序」，即手工维持和 _MihonCatalog（mihon_source_browse_page.dart:102）、_LnReaderCatalog（lnreader_source_browse_page.dart:61）一致；同类 switch 还在 :907、:1033、:1106
- 同一个概念有三个枚举：OnlineCtlKind（ops/ctl_online_support.dart:17）、OnlineSourcesDomain（pages/implementations/browse_online_sources_view.dart:41）、MihonMediaKind

机制：源的数据契约只存在于 UI 适配器里，非 UI 的消费方（ops、video_work_acquisition_backends.dart:282、video_library_update_probe.dart:90、anime_source_launch.dart:84）只能绕过它直接摸 runtime，各自重排调用顺序（先取默认筛选再搜、错误归一化）。每多一个宿主或一处调用顺序修正，就要多改一处。

根本方案：把 OnlineSourceCatalog 拆成两层。(1) 纯数据的 OnlineSourceSession<T>，放在 media/online/host/，不碰 BuildContext：listings / prepare / fetch(query, page) / detail / chapters，结果是宿主无关的 DTO，错误统一归一成 OnlineSourceError。(2) UI 层的 OnlineSourceCatalogView，只负责封面、筛选弹框和跳详情。ops、获取后端、更新探针、浏览页都从同一个 Session 取数，ctl_online_routes 里的 per-kind switch 收成「注册表按 kind 取 host → session」。三个枚举合成一个 OnlineSourceKind（novel / manga / anime），持久化值不变。以后新增一个宿主只写一个 Session 实现。

要动：fushi/lib/src/media/online/online_source_browse_page.dart；fushi/lib/src/media/manga/mihon/mihon_source_browse_page.dart；fushi/lib/src/media/novel/online/lnreader_source_browse_page.dart；fushi/lib/src/ops/ctl_online_routes.dart；fushi/lib/src/ops/ctl_online_support.dart；fushi/lib/src/pages/implementations/browse_online_sources_view.dart；fushi/lib/src/media/video/discovery/video_work_acquisition_backends.dart；fushi/lib/src/updates/video_library_update_probe.dart

核验说明：ctl_online_routes.dart:735-778 按 OnlineCtlKind 分支，直接调 manager.runtime.search / getFilters，注释写着『与源浏览页 prepare + fetch 同序』，是手工维持一致（已验证）。OnlineSourceCatalog 只有 _MihonCatalog（mihon_source_browse_page.dart:102）和 _LnReaderCatalog（lnreader_source_browse_page.dart:61）两个实现，都是 UI 私有类，ops 复用不了。

方案风险：合并三个枚举时要注意，MihonMediaKind 对应 manga_extension* 表的持久化 media_kind 列（冻结），而且它只有 manga / anime 两个值。合进带 novel 的 OnlineSourceKind 后，MihonManager(kind) 这类签名就可能收到 novel，类型安全反而变差。ops 的 wire 字段 'kind'（kind.name）是 AI 操作目录对外的参数值，必须保持 novel / manga / anime 原样。

修正后的方案（以此为准）：数据层 Session 的拆分照原方案做。枚举只合并 OnlineCtlKind 和 OnlineSourcesDomain，合成 OnlineSourceKind；MihonMediaKind 保留为 Mihon 宿主内部的持久化枚举，由 OnlineSourceKind.mihonKind（novel 为 null）映射。ops 的 kind 字符串和持久化 media_kind 值都不变。

## lnreader-handrolled-persistence

**LNReader 状态用手写 JSON 文件加自研原子写 / 隔离 / 读失败态，同一机制已经出了 4 个 bug**

- 类型：成类 bug；规模 L；价值 medium；改持久化 / wire
- 核验：部分成立

证据：

- fushi/lib/src/media/novel/online/lnreader_manager.dart:117-123,173-201 的 _stateLoaded / _stateError / ensureReady 门，:246-305 的 _readJsonObject / _quarantine / _corruptBackups，:335-370 自写的 _writeChains 串行原子写
- BUG-4830（读失败当空状态，随后整份覆盖）、BUG-4977（读失败被误报成插件没装）、BUG-5042（读失败在 UI 上显示成空态）、BUG-4995（online_novel_chapter_loader 的原子写清理吞掉原始异常），都是「自研文件持久化的失败语义」这一类
- 同域的 Mihon / Aniyomi 状态在 Drift 的 manga_extension* 表（docs/agent/online-sources.md 第 1 条），事务、迁移和读失败语义都由数据库层统一提供，没有出过这类 bug

机制：小说源当初为了「删目录即卸载」，把仓库、已装插件和插件存储放进了 <数据根>/lnreader/*.json。这样一来事务性、读写失败语义、并发写合并、坏文件留底都得自己在应用层重写一遍；每条消费路径（取章、扩展页、已装源段）又要各自记得先查 ensureReady 或 stateError，漏掉一处就是一个新 bug。

根本方案：把 LNReader 的仓库、已装插件（顺序 / 启停 / 置顶 / 换行合并）和插件 KV 存储迁进 Drift 的新表（例如 online_plugin_store / online_plugin / online_plugin_storage，按 host 列区分）。插件 .js 本体和 cookies.json 继续留在磁盘。首次启动时一次性导入 state.json 和存储文件，导入成功后改名留底；导入失败就停在可重试的错误态，不写空。删掉 _readJsonObject / _quarantine / _writeChains / _writeAtomically、LnReaderStateErrorNotice 那组特判，以及各消费端的 ensureReady 分支，读失败语义交给数据库打开流程统一处理。这样也正好能接上第 1 条的 OnlineSourceHost（installed 直接是表查询流）。注意：这条要推翻 online-sources.md 里「不进 Drift」的既有设计，需要先上拍板台。

要动：fushi/lib/src/media/novel/online/lnreader_manager.dart；fushi/lib/src/media/novel/online/lnreader_state_error_notice.dart；fushi/lib/src/media/novel/online/lnreader_online_book.dart；fushi/lib/src/media/novel/online/online_novel_chapter_loader.dart；Drift schema / migrations；docs/agent/online-sources.md

核验说明：手写 JSON 持久化和那一组失败语义 bug 属实，对应文件都存在。但 docs/agent/online-sources.md:6 明确写了仓库 / 已装插件 / 插件存储『不进 Drift』，这是有意的既有设计；同文档里音乐插件也同样『不进 Drift』，是个一致的模式。审计员自己也写了要先上拍板台。至于『Drift 那边没出过这类 bug』，这是反事实推论，没有对照。

方案风险：推翻已写进文档的架构决定，必须先上拍板台。迁移要改 Drift schema，加表和迁移步骤（持久化变更）。插件 .js 和 cookies.json 还留在磁盘，『删目录即卸载』的语义就被拆到两个地方，卸载时要做跨存储的一致性清理。数据根迁移和备份 / 还原也要把新表算进去。

修正后的方案（以此为准）：先写拍板台：方案 A 是迁 Drift（按审计方案做）；方案 B 是保留文件存储，但把 _readJsonObject / _quarantine / _writeChains 抽成一个通用的 JsonFileStore<T>（读失败态显式建模成 sealed Loaded / Failed，任何消费方拿不到『空状态』），供 LNReader、音乐插件、cookies.json 和 feedback tickets.json 共用。B 不推翻既有设计，也能消除这一类 bug。

## sidecar-session-state

**桌面 sidecar 的进程生命周期是 4 个平行可空字段，在 5 处手工清零；装 / 卸任一扩展就重启整个 JVM**

- 类型：守卫代替结构；规模 M；价值 medium；改持久化 / wire
- 核验：部分成立

证据：

- fushi/lib/src/media/manga/mihon/desktop_mihon_runtime.dart:125-131 中 _process / _port / _token / _log / _proxyPolicy 是互相独立的字段；:145-150 又额外用一个 Expando<Process> _pageIssuer 给页引用标「哪个进程发的」（BUG-4917 的补丁）
- 同一组字段的清零散在 :561-562（dispose）、:718-719（exitCode 回调）、:734-735（等端口超时）、:766-767（ready 超时）、:956-957（_restart）；_restart 不关旧进程的 _imageClients，这一步只在 dispose 里做
- :500-513 invalidateExtensions 和 :474-496 clearSourceData 都走 _restart，杀掉所有源共享的 JVM。相关 bug：BUG-4917（重启后在读的章剩下的页全部失败）、BUG-2273（单个源超时杀共享桥）、BUG-5053（取图请求号撞号）、BUG-5046（临时文件泄漏）、BUG-1232（退出残留）

机制：「一个 sidecar 进程的一生」没有被建模成对象。端口、令牌、日志、代理策略、取图客户端、页引用这些都属于某一个进程，却挂在 runtime 上的平行字段里，于是每条退出 / 超时 / 重启路径都要记得逐个清零，出了状态泄漏再加一个补丁（Expando、请求号）。扩展热更新只能整进程重启，所以副作用会波及所有源。

根本方案：引入不可变的 _SidecarSession {process, port, token, log, proxyPolicy, containment, imageClients, generation}，runtime 只持有一个 Future<_SidecarSession>? 字段；所有退出路径统一走 session.close()，状态切换就是整个对象一次性换掉。页引用和取图请求号都带上 session.generation，失效判断收到同一处，删掉 _pageIssuer 这个 Expando 和 identityHashCode 一类的补丁。sidecar 侧（m_extension_server overlay）给每个扩展单独的 classloader，加 /extensions/<pkg>/unload，invalidateExtensions 只卸对应包，不再 _restart，其它源的在途请求不受影响。readiness 的 200ms 轮询改成 sidecar 端口就绪后主动回报 capabilities。

要动：fushi/lib/src/media/manga/mihon/desktop_mihon_runtime.dart；fushi/lib/src/media/manga/library/online_manga_runtime_adapter.dart；third_party/m_extension_server/overlay/server/src/main/kotlin/mextensionserver/

核验说明：平行可空字段，以及 dispose / exitCode / 两处超时 / _restart 五处手工清零都属实（desktop_mihon_runtime.dart:125-131,559-561,718-720,734-736,766-768,956-959）。Expando _pageIssuer 属实（:145-150）。invalidateExtensions 和 clearSourceData 都走 _restart，也属实（:470-513）。夸大的部分：『_restart 不关旧进程的 _imageClients』。_imageClients 按 requestId 登记，请求结束就移除并关闭（:378-398），不算泄漏。另外 BUG-4917 的根因文档定位在阅读器侧对页引用的所有权，修复也落在阅读器重解析，不是 Expando 的补丁问题。

方案风险：sidecar 给每个扩展单独一个 classloader 并做卸载，属于改 vendored 上游 server 的深度改造：Mihon 扩展共享 OkHttp / Injekt 单例和 ExtensionInstanceCache 的锁，要卸干净可能碰到 classloader 泄漏、静态单例残留。这个风险远大于 M。Android 端怎么热卸载 APK 类加载，也要对齐。

修正后的方案（以此为准）：分两步。① 先做纯 Dart 的 _SidecarSession 不可变对象加 generation（规模 S-M，收益确定），页引用带 generation，删掉 Expando。② per-extension unload 单独立项评估（L），先在 overlay 里做原型验证卸载后没有静态残留，不通过就保留整进程重启，配合已有的页引用重解析机制。

## online-gate-two-axes

**「合规门 × 宿主平台门」要在每个消费端手工拼，漫画没有组合门，各处判法不一致**

- 类型：缺单一登记源；规模 S；价值 medium；不改外部行为
- 核验：部分成立

证据：

- fushi/lib/src/ops/ctl_online_routes.dart:196-216 三种类各自写两段 if；fushi/lib/src/models/app_model.dart:8518-8525 又手拼一次 MihonRuntimeFactory.isSupported 加 capability switch
- fushi/lib/src/settings/settings_schema_system.dart:485-487、fushi/lib/src/media/manga/interconnect/interconnect_online_manga_host_reader.dart:162-165、fushi/lib/src/pages/implementations/browse_online_sources_view.dart:54-57 各自拼一遍
- 漫画没有组合门：manga_online_sources_view.dart:64 只看运行时、:126 只看合规；manga_discovery_page.dart:174 只看运行时；manga_source_catalog_section.dart:365 只看合规。视频和小说则各有一个组合函数（video_online_sources_gate.dart:9-11、novel_online_sources_gate.dart:12-26）

机制：合规判据有单一真相源，但「这个宿主在本平台能不能跑」没有和它绑在一起，每个消费端自己决定问哪一个、按什么顺序问。iOS 上目前碰巧安全，因为 iOS 两个门都不过；但新增入口时只问其一的写法照样能编过，失败是静默的（守卫测试只查 Platform.isIOS）。

根本方案：在第 3 条的 OnlineSourceKind 枚举上集中定义 capability（对应 StoreRestrictedCapability）、hostSupported（MihonRuntimeFactory / isLnReaderRuntimeSupported）、availability（返回 available / storeRestricted / noHost，ops 用来区分 rejected 和 unsupported）和 isAvailable。删掉 video_online_sources_gate.dart、novel_online_sources_gate.dart 里的组合函数，所有消费端只问 OnlineSourceKind.x.isAvailable。在 ios_store_compliance_guard_test 旁加一条守卫：注册表以外禁止引用 MihonRuntimeFactory.isSupported 和 isLnReaderRuntimeSupported。

要动：fushi/lib/src/media/video/online/video_online_sources_gate.dart；fushi/lib/src/media/novel/online/novel_online_sources_gate.dart；fushi/lib/src/ops/ctl_online_routes.dart；fushi/lib/src/models/app_model.dart；fushi/lib/src/settings/settings_schema_system.dart；fushi/lib/src/media/manga/manga_online_sources_view.dart；fushi/lib/src/media/manga/discovery/manga_discovery_page.dart；fushi/test/build/ios_store_compliance_guard_test.dart

核验说明：视频和小说各有一个组合门，而且文件头写着『判据只写在这一处』（video_online_sources_gate.dart、novel_online_sources_gate.dart），说明这是有意的单点。漫画确实没有组合门：manga_online_sources_view.dart:64 只看 MihonRuntimeFactory.isSupported、:126 只看合规；manga_discovery_page.dart:174 只看运行时。这些已验证。不过 iOS 上 MihonRuntimeFactory.isSupported 为 false（Platform.isAndroid || usesDesktopSidecar），两个门在 iOS 上都不过，目前没有错误行为，属于维护性问题，不是 bug。

方案风险：把门挂在 OnlineSourceKind 上就要依赖第 3 条的枚举合并，耦合进了大改。ops 需要区分 rejected 和 unsupported 是合理的。守卫『注册表以外禁止引用 isSupported』会命中 MihonManager / 工厂内部的合法用法，白名单要写清楚。

修正后的方案（以此为准）：不必等第 3 条。先补 manga_online_sources_gate.dart（onlineMangaSource.isAvailable && MihonRuntimeFactory.isSupported），漫画各消费端改问它；三个组合门再合成一个 onlineSourceAvailability(kind)，返回 available / storeRestricted / noHost。守卫对 media/、pages/、ops/、settings/ 禁止直接引用两个平台门，工厂和 gate 文件本身放进白名单。

## web-browser-shell-rebuild

**内置浏览器：前台标签页每次进度变化、焦点或查词状态变化都 setState 重建整个 3049 行的外壳**

- 类型：性能；规模 M；价值 medium；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/pages/implementations/fushi_web_browser_page.dart:1163-1173 _onActiveTabChanged 对任何 tab 通知都调 _rebuild()（:1147-1149 即 setState(() {})）；:1038-1039 地址栏焦点和查词控制器也挂在 _rebuild 上，:1022 每个 feature 的 actionsChanged 也是
- fushi/lib/src/web_browser/tab_view/web_browser_tab_view.dart:1395-1396 onProgressChanged 每个百分点调一次 _tab.update(progress:)；fushi/lib/src/web_browser/tabs/web_browser_tab.dart:127-159 进度一变就 notifyListeners
- FushiWebBrowserPageState 有约 30 处 setState（:1296-1300 的滚动收起已经做过「只在折叠态翻转时 setState」的局部优化，说明作者意识到了热点，但其它通知源没有同样处理）；_buildTabBody（:2388）才用 ListenableBuilder，顶栏、标签条、侧栏、底栏都跟着整页重建

机制：一个 State 同时持有十几个独立的 UI 状态（抽屉、网格、侧栏宽、书签星标、全屏、收起、标签样式……），通知源都接到同一个 setState，没有按「谁在用这个状态」拆开订阅范围。页面加载期间每个进度百分点、每次输入焦点变化都会重建顶栏、标签条、侧栏和底栏。这是代码路径推断，没有帧耗实测。

根本方案：把外壳拆成按状态订阅的子组件：进度条和地址栏用 ListenableBuilder，或者 select 到 tab 的 (url, progress, title) 子集；标签条只订 tabs 的列表结构；书签星标、全屏、收起各做成 ValueNotifier 加局部 builder。WebBrowserTab 把 progress 拆成单独的 ValueListenable，不再走整对象的 notifyListeners。外壳 State 只保留布局级状态（侧栏开合、标签样式）。顺带把 3049 行按 shell / 顶栏 / 标签条 / 侧栏拆成独立文件，不用 part 互相伸手。

要动：fushi/lib/src/pages/implementations/fushi_web_browser_page.dart；fushi/lib/src/web_browser/tabs/web_browser_tab.dart；fushi/lib/src/web_browser/tab_view/web_browser_tab_view.dart

核验说明：已验证：_onActiveTabChanged 无条件 _rebuild（fushi_web_browser_page.dart:1167-1173），_rebuild 就是 setState(() {})（:1147-1149）；_addressFocus、_lookup 和每个 feature 的 actionsChanged 都挂在 _rebuild 上（:1022,1038-1039）。onProgressChanged 每个百分点都会 _tab.update(progress:)（web_browser_tab_view.dart:1395-1396），WebBrowserTab.update 只要值变就 notifyListeners（web_browser_tab.dart:127-159）。帧耗没有实测，属推断。

方案风险：拆成多个文件时，仓库 UI 硬规则要求保留现有动效（FushiMotion）和工具栏 adaptiveOverflow 的行为。_applyFullscreenDisplay / _refreshBookmark 这类副作用目前搭在同一个通知上，拆订阅时不能漏掉。

## browser-ext-settings-handcopied

**浏览器扩展设置项在 JS 与 Dart 各手写一份，靠正则解析 options.js 的守卫测试兜一致**

- 类型：守卫代替结构；规模 M；价值 medium；不改外部行为
- 核验：部分成立

证据：

- fushi/lib/src/settings/settings_schema_web_browser_extension.dart:21-28 文件头说明「键名、取值、缺省值都以扩展为准」（options.js 的 settingDefaults / selectSettings、subtitle-style.js 的 DEFAULTS / LIMITS、video-shortcuts.js 的 DEFAULT_COMBOS）；:150-178 把 shiftHoverLookup / subtitlePauseOnLookup 等的 fallback 又手写一遍，全文件 1575 行
- tools/browser-extension/options.js:16-40 settingDefaults 才是真值，:115 起是 selectSettings
- fushi/test/pages/web_browser_settings_page_test.dart:306-340 用正则 r'const settingDefaults = Object\.freeze\(\{([\s\S]*?)\n\}\);' 抽 JS 源码来比对缺省值；:406-419 对快捷键默认值做同样的比对；JS 格式稍有变化守卫就会失效或误报

机制：扩展是设置项的真值，但它的元数据（键、类型、缺省、取值范围、选项）是写死在 JS 源码里的常量，没有一份可供机器读取的描述。Dart 侧只能照抄，再用正则守卫追平。每新增一项都要改 JS、Dart 和 omitted 清单三处。

根本方案：在 tools/browser-extension/ 放一份 settings_manifest.json，作为唯一真相源：每项写明 key / type / default / options / limits / group / i18n key / appOmittedReason。options.js、subtitle-style.js、video-shortcuts.js 启动时从它读缺省值（打包阶段可内联成 JS 模块）。Dart 侧经资产或构建时生成的 const 表读取，settings_schema_web_browser_extension.dart 只留「manifest 项 → 控件」的通用映射和少量 app 桥接项，删掉逐项手写的 fallback 和 kWebBrowserExtensionOmittedSettings。正则守卫改成对 manifest 做 schema 校验。以后新增一项只改 manifest。

要动：tools/browser-extension/options.js；tools/browser-extension/subtitle-style.js；tools/browser-extension/video-shortcuts.js；fushi/lib/src/settings/settings_schema_web_browser_extension.dart；fushi/test/pages/web_browser_settings_page_test.dart

核验说明：已验证：Dart 侧手抄了一份，web_browser_settings_page_test.dart:306-312 用正则从 options.js 里抽 settingDefaults 来比对。不过扩展本身作为 assets/browser_extension/ 随 app 打包（pubspec.yaml:291-293），Dart 读 manifest 资产是可行的，方案方向成立。

方案风险：扩展运行时在 options 页和 service worker 里异步 fetch JSON，会让缺省值变成异步，影响 background.js 的同步初始化；fushi-defaults.js 已经用 self.X = {...} 加 importScripts 的同步模式。另外设置键名同时落在 chrome.storage 和 web_browser_extension_storage 偏好里，属于冻结的持久化名，manifest 化时键名必须原样保留。

修正后的方案（以此为准）：真相源做成 settings-manifest.js（self.FUSHI_SETTINGS_MANIFEST = Object.freeze({...})，同步、可 importScripts，与 fushi-defaults.js 同一模式），options.js / subtitle-style.js / video-shortcuts.js 从它取缺省值。Dart 侧用一个生成脚本（fushi/tool/ 下）把它转成 const 表，生成物入库，再由 CI 守卫比对『重新生成后无差异』，代替正则抽源码。键名一个不改。

## 核验补充（审计漏掉的）

- LNReader 插件已经有 hasUpdate（fushi/lib/src/media/novel/online/lnreader_manager.dart:548），但没有接进 UpdateFeed 调度（fushi/lib/src/models/app_model.dart:2204-2220）。能力是现成的，只是没注册，这可以作为第 1 条里成本最低、能单独先做的一步（已验证存在；有没有 UI 入口没细查）。
- manga_download_service.dart 整章下载途中碰上 sidecar 重启，旧页表会失败，只能靠一般失败的退避重试来续（BUG-4917 备注第 9 行写明未改）。页引用失效重解析只在阅读器会话里做了，下载路径没做，同一个所有权问题只修了一半（依据 BUG 文档，代码未逐行核验）。
- 文件持久化的失败语义问题不只在 LNReader：cookies.json（MangaCookieJar，online-sources.md:6 描述了『加载遇 IO 失败不当空 jar』的自研逻辑）、音乐插件存储（<数据库目录>/music_plugins/，同样不进 Drift）、feedback tickets.json，都各自实现了一遍原子写和读失败态。应该抽成一个共用的 JsonFileStore，而不只是迁 LNReader（推测，未逐一读代码）。
