# 架构审计：dictionary-lookup

2026-11-28 只读审计 + 独立反驳核验的原始结论。总方案见 [../../specs/2026-11-28-architecture-redesign.md](../../specs/2026-11-28-architecture-redesign.md)。

## 现状

词典与查词域现在分四层。(1) 原生引擎 native/fushidicts（C++），对外是 C ABI。(2) packages/fushi_dictionary 包着这个引擎：FushiDicts 是静态单例，在 Dart 侧自己维护装载状态机（_pending、_generation、_inFlightShadow、_mappingHolds）；另有一个后台查词 isolate（background_lookup.dart），负责 FFI 结构转成 Dart 对象，再由 buildResultFromLookup / buildPopupJsonFromLookup 产出两种结果表示。(3) app 侧整条查词管线都在 17474 行的 app_model.dart 里，路径是 searchDictionary → _searchDictionaryInLanguage → _searchLocalDictionary（本地与远端并发后合并）。替对端、浏览器扩展、Yomitan API 查词的 _AppModelRemoteLookupService 又手写了一份 popup 快路径。fushi_server 的 dictionary_host.dart 再写一套清洗、对齐、汉字判定和同步 FFI 查词。(4) 渲染端：一份 11,639 行的 popup.js 被 in-app DictionaryPopupWebView（约 25 个可空回调）、app 外 WebView2 覆盖窗（overlay_bridge_handlers 的 switch）、词典样式预览（no-op 名单）、浏览器扩展三个壳（bridge-shim、side-panel、nested-popup-host 白名单）分别宿主。显示偏好一边由 popup_settings_injection 注入 window.*，另一边经 popup_theme_css 的 theme 通道下发给扩展。查词入口在 app 内已基本收口到 AppModel.searchDictionary，渲染设置 JS 也已共用 buildPopupSettingsJs，这两处不是问题。真正的问题集中在五处：结果文档有四到五个并行构建器；远端查词 API 是探测式接口叠出来的，而且 app 和 server 各写一套；任何元数据写入都会在 UI isolate 上同步重装整个引擎；popup.js 的桥协议没有登记源；显示偏好清单被多处手写。docs/bugs 里同一机制已反复出 bug：隐藏词典泄漏有 8 条以上，分组、排序、预算有 7 条以上，桥漏接有 5 条以上，偏好漏下发有 2 条以上。

## lookup-document-multi-builders

**同一份查词结果有 4~5 个并行构建器（原生 popup_json、buildPopupJsonFromLookup、buildResultFromLookup+逐条 extra、buildLookupEntriesJson、合并时对两种表示各改一遍），分组/预算/排序/隐藏/频率音高去重每修一次要改 N 处**

- 类型：缺单一登记源；规模 L；价值 high；不改外部行为
- 核验：部分成立

证据：

- packages/fushi_dictionary/lib/src/language/language.dart:163-243 buildResultFromLookup：词头分组、maximumTerms 预算、隐藏过滤、soleReadings、按词典排序
- packages/fushi_dictionary/lib/src/language/language.dart:295-490 buildPopupJsonFromLookup：同样的分组、预算、隐藏、排序又写一遍，另加频率/音高去重键，注释说「mirrors native popup_json」，并且承认与 fallback 路径语义不同（first 和 last deinflection 谁胜出不一样）
- fushi/lib/src/pages/implementations/dictionary_popup_webview.dart:4516-4560 buildLookupEntriesJson：从 DictionaryEntry 反解每条 extra JSON 重新分组，是第三份实现；由 popup_settings_injection.dart:782-784 popupEntriesJsonOf 在 popupJson 为空时回落调用
- native/fushidicts/fushidicts_src/popup_json.cpp:33-40（284 行）是原生第四份，注释写明靠 Dart 测试锁 parity；它的 Dart 包装 FushiDicts.lookupPopupJson（fushidicts.dart:1409）经 sym.py refs 查到 0 个调用方，是死代码
- packages/fushi_dictionary/lib/src/language/language.dart:111-161 每条 glossary 的 DictionaryEntry.extra 都拼进整个词头的 frequencies/pitches/trace JSON（同一词头 N 条释义就重复 N 份），消费端再逐条 jsonDecode
- packages/fushi_dictionary/lib/src/language/merge_search_results.dart:464-631 远端与本地合并时对 popupJson 和 entries 两种表示各做一次分组、并集、排序（_mergedPopupGroup、_rewrittenEntry），是第五份
- docs/bugs：BUG-791、1472、1749、1967、2579、2753、2997 的修复都写着「与 buildResultFromLookup / buildPopupJsonFromLookup 同一口径」，同一规则逐个构建器补

机制：DictionarySearchResult 同时装着两种互相独立构建的表示：entries（附带逐条 extra JSON 串）和 popupJson（弹窗文档串）。缺了一个只构建一次的规范中间模型，每个消费者（弹窗、制卡/历史、合并、回落渲染、原生）各自从原始结果或另一种表示重新推导。所以分组键、词头预算、词典顺序、隐藏过滤、读音补全这些规则每改一条，就得在所有构建器里同步，漏一处就出一个 bug。

根本方案：在 fushi_dictionary 新建唯一的规范模型 LookupDocument（纯 Dart、不可变），结构是 headwords[]（expression、reading、matched、trace、frequencies、pitches、glossaries[]）加上 kanji[]、bestLength、truncated、headwordCount。它在后台查词 isolate 里由 FFI 结果一次性构建，构建器只有 buildLookupDocument 一个，分组、预算、排序、读音补全只写在这里（隐藏过滤见 dictionary-visibility-layered-filter：交给引擎排除集）。弹窗 JSON 和 DictionaryEntry 都是它的纯投影：document.toPopupJson() 和 document.entries（惰性、按需生成，extra 只存 glossary 级字段，词头级字段从 document 取）。合并改成在 LookupDocument 层做一次 mergeDocuments，不再解析两份弹窗 JSON。要删除的有：buildPopupJsonFromLookup 和 buildResultFromLookup 里的重复逻辑、DictionaryPopupWebViewState.buildLookupEntriesJson 和 popupEntriesJsonOf 的回落、merge_search_results 里的双表示合并、原生 popup_json.cpp 与 fushidicts_lookup_popup_json 导出、FushiDicts.lookupPopupJson 及其 binding。以后新增一个结果字段或规则，只改 LookupDocument 和 buildLookupDocument。拿类型保证：DictionarySearchResult 改成只持有 LookupDocument（popupJson 变成派生 getter），两种表示各自构建在编译期就写不出来。弹窗 JSON 的 wire 字节保持不变，用现有 popup_json 黄金测试锁住。

要动：packages/fushi_dictionary/lib/src/language/language.dart；packages/fushi_dictionary/lib/src/language/merge_search_results.dart；packages/fushi_dictionary/lib/src/models/dictionary_search_result.dart；packages/fushi_dictionary/lib/src/engine/background_lookup.dart；packages/fushi_dictionary/lib/src/engine/fushidicts.dart；fushi/lib/src/pages/implementations/dictionary_popup_webview.dart；fushi/lib/src/pages/implementations/popup_settings_injection.dart；native/fushidicts/fushidicts_src/popup_json.cpp；native/fushidicts/fushidicts_ffi.cpp；packages/fushi_server/lib/src/dictionary_host.dart

核验说明：重复构建器这一点已验证。packages/fushi_dictionary/lib/src/language/language.dart:163 buildResultFromLookup 和 :295 buildPopupJsonFromLookup 各写一遍分组、预算、隐藏过滤和 soleReadings，注释里自己标着 BUG-1472/2753「与另一构建器同一口径」。background_lookup.dart:316 和 :343/355 对同一批 ffiResults 两个构建器都要跑。dictionary_popup_webview.dart:4516 buildLookupEntriesJson 由 popup_settings_injection.dart:782 popupEntriesJsonOf 调用，在 global_lookup_render.dart:151、dictionary_popup_webview.dart:2443 里当回落。原生侧 FushiDicts.lookupPopupJson（fushidicts.dart:1409）在生产代码里确实没有调用方，只剩 native/fushidicts/tests/popup_json_reading_merge_test.cpp 和一条守卫注释引用它，属于死导出。两处不准确：(a) language.dart:111-125 _lookupEntryExtraTail 已经做到「每个词头编码一次、逐条拼接」，所以「每条重复 jsonEncode」已修；剩下的只是 N 份重复字符串和消费端逐条 decode。(b) buildLookupEntriesJson 不是可以删的冗余回落。DictionarySearchResult.toJson（dictionary_search_result.dart:134-150）不含 popupJson（:104），查词历史、game_stream_companion_page.dart:63 的 fromJson、远端 /api lookup 完整模式（fushi_remote_api_handlers.dart:278 jsonDecode(result.toJson())）拿到的都只有 entries，必须靠它从 entries 重建弹窗文档。

方案风险：1) 方案说「extra 只存 glossary 级字段，词头级字段从 document 取」，同时把 changesPersistenceOrWire 标成 false，这是错的。DictionaryEntry.toJson 和 DictionarySearchResult.toJson 是查词历史的持久化格式（BUG-5064 还专门兼容过两种形式），也是互联 /api lookup、game stream、MCP（fushi_cli mcp_server.dart:418）、video_remote_host.dart:1266 的 wire 格式。改 extra 结构会让旧历史行和旧 host、旧客户端解不出频率、音高、变形链。2) 删掉 buildLookupEntriesJson / popupEntriesJsonOf 会让历史回放和远端完整结果没法渲染。必须保留「从 entries 反建 LookupDocument」的入口（LookupDocument.fromEntries），作为唯一的反序列化路径。3) 删原生 popup_json.cpp 时要同步删 C++ 测试 popup_json_reading_merge_test.cpp，以及 language.dart:28 注释里说的「C++ build_popup_json 同一语义」约束。fushidicts 规则是不改写，删除死导出本身不违规。

修正后的方案（以此为准）：保留 LookupDocument 作为唯一规范模型，在后台 isolate 里只用 buildLookupDocument 构建一次；toPopupJson() 和 entries 都从它投影。DictionaryEntry.extra 的 wire 和持久化字节保持不变：投影时照旧写入词头级 matched/deinflected/frequencies/pitches/trace，但同一词头只编码一次、拼接复用（沿用 _lookupEntryExtraTail）。另提供 LookupDocument.fromEntries(List<DictionaryEntry>)，用来接历史、远端完整结果和 game stream 的反序列化，替换掉 buildLookupEntriesJson 里的分组逻辑，popupEntriesJsonOf 改成 document.toPopupJson()。合并在 LookupDocument 层做一次。原生 fushidicts_lookup_popup_json 导出、binding、Dart 包装和 C++ 测试一起删除。要改 entries 的 wire 形状，得另开带版本字段的协议升级，不在本次范围内。

## remote-lookup-probe-interface-stack

**远端/扩展查词接口是探测式接口叠出来的（每新增一个请求字段就多一个 interface、两个方法），app 和 fushi_server 各写一条本地查词管线并已分叉；server 在 HTTP isolate 上同步跑 FFI 查词**

- 类型：补丁叠补丁；规模 L；价值 high；不改外部行为
- 核验：部分成立

证据：

- packages/fushi_engine/lib/sync/fushi_remote_lookup_service.dart:9-200 先后叠了 FushiRemoteLookupService、PopupLookupService、LanguageLookupService、RubyLookupService、FilteredLookupService、TimedPopupLookupService 六个可选接口，每个接口都有 full 和 popup 两个方法
- packages/fushi_engine/lib/sync/fushi_remote_lookup_service.dart:330-410 hasPopupFastPath 与 searchRemoteDictionaryPopupForRequest 靠 is 探测级联分派，新加一个字段就要再插一个分支
- fushi/lib/src/models/app_model.dart:17013-17105 _AppModelRemoteLookupService 有 9 个纯转发 override；17207-17360 的 _searchDictionaryPopup 又手写一遍 normalize、align、simpToTrad、缓存键和 FushiLookupRequest，和 11794-11870 的 _searchLocalDictionary 重复，而且已经分叉：popup 路径没有传 hiddenKanjiDictionaries 和 includeKanji（推测：扩展 popupOnly 查单个汉字时拿不到汉字卡，未实测）
- packages/fushi_server/lib/src/dictionary_host.dart:42-106 normalizeServerSearchTerm、alignServerRubySpans、isSingleKanjiTerm 是 app 版 app_model.dart:870-960 和 11552-11570 的手抄版，口径已分叉：app 按 grapheme（characters）截断，server 按 runes 截断；emoji 正则来源也不同
- packages/fushi_server/lib/src/dictionary_host.dart:505-517 和 554-566 直接同步调用 FushiDicts.instance.lookup，跑在服务端主 isolate 上，没有结果缓存。app 侧注释 app_model.dart:11778-11781 记录过同一段代码放 UI isolate 上每次要 10-60ms
- fushi/lib/src/models/app_model.dart:11578-11645 本机入口又分成 searchDictionary、WithRuby、ForUser、_InLanguage 四个，注释说原因是「加参数会让测试替身失配」

机制：查询参数没有收成一个值对象，每加一个参数（语言、简繁、ruby、请求方词典选择、计时）都为兼容旧实现和测试替身新开一个可选接口加一个分支。本地查词管线（清洗 → 对齐 → 过滤解析 → 缓存键 → 后台请求 → 写缓存）长在 AppModel 这个上帝对象里，server 拿不到，只好抄一份。每抄一次就分叉一次，性能修复（后台 isolate、缓存、上限对齐）也只落在 app 那一份。

根本方案：在 fushi_engine 定义唯一的查询值对象 LookupQuery，字段有 rawTerm、maxTerms、language、scriptVariants、rubySpans、dictionaryConfig、output（full 或 popupOnly）、timing，再定义唯一接口 LookupService.lookup(LookupQuery) → LookupOutcome，删掉六个探测式接口以及 hasPopupFastPath、searchRemoteDictionary*ForRequest 的级联。在 fushi_dictionary 新建纯 Dart 的 LocalLookupPipeline，持有 normalize、align（唯一一份，截断单位统一）、选择解析（见 dictionary-visibility-layered-filter）、缓存键、FushiLookupRequest 构造、后台查词和结果缓存，app 和 fushi_server 都只做装配：app 注入作品配置视图和远端合并，server 注入 ServerPrefs 词典开关。server 因此自动走后台 isolate 并带上缓存。要删除的有：_AppModelRemoteLookupService 的 9 个转发方法和 _searchDictionaryPopup、AppModel 的四个本机入口变体（合成 lookup(LookupQuery)）、dictionary_host.dart 里的 normalizeServerSearchTerm、alignServerRubySpans、isSingleKanjiTerm 和同步 search/searchPopup。以后新增一个请求字段，只改 LookupQuery、wire 编解码和 pipeline 三处。wire 字段名不变，旧 host 照常互通。

要动：packages/fushi_engine/lib/sync/fushi_remote_lookup_service.dart；fushi/lib/src/models/app_model.dart；fushi/lib/src/sync/fushi_remote_api_handlers.dart；fushi/lib/src/sync/fushi_remote_lookup_client.dart；packages/fushi_server/lib/src/dictionary_host.dart；packages/fushi_dictionary/lib/src/engine/background_lookup.dart；fushi/lib/src/ops/ctl_dictionary_routes.dart

核验说明：接口叠加已验证：packages/fushi_engine/lib/sync/fushi_remote_lookup_service.dart:9/53/69/102/136/418 有六个可选接口，:292-398 和 :333-345 hasPopupFastPath 都是 is 探测级联。server 侧复制已验证：dictionary_host.dart:47-51 按 runes 截断，app_model.dart:879-880 按 characters 截断，口径确实不同；:98 isSingleKanjiTerm 是另一份；:507、:556 在服务端 isolate 上同步调 FushiDicts.instance.lookup，:461 同步 queryKanji。不成立的部分：审计推测「popup 路径没传 hiddenKanjiDictionaries/includeKanji，所以扩展拿不到汉字卡，是分叉」。background_lookup.dart:302-331 的 popupOnly 分支本来就不查汉字。fushi_remote_api_handlers.dart:248-255 的快路径和 :276-277 的完整路径在 popupOnly 时都只回 {bestLength}+popupJson，kanjiResults 两条路径都不下发。所以这不是两条管线的差异，而是 popupOnly 契约本身不带汉字，见 missed。

方案风险：1) 六个探测接口只是进程内 Dart 接口，可以合并。实现方有 _AppModelRemoteLookupService（app_model.dart:16340）、fushi_remote_lookup_service.dart:419 的适配器、两个 integration_test 替身（interconnect_remote_audio_tls_ios_itest.dart:138、video_remote_phone_itest.dart:238），都要迁移。2) wire 兼容不能简化：handlers 里 dictionaryConfigApplied 回执、可选字段缺省等于旧行为这套逻辑必须原样保留，LookupQuery 解码时缺字段要映射成「host 用自己的设置」，不能映射成默认值。3) LocalLookupPipeline 放进 fushi_dictionary 时，normalize 依赖 package:characters 和 emoji 正则，fushi_server 不能 import package:flutter，要确认这些依赖是纯 Dart。4) 截断口径统一成 grapheme 会改变 server 对极长输入的截断点，属于轻微行为变化。

修正后的方案（以此为准）：同审计方案。补三点：LookupQuery 的 wire 解码必须区分「缺省」和「显式值」（用可空字段表示请求方没给），配置回执逻辑原样迁进 pipeline。integration_test 里的两个替身要一起迁移。截断统一按 grapheme，写进 pipeline 的单元测试。

## engine-reload-on-every-metadata-write

**任何词典元数据写入（包括折叠、显示名这类纯显示设置）都会触发 UI isolate 上同步的 existsSync 盘点，并在下一次查词时同步全量重装原生引擎；装载生命周期是 Dart 侧手搓的静态状态机**

- 类型：性能；规模 L；价值 high；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/models/dictionary_repository.dart:915-926 _publishDictionaries 每次发布都无条件调 _onCacheRebuild；1587-1605 删除、清空、rebuildEngine 也一样
- fushi/lib/src/models/app_model.dart:6123/6809 把 onCacheRebuild 接到同步的 _rebuildDictPathsCache；4349-4385 这个函数对每本词典做 Directory(p).existsSync() 加 _recheckDictionaryFileHealthSync，再无差别地 scheduleTyped。只有查词视图那条路（4769 起的 onlyIfChanged）做了集合比较，元数据写入路径明确不比较（4396-4400 注释）
- packages/fushi_dictionary/lib/src/engine/fushidicts.dart:262-266 instance getter 先跑 _applyPendingIfAny；531-586 _applyTyped 在调用方 isolate 上同步 dispose 旧句柄，再逐本 addTermDict/Freq/Pitch/Kanji。所以切换开关后的下一次 FushiDicts.instance.lookupInBackground（app_model.dart:11844）会先在 UI isolate 上同步装完全部词典
- fushi/lib/src/models/app_model.dart:4723-4729 自己写明「每本 addTermDict 仍是主 isolate 上的同步 FFI，C++ 侧整读加 mmap 触页」，异步 loadPendingAsync 只在启动和视图切换时调用（4738、6295、12690），开关切换这条路不走它
- fushi/lib/src/pages/implementations/popup_settings_injection.dart:1262-1266 注释确认「persistDictionary……每次点击整个重载 native 词典引擎」
- packages/fushi_dictionary/lib/src/engine/fushidicts.dart:208-262、447-461、628-680 _pending、_generation、_inFlightShadow、_mappingHolds、_loadedDictCount 五个静态量，加上 releaseAllMappings 和 withMappingsReleased，在 Dart 侧镜像原生句柄生命周期（BUG-1756、2110、2504、4510 都是它叠出来的）

机制：「引擎应该装哪些词典」没有被建模成从元数据派生的值。它是挂在每一次元数据写入上的副作用回调：写入不区分「影响装载」和「只影响显示」，也没有拿目标集合跟当前已装集合做 diff。结算又是懒的，而且同步，发生在任意一次 instance 访问上。于是开关、折叠、改显示名都会在下一次查词时把 N 本词典在 UI isolate 上同步卸载再装回来。装载、映射释放、影子实例、代次这些生命周期只能靠 Dart 侧静态量和注释维持。

根本方案：1) 引入派生值 EngineLoadSpec，内容是每本词典的 (path, importStamp/contentRevision, type 桶, language, kanjiHidden)，由 DictionaryRepository 从元数据纯函数算出，并带 ==/hash。Dictionary 元数据按类型拆成 EngineAffecting 部分（hidden、type、language、kanjiHidden、导入戳）和 Display 部分（折叠、显示名、顺序、样式）。只有 EngineAffecting 部分变化、并且新 spec 跟当前 spec 不等时才排期重装，重导用 importStamp 区分，BUG-171 不会回退。2) 装载所有权搬进已有的常驻后台查词 isolate：它持有原生句柄，执行 applySpec(spec) 时在后台建影子实例再原子替换；主 isolate 只发 spec、收「已就绪 serial」事件，按「Rust 胖核心」规则 Dart 侧不存镜像状态。instance getter 不再结算，sync lookup、tokenize 这类主 isolate 调用改成向 owner 借句柄或走后台请求。3) 删除 _rebuildDictPathsCache 的同步盘点（existsSync 和健康检查统一走 _scheduleDictPathsAsync 的后台物化探测）、_applyPendingIfAny 的同步装载分支，以及 _pending、_inFlightShadow、_loadedDictCount 这些静态镜像。withMappingsReleased 改成 owner isolate 的一条命令。以后新增一个影响装载的字段，只改 EngineLoadSpec。守卫是一个类型级约束：DictionaryRepository 的 Display 写接口拿不到 onCacheRebuild。

要动：packages/fushi_dictionary/lib/src/engine/fushidicts.dart；packages/fushi_dictionary/lib/src/engine/background_lookup.dart；packages/fushi_dictionary/lib/src/engine/background_borrow.dart；packages/fushi_dictionary/lib/src/engine/dictionary_buckets.dart；fushi/lib/src/models/dictionary_repository.dart；fushi/lib/src/models/app_model.dart；packages/fushi_server/lib/src/dictionary_host.dart；fushi/lib/src/sync/backup_service/restore.part.dart；fushi/lib/src/sync/sync_settings_schema/data_root.part.dart

核验说明：已验证。dictionary_repository.dart:915-926 _publishDictionaries 无条件调 _onCacheRebuild，:1590/1598/1605 同样如此。app_model.dart:6123/6809 把它接到同步的 _rebuildDictPathsCache（:4349-4385），后者逐本 Directory.existsSync，加 _recheckDictionaryFileHealthSync，再无条件 FushiDicts.scheduleTyped。fushidicts.dart:266-267 instance getter 先跑 _applyPendingIfAny，同步装载。loadPendingAsync 只在 app_model.dart:4738、6295、12690 三处调用，元数据写入路径不走它。app_model.dart:4396-4400 和 4436-4440 的注释也承认，同步排期会把整套重装推给下一次查词、在 UI isolate 上做完。

方案风险：1) importStamp/contentRevision 现在不存在。Dictionary 字段只有 name、formatKey、order、type、metadata、hiddenLanguages、collapsedLanguages、expandedLanguages、languageOverride、displayName，如果加 DB 列就是持久化变更，和 changesPersistenceOrWire:false 矛盾。应当从文件系统派生（导入目录的 mtime 或 manifest 哈希），或在导入时写进已有的 metadata map，不新增列。2) 把句柄所有权搬进后台 isolate 后，主 isolate 上还有不少同步消费者：getMediaFile（dictionary_host.dart:604 及 app 内媒体服务）、dictionaryStyles、queryKanji、tokenizeLengths、dict_style_preview。这些都要逐个改成借用或后台请求，审计的 touches 没列出媒体服务和样式这两类调用点。3) mmap 释放（withMappingsReleased，用于删除和覆盖导入，BUG-2504/4510）必须跨 isolate 有序完成，否则 Windows 上删词典目录会失败。

修正后的方案（以此为准）：同审计方案。补三点：EngineLoadSpec 的内容版本从已有字段派生（导入时写进 metadata，或用磁盘 manifest/mtime），不新增 DB 列。迁移清单里加上 getMediaFile、dictionaryStyles、queryKanji、主 isolate tokenize 的调用点。withMappingsReleased 改成 owner isolate 的 await 命令，主 isolate 等回执后再碰文件。

## popup-bridge-protocol-no-registry

**popup.js 宿主桥协议没有登记源：in-app 约 25 个可空回调、覆盖窗 switch、样式预览 no-op 名单、扩展三个壳的 switch 和白名单各写一份，新桥漏接就静默回 null**

- 类型：成类 bug；规模 L；价值 high；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/pages/implementations/dictionary_popup_webview.dart:429-470 DictionaryPopupWebView 有约 25 个可选的 on* 回调，宿主漏传时桥回空结果；同文件约有 39 个 handlerName 注册
- fushi/lib/src/lookup/overlay_bridge_handlers.dart:1-60 和 145 起，app 外覆盖窗用 switch(case 'srsTermStatus' 等)再实现一套
- fushi/lib/src/pages/implementations/dict_style_preview.dart:300-320 样式预览手写一份 popup.js 能调的 handler 名单注册成 no-op（BUG-1918：未注册的名字能把 app 打死）
- tools/browser-extension/bridge-shim.js:234、side-panel.js:856、nested-popup-host.js:378 扩展三个壳各自维护 switch 或白名单
- docs/bugs/BUG-2698（openInAnki 在 shim、side-panel、nested 白名单三处都没接）、BUG-3141（favoriteEntry/favoriteCheck 扩展三壳没接）、BUG-4209（home_dictionary_page 结果区没接 onMinedCardAction/onOpenInAnki/onFavorite*/onQueueOverwrite）、BUG-1918：同一机制
- fushi/test/lookup/dictionary_webview_mined_card_action_wiring_guard_test.dart（85 行）靠扫描源码断言「接了 onMineEntry 的必须同时接 X、Y、Z」，用守卫兜本该由类型保证的不变量

机制：popup.js 只认字符串形式的 callHandler(name)。协议没有清单，也没有「这个宿主具备哪些能力」的声明。每个宿主（Dart 的三个、JS 的三个）各自决定接哪些名字；没接的名字落进 default 回 null。popup.js 分不清「宿主没这个能力」和「操作失败」，按钮照样显示，点了没反应。新加一根桥要手改约 6 处，只能靠源码扫描守卫逐项补。

根本方案：新建单一的桥清单 popup_bridge_manifest：Dart 侧是 enum PopupBridge，带参数和返回 schema，并按能力分组（mining、favorite、audio、srs、selection、layout）。由它生成两样东西：一是 JS 常量（注入 window.__fushiBridgeCaps，popup.js 据此隐藏宿主不具备的按钮，不再靠 null 猜）；二是扩展 shim、side-panel、nested 白名单共用的 JSON（sync-mirrors.mjs 产出，三壳 import 同一份表）。Dart 宿主实现 abstract class PopupBridgeHost，每个能力组一个 required 的 capability 对象，例如 MiningBridge?，不具备就显式传 null 并由清单下发「无此能力」。DictionaryPopupWebView 的 25 个散装回调收成一个 host 参数。overlay_bridge_handlers 的 switch 和 dict_style_preview 的 no-op 名单都改成 PopupBridgeHost 实现（预览用 PopupBridgeHost.inert()）。删除散装 on* 回调和源码扫描守卫，留一个「清单与 popup.js callHandler 名字集合一致」的生成校验。以后新增一根桥，只改清单，再让编译器指出每个宿主要补的实现。

要动：fushi/assets/popup/popup.js；fushi/lib/src/pages/implementations/dictionary_popup_webview.dart；fushi/lib/src/lookup/overlay_bridge_handlers.dart；fushi/lib/src/lookup/global_lookup_controller.dart；fushi/lib/src/pages/implementations/dict_style_preview.dart；fushi/lib/src/pages/implementations/home_dictionary_page.dart；fushi/lib/src/pages/implementations/dictionary_page_mixin.dart；tools/browser-extension/bridge-shim.js；tools/browser-extension/side-panel.js；tools/browser-extension/nested-popup-host.js；tools/browser-extension/scripts/sync-mirrors.mjs

核验说明：已验证。dictionary_popup_webview.dart 里有 40 处 handlerName:，popup.js 里 callHandler( 有 48 处；overlay_bridge_handlers.dart 有 20 个 case，文件头注释说是从 GlobalLookupController 原样抽出的另一套实现；tools/browser-extension/bridge-shim.js、side-panel.js、nested-popup-host.js 都在。BUG-2698、3141、4209、1918 这类漏接已经反复出现，现在靠源码扫描守卫兜底。

方案风险：1) popup.js 同时被 fushi/assets 和浏览器扩展 vendor 使用。扩展是单独安装在用户浏览器里的，版本可能比 app 旧或新。新增 window.__fushiBridgeCaps 后，popup.js 必须把「没有 caps」当成全能力（旧宿主行为），否则新 popup.js 配旧宿主会把按钮全藏掉。2) 生成链要接进 sync-mirrors.mjs 和现有 CI 守卫，不要再加手写镜像。3) 删掉源码扫描守卫之前，要先有「清单与 popup.js callHandler 名字集合一致」的生成校验。

修正后的方案（以此为准）：同审计方案。补一条：caps 缺省按全能力处理，向后兼容。

## popup-display-settings-handwritten-schema

**查词弹窗显示偏好清单在注入 JS、memo 字段、memo 相等判据、memo 重建、扩展 theme 编码、live/view 两份取值处各手写一遍，漏一处就出现「设置不生效」或「点击没反应」**

- 类型：缺单一登记源；规模 M；价值 medium；不改外部行为
- 核验：部分成立

证据：

- fushi/lib/src/pages/implementations/popup_settings_injection.dart:1015-1070 _PopupStaticSettingsMemo 有约 35 个字段，构造和声明各列一次
- fushi/lib/src/pages/implementations/popup_settings_injection.dart:1240-1270 命中判据逐字段 ==，注释（BUG-2158 补修）明说漏一个字段 memo 就静默命中、用户点「展开」没反应
- fushi/lib/src/pages/implementations/popup_settings_injection.dart:1420-1450 window.harmonicFrequency、collapseDictionaries 等逐个注入；1470-1500 memo 重建又把全部字段列一遍
- fushi/lib/src/utils/popup_theme_css.dart:103-140 PopupDisplayPrefs record 和 buildPopupDisplayPrefsThemeVars 给扩展另编一套 --fushi-* 键，扩展 vendor/dict-media.js 再解回同名全局
- fushi/lib/src/models/app_model.dart:7272-7290 和 7325-7345 live 与配置视图两份 PopupDisplayPrefs 取值逐字段手写
- docs/bugs/BUG-4935：扩展只接了 dedupPitch 一项，其余显示偏好恒为 undefined；BUG-2158：memo 判据漏了 expandedNames

机制：popup 的「设置 → window 全局」映射没有声明式描述。每条偏好都要在 Dart 注入、memo 失效键、扩展编码、扩展解码、live 取值、配置视图取值六处各写一行，几处之间没有任何结构联系，只能靠注释和 bug 回归来发现漏项。

根本方案：新建唯一的描述表 kPopupDisplaySettings：const List<PopupSetting<Object>>，每项写明 jsGlobal 名、读取器 (PreferencesRepository p, List<Dictionary> dicts) → T 和 JS 编码器。由它派生四样东西：注入 JS（循环生成 window.X = …）；memo 失效键（把各项值收成 List 一次比较，不再逐字段 ==）；扩展 theme 通道 map（键由 jsGlobal 名推导）；live 与 view 的取值（同一个读取器传入不同的 prefs 和 dicts）。扩展侧的解码表由 sync-mirrors.mjs 从同一份描述导出的 JSON 生成，dict-media.js 的 applyFushiPopupDisplayPrefs 只遍历这张表。要删除的有：_PopupStaticSettingsMemo 的逐字段声明和比较、PopupDisplayPrefs record、app_model.dart 里两份手写取值、popup_theme_css 的逐键编码。以后新增一条显示偏好，只往描述表加一项。

要动：fushi/lib/src/pages/implementations/popup_settings_injection.dart；fushi/lib/src/utils/popup_theme_css.dart；fushi/lib/src/models/app_model.dart；fushi/assets/browser_extension/vendor/dict-media.js；tools/browser-extension/vendor/dict-media.js；tools/browser-extension/scripts/sync-mirrors.mjs

核验说明：重复手写已验证。popup_settings_injection.dart:1007 _PopupStaticSettingsMemo，popup_theme_css.dart:103 PopupDisplayPrefs record 和 :122 逐键编码；app_model.dart:7273-7290 live 取值和 :7330-7345 配置视图取值确实逐字段各写一遍。BUG-4935 和 2158 属于这类问题。行号与审计略有出入，但事实成立。

方案风险：方案说扩展 theme 通道的「键由 jsGlobal 名推导」，这会改 wire 键。现在的键是 '--fushi-dedup-pitch'、'--fushi-harmonic-frequency' 这一类，而用户浏览器里装的扩展 dict-media.js 可能是旧版，键一改，旧扩展的显示偏好就会全部变成 undefined，等于 BUG-4935 回退。审计把 changesPersistenceOrWire 标成 false，与此矛盾。

修正后的方案（以此为准）：描述表每一项显式写 themeKey 字段，值等于现有的 '--fushi-*' 字面量，冻结不追改。注入 JS、memo 键、扩展编码、live/view 取值都由同一张表派生；扩展解码表由 sync-mirrors.mjs 从这张表导出。另加一个守卫测试，锁住现有 themeKey 集合不变。

## dictionary-visibility-layered-filter

**「哪些词典这次可见」在引擎装载桶、请求排除集、汉字排除集、两个 Dart 构建器、server 的第二道网、popup.js 的 window.hiddenDictionaryNames、合并去重名单等七层各算一遍，泄漏类 bug 反复出现**

- 类型：成类 bug；规模 M；价值 medium；不改外部行为
- 核验：部分成立

证据：

- packages/fushi_dictionary/lib/src/engine/background_lookup.dart:172-185 hiddenDictionaries 注释写着「引擎排除……结果构建期的源头过滤保留为第二道网」，另有 hiddenKanjiDictionaries 单列（BUG-3573）
- packages/fushi_dictionary/lib/src/language/language.dart:195-199 与 348 两个构建器各自按 hiddenDictionaries 再滤一遍
- packages/fushi_server/lib/src/dictionary_host.dart:584-592 server 也注释为「第二道网」，再按 excluded 滤 bestLength
- fushi/assets/popup/popup.js:872、2237-2239、2306、2596、5847-5853 JS 侧还在按 window.hiddenDictionaryNames 过滤（BUG-1749 注释说它已经「退化为冗余保险」）
- fushi/lib/src/models/app_model.dart:11722-11735 合并去重又另算 localDictionaryNames（isHidden(JapaneseLanguage.instance) 加 engineTermDictionaryNames）；全库有 17 处 isHidden(JapaneseLanguage.instance)，按语言隐藏这一维实际已退化成单个布尔
- docs/bugs/BUG-419、432、1749、2997、3454、3573、4741、426 都是「某条输出路径漏了隐藏或可见判据」

机制：可见性没有在查询入口一次解析成一个对象并交给唯一的执行点。引擎曾经不支持排除，于是在每个输出端补过滤；后来引擎支持了排除集，下游各层却作为「保险」保留下来，于是每加一个新表面或新配置维度（作品配置、请求方词典选择、混合词典的汉字开关）都要在多层同时改对。

根本方案：在 LocalLookupPipeline（见 remote-lookup-probe-interface-stack）入口用唯一的解析函数 resolveDictionarySelection(profileView, requesterConfig, engineSpec) 算出不可变的 DictionarySelection，内容是 termExcluded、kanjiExcluded、termOrder、engineVisibleNames，app 和 server 共用。执行点只有一个：引擎的 LookupOptions 排除集加 order，在截断前生效。buildLookupDocument 只做排序，不再做过滤。要删除的有：两个构建器里的 hiddenDictionaries 第二道网、server 的 withoutExcludedDictionaryMeta 二次过滤、popup.js 的 hiddenDictionaryNames 过滤以及它的 window 注入、合并时另算的 localDictionaryNames（改用 selection.engineVisibleNames）。Dictionary 增加 isTermHidden getter，读冻结字段 hiddenLanguages，持久化格式不变，替换掉 17 处 isHidden(JapaneseLanguage.instance)。以后新增一个可见性维度，只改 resolveDictionarySelection。

要动：packages/fushi_dictionary/lib/src/engine/background_lookup.dart；packages/fushi_dictionary/lib/src/language/language.dart；packages/fushi_dictionary/lib/src/engine/dictionary.dart；fushi/lib/src/models/dictionary_repository.dart；fushi/lib/src/models/app_model.dart；packages/fushi_server/lib/src/dictionary_host.dart；fushi/assets/popup/popup.js；fushi/lib/src/pages/implementations/popup_settings_injection.dart

核验说明：多层过滤已验证：language.dart:190-199 两个构建器各滤一遍，background_lookup.dart 有 hiddenDictionaries/hiddenKanjiDictionaries 两套排除集，popup.js:872、2237-2239、5847-5853 仍按 window.hiddenDictionaryNames 过滤，isHidden(JapaneseLanguage.instance) 一共 17 处。审计说下游过滤只是「冗余保险」、可以只保留引擎一个执行点，这一点不成立：(a) 查词历史持久化的 entries 是隐藏某本词典之前录下的，回放时引擎排除集管不到，只能在渲染时过滤；popup.js 的 constructGlossaryHtml 过滤还保证制卡导出不带隐藏词典（2230-2236 注释）。(b) 远端结果来自旧 host：没有 dictionaryConfigApplied 回执时，host 按它自己的隐藏集查词，请求方本机隐藏的词典照样会回来（fushi_remote_lookup_client.dart:117-124、209），请求方这边必须再滤一次。

方案风险：「执行点只有一个：引擎」会破坏两条路径：历史回放和制卡导出会显示或导出已隐藏的词典；旧 host 互联会泄漏请求方隐藏的词典，这是一条 wire 兼容路径。DictionarySelection 应该是唯一的解析点，但执行点至少要有两层。

修正后的方案（以此为准）：resolveDictionarySelection 作为唯一解析函数，app 和 server 共用。执行分两层，都消费同一个 DictionarySelection 对象：① 本机新查询在引擎排除集里执行，并在截断前生效；② 不经引擎的结果（历史回放、没有 config 回执的远端结果、entries 反建）在 LookupDocument.fromEntries / 合并入口按 selection 过滤一次。这样就能删掉两个构建器里的第二道网、server 的二次过滤，以及 popup.js 的 hiddenDictionaryNames 注入和过滤（文档进 JS 之前已经过滤干净，制卡导出用的也是同一份文档）。isTermHidden getter 替换那 17 处的做法可行，不改持久化。

## sync-tokenize-on-ui-isolate

**点词取词和分词在 UI isolate 上同步 FFI 切分整段文本，再为单个下标建等长 wordTape；同步和后台两套 API 并存**

- 类型：性能；规模 M；价值 low；不改外部行为
- 核验：部分成立

证据：

- packages/fushi_dictionary/lib/src/language/implementations/japanese_language.dart:68-74 textToWords 在调用方 isolate 上同步调 FushiDicts.instance.tokenizeLengths（instance getter 还可能顺带触发同步全量装载，见 engine-reload-on-every-metadata-write）
- packages/fushi_dictionary/lib/src/language/language_base.dart:213-226 wordFromIndex 为了拿一个下标处的词，切分整段文本，再分配一个与文本等长的 List<String> wordTape
- packages/fushi_dictionary/lib/src/language/language_base.dart:237、262、294、326 getSearchTermFromIndex、getWordRange、getGuessHighlightLength、getStartingIndex 每次也都整段重新切分
- japanese_language.dart:76-90 同一个类里另有 textsToWordsWithReadingsInBackground，注释记录过整页同步分词实测约 177ms；调用方 fushi/lib/src/lookup/gal_hook_text_overlay_controller.dart:2637、reader_fushi/lyrics.part.dart:2210、app_model.dart:12340、texthooker_page.dart:628 仍走同步版（texthooker 自己按行缓存兜底）

机制：Language 抽象把分词定义成同步的 List<String> textToWords(String)，派生操作（取词、取范围、猜高亮）全都写成「整段切分后再线性扫描」，没有「取 index 处的词」这样的原语。引擎已经有原生 tokenize 和 match_length，Dart 侧却每次点击都整段过一遍 FFI，还要分配 O(n) 的中间表。依据来自代码路径推断加上代码注释里已有的 177ms 实测，单次点击的具体耗时未实测。

根本方案：在 fushi_dictionary 把分词收成一个 TokenizationService：唯一原语是 tokenizeLengths(text)，返回 Int32List，并按 (engineSerial, text) 做 LRU 缓存，缓存随引擎实例一起失效。wordAt、rangeAt、startingIndexAt 都从长度前缀和加二分得到，不建 wordTape。整段分词一律走后台 isolate，返回 Future。只取单个下标的词时走 matchedLength(text.substring(index)) 快路径，或者走一次原生调用。要删除的有：language_base.dart 里五处各自整段切分的实现、wordTape，以及 texthooker 自建的分词缓存（改用服务缓存）。以后新增一种取词派生操作，只在 TokenizationService 上加方法。

要动：packages/fushi_dictionary/lib/src/language/language_base.dart；packages/fushi_dictionary/lib/src/language/implementations/japanese_language.dart；packages/fushi_dictionary/lib/src/engine/fushidicts.dart；fushi/lib/src/pages/implementations/texthooker_page.dart；fushi/lib/src/lookup/gal_hook_text_overlay_controller.dart；fushi/lib/src/media/video/subtitle_word_sweep.dart

核验说明：已验证：japanese_language.dart:67-74 textToWords 同步调 FushiDicts.instance.tokenizeLengths，instance getter 还可能顺带触发同步全量装载；language_base.dart:213-226 建等长 wordTape。windowTextAroundIndex 窗口逻辑（:193）要求 indexMaxDistance 不为空，但没有任何语言设置它，所以窗口不生效。不准确的地方：getSearchTermFromIndex 对非空格分词语言（日语）按文档就是 substring，不切分，审计说它「每次整段重新切分」只对空格分词语言成立。真实调用方是 gal_hook_text_overlay_controller.dart:2637（单行 hook 文本）和 lyrics.part.dart 这类短文本，单次代价未实测；审计自己给的价值判断是 low，这个判断合理。

方案风险：把整段分词全部改成 Future 会扩散到同步 API 的调用方：latin_word_lookup.dart:67-71 依赖同步签名 wordFromIndex，subtitle_word_sweep / texthooker 依赖「未命中按 UTF-16 码元切分」的语义（BUG-3086），必须保持。LRU 缓存必须绑定引擎实例的 serial，否则词典切换后会命中过期结果。

修正后的方案（以此为准）：先做低成本根修：wordFromIndex 改成原生单次 match_length(text.substring(index)) 原语，去掉 wordTape；其余派生操作用长度前缀和加二分。是否 async 化，等引擎装载搬到后台（engine-reload 一条）之后再定；同步签名可以先保留，因为单次 match 是 O(词长)。

## 核验补充（审计漏掉的）

- 查词结果 wire 和持久化体积：DictionarySearchResult.toJson（packages/fushi_dictionary/lib/src/models/dictionary_search_result.dart:134-150）的 entries 是双层 JSON，每条 glossary 的 extra 都带一份整词头的 frequencies/pitches/trace。查词历史表、互联 /api lookup 完整模式（packages/fushi_engine/lib/sync/fushi_remote_api_handlers.dart:278）、game stream、MCP 都走这个格式。BUG-871 只在 popupOnly 时收窄，完整模式的体积问题和历史表膨胀没解决。根修需要一次带版本号的协议和存储格式升级（词头级字段只存一份），审计五条方案都绕开了这一点，反而把它误标成「不改 wire」。
- 浏览器扩展单汉字查词拿不到汉字卡（推测，未实测）：background_lookup.dart:302-331 的 popupOnly 分支不查汉字；fushi_remote_api_handlers.dart:248-255 和 :276-277 在 popupOnly 时，两条路径都只回 bestLength+popupJson；buildPopupJsonFromLookup 产出的 popupJson 也不含 kanjiResults。所以扩展和 Yomitan API 路径从契约层面就没有汉字卡，app 内弹窗有。这比审计说的「app 的 popup 路径漏传参数」更根本：popupOnly 契约本身少了 kanji，应该让 LookupDocument 包含 kanji[]，并进入 toPopupJson。
- 历史回放、旧 host 远端结果的可见性过滤与引擎排除集是两条执行路径（见 dictionary-visibility-layered-filter 的修正），目前分散在 popup.js 和合并代码里，没有一个以 DictionarySelection 为参数的统一入口；审计的方案会把这条路径直接删掉。
- fushi_server 主 isolate 上同步调用的不止 lookup：dictionary_host.dart:461 queryKanji 和 :604 getMediaFile 也是同步 FFI 和文件读取，媒体资源请求会占住 HTTP isolate。审计只提了 lookup。
