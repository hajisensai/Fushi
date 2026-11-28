# 全仓架构重构总方案（2026-11-28）

起因：用户要求重新设计互联、CLI、媒体存储、存储显示以及其余一切该重构的部分，解决性能、可维护性和设计问题，不打补丁。

依据：20 个域的只读审计，每域一个独立反驳核验，共 142 条发现，核验没有驳回任何一条（约一半判「部分成立」，方案以核验修正版为准）。逐条的证据 `file:line`、机制、方案、风险在 [docs/reviews/2026-11-28-architecture-audit/](../reviews/2026-11-28-architecture-audit/)，本文只写归并后的结构与顺序，条目用 `域/发现 id` 引用。

本文是方案，不是已完成的工作。各工作流的状态见 §5。

## 1. 十个反复出现的机制

142 条发现归到十个机制上。按类解决的意思是修这十个机制，而不是修 142 处。

| # | 机制 | 表现 | 根本解 |
|---|---|---|---|
| M1 | 同一事实没有单一登记源 | 偏好键属性 7 处以上清单；受管目录 5 处；路由 / 鉴权豁免 / 能力位三张表；一个操作写三遍；原生 crate 约 20 处接线 | 每类事实一张声明表，其余全部从它派生；穷举由类型保证 |
| M2 | app 与 `fushi_server` 各写一套 | host 装配、host 生命周期、来源扫描器、下载运行时、查词管线、admin 路由、CLI 框架、自更新 | 能力实现进 `fushi_engine`，宿主只注入端口；钩子三态（已接 / 不适用 / 未接）用类型表达 |
| M3 | 上帝对象 | `AppModel` 1.7 万行、阅读器 State 3.3 万行、视频播放页 2.8 万行、漫画页 1 万行、下载管线 6070 行、`FushiSyncServer`、`InterconnectSyncBackend` | 按职责拆成自带状态的对象，页面与宿主只做装配 |
| M4 | 隐式状态机 | 阅读位置 12 处直接写、换集 97 处代次比较、有声书控制器约 20 个布尔旗、四套 seek 落地启发式 | 纯 Dart reducer 加 sealed 事件，状态只有一个所有者 |
| M5 | 镜像状态靠手动失效 | 切 Profile 五张刷新清单、SRS 手动递增修订号、能力位 6 处各自缓存、视频库页自拼投影 | 源头发类型化变更流，镜像订阅或现读 |
| M6 | 持久化模型本身分叉 | 库里存绝对路径；状态塞在偏好表；有声书两套实体；漫画进度两张表；视频进度写 4 处；下载两套任务系统 | 改模型：逻辑路径、专用状态表、单一实体、单一进度仓 |
| M7 | 用源码文本守卫兜结构 | 上千个 grep 守卫，还为此长出词法器和元守卫 | 能由类型 / 构造器 / analyzer lint 保证的改成由它们保证，守卫只留真正跨语言的 |
| M8 | 性能通病 | 任一偏好写入重建整个 app；存储页全树扫描；UI isolate 上同步 FFI / IO；每调用起一个 isolate；轮询扇出 | 按键信号、区域快照、常驻 worker、事件代替轮询 |
| M9 | FFI 与原生构建各写一套 | 每个 crate 自定 C ABI 约定、7 份加载器、约 45 份构建脚本 | 共用 ffi 核心 crate、一个加载器、一张 crate 登记表 |
| M10 | 跨边界协议没有定义 | 阅读器 / 漫画 / 查词弹窗的 JS 桥、平台通道、Worker 线协议、种子状态字符串、按正则解析 Rust 报错 | 单一协议声明，两侧代码由它生成或校验 |

## 2. 工作流

每个工作流是一组必须一起设计的发现。标 **拍** 的含持久化 / wire / 用户可见变化，开工前要先拍板（§4）。

### A. 互联 host（interconnect-host）

- **A1 声明式端点表**：`InterconnectHostModule` 给出 `List<InterconnectRoute>`，每条声明方法、路径、信任级（含 `pairingBootstrap`）、传输要求、handler；能力位由模块给出。`FushiSyncServer` 只剩分发、判门、拼能力文档三个循环。先把 `/api/capabilities` 全表做成逐字节快照，再逐类迁移，最后删 `_handleRequest` 的分支链、`_kPublicRoutes`、能力位手拼段。加通用守卫禁止新增手写 `reqPath` 分支。（host-route-registry-split）
- **A2 调用者身份**：中间件解析一次 sealed `InterconnectCaller` 放进 request context，判门顺序固定；凭据源故障回 503 而不是 401。已有端点保留原状态码与 body。**拍**（caller-identity-trust-gates）
- **A3 能力位即模块存在**：`FushiLibraryHostService` 按功能拆成模块，装配期依赖全部 required，不齐不注册；运行时开关留在 `capability()` 现算。逐键保留「false」与「缺键」两种形态。（capability-from-type-test、capabilities-client-schema）
- **A4 宿主装配**：不可变 `FushiHostAssembly`，钩子是 sealed `HostSlot`（已接 / 不适用 / 未接），`server-parity-gaps.md` 的钩子表由它生成。`InterconnectHostRuntime` 收编 P2P 挂接、配对落库、凭据加载。`EngineHostBindings` 一次安装、每个 isolate 入口显式调用。（host-assembly-nullable-hooks、host-lifecycle-runtime-fork、engine-global-host-bindings）

### B. 互联 client 与同步（interconnect-client）

- **B1 同步种类登记表**：`fushi_engine/lib/sync/kinds/` 的 `SyncKind` 描述表，host 的路由分派与 client 的编排都从它派生；通道拆成同步语义（`LiveHost` / `FileStore`）和资产层（`AssetStore`）。（sync-kind-registry-missing）
- **B2 清单类内核**：`ManifestKind<M>` 加统一 runner，runner 负责错误边界与锁边界。云端标签同步是功能扩展，单列拍板。**拍**（manifest-kind-kernel）
- **B3 进度类内核**：`RegisterSyncKernel<V>` 先覆盖书 / 播放位置 / 章级三份 live 实现，云通道作为不支持前置条件写的远端接入；基线维度键不迁。（register-three-way-kernel）
- **B4 唯一传输层**：`InterconnectSyncBackend` 内部先改走 `InterconnectHostChannel`，再按域拆成薄 endpoint 客户端。能力探测收成 `HostCapability` 枚举加一份缓存。（interconnect-transport-triplicate、capability-registry）
- **B5 host 身份**：`HostIdentity` 值类型，读时归一；连上后拿到真实 hostId 再在一个事务里补行并迁移词典元数据、profile 键与基线槽，不自造 id。**拍**（host-identity-recipes）
- **B6 同步计划**：`SyncPlan` 由 `dependsOn` 与类型化阶段产物拓扑排序，`SyncStageRunner` 统一错误边界。（sweep-plan-as-code）
- **B7 备份合并复用内核**：每种 kind 迁过去时与现有 SQL 结果对照后再删 SQL。（backup-merge-reimplements-sync）

### C. 操作目录与 CLI（cli-ops）

- **C1 `OpSpec`**：路由 handler 与描述合并成一个声明；`CtlServer` 与 `OpInvoker` 共用 `OpArgs.parse`。CLI 的 flag、位置参数、别名是用户脚本面的契约，保持不变，手写命令只引用 `OpSpec` 常量。HTTP 未知参数先告警不拒绝。（op-triple-declaration、spec-validation-bypassed-on-http、stringly-route-refs-and-name-regex-guard）
- **C2 服务端 admin 改路由表**：共用 shelf 分发器，`OpSpec` 加 raw 变体给上传、流式代理、文件下载；删 `_forward`。迁移前录现有回包。（server-admin-hand-router-plus-forward-shim）
- **C3 跨宿主能力只写一份**：`build<Cap>Ops(host)` 放引擎，app ctl / server admin / 互联 host 共用，先做订阅。回包取并集形状，只增不减。**拍**（capability-routes-three-hosts）
- **C4 一个 CLI 框架**：`CtlTransport` 三个实现，命令表编译期共享，退出码取值不变，帮助文本双语。**拍**（two-cli-frameworks）
- **C5 门**：模块门由分发层执行；只读门下沉到存储写入层，UI / 后台 / ops 共用。（cross-cutting-gates-in-handlers）
- **C6 撤销**：`ConditionalRestore` 按后端注入（数据库同事务 CAS、偏好带版本写、Rust 子系统由内核提供条件写），声明 `ownedFields`。（undo-read-compare-write-toctou）

### D. 存储：路径、受管区域、占用（media-storage、storage-display）

两个域审出的「受管目录登记表」是同一件事，合并做。

- **D1 `StorageArea` 登记表**：引擎层值类型（id、根、相对路径、旧名、类别、生命周期、是否随数据根迁移），app 与服务端各自在装配期登记。数据根迁移白名单、存储类目、内容对账、证据豁免、`ServerPaths` 全部从它派生。区域所有者负责枚举条目、给出条目级可删性和删除原语。（managed-area-registry、storage-area-registry、cleanup-policy-scatter、scanner-rederives-owner-paths）
- **D2 逻辑路径 `StoredPath`**：库里存「根 id + 相对路径」，wire 形态用固定前缀的 URI 风格以免与盘符撞形；`content://`、`http(s)` 原样保留；用户命名的外部库根可重映射。换数据根、备份恢复、服务端换挂载点都不再改库。前置项：备份格式显式版本与向下兼容策略。**拍**（absolute-path-persistence、backup-restore-rebase-fork、server-no-path-relocation、picked-video-copies-support-root）
- **D3 受管文件账本**：`managed_files` 加 `managed_file_refs`，引用计数为 0 转待删，由单一回收器删除；对账扫描保留但降频。**拍**（ownership-by-prefix-and-fullscan-gc）
- **D4 占用快照服务**：单一后台扫描，按区域分层快照，按区域失效；设置页、ctl、服务端 admin 消费同一份报告。不迁 Rust（IO 型，无实测依据）。（full-walk-no-cache、three-surfaces-diverge）
- **D5 专属临时根**：`appScratchDirectory(purpose)`，桌面端独占子目录；移动端保留系统托管语义。（unowned-temp-root）

### E. 媒体库模型（library-model）

- **E1 扫描引擎进引擎**：先拆 `source_library_scanner.dart` 对 UI、i18n、pdfrx 的依赖，纯判据先下沉，其余做成端口。（dual-scanner-fork）
- **E2 `SourceKindSpec`**：只含领域属性，缺失策略按宿主取值；UI 能力表留在 app。（kind-registry）
- **E3 `source_entries` 表**：来源与条目的成员关系一张表，设备本地，排除出 Profile 快照 / 同步 / 备份。**拍**（source-membership-table）
- **E4 视频入库单一入口**：按身份类别分 `admitLocalFiles` / `admitDiscTitles` / `admitRemoteReferences`，共用事务落库。（video-intake-single-entry）
- **E5 入库后增强队列**：持久作业表，宿主各起一个 worker；增量单位是归组单元。**拍**（enrichment-owned-by-ui-and-no-incremental）
- **E6 有声书种类**：正式种类还是书的附加能力，二选一。**拍**（audiobook-ingest-two-models）

### F. 偏好、启动与全局状态（startup-appmodel、database）

两个域对偏好的发现重叠，合并做。

- **F1 `PrefKey` 登记表**：`fushi_core` 里每个键声明类型、默认值、正交策略（随 Profile、可同步、进备份、凭据、设备本地）、类别（设置 / 状态）、动态键族。各通道名单由它派生，派生结果与现行名单一致后才删旧名单。存量键名不改。（pref-key-registry、pref-key-scope-scattered-lists、table-fate-registry）
- **F2 `PrefsCore`**：进程内唯一已解码缓存，作品叠加层是它上面的视图；按「生效值变化」发按键信号。（pref-mirror-caches）
- **F3 去掉全局广播**：`prefProvider(PrefKey)` family；根 `FushiReaderApp` 只 watch 派生 provider，副作用改 `ref.listen`；页面逐页迁移后加守卫。（global-pref-broadcast-rebuild、pref-global-broadcast）
- **F4 偏好快照替换事件**：切 Profile、设置同步导入、弹窗热复用、作品叠加层进出、备份恢复都发同一个事件，镜像登记后订阅。（profile-switch-mirror-refresh-list）
- **F5 状态搬出偏好表**：第一步按键类别决定是否抬 `prefs_version`；第二步迁专用表。**拍**（prefs-table-as-state-store）
- **F6 `DatabaseSession` 与启动任务表**：绑库资源在 session 上登记、逆序关闭；启动改成声明式任务表，三个入口是同一张表的子集，runner 统一面包屑、打点、超时；一次性迁移进引擎，app 与服务端共用。（db-bound-lifecycle-manual-teardown、startup-imperative-await-chain、inbound-intent-queues-in-root）
- **F7 拆 `AppModel`**：按域拆成 provider 装配的服务，每批删干净旧委托。（appmodel-god-object）
- **F8 数据库层**：索引用 `@TableIndex` 声明；当前 schema 快照加「最老 fixture 升级后与新装库等价」守卫；开库与恢复合并成后台 isolate 的单次打开。（index-declarations-handwritten、migration-ladder-patch-stack、double-open-single-connection）

### G. 阅读器（reader）

- **G1 `ReadingPositionMachine`**：位置唯一所有者，含引擎丢失 / 加载失败事件。（reading-position-multi-owner）
- **G2 JS 引擎成为真源码**：移到 `assets/reader_engine/`，core 加三种 view mode 策略，接口齐全性在 headless 测试里对三种 mode 各断言一次；引擎注入合并成一次 evaluate。（js-shells-no-contract、reader-engine-js-as-strings）
- **G3 桥协议**：sealed `ReaderJsEvent` 单一声明，信封带文档 id 与代次，歌词 WebView 共用路由。（bridge-no-protocol）
- **G4 字符坐标**：Dart 侧 extension type 区分口径；映射表由 sanitizer 在产出章节 HTML 的同一次扫描里生成。（char-coordinate-systems）
- **G5 `OpenedEpubBook`**：打开、回退、路径解析一个对象，全部在后台 isolate。（epub-model-logic-in-page）
- **G6 拆 State**：G1～G5 落地后按子域拆 controller。（reader-state-god-object）

### H. 视频（video）

- **H1 `VideoProgressStore`**：唯一进度仓，策略按后端声明；旧偏好键在兼容窗口内单点双写。**拍**（video-progress-single-store）
- **H2 `VideoEpisodeSession`**：本集状态一个对象，换集即换会话。（episode-session-lifecycle）
- **H3 `SubtitleTrackRef`**：sealed 类型加 codec，对现存持久化值完全向后兼容。（subtitle-slot-typed-source）
- **H4 `SeekTracker`**：四套守卫归并成一个；mpv 独立事件队列先做 spike。（seek-landing-patch-stack）
- **H5 `VideoLibraryProjection`**：按 uid 增量 patch 的读缓存，后台维护不再挂在页面上。（video-library-projection）
- **H6 `PlaybackHoldSet`**：媒体无关，视频 / 音乐 / 有声书共用。（playback-hold-set）
- **H7 拆播放页**：`VideoPlaybackBackend` 接口每种后端一个实现。（video-page-god-state）

### I. 有声书、ASR 装配、音乐（audiobook-asr-audio）

- **I1 有声书单一身份**：两张表保留，新增稳定 `audiobook_id` 与绑定判别列，迁移回填。**拍**（audiobook-dual-entity）
- **I2 播放状态**：先把调轴写入改成单事务并收敛键前缀；迁专用表另拍。**拍**（audiobook-position-untyped-prefs）
- **I3 播放协调状态机**：先把现有判定与回归用例翻成表驱动测试再切换。（audiobook-controller-flag-state-machine）
- **I4 `ModelAssetManager`**：只管单飞、依赖顺序、进度、取消；就绪判据由各 provider 实现。（model-provisioning-duplicated）
- **I5 其余**：书架探盘移后台且只探一次；音乐刮削整次只建一份 scraper；远程音乐扫描跳过未变的 cue 与播放列表；`fushi-subtitles` 版本用根 `dependency_overrides` 加一条升级命令。（srt-listall-sync-stat-every-path、music-scrape-per-track-no-memo、remote-music-scan-refetch-cue-playlist、fushi-subtitles-sha-multi-pin）

### J. 词典与查词（dictionary-lookup）

- **J1 `LookupDocument`**：唯一规范模型，后台 isolate 构建一次，弹窗 JSON 与条目列表都从它投影；持久化字节不变。（lookup-document-multi-builders）
- **J2 `LookupQuery` 与本地管线**：app 与服务端共用一条管线；服务端查词移出 HTTP isolate。（remote-lookup-probe-interface-stack、dictionary-visibility-layered-filter）
- **J3 引擎装载**：`EngineLoadSpec` 派生值决定是否重装，纯显示设置不触发；装载移后台。（engine-reload-on-every-metadata-write、sync-tokenize-on-ui-isolate）
- **J4 弹窗桥与显示设置**：桥清单与显示设置描述表各一张，注入 JS、扩展编码都由它派生；现有 `--fushi-*` 键冻结。（popup-bridge-protocol-no-registry、popup-display-settings-handwritten-schema）

### K. 复习、制卡、Anki（srs-dart-mining-anki）

- **K1 `SrsCollection` 窄接口与类型化 op 目录**：取代 `noSuchMethod` 冒充，握手回报支持的 op 集合。（srs-remote-store-nosuchmethod-facade）
- **K2 `MiningDestination`**：sealed 三种目标加唯一解析函数；「开了转发到配对主机」的语义变化单独拍板。**拍**（mining-destination-as-anki-decorator）
- **K3 内核视图与变更流**：内核加牌组树 / 笔记类型视图命令；库自己发类型化变更流，删手动递增的修订号。（srs-dart-materialization-mirror、srs-manual-revision-signal）
- **K4 内核 op 目录**：内核事实在 Rust 维护并生成 Dart 枚举，宿主策略留 Dart。（kernel-op-catalog-duplicated-in-dart）
- **K5 `FushiFieldRole`**：字段角色单一枚举，别名表合一。（card-field-role-tables-scattered）

### L. 漫画与 OCR（manga-ocr）

- **L1 漫画进度单表**：章级表为唯一真相源，本地卷视为单章作品。**拍**（manga-progress-two-tables）
- **L2 OCR 引擎流水线**：整卷流水线与逐页缓存只写一份，引擎身份单一枚举。**拍**（ocr-engine-pipeline-per-engine-copy）
- **L3 ONNX 后端统一**：app 改用已有的 `dart:ffi` 后端，删带 19 个补丁的插件。（onnx-two-backends-plugin-patch-stack）
- **L4 其余**：页图不再整块过平台通道；PDF 栅格化移出 UI isolate；漫画 JS 桥类型化；NFKC 表合一；拆漫画页 State。（manga-page-bytes-through-plugin-channel、pdf-raster-dart-ui-app-only、manga-js-bridge-untyped、nfkc-multiple-partial-copies、manga-reader-god-state）

### M. 在线源与浏览（online-sources-browse）

- **M1 扩展管理一套**：Mihon 与 LNReader 共用仓库 / 目录 / 安装 / 更新。**拍**（online-host-twin-stacks）
- **M2 源偏好单一真相源**与 **LNReader 状态入库**。**拍**（source-prefs-dual-truth、lnreader-handrolled-persistence）
- **M3 其余**：目录取数与 Widget 分离供 ops 复用；sidecar 会话对象；合规门与平台门的组合门；浏览器外壳按粒度重建；扩展设置项单一描述表。（ops-reimplements-catalog、sidecar-session-state、online-gate-two-axes、web-browser-shell-rebuild、browser-ext-settings-handcopied）

### N. 下载与 BT（downloads-torrent）

- **N1 删旧 JSON 计划系统**。**拍**（dual-download-job-systems）
- **N2 resume 保留集合由登记派生**；**种子状态类型化**；**后端能力单层**。**拍**（resume-keepset-hand-union、stringly-torrent-state、backend-capability-double-layer）
- **N3 种子快照总线**：一处轮询、多处订阅。（poll-fanout-full-list）
- **N4 下载运行时装配进引擎**。**拍**（app-server-download-runtime-fork）
- **N5 拆管线**：特例收成按内容形态的策略；命名规则单一实现。（pipeline-god-object-special-branches、organize-naming-duplicated）

### O. UI 与设计系统（ui-design-system）

- **O1 删隐藏设计系统的死路径**。（dead-hidden-design-systems）
- **O2 皮肤分支收进组件**：功能页不再出现 `isGlassDesign`。（skin-branch-leaks-into-features）
- **O3 设置项只声明一次**：UI、ctl、设置搜索同源。**拍**（settings-body-escape-hatch-dual-declaration）
- **O4 快捷键分派计划**单表。**拍**（shortcut-dispatch-plan-scattered）
- **O5 原生表面焦点回收**统一机制；**动效时长** helper 合一。（native-surface-focus-reclaim-per-page、motion-gating-two-helpers）

### P. 工程基础设施与原生（i18n-tooling-tests-ci、native-rust-ffi）

- **P1 analyzer lint 取代文本守卫**：分批迁移，每批对应的守卫在 lint 生效后删除。（text-guards-instead-of-analyzer-lints）
- **P2 原生 crate 登记表**：接线、硬依赖判定、构建矩阵、ABI 校验都由它派生。（native-crate-registry 两条、build-script-matrix、native-source-key-triple-impl）
- **P3 FFI 核心**：共用 ffi 核心 crate（状态码、报错通道、缓冲区所有权、ABI 握手）、一个 Dart 加载器、常驻 worker；fsrs 类型化错误不再靠正则。**拍**（rust-ffi-core-crate、dart-native-loader-dup、ffi-async-per-call-isolate、fsrs-error-by-regex、ffi-marshalling-boilerplate）
- **P4 四端合成一个 cdylib**：等 P2、P3 之后评估。（single-native-cdylib）
- **P5 CI**：桌面构建 job 复用；工具链钉版单一来源；i18n 按域拆文件另拍。（desktop-workflow-fork、toolchain-pin-copies、i18n-monolith-merge-driver）

### Q. 统计、AI、排行榜服务与其余（stats-ai-leaderboard-misc）

- **Q1 自更新栈合一**。（update-stack-fork）
- **Q2 统计事实面常驻**：共享缓存加增量失效。（stat-facts-no-resident-state）
- **Q3 平台通道协议单一声明**。（platform-channel-no-contract）
- **Q4 其余**：诊断日志设施合一；app 与 Worker 线协议常量同源；Worker 路由表；AI 协议适配器。（diag-log-copy-paste、app-worker-wire-contract-dup、worker-route-table、ai-wire-protocol-switch-scatter）

## 3. 顺序

依赖决定顺序，不按域轮流做。

1. **第 0 批：现存 bug**。审计与核验顺带确认的 bug，按 bug 流程直接修，不等任何重构（§5）。
2. **第 1 批：登记表与地基**，后面几乎所有工作流都依赖它们，且都不改外部行为：F1 `PrefKey`、D1 `StorageArea`、A1 端点表与能力快照、C1 `OpSpec`、P2 crate 登记表、F6 `DatabaseSession`、P1 lint 基础设施。
3. **第 2 批：建在地基上的内核**：F2～F4、A2～A4、B1～B4、B6、C2、C5、D4、D5、E1、E2、E4、J1～J3、K1、K3、K4、G1～G3、H2、H4、H6。
4. **第 3 批：改持久化模型**（拍板后）：D2、D3、E3、F5、H1、I1、I2、L1、N1、B5。每项带迁移、旧版本兼容与备份格式策略。
5. **第 4 批：拆上帝对象**：F7、G6、H7、L4 的漫画页、N5、O2。前面的内核落地后才拆，否则只是把耦合换个文件。

每个工作流一个或多个 PR，各自带定向测试；不留双轨，迁一类删一类。

## 4. 需要拍板的事项

拍板台 id 前缀 `design-arch-`，2026-11-28 全部拍完：

| 事项 | 结果 |
|---|---|
| `batch-order` 按五批顺序开工 | 做 |
| `stored-path` 库里路径改「根 + 相对路径」（D2、D3） | 做 |
| `state-out-of-prefs` 进度等状态搬出偏好表（F5、H1、I2、L1） | 做 |
| `entity-merge` 有声书单一身份、删旧下载计划系统（I1、N1） | 做 |
| `cloud-tags` 云盘通道同步标签（B2） | 做 |
| `audiobook-kind` 有声书在媒体库里算什么（E6） | a：独立库种类 |
| `mining-forward` 制卡目标各处统一显示（K2） | 做 |
| `host-identity` 老配对条目补真实 hostId（B5） | 做 |
| `hidden-design-systems` 隐藏的 Cupertino / macOS 渲染器（O1） | a：整删 |
| `i18n-split` i18n 源文件按域拆分（P5） | 做 |

**只迁移一次**（用户在 `entity-merge` 下的留言：「我们不发版就只有一次迁移吧。其他的也是」）：改持久化的工作流在同一个发版周期内全部落地，期间不发正式版；schema 迁移合成一级台阶，旧数据兼容只考虑「上一个正式版 → 重构完成版」这一跳，不为中间形态写迁移。第 1、2 批不加 schema 台阶。

其余含用户可见变化、当时给不出具体取舍的工作流（M1、N4、O3、O4 等），开工前各自再上一条。

## 5. 状态

| 项 | 状态 |
|---|---|
| 审计与核验 | 完成，原始结论在 `docs/reviews/2026-11-28-architecture-audit/` |
| 本方案 | 已拍板（§4） |
| 第 0 批 bug 修复 | 进行中，见各自 PR |
| 第 1 批 | 进行中：F1、D1、A1、C1、P2、F6、P1、O1 各自独立 PR |
| i18n 拆分（P5） | 等第 1 批的 PR 合完再做，避免与它们的 i18n 改动冲突 |
| 第 2 批及以后 | 未开始 |
