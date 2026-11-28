# 架构审计：startup-appmodel

2026-11-28 只读审计 + 独立反驳核验的原始结论。总方案见 [../../specs/2026-11-28-architecture-redesign.md](../../specs/2026-11-28-architecture-redesign.md)。

## 现状

启动与全局状态域的核心是 fushi/lib/src/models/app_model.dart：一个 17474 行的单类 AppModel（563 条 import、55 个 late 字段、实现 8 个 Host 接口、82 处 notifyListeners）。它同时是依赖容器、启动编排器、数据库会话持有者、偏好变更广播器和各业务域的门面。冷启动分两段。main.dart:391-764 在 runApp 前串行 await 十几步平台装配。随后 main.dart:975 调 AppModel.initialise()，主体 _initialiseOnce（app_model.dart:5811-6496）是约 700 行的线性 await 链：开库、迁移、settle 一次性迁移、仓库装载、主题、字体、词典、快捷键。先后顺序全靠「必须先于 / 必须在…之后」这类注释和 200 余个读源码字符串的守卫测试来维持。:popup 和 SRS 写入宿主各有一份手抄的精简版初始化（initialiseForDictionaryPopup:6740、initialiseForSrsWriteHost:1955）。偏好仓库的每次变更都经 prefsRepo.addListener(notifyListeners) 转成 AppModel 的全局通知，根 FushiReaderApp（main.dart:3916）和所有 BasePage（base_page.dart:40）都 ref.watch(appProvider)，所以改任何一个设置都会重建整个 MaterialApp，还会重跑根 build 里的副作用。偏好镜像状态（统计日界、主题、快捷键、Anki 后端、Texthooker 开关等）在切 Profile 时靠 refreshPrefCache 和 profileViewModelProvider.onApplied 两张手写清单刷新。键的作用域（随 Profile / 设备本地 / 安装级 / 凭据）分散在 5 处以上的名单和前缀规则里。数据库生命周期（重试、关库、弹窗关库、dispose）靠每条路径各自手工列举要清理的对象。main.dart 的根 State 还为 5 种外部链接各写了一套排队 / 调度。fushi_server 走自己的 server_runtime 装配，只复用了一条 BT 站迁移，没有共用 app 的启动迁移清单。

## startup-imperative-await-chain

**冷启动是三份手抄的命令式 await 链：顺序靠注释维持，卡死靠逐步叠超时和面包屑兜底，副入口漏装配反复出 bug**

- 类型：补丁叠补丁；规模 XL；价值 high；不改外部行为
- 核验：部分成立

证据：

- fushi/lib/src/models/app_model.dart:5811-6496 _initialiseOnce 是约 700 行的线性 await 链：PackageInfo→数据根→开库→SRS 宿主→恢复与快照清理→散书合并→沙箱重基→3 个 Sync 迁移→Anki 存储→platformServices.init→仓库并行装载→5 个 settle 迁移→网络绑定→主题→目录创建→封面前缀迁移→词典路径与引擎装载→字体→快捷键。大部分步骤彼此独立，却是串行的
- fushi/lib/src/models/app_model.dart:5926/5944/5986/6107/6172 以及 main.dart:469/504/628/745/788/884/971：11 处「必须先于 / 必须在…之后 / 须在 initialise() 之前」的注释是仅有的依赖声明
- fushi/lib/src/models/app_model.dart:5738 _guardInitIo 和 5838、6262、6297 的 markInitStep：只有 3 步加了超时和面包屑（TODO-1260），其余 await 卡住时只能靠全局看门狗。同类卡死 bug 有 BUG-572（掉线盘同步 IO）、BUG-2504（云盘词典 FFI 装载）、BUG-4510（rebuild-dict-paths 自喂）、BUG-5484（Surface 卡在某个永不完成的 Future，根因未定位）、BUG-4474（历史 JSON 挡首帧）
- fushi/lib/src/models/app_model.dart:6740-6910 initialiseForDictionaryPopup 把主路径逐段抄了一遍。6771 注释写着「MUST be constructed here exactly as in initialise() — otherwise LateInitializationError (HBK-AUDIT-003)」；1955 initialiseForSrsWriteHost 又是第三份
- docs/bugs/BUG-4940（弹窗进程没装引擎宿主装配，TTS 兜底永远失败）、BUG-5375（弹窗进程经 _prepareRuntimeDirectories 冲掉书库位置锚点）、BUG-3662 / BUG-3724（弹窗只在冷启动读一次）：同属「副入口与主入口装配不一致」一类
- fushi/test 下有 202 个测试 readAsStringSync 读 app_model.dart 源码，其中 app_model_shortcut_load_order_guard_test.dart:32-40 用 src.indexOf 比较两个调用的字符偏移来钉死顺序

机制：初始化没有数据结构，只是一段过程代码。依赖关系只存在于注释和语句先后里；哪个进程装哪些步骤靠复制粘贴；超时、面包屑、计时只加在出过事的那几步。所以每加一步都要人工判断插在哪、副入口要不要抄、要不要加超时，漏了就是新 bug，修法又是再加一条注释和一个源码偏移守卫。串行链还让彼此独立的 IO 白白排队（依据：代码路径推断，StartupTimeline 已有逐段打点但仓库里没有逐段耗时汇总）。

根本方案：新建 fushi/lib/src/startup/startup_graph.dart：声明式启动任务图。每个任务是 `StartupTask{id, deps: Set<StartupTaskId>, phase: preUi | preHome | postHome | idle, processes: Set<EntryProcess>{main, popup, secondScreen, srsWriteHost, floatingDict}, timeout?, run(StartupContext)}`。StartupContext 用类型化槽位（`ctx.provide<FushiDatabase>()` / `ctx.require<PreferencesRepository>()`）交接产物，取代 55 个 late 字段。runner 统一负责：按 deps 拓扑并行执行；每步自动写 markInitStep 面包屑、StartupTimeline 打点和超时（数据根派生的 IO 任务声明 timeout，不再手写 _guardInitIo）；超时报出卡住的任务 id，直接覆盖 BUG-5484 这类取证需求。initialise / initialiseForDictionaryPopup / initialiseForSrsWriteHost 删除，三个入口改成 `runStartup(graph.forProcess(EntryProcess.popup))`；main.dart 里 runApp 前那段和「须在 initialise() 之前注入」的 appModel.xxx = 槽位改成 preUi 任务，或在构造时注入。散落的 settle* / migrate* 一次性迁移统一成 `OneShotMigration{id, marker 键, run}` 注册表，放进 fushi_engine（纯 Dart），由 app 图和 fushi_server 的 server_runtime 共用同一份清单。以后新增一步只在图里加一个任务、写清 deps 和 processes。守卫改为运行时检查：图构建时校验无环、require 的类型必有提供者；某进程缺依赖直接在测试里抛错。删除 shortcut_load_order、stat_day_reset_hour_refresh、app_font_init_covers_refresh 等按字符偏移校验顺序的源码守卫。

要动：fushi/lib/src/models/app_model.dart；fushi/lib/main.dart；fushi/lib/popup_main.dart；fushi/lib/floating_dict_main.dart；fushi/lib/second_screen_main.dart；fushi/lib/src/startup/；packages/fushi_engine/；packages/fushi_server/lib/src/server_runtime.dart；fushi/test/models/*order*_guard_test.dart

核验说明：属实的部分：_initialiseOnce 从 app_model.dart:5811 起；_guardInitIo 只包了 3 步（5844 resolve-data-roots、6251、6292 rebuild-dict-paths）；initialiseForDictionaryPopup（6740）和 initialiseForSrsWriteHost（1955）是手抄的副入口，调用方有 popup_main、floating_dict_main、asr_host、companion_panel_app、game_stream_panel_app；守卫测试确实按字符偏移钉顺序（app_model_shortcut_load_order_guard_test.dart:32-40 用 src.indexOf）。站不住的部分：『大部分步骤彼此独立却串行』说过头了。链里已有 5 组以上 Future.wait（6138 仓库装载、6253、6330、6395 字体、6422 三组嵌套），后台活多半已经 unawaited（5900、6020、6215、6457-6490）。剩下的串行步骤大多真有依赖：开库 → recoverPendingRestore → 哨兵 / 重基 → Sync 迁移 → prefs 装载 → settle → 主题 / 词典。审计自己也承认没有逐段耗时数据，所以并行化能省多少时间只是推测，不能算已证实的性能问题。

方案风险：① 方案说把 settle / migrate 一次性迁移统一放进 fushi_engine，由 server 共用。但多数 settle 是 PreferencesRepository 的方法，而 PreferencesRepository extends ChangeNotifier（preferences_repository.dart:274，依赖 Flutter），不能原样搬进 fushi_engine（仓库硬规则禁止它 import flutter）。另外 AndroidStrayLibraryMerge、SandboxRelocation、migrateSmbToWebDav 这类迁移是 app 或平台专属，server 用不上，目前 server_runtime.dart:195 只共用了 BT 站一条，这本来就是对的。② 用类型化槽位取代 55 个 late 字段，等于同时重写 AppModel 的全部 getter，规模和 appmodel-god-object 完全重叠，不能当成独立的一条来落地。③ 拓扑并行跑任务会改变现有的副作用时序，例如 _settleLegacyBuiltinBtSites 必须在首帧写 first_time_setup 之前跑（6171 注释）。所以 deps 必须从现有注释逐条翻译过来，不能靠推断，否则很容易引入新的竞态。④ 方案漏了 test seam：wireXxxForTesting、forwardPreferenceChangesForTesting（1150）这些需要等价的替代。

修正后的方案（以此为准）：保留『声明式任务表加统一 runner』这个方向，但范围收窄：① runner 先只接管面包屑、StartupTimeline 打点和超时（每个任务都套一层，取代手写的 _guardInitIo / markInitStep），执行顺序先保持现有串行，等有了逐段耗时数据再按 deps 放开并行。② 三个入口改成同一张任务表的子集（processes 过滤），一次删掉三份手抄的装配。③ 只有纯 Dart、和 DB schema 绑定的一次性迁移才下沉到 fushi_engine，以 db / prefs 抽象为参数，由 app 和 server 共用；平台专属迁移留在 app。④ 删源码偏移守卫之前，先换成同等强度的运行时断言（任务表无环、副入口子集齐全）。

## global-pref-broadcast-rebuild

**任一偏好写入都会经 AppModel 全局广播，重建整个 MaterialApp 和所有 BasePage；现行办法是在个别 setter 上「刻意不 notify」**

- 类型：性能；规模 L；价值 high；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/models/app_model.dart:6158 prefsRepo.addListener(notifyListeners) 和 6226 themeNotifier.addListener(notifyListeners)：偏好仓库与主题的每次变化都转成 AppModel 全局通知（6788、6802 弹窗路径同样如此）
- fushi/lib/main.dart:3916 根 FushiReaderApp 的 `AppModel get appModel => ref.watch(appProvider)`；main.dart:3429-3470 根 build 每次重跑时都执行 5 个链接队列的 schedule、AppShortcutsPublisher.sync、DesktopTray.sync 这些副作用
- fushi/lib/src/pages/base_page.dart:40 BasePageState.appModel 就是 ref.watch(appProvider)，33 个页面继承它。全仓 ref.watch(appProvider) 共 74 处，用 .select 的只有 6 处
- fushi/lib/src/models/preferences_repository.dart:2329-2337 注释明写「刻意不 notifyListeners（这是有意的例外）……为一个字幕开关重建整个 app 正是卡的主要成本……新增读取方必须自带刷新」；app_model.dart:8424-8427 videoSpecsService「刻意不接 addListener(notifyListeners)」
- 同一机制的 bug：BUG-1430（字幕遮罩切换卡，根因写明全局广播重建全 app）、BUG-3353（设置开关掉帧，AnimatedTheme 随每次 AppModel 通知 lerp 280ms）、BUG-2010（作品页前台闪回）。反方向的 BUG-4767：读取方用 ref.read 不 watch，于是拿到旧值

机制：Provider 粒度是整个 AppModel。偏好仓库没有按键订阅的能力，只能整仓 notify，AppModel 再整体转发。消费方要么 watch 整个模型，跟着每个设置重建；要么用 read，拿到旧值。两头都出过 bug，修法都是在个别 setter 上开例外，或给个别消费方补 select，每个键各补一次。依据：BUG-1430 / BUG-3353 有现场实测与根因记录，其余为代码路径推断。

根本方案：PreferencesRepository 改成按键发信号：`PrefKey<T>` 类型化键（和下文作用域登记合并成一次声明）加 `Stream<void> changes(PrefKey)`，Riverpod 侧提供 `prefProvider<T>(PrefKey<T>)` family，每个键一个 provider，只在该键值变化时通知。删掉 app_model.dart:6158 / 6802 的 prefsRepo.addListener(notifyListeners)，AppModel 不再转发偏好变更，也不再承担「设置变了」的语义。根 FushiReaderApp 只 watch 它真正用到的派生 provider（themeDataProvider、localeProvider、themeModeProvider），不 watch appProvider。根 build 里的副作用（托盘、长按菜单、链接调度）改成 ref.listen 对应的细粒度 provider 后再触发，不放在 build 里。BasePageState.appModel 改回 ref.read，页面要哪个设置就 watch 哪个 prefProvider。「刻意不 notify」这类例外注释随之删除。以后新增设置只需声明 PrefKey，消费方 watch 对应 provider 即可，写不出全局重建。守卫：一条 lint 或架构测试禁止在 lib 下 `ref.watch(appProvider)` 不带 select（AppModel 本身只剩不可变服务句柄，watch 它也没有意义）。

要动：fushi/lib/src/models/preferences_repository.dart；fushi/lib/src/models/app_model.dart；fushi/lib/main.dart；fushi/lib/src/pages/base_page.dart；fushi/lib/src/models/theme_notifier.dart；74 处 ref.watch(appProvider) 消费方

核验说明：已验证。prefsRepo.addListener(notifyListeners) 在 app_model.dart:6158 和 6802，themeNotifier.addListener 在 6226 和 6788。根组件在 main.dart:3916 ref.watch(appProvider)，base_page.dart:40 也是 watch。全仓 lib 里 ref.watch(appProvider) 有 74 处，带 .select 的只有 6 处。根 build（main.dart:3429-3470）每次重跑都会调 5 个 schedule、AppShortcutsPublisher.sync 和 DesktopTray.sync，这些调用靠签名去重兜底。PreferencesRepository 是一个单一 ChangeNotifier，有几十处整仓 notifyListeners（311、487、629…），按键订阅只有 videoSubtitleMaskListenable（2408）这种个例。

方案风险：① 33 个继承 BasePage 的页面和 74 处 watch 目前是靠全局重建才拿到新值的。如果把 BasePageState.appModel 一口气改回 read，又没逐页补上按键 watch，就会批量造出 BUG-4767 那类读到旧值的 bug。这必须按页面迁移，迁一页删一处 watch。② 方案的触发源只有单键变更和 refreshFromDb，漏了作品级 Profile 叠加层：app_model.dart:12660 起的 _reloadForWorkProfileScope 会让 notifyWorkProfileScopeChanged 整体改变生效值，键值本身没写，按键信号必须覆盖这种『生效值换了』的事件。③ ctl 路由和同步层是按字符串键读写偏好的，PrefKey 类型化不能改掉 wire 上的键名。

修正后的方案（以此为准）：按键信号要发在『生效值变化』上，覆盖三种来源：单键写入、整仓重载、作品叠加层进出。prefProvider family 建在这层信号上。根 FushiReaderApp 先拆出来，只 watch 主题、语言、模块可见性等派生 provider，副作用改成 ref.listen。BasePage 按页迁移，迁一页删一处 watch，全部迁完再加守卫：禁止不带 select 去 watch appProvider。

## profile-switch-mirror-refresh-list

**切 Profile 时的镜像状态刷新是两张手写清单，漏一项就是「切完要重启才生效」，已出 6 次以上**

- 类型：镜像状态；规模 L；价值 high；用户可见
- 核验：成立

证据：

- fushi/lib/src/models/app_model.dart:6918-6950 refreshPrefCache 手工逐项刷新：_applyStatDayResetHour、navRailExpandedNotifier、每个 mediaSource.refreshPreferencesFromDb、themeNotifier.refreshFromDb、restoreAnkiBackendSelection、loadShortcutRegistry
- fushi/lib/src/profile/profile_view_model.dart:591-610 onApplied 是第二张清单：Anki 设置推给 platformServices、invalidate ankiRepositoryProvider、refreshPrefCache、reloadDictionariesFromDb、ReaderFushiSource.readerSettings.refreshFromDb；同文件 :627 invalidateAnkiStateAfterPrefsChange 是第三张
- fushi/lib/src/models/app_model.dart:6184 TexthookerService.instance.foldProgressiveLines 只在 initialise 和 setter（:15836）里推一次，refreshPrefCache 不刷新。而 gal_hook_fold_progressive_lines 没有出现在 ProfileKeys 的排除表或前缀里（profile_keys.dart:69/199），会随 Profile 快照切换，所以切 Profile 后这个开关很可能停在旧值（推测，未在设备上复现）
- 同类 bug：BUG-5073（统计日界镜像 FushiDatabase.statDayResetHour 不刷新，修法是在清单里补一行再加一个源码守卫 stat_day_reset_hour_refresh_guard_test）、BUG-500（dictionary_metadata 不跟随，补 reloadDictionariesFromDb）、BUG-4351（快捷键）、BUG-3896（首页统计不刷新）、BUG-3724（:popup 的 Anki 设置）、BUG-3806（设置输入框旧值）

机制：进程里大量状态是从偏好推送出去的镜像：静态字段、单例上的字段、各自缓存的 notifier。这些镜像只在写入的那一刻被赋值。「偏好整体换了一份」（切 Profile、导入覆盖、:popup 热复用、设置同步）这个事件没有订阅机制，只能由切换方手工列出所有镜像逐个刷新。新增一个镜像的人不知道这张清单在哪，于是漏掉，用户报 bug 后再补一行加一个守卫。

根本方案：以上一条的按键信号为基础，镜像改成拉取或订阅，不再推送：① 能现读的直接现读（TexthookerService 等改成持有 `bool Function()` reader，和 ImmersionMiningEngine.lowMemoryModeReader 同一种做法），不存副本；② 必须持有副本的（FushiDatabase.statDayResetHour、快捷键注册表、主题缓存、Anki 后端选择）统一登记为 `PrefMirror(keys: {...}, apply: (prefs) async {...})`，登记语句写在消费方旁边。PreferencesRepository 在单键变更和整仓重载（refreshFromDb、applyProfile 之后）时自动调用相关的 apply。refreshPrefCache 和 onApplied 的手写清单删除，切 Profile 只剩「applyProfile → prefsRepo.reloadAll()」一步；非偏好表的跟随（dictionary_metadata）也登记成同类 mirror，以表变更为触发源。新增镜像只需写一条 PrefMirror 登记。守卫：测试遍历所有已登记 mirror，切一次 Profile 后断言每个 apply 都被调用；同时删除 stat_day_reset_hour_refresh_guard_test 这类源码扫描守卫。

要动：fushi/lib/src/models/app_model.dart；fushi/lib/src/profile/profile_view_model.dart；fushi/lib/src/models/preferences_repository.dart；fushi/lib/src/sync/texthooker_service.dart；fushi/lib/src/models/theme_notifier.dart；fushi/test/models/stat_day_reset_hour_refresh_guard_test.dart

核验说明：已验证。refreshPrefCache（app_model.dart:6918-6950）不推 TexthookerService.foldProgressiveLines。这个字段在全仓只有两处赋值，6184 冷启动和 15836 setter，消费方在 texthooker_service.dart:998。profile_keys.dart 里找不到 gal_hook 相关的排除项，所以这个键会随 Profile 切换，切完后开关停在旧值，代码路径上成立（未在设备上复现）。手写清单其实不止审计说的三张，还有：设置同步导入后 1787 refreshPrefCache 加 notifyListeners；温弹窗 refreshForWarmDictionaryPopup（6987）；作品叠加层 _reloadForWorkProfileScope（12660 起）。这几条各自刷的项目并不相同，例如 readerSettings.refreshFromDb 只在 onApplied（profile_view_model.dart:610）和作品叠加层路径里出现。

方案风险：① 触发源要包括作品 Profile 叠加层，以及 :popup 跨进程的 prefs_version 水位（TODO-855）。② dictionary_metadata 这类非偏好表的跟随，触发源是表变化，审计说『登记成同类 mirror』可以，但 PreferencesRepository 自己感知不到表变化，需要另立一条事件。③ Anki 后端选择是跨进程推导出来的，invalidateAnkiStateAfterPrefsChange 失效的是 Riverpod 状态，这部分不在 PreferencesRepository 能管的范围里，方案得说明怎么接。

修正后的方案（以此为准）：PrefMirror 登记表的触发源统一成『偏好快照替换』这一个事件，五种来源都发它：切 Profile、设置同步导入、温弹窗 version 变化、作品叠加层进出、备份恢复。Riverpod 那一侧派生状态的失效也订阅同一个事件，不再手写 invalidate。非偏好表另开一个『会话数据换代』事件，挂在下文的 DatabaseSession 上。

## pref-key-scope-scattered-lists

**偏好键的作用域（随 Profile / 设备本地 / 安装级 / 凭据）分散在 5 处以上的名单、前缀、后缀和子串规则里，新增一个键要改 N 处**

- 类型：缺单一登记源；规模 L；价值 high；不改外部行为
- 核验：部分成立

证据：

- fushi/lib/src/models/preference_keys.dart:120 kKnownPreferenceKeys（键名登记），:1528 kCredentialPreferenceKeys（凭据）
- fushi/lib/src/profile/profile_keys.dart:69 _excludedPrefKeys、:199 _excludedPrefPrefixes、:270-279 isExcludedPref 又叠加 _overrideTitleMarker 和 endsWith('/last_picked_file') 两条特例
- fushi/lib/src/sync/sync_repository.dart:2021 deviceLocalPrefKeys、:2043 installScopedPrefKeys、:2053 _perChannelDeviceLocalBases、:2068 _deviceLocalFixedKeys，另外还要展开 web_browser_prefs.dart:143 kWebBrowserDeviceLocalPrefKeys 和 page_backdrop_style.dart:134 kPageBackdropDeviceLocalPrefKeys
- fushi/lib/src/sync/pref_redaction_policy.dart:157-205 deviceLocalKeyPrefixes、deviceLocalKeySuffixes、sensitiveKeys、sensitiveKeyPrefixes、credentialSubstrings 五层判定，注释承认「形状兜底……将来新增、还没进前三条的凭据 key 也先拦下来」
- docs/bugs 下 21 个 bug 引用这些名单：BUG-1072（凭据判定散落三处导致泄漏）、BUG-1019（进度型 pref 被 Profile 快照回灌）、BUG-1683、BUG-1550、BUG-1579 等

机制：每个键的作用域属性没有和键的声明放在一起，而是由各条出境 / 切换通道（Profile 快照、备份、设置同步、合并导入、ctl 读值）各自维护名单，再用前缀、后缀、子串去猜。新增键时作者必须知道要去哪几张表登记，漏登的后果不是编译错误，而是串号、泄漏或被回灌。

根本方案：在 fushi_engine（纯 Dart，app 与 fushi_server 共用）建 `PrefKeyDef<T>{name, codec, default, scope: PrefScope.profile | device | install | credential, dynamicSuffix?: PrefSuffixKind}` 单一声明表，和上文的类型化 PrefKey 是同一个对象。ProfileKeys.isExcludedPref、PrefRedactionPolicy.isDeviceLocalOrCredential、SyncRepository.deviceLocalPrefKeys / installScopedPrefKeys、kWebBrowser/kPageBackdrop*DeviceLocalPrefKeys、kCredentialPreferenceKeys 全部改成从声明表派生的视图，原名单删除（存量键名冻结不改，只改声明位置）。动态键用声明的前缀加 suffix kind 表达，不再各处写 startsWith / endsWith。credentialSubstrings 形状兜底改为构建期断言：名字像凭据但 scope 不是 credential 的键，在测试中直接报错，不再到运行时去猜。以后新增键只写一条 PrefKeyDef。守卫：preference_keys_guard_test 改成「getPref/setPref 只接受 PrefKeyDef」，由类型保证，不再扫描字面量。

要动：fushi/lib/src/models/preference_keys.dart；fushi/lib/src/profile/profile_keys.dart；fushi/lib/src/sync/sync_repository.dart；fushi/lib/src/sync/pref_redaction_policy.dart；fushi/lib/src/web_browser/web_browser_prefs.dart；fushi/lib/src/utils/adaptive/page_backdrop_style.dart；packages/fushi_engine/；packages/fushi_server/lib/src/server_prefs.dart

核验说明：名单分散是真的：preference_keys.dart、profile_keys.dart、sync_repository.dart、pref_redaction_policy.dart 和两个模块常量。但并非 5 处各自独立：PrefRedactionPolicy 直接复用 SyncRepository.deviceLocalPrefKeys（pref_redaction_policy.dart:189），也 import 了 kPageBackdropProfileParkedPrefKeyPrefixes（:14）；ProfileKeys 展开了 kPageBackdropDeviceLocalPrefKeys（profile_keys.dart:81）。也就是说已经有部分派生，只是没收敛成单一声明。而且 Profile 排除和设备本地是两个不同的维度（pref_redaction_policy.dart:26 注释明确区分了两者），不能直接压成一个 scope 枚举。

方案风险：① 单一的 scope 枚举表达不了正交属性：有的键是设备本地但不是凭据，有的不随 Profile 但随备份走，Profile 排除和设置同步排除也不完全相同。应该用多个布尔或位集，或者一个 scope 加上各通道的显式策略。② 『getPref/setPref 只接受 PrefKeyDef』会撞上大量动态键（按 id、channel 展开的）和 ctl、同步按字符串读写的 wire 路径。动态键要能从字符串反查到定义。③ 形状兜底（credentialSubstrings）改成构建期断言后，会拦不住运行时从扩展或第三方写进来的未登记键。兜底应该保留为最后一道防线，再另加构建期断言。

修正后的方案（以此为准）：PrefKeyDef 上声明一组正交策略字段：profileScoped、syncable、backupIncluded、credential、deviceLocal，另加动态前缀描述，各通道的名单都从这份声明派生，再由测试断言派生结果和现行名单一致后才删旧名单。字符串入口保留 lookup(String) → PrefKeyDef? 做反查，未登记的键照旧走形状兜底拦截。存量键名不改。

## db-bound-lifecycle-manual-teardown

**绑定数据库连接的服务靠每条关库路径手工列举清理，漏一项就会静默打在已关闭的连接上**

- 类型：成类 bug；规模 L；价值 high；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/models/app_model.dart:3513-3580 retryInitialise 手工撤 prefs / theme 监听、关 SRS、关库、停远程词典目录、dispose dictRepo、`_galgameRepo = null`
- fushi/lib/src/models/app_model.dart:13308-13332 closeDatabase、:13360-13372 closeForPopup、:13374 起的 dispose 是另外三份各不相同的清理清单。BUG-1569② 的注释写明「生产三条关库路径全都不撤订阅」，最后靠给每条路径补 uninstallCollectionsSyncWatcher() 修掉
- fushi/lib/src/models/app_model.dart:8436-8452 videoSpecsService 注释：「不能靠『每条关库路径都记得清掉它』：那是一条要靠人肉枚举维护的不变式，已经漏过一次（retryInitialise 里只清了 _galgameRepo）」，于是在这一个 getter 里用 identical(_videoSpecsServiceDb, db) 局部兜住
- 同类 bug：BUG-1569、BUG-1647（lazy 服务的旧定时器拿着旧 repository）、BUG-913（dispose 不对称）、BUG-5387 / BUG-5449（换库时后台写手写进新库）、BUG-815（重试与在途 init 竞态导致数据全空）

机制：数据库会话没有作为一个对象存在。依赖 _database 的仓库、观察者、定时器、单例 attach（MusicServerDownloadIndex.attach、MusicServerOfflineQueue.attach、MediaSource.setDatabase）散落在 AppModel 的 late 字段、lazy getter 和全局单例里。每条换库路径（重试、备份恢复、数据根迁移、弹窗关闭、dispose）都要自己记住完整名单，名单随功能增长，必然有漏项。

根本方案：新建 `DatabaseSession`（fushi/lib/src/startup/database_session.dart）：持有 FushiDatabase 加一个 `own<T>(T resource, FutureOr<void> Function(T) close)` 资源栈。所有绑库服务都在 session 上创建（启动图里的任务把产物注册进 session），全局单例的 attach 改成 `session.attach(MusicServerOfflineQueue.instance)`，关闭时自动 detach。换库只有一个操作 `await session.close()`：先 quiesce 后台写手，再按注册逆序关闭资源，最后关连接。retryInitialise、closeDatabase、closeForPopup、dispose 里的四份手写清单删除，videoSpecsService 的 identical 比对也删除（服务本身就挂在 session 上）。AppModel 只持有 `DatabaseSession? current`，Riverpod 侧用 `databaseSessionProvider`，换 session 时整组派生 provider 失效重建。新增绑库服务只需在 session 上 own 一次。守卫：session 关闭后对其连接发起查询必须抛 SessionClosed（类型层面杜绝 drift「connection was closed」被吞），再加一个测试，断言 close 后所有注册资源的 close 都被调用过。

要动：fushi/lib/src/models/app_model.dart；fushi/lib/src/startup/；fushi/lib/src/media/music/server/music_server_offline_queue.dart；fushi/lib/src/sync/backup_service/restore.part.dart；fushi/lib/src/storage/data_root_migrator.dart

核验说明：已验证。closeDatabase 在 app_model.dart:13308，closeForPopup 在 13357，dispose 在 13370，retryInitialise 在 3513，四份清理清单各不相同。例如 closeForPopup 会调 FushiDicts.disposeInstance()，closeDatabase 不调；dispose 停的是 syncServerController、videoRemoteHost、TexthookerWsClientManager 等常驻服务。注释里自己承认这是『靠人肉枚举维护的不变式』，还点了 BUG-1569②（uninstallCollectionsSyncWatcher 当初漏在三条生产路径里）。

方案风险：① 方案没列入的绑库路径还有 initialiseForSrsWriteHost（1959 自己开了一个 isMainProcess:false 的库）、备份恢复和数据根迁移，这些都要走 session。② 有些常驻服务（syncServer、ctl api server、Texthooker WS）的生命周期是跟进程走的，不跟库走，强行挂到 session 上，重试换库时会误杀它们。资源要按 process 级和 session 级分成两个栈。③ 『换 session 时整组派生 provider 失效重建』会牵动 493 处 ref.read(appProvider) 持有的旧句柄，必须保证没人缓存 session 内的对象。

修正后的方案（以此为准）：DatabaseSession 只装 session 级资源：仓库、观察者、绑库定时器、单例 attach、SRS 存储、词典写入队列。进程级的常驻服务另放一个 ProcessLifetime 栈，由 dispose 统一逆序关闭。四条关闭路径全部调用 session.close()，close 之后对连接的访问抛类型化异常，再加一个测试断言每个注册资源都被关闭过。

## appmodel-god-object

**AppModel 是 1.7 万行的上帝对象（563 import、8 个 Host 接口、55 个 late 字段），还反向 import 页面层，靠 202 个源码扫描测试守结构**

- 类型：上帝对象；规模 XL；价值 high；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/models/app_model.dart:1-563 共 563 条 import，含 pages/implementations/dictionary_dialog_page.dart、profile_management_page.dart、text_segmentation_dialog_page.dart（:142-147）等 UI 页面，模型层反向依赖页面层
- fushi/lib/src/models/app_model.dart:1080-1089 `class AppModel with ChangeNotifier implements MusicAudioEffectsHost, MusicPluginQualityHost, AudioProductionHost, ExternalStorageAccess, LookupMatchSearchHost, StudyGoalHost, TrackingSeriesCardHost, AiringCalendarHost`，同一个类承载音乐、制卡、追番、存储、统计等多个域
- fushi/lib/src/models/app_model.dart:3989-4036 一串 `late Map<...> languages / locales / dictionaryFormats / mediaTypes / fields / enhancements / quickActions / mediaSources`，靠 populateXxx 在启动里赋值。:6770-6773 注释记录了漏赋值导致的 LateInitializationError（HBK-AUDIT-003）
- fushi/lib/src/models/app_model.dart:770-773 注释说明 secondScreenControllerProvider 必须定义在 app_model.dart 里，才能避开 import 环（import_cycle_guard_test）
- fushi/test 下 202 个测试 readAsStringSync 读 app_model.dart 源码做字符串断言（例如 app_model_shortcut_load_order_guard_test.dart:32-40）。本该由模块边界和类型保证的不变量，全落在文本匹配上

机制：AppModel 是历史上唯一能拿到数据库、偏好和全部服务的地方，于是新功能默认往里加字段、getter 和 Host 实现，域与域之间经它互相伸手。体积和耦合让它无法在单测里实例化（只能用 wireXxxForTesting 拼装半个对象），行为正确性只好用源码字符串扫描来守，这反过来又让重构代价更高。

根本方案：按域拆成独立的服务对象，由 Riverpod provider 装配，AppModel 本身删除，或退化成只持有 DatabaseSession 和启动状态的薄 `AppRuntime`。拆分顺序：① 偏好与外观（PreferencesRepository、ThemeNotifier、locale）先独立成 provider（配合第 2、3 条）；② 词典子系统（dictRepo、路径缓存、远程目录）抽成 DictionaryRuntime；③ 每个 `implements XxxHost` 改为独立类，例如 MusicAudioEffectsHost 由音乐域的 provider 实现，不再由 AppModel 实现；④ 媒体类型 / 字段 / enhancement / quick action 注册表改成常量注册表或各自的 provider，去掉 late Map 和 populateXxx；⑤ 依赖 Navigator / 页面的方法（打开对话框类）移回 UI 层，模型层禁止 import pages/。新增功能只在本域 provider 里加，不碰中心对象。守卫：用 import 规则测试（lib/src/models 不得 import lib/src/pages）和「单文件不超过 N 行」的架构测试取代 202 个源码扫描测试；可以单测的行为改成真实实例的行为测试。这一条是第 1、2、3、5 条落地后的收尾，可以按域分批进行。

要动：fushi/lib/src/models/app_model.dart；fushi/lib/src/pages/base_page.dart；fushi/test/models/；fushi/test/build/import_cycle_guard_test.dart；493 处 ref.read(appProvider) 与 74 处 ref.watch(appProvider) 消费方

核验说明：已验证。文件 17474 行，563 条 import，其中 11 条 import pages/；app_model.dart:1080-1089 实现了 8 个 Host 接口；test 下引用 app_model.dart 且用 readAsStringSync 读源码的文件约 205 个（这是粗计，不全是扫描 app_model.dart 源码）。方案的拆分顺序依赖前几条先落地，这个判断是合理的。

方案风险：① 删掉 AppModel 会牵动 493 处 ref.read 和 74 处 ref.watch，只能按域分批改，每一批都要一次删干净旧的委托，不留双轨。② 目前靠把 provider 定义在 app_model.dart 里来避开 import 环（770-773），拆分时得先改 provider 的分层，否则 import_cycle_guard 会挡住。③ 规则规定新计算型子系统走 Rust 胖核心；拆出来的 DictionaryRuntime 等如果涉及计算逻辑，不该再加厚 Dart 层，只做装配。④ 『单文件不超过 N 行』这种守卫要按存量设白名单，否则一落地就红。

## inbound-intent-queues-in-root

**外部入链（小组件、长按快捷方式、排行榜、配对、卡片出处、深链查词、外部视频 / 书）在根 State 里各写一套排队、调度和 handled 标志，调度挂在根 build 上**

- 类型：缺单一登记源；规模 M；价值 medium；不改外部行为
- 核验：部分成立

证据：

- fushi/lib/main.dart:2126-2300 _queueAppShortcut / _queueLeaderboardLink / _queueWidgetLink 三套几乎相同的「ready 判断 + setState + 下一帧落地」，_queuePairLink / _schedulePairLinks / _drainPairLinks 和 _queueCardSourceUrl / _scheduleCardSourceNavigation / _drainCardSourceNavigation 又各手写一套 scheduled / running 标志
- fushi/lib/src/leaderboard/leaderboard_deep_link.dart:16-49 LeaderboardDeepLinkQueue、fushi/lib/src/platform/app_shortcut_router.dart:14-45 AppShortcutQueue、fushi/lib/src/platform/widget_links.dart:389 WidgetLinkQueue：三个类实现了同一个 pending + _scheduled + addPostFrameCallback 模式
- fushi/lib/main.dart:1186-1196 _externalVideoHandled / _externalBookHandled / _lookupDeepLinkHandled / _startupPendingMinesFlushed / _startupFeedbackChecked 一组「只触发一次」布尔标志。注释说「[build] 可能多次重建」，即用标志兜住 build 里的副作用
- fushi/lib/main.dart:3429-3439 根 build 在 isInitialised 之后每次都调 5 个 schedule。由于第 2 条的全局广播，任意偏好写入都会重跑这些调用

机制：没有统一的「入站意图」抽象和「app 已就绪可以导航」信号。每接入一种外部入口，就照抄一份排队 / 就绪门控 / 下一帧执行的逻辑，并把触发点挂在根 build 上（因为根 build 恰好是「初始化完成」后第一个执行的地方）。根 State 因此膨胀到 3946 行，还把副作用的正确性绑在 rebuild 次数上。

根本方案：新建 fushi/lib/src/startup/inbound_intent_router.dart：`sealed class InboundIntent`（AppShortcutIntent、WidgetLinkIntent、LeaderboardIntent、PairLinkIntent、CardSourceIntent、LookupDeepLinkIntent、ExternalMediaIntent、OAuthRedirectIntent…）加一个 `InboundIntentRouter`。它持有单一 FIFO 队列（声明可合并的意图，如「只保留最后一条」，由意图类型自身声明），订阅一个 `appReadyListenable`（初始化完成且 navigator 已挂载），就绪后串行 drain，每类意图的执行体用 exhaustive switch 分派（漏写一个分支即编译错误）。三个 *Queue 类、main.dart 里两套手写队列和那组 handled 布尔删除，根 build 不再调用任何 schedule。退出流程（_flushAndExitForWindowClose 等）、ctl server、托盘也从 _FushiReaderAppState 拆进各自的 lifecycle 对象，在启动图里注册。以后新增入口只需加一个 sealed 子类和一个 switch 分支。

要动：fushi/lib/main.dart；fushi/lib/src/leaderboard/leaderboard_deep_link.dart；fushi/lib/src/platform/app_shortcut_router.dart；fushi/lib/src/platform/widget_links.dart；fushi/lib/src/startup/

核验说明：三个 Queue 类属实，leaderboard_deep_link.dart:16、app_shortcut_router.dart:14、widget_links.dart:389。根 build 在 main.dart:3429-3439 调多个 schedule 也属实。但这些 schedule 是幂等的（pending 为空就什么也不做），托盘和快捷方式菜单也按签名去重，所以每次重建的实际开销很小，算维护性问题，谈不上性能或正确性问题。真正被风险牵连的是那组『只触发一次』的布尔，而这组布尔的根源就是第 2 条的全局重建：第 2 条修掉之后，这里的风险大半随之消失。

方案风险：① 不同意图的就绪条件不一样：配对和卡片出处要 navigator 挂上，排行榜要能拿到登录态，外部视频或书要库装载完成。一个 appReadyListenable 不够用，每类意图要能声明自己的就绪谓词。② 冷启动 argv 意图（_pendingArgvLeaderboardLink 以 ready:false 入队）和热启动意图的合并语义要保留。③ 退出流程和托盘搬进启动图属于范围扩大，和意图路由是两件事，应该拆开做。

修正后的方案（以此为准）：InboundIntentRouter 保留单一 FIFO 队列加 sealed 分派，每个意图类型自己声明就绪谓词和合并策略，触发改成 ref.listen 就绪状态的 provider，不再挂在 build 上。退出、托盘、ctl 的生命周期拆分单独列一条去做。

## 核验补充（审计漏掉的）

- 切偏好的刷新清单至少有五条，比审计说的多两条。除了 refreshPrefCache 和 onApplied，还有：设置同步导入后的 refreshPrefCache 加 notifyListeners（fushi/lib/src/models/app_model.dart:1787），温弹窗 refreshForWarmDictionaryPopup（app_model.dart:6987），作品 Profile 叠加层进出时的 _reloadForWorkProfileScope（app_model.dart:12660 起）。五条清单各刷各的。例如 ReaderFushiSource.readerSettings.refreshFromDb 只在 onApplied（profile_view_model.dart:610）和作品叠加层路径里调，设置同步导入路径（1787）不调。于是同步导入别的设备的阅读器设置后，本机 readerSettings 很可能要重启才生效（推测，未复现）。同样，同步导入路径也不调 invalidateAnkiStateAfterPrefsChange。
- TexthookerService.foldProgressiveLines 不跟随 Profile 切换，可以按 bug 流程立刻修：全仓只有 app_model.dart:6184 和 :15836 两处推送，refreshPrefCache（6918）漏了这一项，而 profile_keys.dart 里没有任何 gal_hook 排除，这个键会随 Profile 快照切换。这是确定的代码路径缺陷（未在设备上复现），不必等重构。
- initialiseForSrsWriteHost（app_model.dart:1955-1959）自己另开一个 isMainProcess:false 的 FushiDatabase，可它不在审计列出的四条关库路径里。DatabaseSession 方案必须把这条路径也纳入，否则还会多出第五份手写清理。
- PreferencesRepository 本身就是一个大单体：同一个 ChangeNotifier 里有几十处整仓 notifyListeners（preferences_repository.dart:311-1065 起），还混着 settle 迁移和代理读取器绑定（loadFromDb 里，见 app_model.dart:6190 起的注释）。它继承 ChangeNotifier，不能下沉到 fushi_engine，这正是 app 和 server 无法共用偏好与迁移逻辑的结构性原因，审计的两条方案都默认它能共用，而没有处理这个前提。
