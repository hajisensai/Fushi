# 架构审计：database

2026-11-28 只读审计 + 独立反驳核验的原始结论。总方案见 [../../specs/2026-11-28-architecture-redesign.md](../../specs/2026-11-28-architecture-redesign.md)。

## 现状

Drift 层是一个类：FushiDatabase（packages/fushi_core/lib/src/database/database.dart:1245）混入 25 个私有 mixin（每个一份 *.part.dart），一共约 1000 个公开 Future/Stream 方法。所有 app、引擎、服务端的消费方都直接依赖这整个类型，没有 DAO 边界。schema 版本在 db_schema_version.dart 里统一定义（v182，最低支持 v75）。迁移是 onUpgrade 里一整个约 2300 行的内联闭包（database.dart:1617-3901），共 77 级 `if (from < N)`，用了 339 处 _tableExists/_columnExists 守卫。beforeOpen 里还挂着历史事故的逐次修复。索引全部手写在 customStatement 里，没有一处 @TableIndex，onCreate 和升级路径各建一份。开库是两次：先在调用方 isolate 同步探测一次，再开 drift 后台连接；整个库只有一条连接。偏好层：preferences 是一张 (key,value) 万能表，用 PrefCodec 带类型标签编码。app 侧 PreferencesRepository 有 8479 行，用 dynamic getPref 加 400 多处 `as T` 强转，整体是一个 ChangeNotifier，并且被 AppModel 转成全局广播。同一张表在内存里至少有 5 份互相独立的整表镜像：PreferencesRepository、ThemeNotifier、每个 MediaSource、ReaderSettings、服务端 ServerPrefs。键的属性（是否设备本地、是否凭据、是否随 Profile、是否作品级、默认值、类型）分散在 ProfileKeys、PrefRedactionPolicy、SyncRepository、WorkProfileScope、preference_keys.dart、各 getter 和设置 schema 至少 7 处，靠守卫测试防它们互相漂移。设置页、ctl、伴屏已经共用同一份 settings schema 闭包，这一块是健康的。下面的发现都只读核实过，没有跑测试。

## pref-key-registry

**偏好键的属性分散在 7 处以上手写清单里，默认归属是「随 Profile 走」的反向登记，漏登一个就出 bug**

- 类型：缺单一登记源；规模 XL；价值 high；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/profile/profile_keys.dart:69 `_excludedPrefKeys`（约 60 个点名键）和 :199 `_excludedPrefPrefixes`：不在名单里的键一律当成随 Profile 走
- fushi/lib/src/sync/pref_redaction_policy.dart:80 `sensitiveKeys`、:157 `deviceLocalKeyPrefixes`、:172 后缀表；注释里反复写「也在 deviceLocalPrefKeys 中，双重声明」「点名防名单漂移」
- fushi/lib/src/sync/sync_repository.dart:2021 `deviceLocalPrefKeys`，是第三份设备本地清单
- fushi/lib/src/profile/work_profile_scope.dart:299-310 `isWorkScopedPrefKey`：前缀规则加例外，再并上 videoSubtitleStylePrefKeys、srsMiningPrefKeys、ThemeNotifier.isProfileThemePrefKey
- fushi/lib/src/models/preference_keys.dart:1-16 自称「唯一新增键入口」，实际只登记键名，不带类型、默认值、作用域；守卫只扫字面量，含 `$` 的动态键直接跳过
- packages/fushi_engine/lib/sync/interconnect_service_config.dart:47,68,87 和 packages/fushi_server/lib/src/server_subtitle_providers.dart:51 又各手写一遍同样的键名
- bug 类（读过根因段）：BUG-1019（audiobook_* 进度被 Profile 快照吞掉）、BUG-1072（凭据判定散落三处导致泄漏）、BUG-3754（不再提醒标记被切 Profile 删掉）、BUG-5073（日界随 Profile 但镜像不刷新）、BUG-3310（被同步的开关）。docs/bugs 里提到 Profile 快照 / deviceLocalPrefKeys 的有 33 份

机制：键只是一个裸字符串，作用域、敏感性、同步、备份这些属性没有和键绑在同一个声明里，而是由各子系统用「排除名单 / 前缀 / 子串兜底」反向推出来。新键默认落进「随 Profile 走、可出境」，作者必须记得去 N 处登记。漏一处的后果是切 Profile 时被 prune、凭据随备份出境、作品会话接管错键，而且都是静默的。守卫测试只能校验几份名单之间不漂移，校验不了某个新键在语义上该归哪一类。

根本方案：在 fushi_core（纯 Dart，app 和 server 共用）新建 `PrefKey<T>` / `PrefKeyFamily<T>`（前缀加后缀）声明：`const PrefKey<bool>('srs_lapis_migration_reminder', defaultValue: true, scope: PrefScope.deviceLocal, sensitivity: PrefSensitivity.none, sync: PrefSync.never, backup: BackupCategory.settings)`。scope 是必填枚举（deviceLocal / install / profile / work / appReader），不给默认值，这样「忘了归类」在编译期就写不出来。凭据键用 `sensitivity: credential`。按域分文件登记（`prefs/reader_keys.dart`、`prefs/video_keys.dart` 等），由一个 `allPrefKeys` 聚合。ProfileKeys._excludedPrefKeys/_excludedPrefPrefixes、PrefRedactionPolicy.sensitiveKeys/deviceLocalKeyPrefixes/Suffixes、SyncRepository._deviceLocalFixedKeys、WorkProfileScope 里的几组 Set、kKnownPreferenceKeys 全部改成从 `allPrefKeys` 派生的查询（`isExcludedPref(k) => registry.scopeOf(k) != PrefScope.profile`），手写清单删掉。credentialSubstrings 形状兜底保留为最后一道防线。PreferencesRepository 的 getter 改成 `prefs.get(kReaderFollowBookLayout)`，类型来自 T，删掉约 413 处 `as bool/String`。设置 schema 的 defaultValue 也从 PrefKey 取。以后新增一个键只改一处声明。守卫换成「运行时扫 preferences 表里出现过、但注册表匹配不到的键」，加上「get/set 只接受 PrefKey」（把裸 String API 改成 @internal）。

要动：fushi/lib/src/models/preference_keys.dart；fushi/lib/src/models/preferences_repository.dart；fushi/lib/src/profile/profile_keys.dart；fushi/lib/src/profile/work_profile_scope.dart；fushi/lib/src/sync/pref_redaction_policy.dart；fushi/lib/src/sync/sync_repository.dart；fushi/lib/src/sync/backup_service.dart；packages/fushi_engine/lib/media/media_pref_keys.dart；packages/fushi_engine/lib/sync/interconnect_service_config.dart；packages/fushi_server/lib/src/server_prefs.dart；fushi/test/models/preference_keys_guard_test.dart

核验说明：已核对，属实。profile_keys.dart:69 有 _excludedPrefKeys，:199 有 _excludedPrefPrefixes，采用反向排除。pref_redaction_policy.dart:80 有 sensitiveKeys，:96/:112/:115/:123/:126 的注释自己写着「也在 deviceLocalPrefKeys 中，双重声明」。sync_repository.dart 另有一份 deviceLocalPrefKeys（:107/:326 一带都引用它）。work_profile_scope.dart:299-310 的 isWorkScopedPrefKey 是前缀规则，再并上 3 组 Set 和 ThemeNotifier 判定。键的属性确实分散在多处，靠守卫防漂移，没有单一登记源。

方案风险：① 动态键族要用 PrefKeyFamily 表达：ReaderSettings 的 `$_prefix$key`（按源前缀）、`src:<id>:`、audiobook_pos_<bookKey> 都属于这类。scope 判定若靠前缀匹配，最长前缀与例外（如 floating_lyric_ 下的 kFloatingLyricWindowRectPrefKey）必须能表达，否则又会长回一堆例外分支。② fushi_core 拿不到 app 层的键，所以注册表的类型放 core，键声明分放 core / engine / app，allPrefKeys 由 app 装配。服务端只能看到 core+engine 的子集，server 侧派生的判定会少键，要明确它在服务端的语义。③ 「运行时扫表里出现过、但注册表匹配不到的键」这条守卫只能在测试或调试态跑，生产态不能因为未知键报错：旧版本、外部导入和扩展都会写入未知键。④ 属于 XL 级改动，要按域分批迁，每批跑一次现有守卫；不能一次删掉 7 份清单。不涉及冻结键名，也不改 wire。

## pref-mirror-caches

**同一张 preferences 表在内存里有 5 份以上独立整表镜像，各自整表读取，两种写编码并存**

- 类型：镜像状态；规模 L；价值 high；不改外部行为
- 核验：部分成立

证据：

- fushi/lib/src/models/preferences_repository.dart:330-336 `_prefCache` 整表 getAllPrefs
- fushi/lib/src/models/theme_notifier.dart:2085-2090 自己维护一份 `_prefs` 整表副本（:1499、:1791 还有两次 getAllPrefs）
- fushi/lib/src/media/media_source.dart:145-153 每个 MediaSource 各做一次 getAllPrefs，再在 Dart 里按前缀过滤
- fushi/lib/src/reader/reader_settings.dart:152 又一份整表读取；:198-206 `_set` 写的是裸 `value.toString()`，而 MediaSource/PreferencesRepository 写的是 PrefCodec 标签值。BUG-1116 只在读侧兼容了两种格式，双编码至今还在
- fushi/lib/src/models/app_model.dart:6918-6943 `refreshPrefCache`：prefsRepo 整表读 1 次，每个 source 各 1 次，theme 1 次，再加 Anki 和快捷键重载
- packages/fushi_core/lib/src/database/database_statistics.part.dart:305-310 `static _statDayResetHour` 是偏好的进程静态镜像，BUG-5073 就是切 Profile 后没有重新镜像
- packages/fushi_server/lib/src/server_prefs.dart:12-17 服务端又写了一份缓存加编解码

机制：PrefStore 接口（packages/fushi_engine/lib/foundation/pref_store.dart）只有 get/set 两个方法，没有唯一的进程内持有者，也没有变更通知。于是每个需要偏好的子系统都自己整表读一遍、自己缓存，变更后靠 refreshPrefCache 按顺序挨个通知重载，或者塞进静态字段。每加一个镜像，都要记得把它挂进 refreshPrefCache 和 Profile 切换路径，漏了就是「切 Profile 后不生效直到重启」这一类 bug。这些重载每次都整表读取、整表解码。

根本方案：在 fushi_core 实现唯一的 `PrefsCore`：进程内只此一份已解码缓存，加载只走一条 getAllPrefRows；对外提供 `get<T>(PrefKey<T>)`、`watch(PrefKey<T>) -> ValueListenable/Stream`、`watchPrefix(prefix)`、`setMany`，写路径统一用 PrefCodec 编码。app 的 PreferencesRepository、ThemeNotifier、MediaSource._preferences、ReaderSettings._cache 和服务端 ServerPrefs 都改成它上面的薄视图（MediaSource 用 `src:<id>:` 前缀视图，ReaderSettings 用 reader 前缀视图），删除各自的 `_prefs` / `_cache` 和各自的 getAllPrefs 调用。Profile 切换、跨进程版本变化只让 PrefsCore 重载一次，再按键 diff 发出变更事件。FushiDatabase.statDayResetHour、DandanplayConfig.current 这类静态镜像改成订阅对应 PrefKey。refreshPrefCache 里逐个子系统的重载列表删掉。ReaderSettings._set 改走 PrefCodec，读侧保留 decodeUntyped 兼容旧值；这一步不改数据，只是新写入统一成标签格式。以后新增一个消费方只需要订阅 PrefKey。

要动：packages/fushi_engine/lib/foundation/pref_store.dart；packages/fushi_core/lib/src/database/database_prefs_media.part.dart；fushi/lib/src/models/preferences_repository.dart；fushi/lib/src/models/theme_notifier.dart；fushi/lib/src/media/media_source.dart；fushi/lib/src/reader/reader_settings.dart；fushi/lib/src/models/app_model.dart；packages/fushi_core/lib/src/database/database_statistics.part.dart；packages/fushi_server/lib/src/server_prefs.dart

核验说明：镜像部分属实。media_source.dart:147、theme_notifier.dart:1499/1791/2087、reader_settings.dart:152 各自整表 getAllPrefs；refreshPrefCache（app_model.dart:6918 起）按 prefsRepo、各 source、theme、Anki、快捷键的顺序逐个重载；ReaderSettings._set（:198-206）写 `value.toString()`，读侧在 :235-240 用 decodeUntyped 兼容两种格式（BUG-1116），双编码确实还在。漏掉的关键点：ReaderSettings.refreshFromDb 读的是 WorkProfileScope.instance.effectivePrefs(全表) 这层作品级会话覆盖，写入时 WorkProfileScope.overrides(dbKey) 会把值改道进覆盖层（:200-203）。方案里的 PrefsCore 没有建模这层覆盖。

方案风险：① PrefsCore 必须原生支持「全局值加作品会话覆盖层」两层视图，并把覆盖层的写路由收编进来，否则 ReaderSettings 这类视图会读写错层，作品级配置随即失效（反馈 kEFPY4cuKZ 那类回归）。② 把 _set 改成 PrefCodec 编码时，WorkProfileScope.write(dbKey, value.toString()) 那条覆盖层写入也要同步改成 PrefCodec，否则覆盖快照仍是裸串。③ 服务端 ServerPrefs 和 app 的 PrefsCore 应是同一个类的两个实例（各进程各一份），不能做成「进程唯一的全局单例」。:popup 进程、服务端进程各自持有一份，跨进程一致性仍靠 prefs_version。

修正后的方案（以此为准）：PrefsCore 分两层：底层是唯一的已解码表缓存（getAllPrefRows 只读一次）；上层由 WorkProfileScope 提供一个 overlay 视图，get/watch 先查覆盖层，set 按 isWorkScopedPrefKey 路由到覆盖层或底层，两层都用 PrefCodec 编码。ReaderSettings、MediaSource、ThemeNotifier 都做成 overlay 视图上的前缀视图。作品会话的开 / 关在 overlay 上按键 diff 发变更事件，取代各消费方的 refreshFromDb。

## pref-global-broadcast

**任何一次偏好写入都经 AppModel 广播，引起整个 app 重建；现在靠在各 setter 里「刻意不 notifyListeners」逐个挡**

- 类型：性能；规模 L；价值 high；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/models/app_model.dart:1153、:6158、:6802 `prefsRepo.addListener(notifyListeners)`；:747 appProvider 是 ChangeNotifierProvider，代码里有 74 处 `ref.watch(appProvider)`
- fushi/lib/src/models/preferences_repository.dart:2329-2337 注释写明「全局广播重建全 app」，所以这个 setter 刻意不通知，并要求「新增读取方必须自带刷新」；同类例外在文件里有 5 处
- fushi/lib/src/models/preferences_repository.dart 有 478 处 notifyListeners，基本是每个 setter 一处
- docs/bugs/BUG-1430-subtitle-obscure-switch-lag.md 根因 ③：全局广播重建全 app，有实测卡顿（已有 bug 记录，不是推断）

机制：偏好变更只有一个粒度：整个 PreferencesRepository 一个 Listenable，再被转发成 AppModel 的全局通知。消费方没法只订阅自己关心的键，所以每个 setter 都在「通知了全 app 重建」和「不通知、读取方自己刷新」之间二选一。后者只能靠注释约定，新读取方忘了就拿到旧值。这种按 setter 打例外的做法本身就在补粗粒度的结构。

根本方案：依托上一条的 PrefsCore 提供按键的 `ValueListenable<T>`，再加一个 Riverpod `prefProvider<T>(PrefKey<T>)` family（app 层装配）。widget 用 `ref.watch(prefProvider(kGamesLibraryListLayout))` 或 ValueListenableBuilder 只订阅自己的键。删掉 AppModel 里三处 `prefsRepo.addListener(notifyListeners)`，再把 PreferencesRepository 的 478 处 notifyListeners 和 5 处「刻意不通知」例外一起删掉，setter 不再负责通知。迁移期可以逐页把 ListenableBuilder(listenable: prefs) 换成按键订阅，最后去掉 PreferencesRepository 的 ChangeNotifier 基类，这样「全局广播」从结构上就写不出来了。

要动：fushi/lib/src/models/app_model.dart；fushi/lib/src/models/preferences_repository.dart；fushi/lib/src/pages/implementations/games_library_page.dart；fushi/lib/src/floating_ball/app_floating_ball_host.dart

核验说明：已核对。app_model.dart:1153/6158/6802 三处 `prefsRepo.addListener(notifyListeners)`；fushi/lib 里 `ref.watch(appProvider)` 有 74 处；preferences_repository.dart 里 notifyListeners() 有 472 处（审计写 478，数量级一致）。BUG-1430 已有卡顿记录。

方案风险：这 74 个 watch(appProvider) 的消费方，以及所有通过 appModel 读 prefsRepo getter 的 widget，眼下都隐式依赖这条全局广播来拿到新值。删掉 addListener 必须放在最后一步，并且要先枚举出每个读 prefsRepo 的 build 方法、逐个改成按键订阅，否则会大面积出现「改了设置不刷新」。建议加一个守卫：build 里读 prefsRepo getter 却没有订阅对应 PrefKey 的就报错，或者在迁移期保留一个 debug 断言。

## prefs-table-as-state-store

**每秒写的播放进度这类状态塞在 preferences 里，每次写都抬全局 prefs_version，触发 :popup 整表重载**

- 类型：性能；规模 L；价值 high；改持久化 / wire
- 核验：部分成立

证据：

- packages/fushi_audio/lib/src/audiobook/audiobook_repository.dart:330-349 注释说「播放中每个整秒走一次这里」，经 setPrefs 写 audiobook_pos_/pos_at_
- packages/fushi_core/lib/src/database/database_prefs_media.part.dart:118-140 每次 setPref/setPrefs 都在事务里额外读改写一次 prefs_version（_bumpPrefsVersion :274）
- fushi/lib/src/models/app_model.dart:6963-6966 `refreshPrefCacheIfChanged`：版本号一变就做完整的 refreshPrefCache（整表多次读取，加 Anki 状态失效）
- fushi/lib/src/sync/sync_orchestrator/audiobooks.part.dart:27 和 packages/fushi_engine/lib/sync/local_library_host_service/audiobooks.part.dart:20 为了找 audiobook_pos_ 键做整表 getAllPrefs 再扫描
- fushi/lib/src/profile/profile_keys.dart:199-216 还得专门把 8 个 audiobook_*_ 前缀排除出 Profile 快照（BUG-1019 的起因就是状态被当成了设置）

机制：preferences 同时承担「用户设置」和「按条目的运行状态 / 进度 / 扫描索引 / 日志」两种角色，而跨进程变更信号 prefs_version 是全表一个计数器、不区分这两类。结果是播放进度每秒推进一次，:popup 下次查词就判定「偏好变了」，然后做整表重载、重建派生状态。同步、主机服务为了枚举某一族状态也只能整表扫。两种角色混在一起，又反过来要求 Profile、备份、同步各自写排除前缀。性能影响是按代码路径推断的：每秒一次的写入频率来自代码注释，:popup 端实际重载次数没有实测。

根本方案：两步走。第一步不改数据：在 PrefKey 注册表里给键加 `kind: setting | state`，_bumpPrefsVersion 只对 setting 类键执行（判定在 FushiDatabase.setPref 这个唯一写入口按注册表做；fushi_core 拿不到 app 注册表时，可以由 PrefsCore 在调用 setPref 时传 `bumpVersion` 参数）。这样进度写入就不再触发 :popup 重载。第二步（持久化变更，需要拍板）：把 audiobook_*_、远端视频续播、书库扫描索引、book_library_prune 日志这些按条目的状态族迁到有类型的表（比如 `audiobook_playback_state(book_key PK, position_ms, position_at, speed, volume, follow, delay...)`），用一次性迁移搬走旧行。同步、主机服务改成按主键查询；ProfileKeys 里对应的排除前缀和 backup 里的 progress 谓词也随之删掉。冻结名规则只约束「不改名」，迁表属于数据迁移，要单独评估。

要动：packages/fushi_core/lib/src/database/database_prefs_media.part.dart；packages/fushi_audio/lib/src/audiobook/audiobook_repository.dart；fushi/lib/src/models/app_model.dart；fushi/lib/src/sync/sync_orchestrator/audiobooks.part.dart；packages/fushi_engine/lib/sync/local_library_host_service/audiobooks.part.dart；fushi/lib/src/media/video/remote_video_resume.dart；fushi/lib/src/profile/profile_keys.dart；packages/fushi_core/lib/src/database/tables.dart

核验说明：写入频率已核实：audiobook_controller.dart:1535/1568 按整秒去重后调 onPositionWrite，接到 audiobook_session_launcher.dart:251 的 updatePositionMs，再走 setPrefs，每次都抬一次 prefs_version（database_prefs_media.part.dart:118-140、:274）。所以播放中大约每秒抬一次版本号。审计说的影响面需要收窄：refreshPrefCacheIfChanged 的调用方只有 popup_main.dart 一处，只在 :popup 查词前跑一次，所以代价是「每次查词前做一次完整重载」，不是「每秒重载」。prefs_version 的其他读者在 migration_importer、profile_repository、extension_profile_adapter 里，也要一并评估。

方案风险：① 第一步「state 类键不抬版本号」有一个前提：:popup 和其他 prefs_version 读者（profile_repository、migration_importer、extension_profile_adapter）都不需要感知 state 键的变化。目前没有核实。若 :popup 要显示有声书进度之类的状态就会读到旧值，必须逐个读者确认。② 第二步迁表属于持久化变更：备份 / 同步的 wire 里这些键是以 preferences 行的形式出境的（sync_orchestrator/audiobooks.part.dart 和 host_service 按 audiobook_pos_ 键读写，LWW 依赖 runIfIntPrefUnchanged 按键成对比较）。迁表就要同时改同步协议、做旧版本对端兼容，并改 BUG-4825 的事务原子性实现。这是跨设备的 wire 兼容问题，不只是本地数据迁移，必须交拍板。

修正后的方案（以此为准）：第一步只做「按键类别决定是否 bump」，并先列出 prefs_version 的全部读者，逐个确认它们不依赖 state 键。第二步迁表进拍板台，附上同步 wire 的兼容方案：新表与旧 pref 键在一个过渡期内双写，或者协议版本协商。

## index-declarations-handwritten

**索引全部手写 customStatement，onCreate 和升级路径各建一份，靠「两处 SQL 必须逐字一致」的注释维持**

- 类型：缺单一登记源；规模 M；价值 high；不改外部行为
- 核验：成立

证据：

- packages/fushi_core/lib/src/database：79 处 `CREATE INDEX` 字面量，`@TableIndex` 一处都没有（grep 计数）
- packages/fushi_core/lib/src/database/database_infra.part.dart:145 `_ensureIndexes`（注释：只在 onCreate 和个别迁移步里跑，不是每次开库）、:339 `_ensureStatIndexes`；另有 database_srs.part.dart:143/151、database_music.part.dart:32/56、database_ai_agent.part.dart:68/83/90，一共 9 个 _ensure*Index
- packages/fushi_core/lib/src/database/database.dart:2523-2528 「索引与建表同步内联：`_ensureIndexes` … 升级路径不会自动补上」；:2576-2578 「fresh 库由 `_ensureIndexes` 建同名索引，两处 SQL 必须逐字一致」
- packages/fushi_core/lib/src/database/database.dart:3897-3923 onUpgrade 末尾补 _ensureStatIndexes 的理由是「v105 后新装的库 onCreate 曾漏建（video-36i）」；onCreate 末尾手动串 9 个 _ensure* 调用，另有 2 条内联
- docs/bugs/BUG-906-prefs-version-txn-and-indexes.md 缺陷 B：热路径缺索引

机制：索引没有和表定义写在一起，drift 的 createAll 和 Migrator 都不知道它们的存在，只能在 onCreate 和对应的升级台阶里各写一遍 SQL。有的清单会被更早的台阶调用，而那时列还没加，所以又不得不把部分索引拆出来内联（v81、v82 的 uid / book_uid 索引）。漏掉 onCreate 一侧，新装库就缺索引；漏掉升级一侧，老库就缺索引。两种情况都不报错，只是变慢。

根本方案：索引一律在表类上用 drift 的 `@TableIndex(name:'idx_…', columns:{#profileId,#dateKey}, unique:…)` 声明；部分索引和表达式索引用 `@TableIndex.sql(...)`。这样 onCreate 的 `m.createAll()` 自动建全。阶梯跑完后，由一个通用的 `_reconcileDeclaredIndexes(m)` 遍历 `allSchemaEntities.whereType<Index>()`：对应表存在、所需列也都在就 `CREATE INDEX IF NOT EXISTS`（每次升级都跑，全部幂等）。删除 9 个 _ensure*Index 和各台阶里内联的 CREATE INDEX（已发布台阶里的 DDL 可以留着，但不再是建索引的唯一来源）。以后新增索引只在表类上加一个注解。守卫换成「fresh 库与从最老 fixture 升上来的库，sqlite_master 中索引集合相等」，见下一条。

要动：packages/fushi_core/lib/src/database/tables.dart；packages/fushi_core/lib/src/database/*_tables.dart；packages/fushi_core/lib/src/database/database.dart；packages/fushi_core/lib/src/database/database_infra.part.dart；packages/fushi_core/lib/src/database/database_srs.part.dart；packages/fushi_core/lib/src/database/database_music.part.dart；packages/fushi_core/lib/src/database/database_ai_agent.part.dart

核验说明：已核对。onCreate（database.dart:3901 起）手动串了 9 个 _ensure* 调用，外加 2 条内联 CREATE INDEX，注释写明「与 v81/v82 步成对」；onUpgrade 末尾补 _ensureStatIndexes 的理由是 video-36i 曾漏建。database 目录下 CREATE INDEX 字面量有 72 处（审计写 79，相近），没有任何 @TableIndex。只有逐版本迁移测试各自检查个别索引，没有全局「新装与升级索引集合相等」的校验。

方案风险：① @TableIndex 的 name 必须和现有索引名逐字一致，IF NOT EXISTS 才不会造出重名的第二份索引；部分索引（如 idx_epub_books_uid 的 WHERE uid != ''）和 DESC 列要用 @TableIndex.sql。② 有些索引可能建在 srs 相关表或其他库文件上（_ensureSrsIndexes），要确认它们在 fushi.db 的 allSchemaEntities 里，不属于另一个数据库类。③ 存量库上若有同名但定义不同的旧索引，IF NOT EXISTS 不会纠正；reconcile 要比对 sqlite_master.sql，必要时 DROP 后重建。

## migration-ladder-patch-stack

**迁移阶梯是 2300 行内联闭包加 339 处存在性守卫，还叠着并行历史的重放补丁和每次开库的修复，没有「新装与升级 schema 等价」的结构性校验**

- 类型：补丁叠补丁；规模 XL；价值 medium；不改外部行为
- 核验：部分成立

证据：

- packages/fushi_core/lib/src/database/database.dart:1617-3901 onUpgrade 单个闭包，77 级 `if (from < N)`，全文件 339 处 _tableExists/_columnExists
- packages/fushi_core/lib/src/database/database.dart:3949-3954 beforeOpen 每次开库都跑 `_ensureDictionaryExpandedLanguagesColumn`（BUG-2335 版本号撞车）和 `_repairProfilesColumnShift`（:1502，覆盖恢复写错位）；:3960 起还在 beforeOpen 里做视频刮削 run 的业务对账
- docs/bugs/BUG-2162-schema-drift-v95-missing-columns.md 根因：并行迁移史把版本号先写高，`from < 52/57/87/88` 永远不再进入，只能开 v97 新台阶重放
- packages/fushi_core/lib/src/database/database.dart:3881-3897 v182 台阶要写 9 个 _tableExists 守卫，因为「迁移测试的局部建表夹具会缺表」，测试夹具的形状反过来渗进了生产迁移代码
- fushi/test/database/*.dart：约 90 处 `expect(db.schemaVersion, kFushiDbSchemaVersion)`、8 处 `expect(user_version, db.schemaVersion)`，都是恒真断言（BUG-2022 之后从字面量改成常量，绊线失效）；仓内没有 SchemaVerifier / drift_schemas 快照，也没有 fresh 与 upgraded 的 sqlite_master 对比

机制：阶梯只认 user_version，不认库的真实形状。只要版本号与形状对不上（并行历史、恢复错位、局部夹具），就只能逐个开重放台阶、在 beforeOpen 里加专项修复、在每一步加存在性守卫。同时没有任何机制断言「从 v75 升上来的库」和「新装库」结构一致，漂移只能等用户报 no such column 才发现。那批恒真断言让人以为有覆盖，实际什么也没测。

根本方案：① 用 drift_dev 的 `make-migrations` / `schema dump` 给每个发布版本生成 drift_schemas/drift_schema_vN.json 快照，加上生成的 `stepByStep` 有类型台阶；新台阶在 `database_migrations/vN.dart` 里一个函数一个文件，onUpgrade 只负责分发。② 阶梯之后跑一次通用的 `_reconcileSchemaShape(m)`：按生成的当前 schema 对比 `PRAGMA table_info`，只补 additive 的缺列、缺索引、缺表，用来替代 _replayColumnStepsForDriftedSchema 和 _ensureDictionaryExpandedLanguagesColumn 这类按事故写的重放（按值修数据的 _repairProfilesColumnShift 仍单独保留，但移进一个有登记的一次性修复表并打完成标记，不再每次开库都跑）。③ 刮削 run 对账这种业务逻辑移出 beforeOpen，放到 app 启动服务。④ 测试换成 drift 官方的 `SchemaVerifier`：对每个历史快照 vN 验证「升到当前版本后 validateDatabaseSchema 通过」，删掉约 100 处恒真断言和夹具驱动的生产守卫（测试改用快照生成的完整旧库，不再手搭局部表）。⑤ 另交拍板：要不要把 kMinSupportedSchemaVersion 从 75 抬高，以便整段删掉老台阶（这会改变用户可见行为，极老的库将无法打开）。以后加一列只需改表定义，再加一个 vN 台阶文件，再 dump 一次 schema。

要动：packages/fushi_core/lib/src/database/database.dart；packages/fushi_core/lib/src/database/db_schema_version.dart；packages/fushi_core/pubspec.yaml；packages/fushi_core/drift_schemas/；fushi/test/database/

核验说明：结构问题属实。onUpgrade 是单个超长闭包；v182 台阶（:3881-3897）为了迁移测试的局部夹具写了 9 个 _tableExists 守卫，注释原话是「只有迁移测试的局部建表夹具会缺表」。beforeOpen 里每次开库都跑 _ensureDictionaryExpandedLanguagesColumn 和 _repairProfilesColumnShift，还有刮削 run 的业务对账。仓内没有 drift_schemas、没有 SchemaVerifier，也没有全局的 fresh 与 upgraded 对比。夸大的部分：`expect(db.schemaVersion, kFushiDbSchemaVersion)` 确实恒真，但另有约 100 处 kFushiDbSchemaVersion 断言，其中 `expect(user_version, db.schemaVersion)` 在开库升级之后读的是磁盘上的 user_version，确实验证了迁移跑完，不能一概算恒真。

方案风险：① SchemaVerifier 要求有 v75 到 v181 每个历史版本的 schema 快照，这些快照现在不存在，只能从历史提交逐版本 dump。2026-11-01 的 filter-repo 重写保留了树内容，所以理论上可以做，但工作量很大，且要逐个核对 dump 的形状和当时真实的发布库一致（并行历史 BUG-2162 正说明「同一个版本号对应过两种形状」）。务实做法是只为当前版本 dump 一份，再加「从最老真实 fixture 升上来的库与新装库对比 sqlite_master」的守卫。② 用通用的 _reconcileSchemaShape 自动补缺列会掩盖迁移台阶本身的错误，和根因修复原则冲突。它应该只在检测到漂移时补齐并上报日志，测试态下漂移直接判失败。③ 刮削 run 对账依赖 `_isMainProcess`，而且要求「在任何 app 查询之前」完成；移到启动服务时必须保证它排在首页刮削批次启动之前。④ pubspec 里 drift 钉在 >=2.33.0 <2.34.0，drift_dev 是 ^2.23.0，lock 里 drift 解析到 2.33.0。make-migrations 依赖的 drift_dev 版本要和 drift 2.33 匹配，升级 drift_dev 时同样受这个钉版约束，要注明钉版的理由。

修正后的方案（以此为准）：第 ① 步改为：只 dump 当前版本的快照，加一个守卫，用 v75 最老真实 fixture 升级后的库对比新装库的 sqlite_master（表、列、索引、外键）；以后每次发版再追加快照，SchemaVerifier 只覆盖新增版本。第 ② 步的 reconcile 在生产态补齐并打日志，在测试态漂移即失败。其余照原方案。

## double-open-single-connection

**开库先在调用方 isolate 同步探测，再在后台二次开库，恢复逻辑层层包装；整个库只有一条连接，读写互相排队**

- 类型：成类 bug；规模 M；价值 medium；不改外部行为
- 核验：部分成立

证据：

- packages/fushi_core/lib/src/database/database.dart:384-395 Layer 0 在调用方（UI）isolate 上 `sqlite3.open` 加 `_applyOpenPragmas`（WAL 切换，最长 5s busy），同步执行，然后关掉，再交给后台连接
- packages/fushi_core/lib/src/database/database.dart:379-383 注释 BUG-4954 写明「探测过了不等于后台连接也能过」，于是又包一层 `_RecoveringOpenExecutor`（:553）和 `_TypedOpenErrorInterceptor`（:951，BUG-4509）
- packages/fushi_core/lib/src/database/database.dart:1-1245 开库段引用了 BUG-772/1870/1899/4241/4509/4701/4954/5076 共 8 个 bug；docs/bugs/BUG-772-video-startup-freeze.md 修复 ③ 就是在缓解 probe 在 UI isolate 上的同步阻塞
- packages/fushi_core/lib/src/database/database.dart:426-427 `NativeDatabase.createInBackground(dbFile, setup: _applyOpenPragmas)` 没有传 readPool，WAL 下的只读查询和写事务共用一条队列
- 同类机制有实测：docs/bugs/BUG-3961-srs-concurrent-reads-serialized.md（srs.db 单队列，长读拖慢短读，设置页约 20s）

机制：打开同一个文件被拆成两条独立的连接生命周期（探测连接和后台连接）。两次打开之间 sidecar 状态可能变化，所以每发现一种失败模式就再包一层恢复或拦截器。探测放在调用方 isolate 上，又给启动路径带来了同步 IO。主库单连接这一条是推断：fushi.db 上的统计聚合（database_statistics.part.dart 约 2000 行）、库管家扫描等长读会挡住 UI 的短读和写；srs.db 的实测说明这个机制确实存在，但 fushi.db 本身还没有实测数据。

根本方案：开库只做一次，而且在后台 isolate 内完成：自建 `DriftIsolate.spawn`（或 `NativeDatabase.createInBackground(isolateSetup:…)`），把头部校验、sidecar 恢复阶梯、PRAGMA 和失败分类（classifyFushiDatabaseOpenFailure）都放进那个 isolate 里的同一个打开函数，用一条有类型的结果（成功 / FushiDatabaseUnrecoverableException）回传。删掉 Layer 0 探测连接、_RecoveringOpenExecutor、_TypedOpenErrorInterceptor 和 debugAfterOpenProbeForTesting。UI isolate 上不再有任何同步的 sqlite 调用。在 WAL 下给 createInBackground 配 `readPool: 2~4`（drift 2.33 支持），事务外的只读查询走读池；需要读己之写的路径放进 transaction。接入前先拿真实库副本量一下统计页和库管家的长读对 UI 短读的阻塞时长（目前是推断，要实测落地）。

要动：packages/fushi_core/lib/src/database/database.dart；packages/fushi_core/lib/src/database/sqlite_busy_timeout.dart；packages/fushi_core/lib/src/database/database_check.dart

核验说明：双开库属实：database.dart:384-395 在调用方 isolate 用 sqlite3.open 加 _applyOpenPragmas 做同步探测，之后由 :427 createInBackground 再开一次，并包上 _RecoveringOpenExecutor（BUG-4954）。单连接属实：createInBackground 没有传 readPool。不过 fushi.db 上「长读挡住 UI」是推断，审计自己也标了没有实测。drift 2.33 的 createInBackground 是否带 readPool 参数我没有在本地源码里核实（推测有）。

方案风险：① readPool 和侧车恢复阶梯冲突：恢复阶梯可能删除 -wal/-shm（allowSidecarDelete）。有读池时，多条连接同时持有 WAL，任何一条撞到侧车错误时都不能在别的连接还开着的情况下删侧车，否则会损坏数据。所以恢复必须在全部连接建立之前于同一个 isolate 里串行完成，读池连接的 setup 失败也要走同一套分类。② 每条读池连接的 setup 都要装 installWallClockBusyTimeout 和 registerFushiSqlFunctions，「检查数据库」用到的自定义函数在读连接上也得可用。③ 多进程（:popup、服务端）共享同一个 WAL 文件，读池会增加 checkpoint 饥饿的风险，需要实测 WAL 增长。④ Layer 0 的初衷是在开库时就同步抛出可分类的错误（BUG-4509 typed error）。移进后台 isolate 后，必须保证 open() 返回 future 之前已经完成真实开库并回传有类型的结果，不能退化成等到第一次查询才抛。

修正后的方案（以此为准）：分两步。第一步：开库、恢复、PRAGMA 合并成后台 isolate 里的单次打开，用 DriftIsolate 或自建 isolate 回传有类型的结果，删掉 UI isolate 上的探测连接；这一步风险低、收益确定。第二步：readPool 在实测 fushi.db 长读阻塞之后再决定，前提是恢复阶梯只在写连接建立前串行执行，读池连接不参与恢复，只做失败分类后整体重开。

## table-fate-registry

**每张表的出境 / 设备本地去向在 4 份字符串清单里各写一遍，靠守卫测试防漂移**

- 类型：守卫代替结构；规模 M；价值 medium；不改外部行为
- 核验：部分成立

证据：

- fushi/lib/src/sync/backup_service/table_rules.part.dart:70 `backupTableRules` 自称「每张表的去向唯一真相源」，但 :445-451 又导出 `_deviceLocalTables`、`_deviceLocalTablesParentFirst`、`_statisticsTables` 给守卫做「不漂移」比对
- fushi/lib/src/sync/backup_service.dart:521、:598、:673 三份手写表名清单；同一张表（如 remote_audio_bindings、music_scrape_meta）在 :540/:600、:577/:636 重复出现
- fushi/lib/src/sync/backup_merge_engine.dart:2615-2641 合并导入的设备本地表又写了第四份，每条都带「vNNN：…设备本地」注释
- fushi/test/sync/backup_table_rules_guard_test.dart:12-16 守卫要求 schema 里每张表都登记，起因是 32 张没人点名的表整份随包出境

机制：「这张表属于设备本地、统计、还是跟随某个类别」是表本身的属性，却以表名字符串的形式散在 backup、restore、merge 三个子系统的清单里。每加一张表就要改 3 到 4 处，删除顺序（父表在前还是子表在前）也要手工排。守卫只能抓「没登记」和「清单之间不一致」，抓不到「登记错了类别」。

根本方案：在 fushi_core 的表定义旁边建一个按 `TableInfo` 键控的 `kTableFates` 注册表（`{videoThemeSongSpans: TableFate.deviceLocal(reason:'本机重算'), studySegments: TableFate.follows({statistics}), …}`），用 TableInfo 而不是字符串，编译期就能发现表名不存在。删除顺序用 drift 的外键元数据（`$TableInfo` 上的 references）做拓扑排序自动得出，不再手写 ParentFirst 清单。backupTableRules、_deviceLocalTables、_deviceLocalTablesParentFirst、_statisticsTables 和 merge engine 那份清单都改为从注册表过滤得到，原清单删除。守卫简化成「`allTables` 中每个都在 kTableFates 里」一条（最好用穷举 switch 写成编译期约束）。以后新增一张表只在注册表里加一行。

要动：fushi/lib/src/sync/backup_service/table_rules.part.dart；fushi/lib/src/sync/backup_service.dart；fushi/lib/src/sync/backup_merge_engine.dart；fushi/lib/src/sync/backup_service/restore.part.dart；packages/fushi_core/lib/src/database/tables.dart；fushi/test/sync/backup_table_rules_guard_test.dart

核验说明：四份清单属实：table_rules.part.dart:70 的 backupTableRules，:445-451 为守卫导出的 _deviceLocalTables / ParentFirst / _statisticsTables，backup_service.dart:515-600 一带的多份清单，backup_merge_engine.dart:2610 起又一份设备本地表清单。不过 table_rules.part.dart:440-443 的注释说明，分成「子表在前 / 父表在前」两份是有意设计（foreign_keys=ON 下删除和恢复方向相反），并不是单纯的重复。

方案风险：① 「用 drift 的 $TableInfo 外键元数据做拓扑排序」不可行：drift 生成代码在运行时并不以结构化形式暴露外键目标，大量 FK 写在 customConstraint 字符串或 REFERENCES 文本里（tables 文件里 references( / REFERENCES 共 66 处）。应改用运行时 `PRAGMA foreign_key_list` 求拓扑序，或者在注册表里显式声明父表。② 表的去向是备份 / 同步策略，属于 app 层（fushi/lib/src/sync）。放进 fushi_core 的话，server 会依赖它，服务端自己的备份语义要先确认；若只有 app 用，注册表应该放在 app，用 core 导出的 TableInfo 做键。

修正后的方案（以此为准）：kTableFates 放在 app 的 sync 层，以 TableInfo 为键，用穷举守卫保证 allTables 每张都登记。删除和恢复顺序在运行时由 PRAGMA foreign_key_list 拓扑排序得到（正向用于恢复，反向用于清空），并用守卫测试对照当前 schema 验证这个顺序在 foreign_keys=ON 下可执行。

## 核验补充（审计漏掉的）

- drift 钉版不一致：packages/fushi_core/pubspec.yaml:16 把 drift 钉在 >=2.33.0 <2.34.0，dev 依赖 drift_dev 却是宽松的 ^2.23.0（:22），钉版理由没有写在 pubspec 里。迁移阶梯重构若引入 make-migrations / schema dump，codegen 和运行时版本必须锁成一对，并写明理由，否则 build_runner 解析到不匹配的 drift_dev 时会生成不兼容的代码。
- 生产迁移代码里渗进了测试夹具的形状：database.dart:3881-3897（v182）的注释原话是「只有迁移测试的局部建表夹具会缺表」，却写了 9 个 _tableExists 守卫。这是测试基建反向污染生产路径，比恒真断言更根本：应先把迁移测试统一改为「从真实 fixture 库升级」，再删掉这些守卫。审计只顺带提了一句，没有把它列为独立的根因项。
- beforeOpen 里掺了业务逻辑并有隐式顺序：database.dart:3958 起依赖 _isMainProcess 把刮削 run 标成 interrupted，要求在任何查询之前完成。开库层知道了业务表的语义，:popup 与主进程的区分也被塞进数据层。审计把它归在阶梯项里，没有指出其他进程（服务端、:popup）各自的开库语义没有统一定义。
- prefs_version 是全表单计数器，读者不只 :popup：fushi/lib/src/profile/profile_repository.dart、migration_importer.dart、extension_profile_adapter.dart 也读或写它。审计的「state 键不 bump」方案只考虑了 :popup，这几个读者没有核对。
- WorkProfileScope 的覆盖层是第六份偏好视图：fushi/lib/src/reader/reader_settings.dart:150-152 读的是 effectivePrefs(全表)，:200-203 写入时改道进覆盖层。审计的镜像清单把它漏掉了，可它决定了 PrefsCore 必须是两层结构。
