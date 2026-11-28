# 架构审计：media-storage

2026-11-28 只读审计 + 独立反驳核验的原始结论。总方案见 [../../specs/2026-11-28-architecture-redesign.md](../../specs/2026-11-28-architecture-redesign.md)。

## 现状

媒体存储域现在的做法是：DB 里存绝对路径，换了根就把这些路径改写一遍。tables.dart 里约 35 个 *Path/*Dir/*Root 文本列，加上 JSON 内嵌路径（playlist_json、subtitleSource 四态编码、字体 catalog、本地发音库列表等 10 种 PathValueShape），再加约 20 个 pref 键，都存本机绝对路径，没有一个列用 TypeConverter。这个模型默认「根不会变」，可实际上有六个入口会让根变：桌面换数据根（DataRootMigrator）、iOS 每次更新换容器 UUID（SandboxRelocation）、换下载根（DownloadRootMigrator）、Android 双根散书合并（AndroidStrayLibraryMerge）、备份恢复（backup_service/path_rebase.part.dart，自己另写了一套改写），以及 C++ 种子 fast-resume 里记的保存路径。补救手段是三层：path_rebase_coverage.dart（1526 行声明表）登记哪些列要改写；data_root_migrator.dart 手写了 21 个 _rebase<Table> 函数；守卫测试只做源码文本匹配，检查「列名在迁移器源码里出现过」「_rebase<Table> 正好声明并调用了一次」。同类漏改已经出过至少 9 次（TODO-1255、BUG-1174、1575、183、2020、2100、3541、3702、5370）。「哪些东西归 Fushi 管」同样没有单一来源：documents 根下的目录名在 EnginePaths、AppPaths.fushiOwnedDocumentsEntries（30 项）、kStorageCategoryDocumentsChildren、libraryEvidenceIgnoredEntries、ServerPaths 里各写一遍，靠正则扫源码的守卫兜着。文件归不归 Fushi 管全靠路径前缀推断：删除时先拿幸存行全表算引用集，再判路径是否落在自有目录内；SandboxRelocation、AndroidLibraryDbWitness、LibraryContentAudit 都要从绝对路径里倒推「数据根以下那一段」（从右往左找白名单段）。存储页每次打开都在 isolate 里递归 stat 整棵目录树，类目总量和明细是两套口径（BUG-2096）。fushi_server 用的是同一套表，但完全没有改写逻辑：备份还原到另一个 data_dir 时只改了配置里的 data_dir，库里的路径还指着原机器。app 和 server 的目录布局也不一致：词典 app 放在 documents/dictionaryResources，server 放在 support/dictionaries。总的看法：「受管存储 + 逻辑路径（根 id + 相对路径）」这个模型能让改写引擎、覆盖声明表、沙盒重定位、备份改写和根推断这几类补丁整类消失。只有 Android 「书库放内部还是外部存储」这个锚点决策还要保留，但它会退化成单纯的根解析，不再需要改写 DB。

## absolute-path-persistence

**DB/pref 存绝对路径，换根就改写全库：声明表 + 21 个手写改写函数 + 源码文本守卫，同一机制已漏改 9 次以上**

- 类型：补丁叠补丁；规模 XL；价值 high；改持久化 / wire
- 核验：成立

证据：

- fushi/lib/src/storage/path_rebase_coverage.dart:1-9 文件头自述：TODO-1255 漏了 video_books.cover_path，BUG-1174 又一次查出漏了 galgames.cover_path、subtitle_source ×2、media_images.image_url、整张 profile_settings 和 5 个 pref 键；后来又靠 BUG-1575/183/2020/2100/3541/3702/5370 逐个补
- fushi/lib/src/storage/path_rebase_coverage.dart:81-110 有 10 种 PathValueShape（JSON 列表、字幕四态 map、字体 catalog、本地发音库、legacy galgame JSON……），每种都配一个专用改写器
- fushi/lib/src/storage/data_root_migrator.dart:1251-1283 rebaseOpenDatabasePaths 在一个事务里依次调 20 个 _rebase<Table>（整个文件共 21 个手写 static _rebase*），这份声明表并不是执行器
- fushi/test/storage/path_rebase_coverage_guard_test.dart:125-131 守卫只做 src.contains(sqlColumn)（列名在迁移器源码里出现过就算接线了），:142-157 数 'static Future<void> _rebase$table(' 出现了几次：都是文本匹配，不是结构保证
- fushi/lib/src/storage/sandbox_relocation.dart:17-23 自述：库里存绝对路径，隐含「两次启动之间数据根不变」，iOS 每次更新换容器 UUID，于是整库悬空（BUG-2100）；:180-230 台账为空时只能从存量数据倒推旧根
- fushi/lib/src/storage/download_root_migrator.dart:193 和 android_stray_library_merge.dart:140,165 换下载根、合并散书都要再调一次全库改写
- packages/fushi_core/lib/src/database/tables.dart:3085-3088 同一张 VideoDownloadJobFiles 表里 currentRelativePath（相对）和 finalAbsolutePath（绝对）并存；:3646 MangaExtensions.apkPath 已经改成相对路径（path_rebase_coverage.dart:1163-1168 说明相对存储就是为了换根不用改写）；path_rebase_coverage.dart:1490-1497 BUG-5370 把页面背景改成只存文件名。逐个相对化已经在零散地做，但没有统一
- fushi/lib/src/sync/backup_service/path_rebase.part.dart:87-107 _resolveExtractDirOnDevice：EPUB 落点本来就能确定是 <booksRoot>/<bookKey>（packages/fushi_engine/lib/epub/epub_storage.dart:446-459），库里却存绝对的 extract_dir，前缀改写失败后只好按 bookKey 再兜一次底

机制：持久层的路径类型是裸 String，内容是本机绝对路径。根本来就会变（用户换根、iOS 容器漂移、换下载根、跨机恢复），于是每个会让根变的入口都得把全库改写一遍。每加一个存路径的列、JSON 字段或 pref，就得手动去声明表、改写函数、JSON 形态改写器三处登记，漏一处就是一次数据损坏级的 bug。守卫只看源码字符串，拦不住「接线了但写错」（比如漏了某种形态、漏了某个根）。

根本方案：在 fushi_core 引入 StoredPath 值类型，wire 形态是 '<rootId>:<相对路径>'（相对路径用 / 分隔、禁止 ..），外部文件用 'ext:<绝对路径>'，远端用 URL 原样保存。rootId 是封闭枚举 StorageRootId { library, support, downloads, temp }。每个进程启动时由宿主注册一张 RootRegistry（app 在 AppPaths.resolve 之后注册，server 由 ServerPaths 注册），fushi_engine 里统一用 enginePaths.resolve(StoredPath) 换成 File/Directory。所有路径列改成 text().map(const StoredPathConverter())()，Dart 层拿到的是 StoredPath 而不是 String，repository 写入时只能传 StoredPath，绝对路径字符串在类型上就写不进去。JSON 内嵌路径（playlist、subtitleSource、字体 catalog、本地发音库、galgame legacy）在各自的 codec 里也改用 StoredPath 序列化。做一次 schema 迁移，用当前根把存量绝对路径转成逻辑路径：在根内的转成 <rootId>:rel，不在的转成 ext:abs，迁移只跑一次；iOS 已经漂移的旧安装沿用 SandboxRelocation 现有的倒推逻辑，作为这次迁移的输入。之后换根只是改 RootRegistry 里的一条根，DB 不用动。可以删掉：path_rebase_coverage.dart 的 kPathRebaseColumns/kPathRebasePrefs/PathValueShape、data_root_migrator.dart 的 rebaseOpenDatabasePaths 和 21 个 _rebase*、DocumentsPathRebaser、sandbox_relocation.dart（只保留一次性迁移内核）、download_root_migrator/android_stray_library_merge 里改写 DB 的那一步、backup_path_rebase.dart 的字体/列表改写器、path_rebase_coverage_guard_test.dart。以后新增路径列只需声明成 StoredPath 列。守卫换成结构性的：在 drift 生成物上断言凡是列名形如 *Path/*Dir/*Root 的 TextColumn 都挂了 StoredPathConverter，或在 notAPath 豁免集里并写明理由。fushi_torrent 的 fast-resume（C++，不改写）改成每次加任务时由宿主按逻辑路径解析出 save path 传进去，不再依赖 resume 文件里存的绝对路径。

要动：packages/fushi_core/lib/src/database/tables.dart；packages/fushi_core/lib/src/database/（新 StoredPath/converter + 一次性迁移）；packages/fushi_engine/lib/foundation/engine_paths.dart；fushi/lib/src/storage/path_rebase_coverage.dart；fushi/lib/src/storage/data_root_migrator.dart；fushi/lib/src/storage/sandbox_relocation.dart；fushi/lib/src/storage/download_root_migrator.dart；fushi/lib/src/storage/android_stray_library_merge.dart；fushi/lib/src/sync/backup_path_rebase.dart；fushi/test/storage/path_rebase_coverage_guard_test.dart；所有读写路径列的 repository（epub/audiobook/srt/video/music/galgame/collections/scrape/download jobs）

核验说明：已核实：path_rebase_coverage.dart 共 1526 行，文件头 :1-9 自述 TODO-1255/BUG-1174 的漏改史；data_root_migrator.dart 2276 行，grep 到 21 个 `static Future<void> _rebase`；守卫 path_rebase_coverage_guard_test.dart:125-157 确实只做 src.contains(列名) 和数 `_rebase$table(` 的声明/调用次数，属于文本匹配；sandbox_relocation.dart:113-123 构造 DocumentsPathRebaser，scope 是 AppPaths.fushiOwnedDocumentsEntries。声明表本身自称「单一真相源」（:1），但执行器仍是 21 个手写函数，所以说「声明表不是执行器」成立。审计还漏了一点：除了这三层，读取时还有第四层兜底，即 fushi/lib/src/media/video/video_resource_check.dart:55-73 的 relocateMissingAppDocumentPath，它在读取时按 `Containers/Data/Application/<uuid>/Documents` 倒推新路径，这也印证了「存绝对路径」才是根因。

方案风险：1) wire 形态 `<rootId>:<rel>` 在 Windows 上会和盘符 `C:\...` 撞形；旧数据迁移时如果有单字母或与盘符同形的 rootId 会解析错，必须规定 rootId 至少两个字符并且做显式 scheme 校验。另外 content://（Android SAF）、file://、http(s) 三类都要原样保留，不能落进 ext:。2) 「Android 书库放内部还是外部」不只是单个根解析的问题：AndroidStrayLibraryMerge 处理的正是两个根同时存在散书的情况，只有一个 `library` 根表达不了合并前那一刻的状态。要么用两个 rootId（libraryInternal/libraryExternal）再加一次性归并，要么合并仍然要搬文件并改写这些行。3) 兼容方向：备份包、互联同步里的 profile_settings 和 pref 一旦带上新格式的值，旧版本 app 导入就会全部悬空。列名不变，所以没碰「冻结名」，但值的语义变了，需要备份格式版本号和向下兼容策略，不能只做单向迁移。4) 已经相对化的列（MangaExtensions.apkPath、页面背景只存文件名 BUG-5370）语义各不相同，转换器要能兼容这些存量形态，否则会二次迁移。5) 桌面换数据根仍然要搬文件，DataRootMigrator 的搬文件、校验、合并部分不会消失，消失的只是 DB 改写那一块，这一点审计的表述基本准确。6) fushi_torrent 是 C++，按规则不改写；「加任务时由宿主传 save path」需要先确认 fast-resume 没有恢复后自行用 resume 里的路径，属于推测。

修正后的方案（以此为准）：总体保留审计方案，补三处：(a) StoredPath 的 wire 形态改成带固定前缀的 URI 风格（如 `fushi-root://library/<rel>`、`fushi-ext:<abs>`），或者 rootId 硬性要求不少于 2 个字符并带白名单，杜绝与盘符混淆；content:// 和 http(s) 原样保留。(b) Android 书库拆成 libraryInternal 和 libraryExternal 两个 rootId，散书合并改成「搬文件 + 只改这批行的 rootId」，不再前缀改写全库。(c) 备份包加 schemaVersion：旧版 app 读到新格式包时显式拒绝，不能静默悬空；新版读旧包时走一次性迁移内核。删除清单里要加上 video_resource_check.dart 的 relocateMissingAppDocumentPath（读取时倒推）。

## backup-restore-rebase-fork

**备份恢复另写了一套按类目分根的路径改写，不受覆盖声明表约束、也没有守卫**

- 类型：缺单一登记源；规模 L；价值 high；改持久化 / wire
- 核验：部分成立

证据：

- fushi/lib/src/sync/backup_service/path_rebase.part.dart:14-50 _rebaseAllPaths 按 books/audiobooks/fonts/localAudio/videos/gameCovers 六个 meta 根各改一遍，和 DataRootMigrator.rebaseOpenDatabasePaths 是两套执行器
- fushi/lib/src/sync/backup_service/path_rebase.part.dart:364-385 视频只改 videoPath 和 playlistJson；kPathRebaseColumns 标为 documentsRooted 的 video_books.cover_path/subtitle_source/secondary_subtitle_source、media_images、item_images、video_metadata_extras、collection 封面这里都没处理（推测：这些文件如果在备份包里，恢复后就会悬空；没有实机复现）
- fushi/lib/src/sync/backup_service/path_rebase.part.dart:87-107 前缀对不上时「静默原样返回导出设备的绝对路径」，只好再加一层按 bookKey 兜底
- fushi/test/storage/path_rebase_coverage_guard_test.dart:125-157 守卫只读 data_root_migrator.dart 的源码，不看 backup_service/path_rebase.part.dart
- docs/bugs/BUG-1575-srt-path-rebase-missing.md（_rebaseContentPaths 漏了 srt）、BUG-183-font-backup-path-stale.md、BUG-3702-local-audio-dangling-after-profile-import.md 都是这套执行器漏改的

机制：备份包按类目打包（每个类目记一个源根），恢复时用「源根前缀 → 本机新根」逐类做字符串替换。它和数据根迁移解决的是同一个问题（库里的绝对路径要指向本机），却是第二份独立实现，覆盖面各自演化：声明表补了列，这里不会跟着补。

根本方案：依赖 absolute-path-persistence 的 StoredPath。备份包里的文件布局就是 <rootId>/<相对路径>，和库里的逻辑路径一一对应，恢复时只需把文件解到本机对应的根下，DB 一个字节不用改；ext: 外部路径照原样保留，由 UI 标记为「来自别的设备的外部文件」。可以删掉：path_rebase.part.dart 全文（479 行）、BackupMeta 里的 *Root 字段（只读兼容旧包时做一次性转换）、_resolveExtractDirOnDevice、backup_merge_engine 里的路径相关分支。旧格式备份在导入时用同一个一次性迁移内核（绝对路径按 meta 根转成 StoredPath）转一次。以后加新媒体类型不用碰备份代码，备份按 ManagedArea 登记（见 managed-area-registry）里 backupIncluded 的标记打包。

要动：fushi/lib/src/sync/backup_service/path_rebase.part.dart；fushi/lib/src/sync/backup_service/restore.part.dart；fushi/lib/src/sync/backup_merge_engine.dart；fushi/lib/src/sync/backup_service.dart；fushi/lib/src/profile/profile_repository.dart

核验说明：成立的部分：path_rebase.part.dart（479 行）确实是第二套执行器，_rebaseVideoPaths（:364-385）只改 video_path 和 playlist_json；守卫只读 data_root_migrator.dart，不看这一份。不成立或夸大的部分：推测「视频封面/字幕在备份包里，恢复后会悬空」不对。backup_service.dart 里只有 game_covers（:87,:440-442）和 videoFiles 被打包，grep 不到 video_covers 打包，所以视频封面压根不进包，不存在「包里有但没改写」的漏改，是没有备份（恢复后靠重刮）。这是范围上的取舍，不是这套执行器的漏洞。media_images 在 table_rules.part.dart:240 是 rowLevel 规则，作为可重建缓存处理。

方案风险：「恢复时 DB 一个字节不用改」只对 library 根内的文件成立。各类目在包里是否存在由用户勾选决定，比如没选 videos 时 StoredPath 照样指向本机根下一个不存在的文件，只是从「指向别机绝对路径」变成「指向本机空位」，仍然要有缺失对账的 UI。另外合并导入（backup_merge_engine）有行级 uid 重映射，文件名带 uid（如 game_covers/<id>.<ext>）时，逻辑路径也要跟着重映射，并不是零改写。

修正后的方案（以此为准）：沿用 StoredPath 方案，但要写明两点：(1) 合并导入时，文件名里含本机 id 的受管文件（game_covers/<galgames.id> 之类）仍要随 id 重映射改 rel；最好先改成文件名不含行 id（用内容哈希或 uid），重映射才能整类消失。(2) 未打包类目的行恢复后统一进 LibraryContentAudit 的缺失对账，不再按类目各自兜底。

## picked-video-copies-support-root

**选择器导入的视频副本放在 <support>/imported_videos，可只有 documents 根会被改写：iOS 换容器 / 换数据根后会悬空（推测，未复现）**

- 类型：成类 bug；规模 M；价值 high；改持久化 / wire、用户可见
- 核验：成立

证据：

- packages/fushi_engine/lib/foundation/engine_paths.dart:74-76 pickedVideoCopiesDirectory = <support>/imported_videos
- fushi/lib/src/media/video/video_import_dialog.dart:617-622 和 fushi/lib/src/pages/implementations/video_fushi_page.dart:8011-8015 adoptPickedVideoCopy 把副本挪进去，落库的是这个绝对路径
- fushi/lib/src/storage/path_rebase_coverage.dart:413-418 VideoBooks.videoPath 标为 documentsRooted，理由里只列了 <documents>/remote_videos、videos，没提 support 下的副本
- fushi/lib/src/storage/data_root_migrator.dart:2043-2083 DocumentsPathRebaser 只认 oldRoot（documents）前缀；:1251-1283 表列只按 docs 改写，newSupportRoot 只给 prefs 用
- fushi/lib/src/storage/sandbox_relocation.dart:103-107 iOS 容器漂移时只构造 documents 的改写器，可 support（Library/Application Support）也在同一个容器 UUID 下
- fushi/lib/src/storage/app_paths.dart:1490-1540 fushiOwnedDocumentsEntries、storage_usage_service.dart:488-540 存储类目、library_content_audit.dart:276-301 的对账都只看 documents 根，所以这批副本也不进存储明细、不进缺失对账

机制：「哪里放受管媒体」没有单一规定。这个导入副本目录是单独加的，放在了 support 根，可改写引擎、白名单、存储页、内容对账都默认受管媒体只在 documents 根下。前缀推断模型分辨不出这是 Fushi 自己的副本，也就不会跟着根走。

根本方案：根本解是 absolute-path-persistence 加 managed-area-registry：副本登记为 ManagedArea.importedVideos，存成 StoredPath(library, 'imported_videos/<uid>/...')，根变了自动跟着走，同时出现在存储类目和内容对账里。在逻辑路径落地之前不另打补丁：受管媒体一律放在 library 根，由 ManagedArea 登记表决定，support 根只放 DB、密钥、任务状态这类非媒体数据。存量的 <support>/imported_videos 由 StoredPath 的一次性迁移转成 support 根下的逻辑路径，不需要搬文件。守卫：ManagedArea 里凡是 kind=media 的，root 必须是 library（这是登记表的结构断言，不用扫源码）。动手前要先在 iOS 模拟器上复测原始失败路径：选择器导入视频 → 换容器重装 → 打开。

要动：packages/fushi_engine/lib/foundation/engine_paths.dart；fushi/lib/src/engine_bindings.dart；fushi/lib/src/media/video/video_import_dialog.dart；fushi/lib/src/pages/implementations/video_fushi_page.dart；packages/fushi_engine/lib/media/video/video_book_repository.dart

核验说明：代码路径已验证，iOS 设备上未复现。engine_paths.dart:68-77 把副本放在 `<support>/imported_videos`；sandbox_relocation.dart:113-123 只构造 DocumentsPathRebaser（scope=fushiOwnedDocumentsEntries），表列改写只用 docs，newSupportRoot 只用于 prefs/profile（data_root_migrator.dart:1254-1282）；读取时的兜底 video_resource_check.dart:55-73 也只识别 `.../Documents/...` 段，support（Library/Application Support）下的副本两层都兜不住。桌面换数据根有 BUG-1188「support 不搬」（data_root_migrator.dart:93），所以桌面不受影响，问题只在 iOS 容器漂移，审计把「换数据根」也列进去略有夸大。

方案风险：「受管媒体一律放 library 根」会和 Android 的外部/内部书库锚点交织：放到外部 library 根以后，卸载时文件保留但 DB 被清，正是 orphan_book_recovery 要处理的形态，需要一并考虑。守卫「media 类的 root 必须是 library」会和 iOS 的 Directory.systemTemp、inbox_imports 这些回收目录（engine_bindings.dart:70-82 pickerImportCopyDirectories）冲突，它们属于回收源，不是落点，应该单独建模。

修正后的方案（以此为准）：同意。在 StoredPath 落地之前，iOS 上最小的根本修法是把 sandbox_relocation 的表列改写扩展到 support 根（PathRebaseKind.supportRooted 已经存在，path_rebase_coverage.dart:33，但表列没接上 support 改写器），而不是把副本搬去 documents。最终在 ManagedArea 里把 pickerImportCopyDirectories 建成 kind=reclaimSource，和 media 落点分开。

## managed-area-registry

**受管目录清单在 EnginePaths / AppPaths 白名单 / 存储类目 / 证据豁免 / ServerPaths 五处手写，靠正则扫源码的守卫对齐**

- 类型：缺单一登记源；规模 M；价值 high；不改外部行为
- 核验：成立

证据：

- packages/fushi_engine/lib/foundation/engine_paths.dart:38-50 用字面量 'video_covers'/'video_subtitles'/'fushi_books'/'audiobooks' 派生目录
- fushi/lib/src/storage/app_paths.dart:1801-1850 又把同一批名字重写一遍（外加 game_covers、music_covers、mpv_* 等），:1490-1540 fushiOwnedDocumentsEntries 30 项，每项都靠注释说明「派生点在哪、必须随数据根走」，:648 libraryEvidenceIgnoredEntries 是第四份
- fushi/lib/src/storage/storage_usage_service.dart:488-540 kStorageCategoryDocumentsChildren 再把同一批目录名按类目列一遍，注释写着「与白名单保持全覆盖（守卫测试咬住）」；:738-745 audiobookPersistDirPath 把 AudiobookStorage.ensurePersistDir 的 fnv 口径抄了一份
- fushi/test/storage/documents_whitelist_guard_test.dart:25-27 守卫只认得 documentsSubdirectory('x') 和 appDirectory.path, 'x' 这两种字面写法，换个变量名（storage_usage_service.dart:949 p.join(docs.path, 'dictionaryResources')、app_model.dart:6237）就扫不到
- packages/fushi_server/lib/src/server_paths.dart:34 server 的词典放在 <support>/dictionaries，app 放在 <documents>/dictionaryResources（app_model.dart:6237）：同一个能力两套布局

机制：目录布局是一个事实，但带着多个属性（在哪个根、是否随数据根迁移、是否算书库证据、归哪个存储类目、是否进备份、app 和 server 是否共享），这些属性散落在各处的字符串集合里。每加一个目录就要改 3～5 处，再靠扫源码的守卫事后抓遗漏。

根本方案：在 fushi_engine/foundation 新建 managed_area.dart，用一个增强枚举 ManagedArea { epubBooks('fushi_books', root: library, category: books, evidence: true, backup: true), videoCovers(...), dictionaryResources(...), importedVideos(...), ... } 作为唯一登记源，字段包括 dirName、StorageRootId、StorageCategoryId、migratesWithRoot、countsAsLibraryEvidence、backupIncluded、kind(media/cache/working/export)。EnginePaths 只暴露 Future<Directory> area(ManagedArea) 和 resolve(StoredPath)，删掉全部按名字字面量写的 *Directory() getter（AppPaths 的同名 getter 和 EnginePaths 里的字面量一起删）。fushiOwnedDocumentsEntries、libraryEvidenceIgnoredEntries、kStorageCategoryDocumentsChildren、备份打包清单都改成从 ManagedArea.values 派生。ServerPaths 只负责注册根，不再自定子目录名，app 和 server 的布局自然一致。守卫换成：lib/ 里禁止对根目录做 p.join(<root>, '<字面量>')，只用一条 lint 拦字符串派生，不再逐个比对名字；外加 ManagedArea 自身的结构断言（dirName 唯一、media 类必须在 library 根）。以后新增目录只加一个枚举值。

要动：packages/fushi_engine/lib/foundation/engine_paths.dart；packages/fushi_engine/lib/foundation/（新 managed_area.dart）；fushi/lib/src/storage/app_paths.dart；fushi/lib/src/storage/storage_usage_service.dart；fushi/lib/src/storage/android_library_db_witness.dart；packages/fushi_server/lib/src/server_paths.dart；fushi/test/storage/documents_whitelist_guard_test.dart

核验说明：documents_whitelist_guard_test.dart:15-30 确认只用三条正则（documentsSubdirectory('x')、appDirectory.path, 'x'、插值）；同一文件 :20-23 还写明 video_clips、Hibiki、AudiobookStorage「直连 getApplicationDocumentsDirectory，不随数据根走」，被刻意排除在扫描之外，进一步证明布局属性是分散的。ServerPaths（server_paths.dart:34）词典放在 support/dictionaries，app 白名单（app_paths.dart:1510）是 documents 下的 dictionaryResources，两套布局属实。app_model.dart:6237 这个引用在当前树里不存在（文件已拆分），这条证据过时，不影响结论。

方案风险：把 AppPaths/EnginePaths 的具名 getter 全部换成 area(ManagedArea) 改动面很大，而 fushi_engine 不能依赖 flutter/fushi，所以 ManagedArea 要放在 fushi_engine/foundation 或 fushi_core，StorageCategoryId 这类 UI 概念要避免下沉进引擎（只放 id，标签和图标留在 app）。server 与 app 的词典布局统一后，server 存量的 support/dictionaries 需要一次搬迁。

## ownership-by-prefix-and-fullscan-gc

**文件归属靠路径前缀推断：删除回收要全表算引用集，孤儿回收、内容对账、存储统计都得重扫磁盘或倒推尾段**

- 类型：性能；规模 XL；价值 medium；改持久化 / wire、用户可见
- 核验：部分成立

证据：

- packages/fushi_engine/lib/media/video/video_storage.dart:330-360 _OwnedAssetGuard 用 canonicalize + _isInside(ownedDir) 判断是不是自家文件，外加调用方给的 stillReferenced 集合；:347 删除失败就循环 6 次、每次 delay 40ms 重试（延迟重试掩盖文件被占用）
- packages/fushi_engine/lib/media/video/video_book_repository.dart:1860-1897 每次删除都要拿 survivors（全表 listAll）算 referencedAssetPathsOf；注释承认原实现是 O(N²)，BUG-4748 只是把规范化提到循环外
- packages/fushi_engine/lib/media/video/video_book_repository.dart:1777-1790 iOS /var 和 /private/var 软链导致前缀比对两边都要试的补丁
- fushi/lib/src/storage/android_library_db_witness.dart:52-56 和 :123-150、fushi/lib/src/storage/library_content_audit.dart:276-301 各自手写一份 SELECT 路径列清单，再从右往左找白名单段倒推「数据根内尾段」，和 sandbox_relocation.dart:196 的倒推是第三份
- fushi/lib/src/storage/storage_usage_service.dart:693,805,897 每次打开存储页都在 isolate 里递归 stat 整棵树求和；docs/bugs/BUG-2096-storage-category-detail-gap.md 指出总量按整树算（含孤儿）、明细只列 DB 已知条目，是两套口径
- fushi/lib/src/storage/orphan_book_recovery.dart:1-25 从目录内容和目录名去猜孤儿书的类型和 bookKey（legacyNumericDirectory、duplicateSuffixDirectory 这类还原不出来的分支）

机制：DB 只存路径，不记「这个文件是不是 Fushi 管的、属于哪一行、多大」。于是删除时只能现场全表扫引用，统计时只能扫盘，对账和倒推旧根只能解析路径字符串，孤儿只能按目录内容反向猜。每种媒体各写一份，彼此口径不一致。

根本方案：在 StoredPath 的基础上加一张受管文件账本 managed_files(root_id, rel_path PK, area, owner_kind, owner_id, bytes, created_at)，由 fushi_core 的 ManagedStore 统一负责「放入（复制/移动/下载完成）→ 登记」「删除 owner → 级联回收」。按复制导入和按引用导入的区别在类型上就表达出来：受管文件是 <rootId>:rel 并在账本里有行，外部文件是 ext:，永远不删。删除变成按 owner_id 查账本再删文件，不再全表 listAll，也不再做前缀和软链判断；文件被占用这类失败记进账本的 pending_delete 状态，下次启动统一清理，不再原地 sleep 重试。存储页按 area 求和 bytes，O(行数)，账本外的文件就是孤儿，单列一行「未登记」，两套口径合成一套。LibraryContentAudit 和 AndroidLibraryDbWitness 直接读账本的 rel_path，删掉各自的 SELECT 清单和尾段倒推。orphan_book_recovery 只处理账本外的目录。可以删掉：VideoStorage._OwnedAssetGuard 和重试循环、referencedAssetPathsOf 引用集计算、collection_asset_reclaim 的 stillReferenced、gcOrphanCovers 的目录遍历、witness 和 audit 的 SQL 清单。守卫：ManagedStore 是唯一允许往受管根写文件的 API（lint 禁止在 fushi_engine/lib/media 里直接对受管根 File.create/rename）。

要动：packages/fushi_core/lib/src/database/tables.dart；packages/fushi_engine/lib/media/video/video_storage.dart；packages/fushi_engine/lib/media/video/video_book_repository.dart；packages/fushi_engine/lib/media/collections/collection_asset_reclaim.dart；packages/fushi_engine/lib/epub/epub_storage.dart；packages/fushi_engine/lib/media/manga/manga_storage.dart；fushi/lib/src/storage/storage_usage_service.dart；fushi/lib/src/storage/library_content_audit.dart；fushi/lib/src/storage/android_library_db_witness.dart；fushi/lib/src/storage/orphan_book_recovery.dart

核验说明：现象属实：video_storage.dart:330-360 有 6 次 × 40ms 的删除重试，违反「禁止延迟重试掩盖症状」；video_book_repository.dart:1842-1897 每次删除都要 listAll 幸存行求引用集，注释写着 BUG-2754 已把批量删除从 O(N²) 降到 O(N)。但根本方案有结构漏洞：之所以要算幸存行引用集，是因为资产会被多行共享（注释「仍被幸存行引用的封面/字幕/附加图一律保留」），而 managed_files 以 rel_path 为主键、只有单个 owner_id，表达不了共享，会误删或漏删。

方案风险：1) 共享资产要建成多对多的引用表（managed_file_refs(rel_path, owner_kind, owner_id)），按引用计数为 0 才回收，不能用单 owner 列。2) 账本和文件系统是双写，崩溃或外部删文件都会让两边不一致，还是需要对账扫描（频率可以降，但不能消失），所以「存储页 O(行数)」只在账本可信时成立，孤儿检测仍要扫盘。3) bytes 字段在文件被外部修改、下载断点续传、torrent 写入时都会过期，需要定义更新点。4) 这是持久化与生命周期逻辑，可以留在 Dart/fushi_core，不违反 Rust 胖核心规则，但如果要做批量扫盘对账，>1ms 的部分需要放后台 isolate（现在已在 isolate）。

修正后的方案（以此为准）：账本改成两张表：managed_files(root_id, rel_path PK, area, bytes, state[live/pending_delete], created_at) 加 managed_file_refs(rel_path, owner_kind, owner_id, PK 三元组)。删除 owner 时只删 refs 行，refs 计数为 0 的文件转为 pending_delete，由单一回收器在后台删除；删除失败保持 pending_delete 状态，不原地重试。存储页用账本 bytes 出快速总量，同时保留低频后台扫盘对账，用来发现「未登记」和「账本有、磁盘无」两种漂移。

## server-no-path-relocation

**fushi_server 用同一套存绝对路径的表，但没有任何改写或重定位：备份还原到另一个 data_dir、改 Docker 挂载路径后库里的路径整体悬空**

- 类型：app / 服务端各写一套；规模 M；价值 medium；改持久化 / wire
- 核验：成立

证据：

- packages/fushi_server/lib/src/server_runtime.dart:192 server 用的是同一个 FushiDatabase（同样的 video_books.video_path / epub_books.extract_dir 等绝对路径列）
- packages/fushi_server/lib/src/backup/server_backup.dart:343-346 还原时把配置里的 data_dir 改成本机路径，注释原话「包里那份是备份机器上的绝对路径」，但只改了配置，库里的路径列没动
- packages/fushi_server/lib/src/backup/server_backup.dart:22-24 includeDocuments:false 时「还原后库里的条目会指向缺失的文件」，靠用户重扫
- packages/fushi_server 下 grep 不到任何 rebase / Relocation 实现；app 那边同样的问题有 DataRootMigrator / SandboxRelocation 两套机制（fushi/lib/src/storage/data_root_migrator.dart:1251、sandbox_relocation.dart:73）
- packages/fushi_server/lib/src/server_paths.dart:13-34 server 自定了布局（documents/support/tmp/interconnect，词典在 support/dictionaries），和 app 的布局不一致

机制：路径的可移植性是在 app 层（fushi/lib/src/storage）靠事后改写补上的，并没有做进 fushi_core/fushi_engine 的数据模型。server 复用了同一套表和引擎，却没有复用 app 的补丁。按现在的架构，只能把 app 的补丁再抄一份到 server，这正是要避免的分叉。

根本方案：StoredPath（absolute-path-persistence）和 ManagedArea（managed-area-registry）下沉到 fushi_core / fushi_engine 之后，server 只在启动时由 ServerPaths 向 RootRegistry 注册 library/support/downloads/temp 四个根，备份还原、换 data_dir、换挂载点都不需要改 DB。server 的一次性迁移和 app 共用 fushi_core 里同一个迁移内核：用 server 当前的 data_dir 把绝对路径转成逻辑路径。不在 server 里另写 rebase。词典目录按 ManagedArea.dictionaryResources 统一。可以删掉：server_backup.dart 里改写 data_dir 之外的任何路径兜底（现在没有，以后也不用加），以及 server-parity-gaps.md 里相应的缺口条目。

要动：packages/fushi_server/lib/src/server_paths.dart；packages/fushi_server/lib/src/backup/server_backup.dart；packages/fushi_server/lib/src/host_bindings.dart；packages/fushi_core（迁移内核）；docs/agent/server-parity-gaps.md

核验说明：server_backup.dart:335-346 注释写明只把配置里的 data_dir 改成本机路径；packages/fushi_server/lib 下 grep 不到 rebase 或 Relocat；server 复用同一套 FushiDatabase 和引擎仓储，写进去的是绝对路径。server_paths.dart:25-40 自定了布局（support/dictionaries、host_jobs、interconnect_profiles）。

方案风险：Docker 场景下用户可能直接挂载外部媒体目录（ext:），换挂载点后 ext: 照样悬空，StoredPath 解决不了；如果要支持，需要允许用户登记「外部库根」作为可重映射的命名根（userRoot:<id>），不能全部塞进 ext:。

修正后的方案（以此为准）：在四个固定根之外，再允许注册用户命名的外部库根（libraryScanRoot:<id>），app 的外部素材目录、server 的挂载媒体目录都按它存，换挂载点只改根表；真正零散的外部文件才用 ext:。

## 核验补充（审计漏掉的）

- fushi/lib/src/media/video/video_resource_check.dart:55-73 relocateMissingAppDocumentPath 是第四层「读取时按 iOS 容器 UUID 倒推」的补丁，和 SandboxRelocation 的倒推（sandbox_relocation.dart:196 附近）是两份独立的判据；审计的删除清单里没有它
- fushi/test/storage/documents_whitelist_guard_test.dart:20-23 明写 video_clips、桌面导出目录 Hibiki、AudiobookStorage 直连 getApplicationDocumentsDirectory、不随数据根走：同一个 documents 下有「随根迁移」和「刻意不迁移」两种媒体目录。这是比白名单重复更根本的布局分叉，ManagedArea 设计里必须明确 migratesWithRoot=false 的目录在 StoredPath 下归哪个根（否则会被当成 library 根下的路径而出错）
- path_rebase_coverage.dart:33 已经有 PathRebaseKind.supportRooted，但表列改写只接 documents（data_root_migrator.dart:1254-1282，support 只给 prefs/profile），也就是说声明表的模型和执行器在 support 根上本来就不对齐，picked-video-copies 只是其中一个实例
- 备份格式没有显式的版本与向下兼容策略：任何把路径值改成新格式的方案，都会让旧版 app 导入新包时静默悬空。这比任何单列漏改的影响面都大，需要在 StoredPath 方案里作为前置项
