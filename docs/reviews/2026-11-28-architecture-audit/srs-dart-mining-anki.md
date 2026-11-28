# 架构审计：srs-dart-mining-anki

2026-11-28 只读审计 + 独立反驳核验的原始结论。总方案见 [../../specs/2026-11-28-architecture-redesign.md](../../specs/2026-11-28-architecture-redesign.md)。

## 现状

完成（只读审计，未改文件、未跑测试）。复习域现状：Rust 内核 native/fushi_fsrs 独占 srs.db 连接，Dart 侧 SrsCore（packages/fushi_srs/lib/src/store/srs_core.dart）只发 `{'op': ...}` JSON 命令，放在常驻 worker isolate 池里跑（srs_core_workers.dart），主 isolate 上没有发现同步 SQL。但 SrsDbStore（packages/fushi_engine/lib/srs/srs_db_store.dart，7188 行，类体从 :496 起，约 250 个成员，另有 7 个文件挂扩展）仍然是一个上帝对象。它在 Dart 里把牌组树和笔记类型重新物化一遍（读身份记录和修改记录 → 再交回寄存器内核），并带着一串按内核修订号失效的缓存镜像。笔记这一类已经在 BUG-5572 里改成由内核 note_views 一跳物化，牌组和笔记类型还走旧的两跳。远程复习靠 SrsRemoteStore「implements 具体类 SrsDbStore + noSuchMethod」来冒充本地库，两端的操作名都是手写字符串，一致性靠正则扫源码的守卫兜着。内核命令的分类（改投影 / 免锁 / 带缓存配置 / 分道 / 远程白名单）在 Dart 里又抄了一份，也是正则守卫在和 Rust 对齐。制卡目标方面：「Fushi 复习」被做成一个冒充 Anki 仓库的装饰器（SrsMiningAnkiRepository extends DelegatingAnkiRepository）。装饰链在 app 里有 3 处装配，主机侧的分派 app 和 fushi_server 各写一套，「是不是发往复习」的判据至少手写了 7 处，相关 bug 记录有 9 条。界面刷新靠一个手动递增的无类型信号 srsRevisionProvider，同步自唤醒、整页重建、外部变更收不到这几类问题反复出现。卡片字段角色（Lapis / Fushi 卡片字段名、默认映射、字段说明、编辑页主字段、可视分组、字段名猜角色的启发表）散在 6 处以上，其中两张启发表对同一个字段名给出相互矛盾的结论。app 和服务端的同步一轮、发布 profile 说明文件已经收进 fushi_engine 共用（srs_location_runner.dart、srsPublishProfileInfo），卡面模板渲染和字段合成（renderAnkiCard、AnkiNoteComposer）也是共用的，这几块不算问题。

## srs-remote-store-nosuchmethod-facade

**远程复习库靠 implements 具体类 SrsDbStore + noSuchMethod 冒充本地库，一致性只有正则守卫和一份手写的可达页面清单在兜**

- 类型：守卫代替结构；规模 XL；价值 high；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/srs/srs_remote_store_client.dart:253 `class SrsRemoteStore implements SrsDbStore, SrsRemoteForwarding`：implements 的是 7188 行的具体类
- fushi/lib/src/srs/srs_remote_store_client.dart:539 `noSuchMethod` 统一抛 UnsupportedError；:549、:556 还有两处手写抛错，没覆盖的成员要到运行时才炸
- fushi/test/srs/srs_remote_store_parity_guard_test.dart:18-56 手写了 36 个可达页面 / 引擎文件；:74-95 用正则 `^  (?:Future<.*?>|Stream<.*?>|bool|int|String\??|...)` 从源码里抠成员名，返回类型不在白名单里的成员会被漏掉
- packages/fushi_engine/lib/srs/srs_remote_store.dart:1444 主机 `_ops` 是 Map<String,_Op>，键 'deckSummaries' / 'studyState' / 'cardRows'；客户端 fushi/lib/src/srs/srs_remote_store_client.dart:661、:702、:728 把同样的字符串再写一遍，编解码两边各写一份
- packages/fushi_engine/lib/srs/srs_remote_store.dart:114 `SrsRemoteForwarding`：扩展方法直接读库，所以要求它们在开头手动转发，守卫第 2 条专门查这件事
- docs/bugs/BUG-3981-srs-remote-review-scope-leak-and-browse-ops.md、BUG-4480（:4 记着主机侧 srs_remote_store.dart:1084 不核对请求里的 id 属于哪份 profile）

机制：页面的类型写的是具体类 SrsDbStore，远程实现只能 implements 它整个 250 个成员的面，再拿 noSuchMethod 兜底，编译器管不住「远程这边到底支持什么」。操作名、参数和回包形状在主机分派表和客户端 stub 里各写一次，没有共同的类型源，只能靠扫源码的正则守卫加一份手维护的页面清单来对齐。新页面没加进清单、扩展方法忘了转发、成员的返回类型正则没覆盖，都是绿灯放过、到运行时才坏。

根本方案：在 fushi_engine/srs 里新建一个窄接口 `abstract interface class SrsCollection`，只放复习会话可达的能力（排队、作答、渲染、笔记编辑、牌组设置、浏览），由一份类型化的操作目录 `srs_collection_ops.dart` 定义：每个操作是一个 `const SrsCollectionOp<Req, Res>(name, encodeReq, decodeReq, encodeRes, decodeRes, write: bool)`。主机分派表（取代 `_ops`）和客户端 stub（取代 SrsRemoteStore 的 81 个手写 override）都从这份目录生成，也可以由 build_runner 生成一个 `SrsCollectionRemote implements SrsCollection`。SrsDbStore 改成 `implements SrsCollection`，可达页面的参数类型从 SrsDbStore 改成 SrsCollection，页面里调了接口外的成员就编译不过。扩展方法里需要读库的部分挪进接口方法（这样 SrsRemoteForwarding 就不需要了）。按 id 的入口统一由接口实现方做 profile 归属校验（顺带收掉 BUG-4480 / BUG-4626 一类问题）。删除：noSuchMethod、srs_remote_store_parity_guard_test.dart 整份（清单和正则）、SrsRemoteForwarding、客户端手写的 op 字符串。以后加一个远程能力，只在操作目录里加一项，再在 SrsDbStore 里实现它。线上的 op 名可以保持不变，复习库协议不用升代。

要动：packages/fushi_engine/lib/srs/srs_db_store.dart；packages/fushi_engine/lib/srs/srs_remote_store.dart；fushi/lib/src/srs/srs_remote_store_client.dart；fushi/test/srs/srs_remote_store_parity_guard_test.dart；fushi/lib/src/pages/implementations/srs/*；packages/fushi_engine/lib/srs/srs_browse*.dart；packages/fushi_engine/lib/srs/srs_note_batch_edit.dart

核验说明：已验证：srs_remote_store_client.dart:253 `class SrsRemoteStore implements SrsDbStore, SrsRemoteForwarding`，:539 noSuchMethod 抛 UnsupportedError，:549/:556 另有两处手写抛错；parity 守卫 fushi/test/srs/srs_remote_store_parity_guard_test.dart:18-56 是手写的 36 项可达清单，_storeMembers 的正则只认 Future/Stream/bool/int/String?/少数具体类型，返回 List/Map/自定义类型的同步成员会漏掉；SrsRemoteForwarding（srs_remote_store.dart:114）就是为了让扩展方法转发。spec docs/specs/2026-11-01-srs-remote-review-design.md:45-46 明写「implements SrsDbStore + noSuchMethod」，属于当初有意的设计，但设计文档并没有排除改用窄接口，不构成反驳。page 目录里引用 SrsDbStore 140 处，迁移面确实是 XL。

方案风险：1) 7 个文件挂在 SrsDbStore 上的扩展方法要整体改挂到 SrsCollection 上，或者挪进接口。否则本地专用的扩展照样能在远程会话里调到，编译期约束只覆盖一半。2) 现在线上 op 的回包大量是 entity_views 原料（payload+edits），由客户端自己物化（见第三条）；目录化以后要先把编解码收成一份，否则只是把两份手写搬进一份 const 表，Req/Res 的形状仍然没有类型源。3) 主机和客户端可能是不同版本的 app，op 目录必须保留「主机缺 op 时 400 → 客户端降级」的现有语义，不能假定两端同时编译。4) 引入 build_runner 生成器之前要先确认 packages/fushi_engine 能用它（engine 禁 Flutter，可以用 build_runner，但这会新增一个构建步骤）。

修正后的方案（以此为准）：保留窄接口 SrsCollection 加类型化 op 目录的方向，补三点：(a) 扩展方法按「需要读库 / 不需要」拆开，需要读库的升成 SrsCollection 的接口方法，其余改挂在 SrsCollection 上，SrsDbStore 专属的扩展另放一个只有本地页面 import 的 library；(b) op 目录的每一项声明最低协议能力位，主机握手时回报自己支持的 op 集合，客户端按集合决定入口显隐，而不是撞上 400 才知道；(c) 不用 build_runner，op 目录写成手写的 const Dart 表（每项带 encode/decode 闭包），主机分派和客户端 stub 都遍历这一张表，客户端只剩一个泛型 `_call<Req,Res>(SrsCollectionOp<Req,Res>, Req)`。

## mining-destination-as-anki-decorator

**制卡目标「Fushi 复习」被做成冒充 Anki 仓库的装饰器：装配散在 app 3 处和主机侧两套，判据手写 7 处，同一机制累计 9 条 bug**

- 类型：成类 bug；规模 XL；价值 high；用户可见
- 核验：成立

证据：

- fushi/lib/src/srs/srs_mining.dart:156 `class SrsMiningAnkiRepository extends DelegatingAnkiRepository`，:704-716 createNoteType / createDeck 抛 UnsupportedError，:746 probeDeckReposition 的注释写着「必须与 supportsDeckReposition 成对覆盖」（BUG-4122）
- fushi/lib/src/anki/delegating_anki_repository.dart:1-10 文件头自己承认「Dart 没有自动转发，漏委派一个成员不会报错」，靠 50 个 override 加 fushi/test/anki/auto_reposition_repository_delegation_test.dart、delegating_capability_probe_pairing_test.dart 两个守卫兜着
- fushi/lib/src/anki/anki_view_model.dart:746、:799、:819（ankiRepositoryProvider / hostMiningAnkiRepositoryProvider / _withSrsMining）和 fushi/lib/src/models/app_model.dart:14054 hostMiningRepositoryForView，一共三处各自拼装饰链
- 主机侧分派写了两套：fushi/lib/src/sync/host_remote_mining_targets.dart:57-200（app）和 packages/fushi_server/lib/src/remote_mining_host.dart:155-260（服务端），默认类别、复习目录、换代拒绝各写各的，只有 resolveRemoteMiningTarget 是共用的
- 「是否发往复习」的判据手写了至少 7 处：srs_providers.dart:71、:81，app_model.dart:14033，stats/study_goals.dart:82，platform/widget_snapshot_source.dart:624，popup_settings_injection.dart:1225，settings_schema_card_creation.dart:597。这些都不看 mineToServerEnabled，而 anki_view_model.dart:752-790 在制卡到已配对设备时根本不套复习层，所以开着这个开关时，小组件 / 弹窗标记 / 设置显隐的判断和实际落卡去向不一致（推测，未实测）
- docs/bugs 里命中 SrsMiningAnkiRepository / DelegatingAnkiRepository 的有 9 份：BUG-3580、3790、3863、4107、4122、4255、4720、5085、5542
- SrsMiningAnkiRepository（srs_mining.dart:257、:757、:809）和 packages/fushi_engine/lib/srs/ankiconnect/srs_ankiconnect_handler.dart:1215、:1401 是两份「把 Anki 语义翻译到 SRS」的门面，整数句柄、查重、重排各自实现

机制：制卡的抽象只有 BaseAnkiRepository 这一个：46 个成员，能力用 supportsX / probeX 布尔对表示，降级默认值静默生效。新目标只能「伪装成 Anki 后端」接进来，每个只在 Anki 有意义的成员都得手动覆盖或抛错，漏一个就悄悄落回内层 Anki 的行为（BUG-4122），界面文案也只会说 Anki（BUG-3790、4255）。目标的判定没有单一来源：provider、AppModel、小组件、设置各自用 srsMiningTarget == srs 拼一个判据，主机侧 app 和服务端又各写一套分派。

根本方案：在 fushi_engine/mining 里新建：(1) `sealed class MiningDestination`，分 `AnkiDestination(backend)`、`ReviewDestination(profileUid, deckId, noteTypeId)`、`PairedHostDestination(target)` 三种；(2) 单一解析函数 `MiningDestination resolveMiningDestination(MiningInputs)`，输入是模块开关、挖词目标、mineToServer、作品会话 / 激活配置、只读进程，app 用一个 `miningDestinationProvider` 暴露它，所有界面判据（设置显隐、小组件、首页目标、弹窗标记）都只读这个 provider 和它上面的 getter；(3) 一个窄接口 `abstract interface class CardSink`，只有 mine / updateMined / isDuplicate / findByExpression / openNote / listNewCards / setPositions，加上一个不可变值对象 `CardSinkCapabilities`，取代 supports/probe 布尔对；(4) 实现分两种：`AnkiCardSink` 包现有的 AnkiConnect / AnkiDroid / AnkiMobile 仓库；`SrsCardSink` 放在 fushi_engine，app、服务端和 AnkiConnect 兼容端点共用（SrsAnkiConnectHandler 的 addNote / canAddNotes / 重排改调它）；(5) 待发队列、已制卡缓存、后台写入这些装饰器改成包 CardSink，链只在 `CardSinkFactory.forDestination` 一处拼；(6) 主机侧分派收成 engine 里的 `RemoteMiningHostCore`，app 的 HostRemoteMiningTargets 和服务端的 RemoteMiningHost 只注入 sink 工厂和目录。删除：SrsMiningAnkiRepository、DelegatingAnkiRepository 里专为复习层做的委派、两份委派守卫测试、7 处手写判据、hostMiningRepositoryForView 和 _withSrsMining 里的重复装配。以后加一种目标，只要加一个 MiningDestination 分支和一个 CardSink 实现，sealed switch 会在编译期逼出所有消费点。BaseAnkiRepository 收窄成只管 Anki 后端（配置拉取、笔记类型编辑、媒体维护）。

要动：fushi/lib/src/srs/srs_mining.dart；fushi/lib/src/anki/delegating_anki_repository.dart；fushi/lib/src/anki/anki_view_model.dart；fushi/lib/src/models/app_model.dart；fushi/lib/src/sync/host_remote_mining_targets.dart；packages/fushi_server/lib/src/remote_mining_host.dart；packages/fushi_engine/lib/srs/ankiconnect/srs_ankiconnect_handler.dart；packages/fushi_engine/lib/srs/srs_miner.dart；packages/fushi_engine/lib/srs/srs_mining_target.dart；packages/fushi_anki/lib/src/base_anki_repository.dart；fushi/lib/src/srs/srs_providers.dart；fushi/lib/src/platform/widget_snapshot_source.dart；fushi/lib/src/stats/study_goals.dart；fushi/lib/src/settings/settings_schema_card_creation.dart；fushi/lib/src/pages/implementations/popup_settings_injection.dart

核验说明：已验证：anki_view_model.dart:746 ankiRepositoryProvider 在 mineToServer 打开时直接 return `_withPendingQueue(ref, _withAutoReposition(ref, remote))`，不套 _withSrsMining（注释写明是有意为之）；:799 hostMiningAnkiRepositoryProvider、:819 _withSrsMining，再加 app_model.dart:14054 一带，各自拼装饰链。判据手写：srs_providers.dart:71/:81，app_model.dart:14033（studyGoalReviewsHidden），study_goals.dart:82（还和 fromWire != anki 叠了一次），widget_snapshot_source.dart:624（只看 srsMiningTarget == anki，连模块开关都不看），popup_settings_injection.dart:1225，settings_schema_card_creation.dart:597。这些都不看 mineToServerEnabled，和 ankiRepositoryProvider 的实际去向确实对不上：比如 popup 的 srsMiningToReview 会让 popup.js 去掉「在 Anki 中打开」，而 mineToServer 打开时实际仓库是 RemoteMining，并没有复习层。这一点是从代码推出来的，没实测。docs/bugs 里命中这两个类名的文件实测 9 份，与审计一致。

方案风险：1) changesUserVisible 只要「判据统一到考虑 mineToServer」这一步就会改变小组件、首页目标、设置显隐的表现，要先列取舍问用户（CLAUDE.md「方案取最优」）。2) 后台制卡（srsMiningBackground，回「已入队」）、离线已制卡缓存、待发队列、自动重排、WorkScopedAnkiSettingsStore 的作品级设置这几层，CardSinkFactory 必须逐一保留顺序语义：复习层在待发队列外面，自动重排不套在复习层外面。3) 浏览器扩展 / AnkiConnect 兼容端点（SrsAnkiConnectHandler）对外是 AnkiConnect wire 协议，SrsCardSink 只能替换它的内部实现，不能改它的 wire。4) BaseAnkiRepository 还被设置页的配置拉取用着，收窄时要同步拆设置页。

修正后的方案（以此为准）：方向不变，加两条：(a) 第一步只做 MiningDestination 加 resolveMiningDestination 加 miningDestinationProvider，把 7 处判据换成读它，并把「mineToServer 开 → PairedHostDestination」的语义变化单独列给用户拍板；CardSink 拆分放第二步。(b) CardSinkFactory 用一张显式的层序声明（cache → autoReposition → pendingQueue → review/background），并用一条测试钉住各 destination 的链形状，取代现在两份委派守卫。

## srs-dart-materialization-mirror

**牌组树和笔记类型仍在 Dart 里两跳物化并缓存镜像，和内核 note_views / entity_views 形成三条物化路径，单个 id 还有 N+1 往返**

- 类型：镜像状态；规模 L；价值 high；不改外部行为
- 核验：部分成立

证据：

- packages/fushi_engine/lib/srs/srs_db_store.dart:2765-2791 `_materializeNoteTypes`：每个 id 逐个 `await _entityRow(id)` 再 `await _editItems(...)`，然后整批交给 srsMaterializeNoteTypes（寄存器内核）。noteType(id) 没有预读时（:2747），一个类型要两三次内核往返
- packages/fushi_engine/lib/srs/srs_db_store.dart:2960-2985 `_loadDeckTree`：先 read entities，再 prefetchEdits，再 srsMaterializeDecks，同样是「内核 → Dart → 寄存器内核」两跳
- packages/fushi_engine/lib/srs/srs_db_store.dart:2837-2846 笔记已经改走内核 `read note_views` 一跳物化（BUG-5572 实测：每条笔记 1.5 ms 降到 0.7 ms），牌组和笔记类型没有跟着改
- packages/fushi_engine/lib/srs/srs_db_store.dart:1160-1175（_deckTreeCache / _profileEditsCache）、:2735-2760（_noteTypeCache 按 contentFingerprint）、:630-640（onBindingChanged 手动清 5 种缓存）、:6640 `_RefreshPrefetch` 用 zone 做预读，这些都是 Dart 侧按内核修订号维护的镜像
- packages/fushi_engine/lib/srs/srs_remote_store.dart:407、:426、:456 远程客户端拿到主机内核算好的 entity_views 后，又调一遍 srsMaterializeNotes / NoteTypes / Decks，这是第三条物化路径
- packages/fushi_engine/lib/srs/srs_db_store.dart:5102-5110 deckSummaries 用 Dart 的树拼 study 请求，内核回的是按位置排的数组；:4996 `c.length > 7 ? c[7] as String?` 无类型解码，注释（:4984）承认「内核与 Dart 的牌组树来自同一份数据」

机制：Rust 胖核心迁移是按实体一类一类推进的。笔记因为性能 bug 被搬进内核一跳物化，牌组和笔记类型还留在「Dart 读原始记录 → 送回内核物化 → Dart 缓存」这个过渡结构上。缓存失效于是变成 Dart 的责任（structure key、fingerprint、bindingChanged、zone 预读），远程客户端又得在本地再物化一次。同一份牌组树在内核（排队计数用）和 Dart（拼请求、排序、全名）里各存一份。

根本方案：内核加两条读命令：`read deck_tree` 返回整棵树的视图（含全名、深度、排序位、生效的排程配置），`read note_type_views` 和 note_views 同形；再把 study / deckSummaries 改成内核按树直接返回类型化的摘要行（列式表，具名列），不再要 Dart 给牌组清单。Dart 侧只保留一份不可变快照，键用每条命令回包里带的 (epoch, structureRev)：只有一个 `_snapshot`，不再有多种缓存。删除：_materializeNoteTypes、_loadDeckTree、_prefetchEntities、_prefetchEdits、_RefreshPrefetch 和它的 zone 机制、_deckTreeCache / _profileEditsCache / _noteTypeCache、srs_remote_store.dart 客户端里的三处 srsMaterialize* 调用（客户端直接解 entity_views 的视图 JSON，和本机走同一个解码器）、fushi_srs 里只给宿主两跳用的 ffsrs_materialize 打包（register_kernel.dart 的宿主入口）。以后加一类实体视图，只在内核加一个 read 分支，再在 srs_entity_views.dart 加一个解码器。

要动：packages/fushi_engine/lib/srs/srs_db_store.dart；packages/fushi_engine/lib/srs/srs_remote_store.dart；packages/fushi_engine/lib/srs/srs_entity_views.dart；packages/fushi_srs/lib/src/register_kernel.dart；native/fushi_fsrs/src/store/gen4/cmd/reads.rs；native/fushi_fsrs/src/store/gen4/cmd/views.rs；native/fushi_fsrs/src/store/study.rs

核验说明：已验证：srs_db_store.dart:2751-2795 noteType/_materializeNoteTypes 逐 id `await _entityRow` + `_editItems`，再走 srsMaterializeNoteTypes；:2960-2985 _loadDeckTree 是 read entities → _prefetchEdits → srsMaterializeDecks；:2840-2846 笔记已经改走 `read note_views`（BUG-5572）。这些都成立。不成立的是：审计说远程客户端拿到的是「主机内核算好的 entity_views」，又物化了一遍。实际上 entity_views（:2907-2930、srs_entity_views.dart:1）回的是物化前的原料（payload+edits），客户端 srs_remote_store.dart:402-407 用 srsMaterializeNotes 等把它物化，只算一次，不是重复的第三条路径。所以「三条物化路径」的说法不准；准确地说是「本机两跳 + 远程在客户端物化」。

方案风险：changesPersistenceOrWire 标成 false 是错的。要让客户端直接解已物化视图、并删掉 register_kernel 的 ffsrs_materialize 宿主入口，就得改远程复习线上的 entity_views 形状：老版本主机回的是原料，新客户端没有物化器就解不了；老客户端碰上新主机也一样。这需要远程复习协议升代，或者在过渡期双发。另外 _RefreshPrefetch 的 zone 预读还服务于笔记以外的刷新路径，删之前要逐个调用点核对。

修正后的方案（以此为准）：内核加 `read deck_tree` / `read note_type_views`，本机路径改成一跳，这部分照做，删掉 _materializeNoteTypes、_loadDeckTree 和对应缓存。远程协议另作一步：新增带物化视图的 op（或者在 entity_views 里加 `materialized: true` 能力位），握手协商；老主机仍按原料加本地 ffsrs_materialize 处理。等协议最低版本抬过去以后，再删客户端物化和 ffsrs_materialize 宿主入口，并在 BUGS.md 或拍板台登记清理条件。

## srs-manual-revision-signal

**库不发变更流，界面靠到处手动递增一个无类型的 srsRevisionProvider，补出了 srsLocalWriteProvider / SrsRevisionOrigin / 新鲜度启发三层**

- 类型：补丁叠补丁；规模 L；价值 high；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/srs/srs_providers.dart:11-16 文件头写明「store 本身不发变更流，页面写完一律 bumpSrsRevision」；:478 StateProvider<int>；:483 bumpSrsRevision
- fushi/lib/src/srs/srs_providers.dart:487-519 `SrsRevisionOrigin` 靠「记下同步那一跳的值」区分本机写入和同步拉入（反馈 I1Bg6uMZ32 / BUG-3823 的补丁）；:530 又另立一个 srsLocalWriteProvider，用来绕开评分时整页重建（BUG-3847）
- 手动递增点分散在 main.dart:921、:927，anki_view_model.dart:835，srs_app_runtime.dart:111、:113，srs_change_note_type.dart:177，srs_import_task.dart:369，srs_builtin_template_restore_action.dart:40，srs_legacy_lapis_migration_page.dart:141，共 10 处以上
- fushi/lib/src/srs/srs_review_freshness.dart:1-20 复习页刻意不 watch、只 listen，再用缓存变更日志加内容指纹自己判断当前卡还新不新鲜（BUG-4294 的补丁）
- packages/fushi_engine/lib/srs/srs_db_store.dart:1130-1145 `_adoptRevision`、:1785 缓存变更日志：内核每条命令其实已经带回修订号和变更集合，只是没变成事件发出去
- docs/bugs 里同一机制的记录：BUG-3548（新建牌组列表不刷新）、3823（拉入触发推送）、3847（评分叫醒被盖住的列表）、3860（同步自己唤醒自己）、4294（复习页收不到外部变更）、4918（冲突页失败后不重读）

机制：变更通知没有放在唯一的写入口（SrsDbStore._sync2Raw，所有改投影的命令都从这里过），而是交给每个写入调用方「记得递增」。信号不分种类、不分来源，消费方只好要么整页重读，要么各自加启发式过滤。每冒出一种误唤醒或漏唤醒，就再叠一层补丁信号。

根本方案：SrsDbStore 自己暴露 `Stream<SrsStoreChange> changes`：在 `_sync2Raw` 吸收回包（修订号、缓存变更日志、bindingChanged）的同一个地方发出，类型化成 `SrsStoreChange { Set<String> cards, notes; bool structure, uiState, logs, binding; SrsChangeOrigin origin (local|pulled|import|remote) }`。app 用一个 `srsChangesProvider` 包这条流，再派生几个窄 provider（deckCountsDirty、structureDirty、cardChanged(id)），页面只 watch 自己关心的那一种。互联推送只订 origin == local。删除：srsRevisionProvider、srsLocalWriteProvider、SrsRevisionOrigin、bumpSrsRevision 和全部手动递增点，srs_review_freshness.dart 收缩成按 cards / notes 集合判断。远程库（SrsRemoteStore）从回包信封里的 tag 合成同一种事件。以后加写操作不用再记得通知，加一种消费方只订对应的字段。

要动：packages/fushi_engine/lib/srs/srs_db_store.dart；fushi/lib/src/srs/srs_providers.dart；fushi/lib/src/srs/srs_review_freshness.dart；fushi/lib/src/srs/srs_app_runtime.dart；fushi/lib/main.dart；fushi/lib/src/anki/anki_view_model.dart；fushi/lib/src/pages/implementations/srs/srs_review_page.dart；fushi/lib/src/pages/implementations/srs/srs_deck_list_page.dart；fushi/lib/src/pages/implementations/home_srs_panel.dart；fushi/lib/src/srs/srs_remote_store_client.dart

核验说明：已验证：srs_providers.dart:11-16 文件头写着「store 本身不发变更流」，:478 StateProvider<int>，:483 bumpSrsRevision，:487-519 SrsRevisionOrigin，:530 srsLocalWriteProvider。fushi/lib 下 bumpSrsRevision / srsRevisionProvider.notifier 共 59 处，比审计说的 10 处还多。SrsDbStore 目前只有 :625 一条 `Stream<void> bindingChanges`，没有类型化的变更流。

方案风险：1) 只在 `_sync2Raw` 发事件，覆盖不到不经过这里的变化：profile 切换（srsStoreProvider 重建）、覆盖恢复或重开库后的 _loadLocal、导入任务在别的 isolate 或进程里写库（CLAUDE 提到存在非主进程打开 srs.db 的 SrsStorageHost）。别的进程写的库变化，本副本的流看不见。这一点是推测，要核对多进程写入路径。2) 评分（复习页）现在刻意不叫醒被盖住的列表（BUG-3847）。改成流以后，deckCountsDirty 这类派生 provider 要有「页面不可见时不重算」的语义，否则 BUG-3847 会回归。3) SrsRemoteStore 回包信封里目前未必带变更 tag，要先确认主机回包形状，否则又要改 wire。

修正后的方案（以此为准）：流照建，补三点：(a) 事件源要覆盖 _sync2Raw、_loadLocal / 覆盖恢复（发 structure+binding 全量脏）、以及跨进程通知（复用现有 SrsStorageHost 的进程间信号，发 origin=external）；(b) 派生 provider 只标脏，可见页面在 TickerMode / 路由可见时才重读，用来保留 BUG-3847 的行为；(c) 远程会话先用「每次写 op 成功 → 合成 origin=remote 的全量脏」顶上，不改 wire，以后再按需细化。

## kernel-op-catalog-duplicated-in-dart

**内核命令的分类（改投影 / 免锁 / 带缓存配置 / 分道 / 浏览 / 统计 / 远程白名单）在 Dart 里手抄了 8 份字符串集合，靠正则扫 Rust 源码对齐**

- 类型：缺单一登记源；规模 M；价值 medium；不改外部行为
- 核验：部分成立

证据：

- packages/fushi_engine/lib/srs/srs_db_store.dart:2534 kSrsSync2ProjectingOps，注释写「与内核 dispatch.rs PROJECTING_OPS 同一组」；native/fushi_fsrs/src/store/gen4/dispatch.rs:223 PROJECTING_OPS 又写一遍
- packages/fushi_engine/test/srs/srs_read_only_executor_guard_test.dart:206-218 用 indexOf('pub const PROJECTING_OPS') 抠 Rust 源码来比对
- packages/fushi_engine/lib/srs/srs_db_store.dart:1901 kSrsBrowseOps（「与 dispatch.rs 分派到浏览会话的那一组相同」）、:1927 kSrsSync2LockFreeOps、:2474 _kBindingReloadOps、:2564 _kSync2CacheOps（和 ProjectingOps 几乎一样又抄一遍）、:6404 _kStatsOps
- packages/fushi_engine/lib/srs/srs_db_store.dart:2517-2526 srsCoreLaneOf 用 switch 按 op 字符串分道
- packages/fushi_engine/lib/srs/srs_remote_store.dart:1089 kSrsRemoteKernelOps 远程白名单
- srs_db_store.dart 里有 51 处 `'op': '...'` 字面量，回包约 100 处 `as` 强转（如 :578-583 `id['collection']! as String`）

机制：命令的属性（会不会改投影、要不要进写锁、走哪条 worker 道、要不要带缓存配置、能不能替远程发）是内核命令本身的事实，却由 Dart 按字符串在多个集合里各登记一次。内核加命令或改属性时，Dart 每个集合都要手改，漏改就成了时序 / 锁类 bug，只有一份 PROJECTING_OPS 有守卫。

根本方案：Rust 在 dispatch.rs 里维护唯一的 `OP_CATALOG: &[OpMeta { name, projecting, lock_free, cache_config, lane, browse, stats, remote_allowed, binding_reload }]`，现有的 PROJECTING_OPS 等改成从它派生。再用构建期 codegen（tool 脚本读 OP_CATALOG 生成 `packages/fushi_srs/lib/src/store/srs_kernel_ops.g.dart`，CI 检查生成物没有漂移），或者由 FFI 的 `ffsrs_op_catalog` 在开库时返回，得到 Dart 的 `enum SrsKernelOp { apply(projecting: true, lane: interactive, ...) ... }`。`_sync2` 的签名改成 `_sync2(SrsKernelOp op, Map<String,Object?> args)`，op 名不再以字符串字面量出现。删除 Dart 的 8 个集合、srsCoreLaneOf 的 switch，以及 srs_read_only_executor_guard_test 的源码比对段。以后加命令只改 OP_CATALOG 一处。

要动：native/fushi_fsrs/src/store/gen4/dispatch.rs；packages/fushi_srs/lib/src/store/srs_core.dart；packages/fushi_engine/lib/srs/srs_db_store.dart；packages/fushi_engine/lib/srs/srs_remote_store.dart；packages/fushi_engine/lib/srs/srs_core_workers.dart；packages/fushi_engine/test/srs/srs_read_only_executor_guard_test.dart

核验说明：已验证：Dart 侧有 kSrsSync2ProjectingOps（srs_db_store.dart:2534）、kSrsBrowseOps（:1901）、kSrsSync2LockFreeOps（:1927）、_kBindingReloadOps（:2474）、_kSync2CacheOps（:2564）、_kStatsOps（:6404），srs_remote_store.dart:1089 有 kSrsRemoteKernelOps。只有 PROJECTING_OPS 用 indexOf 扫 Rust 源码对齐（srs_read_only_executor_guard_test.dart:206-218）；Rust 侧 dispatch.rs:1280-1313 另有自测。不成立的部分：LockFree（不进 Dart 写锁）、cache_config（带只有 Dart 知道的缓存配置，见 :2560 注释）、lane（Dart worker 池分道）、remote_allowed（主机安全白名单，属于 Dart HTTP 层的策略）这几个属性是 Dart 宿主侧的调度 / 安全策略，不是「内核命令本身的事实」。全搬进 Rust OP_CATALOG，会让内核去承载宿主的调度和安全策略。

方案风险：把 remote_allowed 放进内核目录，等于把远程安全边界交给一个 Rust 常量，任何人加 op 时顺手标 true 就开了远程写入面，审查点反而更分散。lane / lock_free 和 Dart 的 worker 池、写锁实现绑在一起，内核改不了这两样东西的语义，放进去也只是字符串搬家。

修正后的方案（以此为准）：拆成两层。内核事实（projecting、binding_reload、browse、stats，即内核里真正按会话或写入分派的属性）在 Rust OP_CATALOG 维护，用 codegen 生成 Dart 的 `enum SrsKernelOp`，加 CI 漂移检查。宿主策略（lock_free、cache_config、lane、remote_allowed）在 Dart 里作为这个 enum 的扩展 getter 集中写在一个文件里，并用穷举 switch 强制每个新 op 显式表态。_sync2 签名改收 SrsKernelOp，去掉散落的 'op' 字面量。

## card-field-role-tables-scattered

**卡片字段角色（Lapis / Fushi 卡片字段、默认映射、说明、主字段、可视分组、名字猜角色）散在 6 处以上，两张启发表对同一个字段名给出相互矛盾的结论**

- 类型：缺单一登记源；规模 M；价值 medium；用户可见
- 核验：部分成立

证据：

- packages/fushi_anki/lib/src/lapis_note_type.dart:36-80 字段表和 defaultFieldMappings；packages/fushi_anki/lib/src/fushi_card_note_type.dart:37-80 同序的改名版本，注释写「与 Lapis 的对应关系由测试 fushi_card_fields_test.dart 钉死」
- fushi/lib/src/srs/srs_field_catalog.dart:91、:161-203 字段说明表按 Lapis 名建，经 FushiCardFields.legacyNameOf 再对一遍；fushi/lib/src/pages/implementations/srs/srs_ui.dart:597-623 编辑页主字段，Lapis 和 Fushi 卡片各手写一份
- packages/fushi_anki/lib/src/lapis_styling.dart:625-660 可视分组 → 字段名清单（MainDefinition 出现 6 次）
- 三张「字段名 → 角色」启发表：packages/fushi_anki/lib/src/note_type_default_mappings.dart:60-90（'pronunciation' → '{reading}'，'意味' / '释义' → '{glossary}'）、packages/fushi_engine/lib/srs/srs_legacy_lapis_migration.dart:110-143（'pronunciation' → 'ExpressionAudio'，'意味' / '释义' → 'MainDefinition'）、fushi/lib/src/srs/srs_template_presets.dart:77-90（_kMeaningNames + _meaningPattern），同一个名字结论互相矛盾
- 制卡占位符的候选清单 packages/fushi_anki/lib/src/anki_models.dart:1527-1556（AnkiHandlebarOptions.coreOptions）和渲染 switch :1275-1300 分两处维护

机制：字段角色这个概念从没被建模过。每个消费方（建笔记类型、默认映射、字段说明、编辑页、可视样式、旧 Lapis 迁移、模板预设）都按字段名字符串自己列一张表，改名映射另靠一份 FushiCardFields 和守卫测试对齐，启发式别名表各写各的，已经出现语义分歧。

根本方案：在 fushi_anki core 里新建 `enum FushiFieldRole`：每一项声明 lapisName、fushiCardName、kind（text/rich/audio/image/flag/data）、defaultHandlebar、backOrder、editorPrimary、visualGroups 和多语言别名，再加一个唯一的 `FushiFieldRole? fieldRoleOfName(String)`（规范化 + 别名表）。LapisNoteType.fields / defaultFieldMappings、FushiCardNoteType.fields / defaultFieldMappings、kSrsKnownFields、kSrsLapisPrimaryFields / kSrsFushiCardPrimaryFields、lapis_styling 的分组表都从这个 enum 派生（const 需要的话用 codegen 或 static final）。note_type_default_mappings、srs_legacy_lapis_migration、srs_template_presets 三张启发表合成 fieldRoleOfName 一张，冲突项需要选定一种语义。占位符同理收成一张 `enum AnkiHandlebar { expression('{expression}', render: ...) }`，候选清单和渲染分派从这一张表出。删除 FushiCardFields 的手写映射和 fushi_card_fields_test 的对齐断言。以后加字段或占位符只改 enum 一处。持久化的字段名不变，只是来源收拢。

要动：packages/fushi_anki/lib/src/lapis_note_type.dart；packages/fushi_anki/lib/src/fushi_card_note_type.dart；packages/fushi_anki/lib/src/fushi_card_fields.dart；packages/fushi_anki/lib/src/note_type_default_mappings.dart；packages/fushi_anki/lib/src/lapis_styling.dart；packages/fushi_anki/lib/src/anki_models.dart；packages/fushi_engine/lib/srs/srs_legacy_lapis_migration.dart；fushi/lib/src/srs/srs_field_catalog.dart；fushi/lib/src/srs/srs_template_presets.dart；fushi/lib/src/pages/implementations/srs/srs_ui.dart

核验说明：已验证：散落属实（lapis_note_type.dart:36-80、fushi_card_note_type.dart、srs_field_catalog.dart、srs_ui.dart:597-623、lapis_styling.dart、三张启发表）。「相互矛盾」只成立一半：'pronunciation' 在 note_type_default_mappings.dart:68 映射 '{reading}'，在 srs_legacy_lapis_migration.dart:128 映射 'ExpressionAudio'（即 {audio}），这是真正的语义冲突。'意味' / '释义' 一边映射 '{glossary}'，一边映射 'MainDefinition'，而 MainDefinition 的默认映射是 '{glossary-first}'（lapis_note_type.dart:71），只是全部释义和首条释义的差别，同属释义角色，不算矛盾。

方案风险：1) 两张启发表的定义域不同：一张是「任意 Anki 笔记类型的字段 → 占位符」，用于给用户自己的 Anki 类型猜默认映射；另一张是「旧字段 → Lapis 字段」，用于迁移。合成一张 fieldRoleOfName 时，迁移那一侧的结论会改变已经发布的迁移行为（老用户再跑一次迁移，结果不一样）。要先拍板 'pronunciation' 的语义，并加迁移回归测试。2) FushiCardFields.legacyNameOf 和 fushi_card_fields_test 钉的是持久化字段名的对应关系（DB 里存量笔记的字段名冻结），删测试前必须换成从 enum 派生的同等断言，不能只删不补。3) 占位符 enum 化以后，用户模板里存的 '{xxx}' 字符串是持久化数据，enum 的 wire 名必须逐字保持。

修正后的方案（以此为准）：enum FushiFieldRole 照建，作为 Lapis / Fushi 卡片字段表、默认映射、说明、主字段、可视分组的唯一来源。启发表合成一张别名表 → FushiFieldRole，两个消费方各自从角色投影：映射侧角色 → defaultHandlebar，迁移侧角色 → lapisName。'pronunciation' 这类歧义项在表里显式标 ambiguous，由消费方各自决定，或者交用户拍板。保留一条测试钉 lapisName ↔ fushiCardName 和占位符 wire 名，防持久化漂移。

## 核验补充（审计漏掉的）

- widget_snapshot_source.dart:624 的 _collectSrs 只看 `srsMiningTarget == SrsMiningTarget.anki`，而审计把它算作「与 srsMiningToReviewProvider 同一判据」。实际上这里连模块开关都放在后面判断，和 study_goals.dart:82（fromWire != anki && miningToReview 叠了两次）一样，属于同一判据的不同写法。审计只算了数量，没指出这几种写法本身语义就不等价（模块关、目标=srs 时，小组件和首页的结论不同，属推测，未实测）。
- 远程复习线上的 entity_views 回的是物化前的原料（srs_db_store.dart:2907-2930，srs_entity_views.dart:1），客户端靠本地的 register 内核物化（srs_remote_store.dart:402-407）。所以远程复习隐含一个要求：客户端的 ffsrs_materialize 版本要和主机的修改记录格式兼容，两端版本不一致时物化结果可能静默不同。这条跨版本契约目前没有握手校验，审计没有提到。属推测，需核对握手里是否带 register 内核版本。
- popup_settings_injection.dart:1225 的 srsMiningToReview 决定 popup.js 是否去掉「在 Anki 中打开」。mineToServer 打开时 ankiRepositoryProvider（anki_view_model.dart:775-790）不套复习层，按钮打开的就不是复习笔记，用户会丢掉一个真实可用的入口。这是现在就能看到的错误结果，审计只标了推测。建议按 bug 流程先验真伪，不要等大重构。
