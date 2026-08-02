/// BUG-1174：数据根迁移「哪些持久化字段承载绝对路径、迁移要不要改写」的**单一真相源**。
///
/// 历史上这份知识只活在 [DataRootMigrator] 的一串 UPDATE 语句里，于是每加一列存路径的
/// 字段就漏一次：TODO-1255 漏了 video_books.cover_path（迁移后视频封面全占位），
/// BUG-1174 又一次性发现漏了 galgames.cover_path、video_books.subtitle_source ×2、
/// media_items.image_url、整张 profile_settings 和 5 个 pref key。注释拦不住这种遗漏
/// ——注释不会红。把清单**声明化**并由源码扫描守卫
/// （test/storage/path_rebase_coverage_guard_test.dart）比对：新增路径列而忘了登记就在
/// CI 上红，而不是等用户数据坏了才发现。
///
/// 与 sync/pref_redaction_policy.dart 同款骨架：一份声明 + 一个谓词 + 多处消费。
library;

import 'package:flutter/foundation.dart';

import 'package:hibiki/src/media/media_source.dart' show dbSourcePrefKey;

/// 一个持久化字段在数据根迁移里的处置。
enum PathRebaseKind {
  /// 落在 **documents（内容/书库）根**下的绝对路径 —— 迁移必须 rebase 到新 documents 根。
  documentsRooted,

  /// 落在 **support（数据库）根**下的绝对路径 —— 迁移必须重挂到新 support 根
  /// （按文件名，见 LocalAudioManager.resolveInternalPath）。
  supportRooted,

  /// 用户自选的**外部**绝对路径（外部素材目录 / 游戏安装位置 / 系统工具 / 文件选择器
  /// 上次目录）—— 不在数据根内，迁移**绝不能**动它，动了就让外部资源失联。
  externalUserPath,

  /// 不是文件系统绝对路径：相对 href、裸文件名、成员引用、远端 URL、枚举/编码值、
  /// 与路径无关的结构化 JSON。
  notAPath,
}

/// 一列 Drift 列的迁移处置声明。
///
/// [table] / [column] 用 packages/hibiki_core/lib/src/database/tables.dart 里的
/// **Dart 名**（表类名 + 列 getter 名），因为守卫测试扫的就是那份源码；SQL 名由 drift
/// 从它派生（全仓无 named() 显式改名），两者一一对应。
@immutable
class PathRebaseColumn {
  const PathRebaseColumn(this.table, this.column, this.kind, this.reason);

  /// tables.dart 里的 Dart 表类名（如 VideoBooks）。
  final String table;

  /// tables.dart 里的 Dart 列 getter 名（如 coverPath）。
  final String column;

  final PathRebaseKind kind;

  /// 为什么是这个处置。**必填**：豁免一列必须给得出理由，否则下一个人无从判断该不该
  /// 改判。守卫测试断言非空。
  final String reason;

  /// 迁移是否必须改写这一列。
  bool get mustRebase =>
      kind == PathRebaseKind.documentsRooted ||
      kind == PathRebaseKind.supportRooted;

  /// drift 默认的 snake_case SQL 列名。守卫据此断言 must-rebase 列真的出现在迁移器里。
  String get sqlColumn => column.replaceAllMapped(
      RegExp('[A-Z]'), (Match m) => '_${m[0]!.toLowerCase()}');

  @override
  String toString() => '$table.$column($kind)';
}

/// pref 值承载路径的形态（决定用哪个改写器）。
enum PathValueShape {
  /// 裸绝对路径（空串 = 未设置）。
  bare,

  /// JSON 字符串数组，每个元素是绝对路径。
  jsonStringList,

  /// JSON map，value 是 subtitleSource 四态编码（本地已下载 = 绝对路径）。
  subtitleSourceMapJson,

  /// 字体 catalog：{version, fonts:[{id,name,path}]}。
  fontCatalogJson,

  /// 字体列表：[{name,path,enabled}]。
  fontListJson,

  /// 本地发音库列表（PrefCodec s: tag + JSON 对象数组，按**文件名**重挂）。
  localAudioDbsJson,

  /// typed 音频来源配置（PrefCodec j: tag + JSON 对象数组，仅 localAudio 条目带 path）。
  audioSourceConfigsJson,

  /// v55 legacy 游戏库 JSON 数组，仅 coverPath 字段是数据根内路径。
  legacyGalgameLibraryJson,

  /// 不承载数据根内路径。
  none,
}

/// 一个 Drift preferences / profile_settings KV 键的迁移处置声明。
@immutable
class PathRebasePref {
  const PathRebasePref(this.key, this.kind, this.shape, this.reason);

  /// pref key 的**字面值**。经编码器生成的键（dbSourcePrefKey('reader_ttu', ...)）
  /// 也写展开后的字面值，守卫按字面值比对。
  final String key;

  final PathRebaseKind kind;
  final PathValueShape shape;
  final String reason;

  bool get mustRebase =>
      kind == PathRebaseKind.documentsRooted ||
      kind == PathRebaseKind.supportRooted;

  @override
  String toString() => '$key($kind/$shape)';
}

/// tables.dart 里**所有**名字带 path|dir|root|url|source|file|json 的 TextColumn 的
/// 处置声明，外加几列名字看不出、但确实承载路径 / KV 的列（preferences.value、
/// profile_settings.value、galgames.launchArgs、galgames.upscalingMode）。
///
/// 守卫双向比对：路径形列漏声明红、声明了但列已不存在也红。
/// 按 tables.dart 出现顺序排列，便于人工对照。
const List<PathRebaseColumn> kPathRebaseColumns = <PathRebaseColumn>[
  // ── media_items（媒体历史）─────────────────────────────────────────
  PathRebaseColumn('MediaItems', 'mediaSourceIdentifier',
      PathRebaseKind.notAPath, '媒体源标识（MediaSource.uniqueKey），不是路径。'),
  PathRebaseColumn(
      'MediaItems',
      'imageUrl',
      PathRebaseKind.documentsRooted,
      '本地书封面存 file://<绝对路径> URI（reader_hibiki_source.dart 的 '
          'Uri.file(candidate)，候选全在 <documents>/hoshi_books 下；SRT 书同款）。'
          '远端源存 http(s) URL，scheme 非 file 时改写器原样跳过。'),
  PathRebaseColumn('MediaItems', 'audioUrl', PathRebaseKind.notAPath,
      '历史 MediaItem 的远端音频 URL 字段；生产代码无写入点（jidoujisho 血统遗留）。'),
  PathRebaseColumn('MediaItems', 'extraUrl', PathRebaseKind.notAPath,
      '同 audioUrl：生产代码无写入点，只被历史仓库原样搬运。'),
  PathRebaseColumn('MediaItems', 'sourceMetadata', PathRebaseKind.notAPath,
      '每章字符数 JSON（jsonEncode(sectionChars)），无路径。'),

  // ── anki_mappings ─────────────────────────────────────────────────
  PathRebaseColumn('AnkiMappings', 'exportFieldKeysJson',
      PathRebaseKind.notAPath, '字段 key 列表 JSON，无路径。'),
  PathRebaseColumn('AnkiMappings', 'creatorFieldKeysJson',
      PathRebaseKind.notAPath, '字段 key 列表 JSON，无路径。'),
  PathRebaseColumn('AnkiMappings', 'creatorCollapsedFieldKeysJson',
      PathRebaseKind.notAPath, '字段 key 列表 JSON，无路径。'),
  PathRebaseColumn(
      'AnkiMappings', 'tagsJson', PathRebaseKind.notAPath, '标签字符串列表 JSON，无路径。'),
  PathRebaseColumn('AnkiMappings', 'enhancementsJson', PathRebaseKind.notAPath,
      '增强功能 key 映射 JSON，无路径。'),
  PathRebaseColumn('AnkiMappings', 'actionsJson', PathRebaseKind.notAPath,
      '快捷操作 key 列表 JSON，无路径。'),

  // ── preferences / profile_settings（KV 承载列）──────────────────────
  PathRebaseColumn('Preferences', 'value', PathRebaseKind.documentsRooted,
      'KV 承载列：逐 key 的处置见 [kPathRebasePrefs]。documents / support 两族都有。'),
  PathRebaseColumn(
      'ProfileSettings',
      'value',
      PathRebaseKind.documentsRooted,
      'BUG-1174 最阴的一处：ProfileRepository.snapshotCurrentSettings 把**每一条**非'
          '排除 Drift pref 原样复制进来（category=pref），applyProfile 再原样写回 '
          'preferences。迁移只改 preferences 的话，用户切一次 Profile 就把刚 rebase 好的'
          '路径整体回滚回旧值——迁移当天一切正常、几天后突然坏，极难归因。'
          '必须与 preferences 用**同一个**改写函数、覆盖**所有** Profile 的快照。'),

  // ── audiobooks ────────────────────────────────────────────────────
  PathRebaseColumn(
      'Audiobooks',
      'audioRoot',
      PathRebaseKind.documentsRooted,
      '复制导入模式 = <documents>/audiobooks/<hash>；folder 模式的外部目录（遗留、当前'
          '无写入点）不以旧根开头 → 天然跳过。'),
  PathRebaseColumn(
      'Audiobooks',
      'audioPathsJson',
      PathRebaseKind.documentsRooted,
      'JSON 字符串数组；复制模式是持久目录内绝对路径，「引用原文件」模式是外部路径（天然跳过）。'),
  PathRebaseColumn(
      'Audiobooks',
      'alignmentPath',
      PathRebaseKind.documentsRooted,
      '<documents>/audiobooks/<hash>/ 下的字幕副本绝对路径。'),

  // ── srt_books ─────────────────────────────────────────────────────
  PathRebaseColumn('SrtBooks', 'audioRoot', PathRebaseKind.documentsRooted,
      '同 Audiobooks.audioRoot。'),
  PathRebaseColumn('SrtBooks', 'audioPathsJson', PathRebaseKind.documentsRooted,
      '同 Audiobooks.audioPathsJson。'),
  PathRebaseColumn('SrtBooks', 'srtPath', PathRebaseKind.documentsRooted,
      '持久目录内 SRT 副本绝对路径。'),
  PathRebaseColumn('SrtBooks', 'coverPath', PathRebaseKind.documentsRooted,
      '<documents>/audiobooks/<hash>/cover.<ext> 绝对路径。'),

  // ── dictionary_metadata / dictionary_history ──────────────────────
  PathRebaseColumn('DictionaryMetadata', 'metadataJson',
      PathRebaseKind.notAPath, '词典元数据 JSON（标题/版本/作者），无路径。'),
  PathRebaseColumn('DictionaryMetadata', 'hiddenLanguagesJson',
      PathRebaseKind.notAPath, '语言代码列表 JSON，无路径。'),
  PathRebaseColumn('DictionaryMetadata', 'collapsedLanguagesJson',
      PathRebaseKind.notAPath, '语言代码列表 JSON，无路径。'),
  PathRebaseColumn('DictionaryHistory', 'resultJson', PathRebaseKind.notAPath,
      '查询结果快照 JSON（词条文本），无路径。'),

  // ── epub_books ────────────────────────────────────────────────────
  PathRebaseColumn(
      'EpubBooks',
      'coverPath',
      PathRebaseKind.notAPath,
      '**相对 href**（相对 extractDir）/ PDF 的 cover.png / 漫画的相对路径。迁移器仍把'
          '它送进改写器，是防御性 no-op（不以旧根开头 → 原样返回）。'),
  PathRebaseColumn(
      'EpubBooks',
      'epubPath',
      PathRebaseKind.notAPath,
      '多语义：普通导入 = 裸 basename / PDF = document.pdf / 漫画 = manga.json / '
          '来源库扫描 = **外部**绝对路径。四种都不是数据根内路径，改写恒 no-op；调用'
          '保留作防御。'),
  PathRebaseColumn('EpubBooks', 'extractDir', PathRebaseKind.documentsRooted,
      '<documents>/hoshi_books/<bookKey> 绝对目录。'),
  PathRebaseColumn('EpubBooks', 'chaptersJson', PathRebaseKind.notAPath,
      '书内相对 href 列表，无绝对路径。'),
  PathRebaseColumn(
      'EpubBooks', 'tocJson', PathRebaseKind.notAPath, '书内相对 href 目录树，无绝对路径。'),
  PathRebaseColumn('EpubBooks', 'sourceMetadata', PathRebaseKind.notAPath,
      '来源库扫描元数据 JSON，无本机数据根路径。'),

  // ── video_books ───────────────────────────────────────────────────
  PathRebaseColumn(
      'VideoBooks',
      'videoPath',
      PathRebaseKind.documentsRooted,
      '三态：数据根内下载副本（<documents>/remote_videos、videos）/ 用户原位外部视频 / '
          'http(s) 流 URL。后两态不以旧根开头 → 天然跳过。'),
  PathRebaseColumn(
      'VideoBooks',
      'subtitleSource',
      PathRebaseKind.documentsRooted,
      'BUG-1174 漏项。四态编码（video_subtitle_source.dart:362-430）：外挂 = 裸绝对'
          '路径（多为 <documents>/video_subtitles/<basename> 内部副本）/ 内嵌 = '
          'embedded:<n> / 关闭 = off: / 无偏好 = null。**只有绝对路径态**参与改写，'
          '另两个哨兵显式判掉（不靠「不以旧根开头」这个巧合）。video_subtitles 在搬移'
          '白名单里 → 不改写 = 所有外挂字幕失联，查词与双字幕一并失效。'),
  PathRebaseColumn(
      'VideoBooks',
      'secondarySubtitleSource',
      PathRebaseKind.documentsRooted,
      'BUG-1174 漏项，与 subtitleSource 同款四态编码，处置相同。'),
  PathRebaseColumn('VideoBooks', 'coverPath', PathRebaseKind.documentsRooted,
      '<documents>/video_covers/<sanitize(bookUid)>.jpg（TODO-1255 补的漏项）。'),
  PathRebaseColumn('VideoBooks', 'playlistJson', PathRebaseKind.documentsRooted,
      'JSON 对象数组 [{title,path}]，path 与 videoPath 同语义。'),
  PathRebaseColumn(
      'VideoBooks',
      'streamSpecJson',
      PathRebaseKind.notAPath,
      'TODO-1157 流媒体加载凭据 {subtitleUrl,subtitleFileName,referer,userAgent}，'
          '全是远端 URL / HTTP header，无本机路径。'),

  // ── 统计 / 收藏 ────────────────────────────────────────────────────
  PathRebaseColumn('FavoriteWords', 'sourceType', PathRebaseKind.notAPath,
      '统计桶枚举值（book/video/...），不是路径。'),
  PathRebaseColumn('MiningStatistics', 'sourceType', PathRebaseKind.notAPath,
      '统计桶枚举值，不是路径。'),
  PathRebaseColumn('LookupMiningCounters', 'sourceType',
      PathRebaseKind.notAPath, '统计桶枚举值，不是路径。'),
  PathRebaseColumn('MinedSentences', 'source', PathRebaseKind.notAPath,
      '跳转/统计来源标识（book | video | audiobook | lyrics），不是路径。'),
  PathRebaseColumn('StatisticsTombstones', 'sourceType',
      PathRebaseKind.notAPath, '统计桶枚举值，不是路径。'),

  // ── media_sources（来源库扫描根）────────────────────────────────────
  PathRebaseColumn(
      'MediaSources',
      'rootPath',
      PathRebaseKind.externalUserPath,
      '用户自选的**外部**扫描目录 / 带 scheme 的远端根，不在数据根内。改写它会让整个'
          '外部库失联（迁移器 :727-728 已显式声明跳过）。'),
  PathRebaseColumn('MediaSources', 'configJson', PathRebaseKind.notAPath,
      '远端来源连接参数 JSON（host/port/user/tls），无本机路径。'),

  // ── 合集 / 系列封面来源 ─────────────────────────────────────────────
  PathRebaseColumn('Series', 'coverSource', PathRebaseKind.notAPath,
      '成员引用 <mediaType>|<entryKey>，不是路径。'),
  PathRebaseColumn('MediaCollections', 'coverSource', PathRebaseKind.notAPath,
      '成员引用 <mediaType>|<entryKey>，不是路径。'),
  PathRebaseColumn(
      'MediaCollections',
      'coverPath',
      PathRebaseKind.documentsRooted,
      'BUG-1211 合集自有封面：<documents>/video_covers/collections/<id>.jpg'
          '（VideoStorage.collectionCoversDir，落盘唯一入口 '
          'cover_scraper_service.dart downloadCollectionCover）。与 '
          'video_books.cover_path / galgames.cover_path 完全同型 → 不改写 = '
          '换过封面的合集在换数据根后全部退回成员借用链，用户看到封面「自己变了」。'),

  // ── book_custom_css ───────────────────────────────────────────────
  PathRebaseColumn('BookCustomCss', 'relativePath', PathRebaseKind.notAPath,
      '相对 extractDir 的相对路径，不是绝对路径。'),

  // ── video_scrape_meta（刮削快照）───────────────────────────────────
  PathRebaseColumn('VideoScrapeMeta', 'source', PathRebaseKind.notAPath,
      'ScrapeSource 枚举名（bangumi/tmdb/...），不是路径。'),
  PathRebaseColumn('VideoScrapeMeta', 'tagsJson', PathRebaseKind.notAPath,
      '标签 JSON 数组，无路径。'),
  PathRebaseColumn('VideoScrapeMeta', 'infoboxJson', PathRebaseKind.notAPath,
      'infobox JSON 数组，无路径。'),
  PathRebaseColumn('VideoScrapeMeta', 'detailUrl', PathRebaseKind.notAPath,
      '远端条目详情页 URL，不是本机路径。'),

  // ── collection_scrape_meta（合集级刮削资料，schema v64 / BUG-1310）────
  PathRebaseColumn('CollectionScrapeMeta', 'source', PathRebaseKind.notAPath,
      'ScrapeSource 枚举名（bangumi/tmdb/...），不是路径。'),
  PathRebaseColumn('CollectionScrapeMeta', 'tagsJson', PathRebaseKind.notAPath,
      '标签 JSON 数组，无路径。'),
  PathRebaseColumn('CollectionScrapeMeta', 'infoboxJson',
      PathRebaseKind.notAPath, 'infobox JSON 数组，无路径。'),
  PathRebaseColumn('CollectionScrapeMeta', 'detailUrl', PathRebaseKind.notAPath,
      '远端条目详情页 URL，不是本机路径。'),
  PathRebaseColumn(
      'CollectionScrapeMeta',
      'backdropPath',
      PathRebaseKind.documentsRooted,
      'BUG-1310 合集横版背景：<documents>/video_covers/collections/'
          '<id>_backdrop.jpg（与同表兄弟 media_collections.cover_path 同目录、'
          '同落盘入口 cover_scraper_service.dart applyCandidateToCollection）。'
          '与 media_collections.cover_path 完全同型 → 不改写 = 换数据根后详情页'
          'hero 背景变死链，静默退回海报模糊垫底，用户看到背景「自己没了」。'),

  // ── media_images（媒体附加图组，schema v68 / Jellyfin 图组对齐）──────
  PathRebaseColumn('MediaImages', 'bookUid', PathRebaseKind.notAPath,
      '归属视频的 bookUid 逻辑外键，不是路径。'),
  PathRebaseColumn('MediaImages', 'kind', PathRebaseKind.notAPath,
      'MediaImageKind 枚举值（backdrop/logo/title_card），不是路径。'),
  PathRebaseColumn(
      'MediaImages',
      'path',
      PathRebaseKind.documentsRooted,
      'v68 附加图组落盘位：<documents>/video_covers/collections/（合集归属）与 '
          '<documents>/video_covers/images/（视频归属）两个目录族，与合集封面'
          '完全同型 → 不改写 = 换数据根后 hero 背景/logo、续播横卡全部死链，'
          '静默退回海报模糊垫底。'),
  PathRebaseColumn('MediaImages', 'sourceUrl', PathRebaseKind.notAPath,
      '来源远程 URL（重下/诊断用），不是本机路径。'),

  // ── collection_relations（合集相关作品边表，schema v66 / TODO-2484）──
  PathRebaseColumn('CollectionRelations', 'source', PathRebaseKind.notAPath,
      'ScrapeSource 枚举名（bangumi/tmdb/...），不是路径。'),
  PathRebaseColumn('CollectionRelations', 'coverUrl', PathRebaseKind.notAPath,
      '关联条目封面的远端 URL，不是本机路径。'),
  PathRebaseColumn(
      'CollectionRelations',
      'coverPath',
      PathRebaseKind.documentsRooted,
      '关联条目封面下载后的本地落盘位（<documents>/video_covers/ 目录族，与'
          '合集封面同型）。当前尚无写入方（下载归 UI 接力线程），但列语义即'
          '文档根内路径 —— 不改写 = 换数据根后相关作品卡封面变死链。'),

  // ── galgames ──────────────────────────────────────────────────────
  PathRebaseColumn('Galgames', 'exePath', PathRebaseKind.externalUserPath,
      '用户外部游戏安装位置（hook 注入目标），不在数据根内。'),
  PathRebaseColumn('Galgames', 'workdir', PathRebaseKind.externalUserPath,
      '游戏工作目录（默认取 exe 所在目录），外部路径。'),
  PathRebaseColumn(
      'Galgames',
      'launchArgs',
      PathRebaseKind.externalUserPath,
      '用户原样输入的命令行整行，可能内嵌外部绝对路径（如 --save="D:\\My Saves"）。'
          '**绝不能** rebase：它不是单一路径，切分/改写都会毁掉用户的启动参数。'),
  PathRebaseColumn('Galgames', 'upscalingMode', PathRebaseKind.notAPath,
      '窗口超分档位枚举 key（auto/installed_only/off，空串 = 未设置），不是路径。'),
  PathRebaseColumn(
      'Galgames',
      'coverPath',
      PathRebaseKind.documentsRooted,
      'BUG-1174 漏项：<documents>/game_covers/<id>.<ext>（AppPaths.gameCoversDirectory，'
          '落盘唯一入口 galgame_cover_resolver.dart:300-320）。与 TODO-1255 的 '
          'video_books.cover_path 完全同型 → 不改写 = 整个游戏库封面退化成默认手柄图标。'),
  PathRebaseColumn('Galgames', 'primarySource', PathRebaseKind.notAPath,
      '主展示源枚举（bgm/vndb/mixed/custom），不是路径。'),
  PathRebaseColumn('Galgames', 'customDataJson', PathRebaseKind.notAPath,
      '用户覆盖层 JSON；其中 coverSource 是**刮削源枚举 key**（bgm/vndb）而非本机文件路径。'),
  PathRebaseColumn('GalgameSources', 'source', PathRebaseKind.notAPath,
      '元数据源 key（bgm/vndb），不是路径。'),
  PathRebaseColumn('GalgameSources', 'dataJson', PathRebaseKind.notAPath,
      '刮削快照 JSON（远端字段，含远端封面 URL），无本机路径。'),

  // ── Mihon 漫画扩展（PR#594）────────────────────────────────────────
  // 这一组全部 notAPath，但理由分两类，别混：
  //  ① 远端 URL / 标识符 / 结构化 JSON —— 本来就不是本机路径；
  //  ② apkPath —— 是路径，但存的是**相对 mihon 根**的相对路径
  //     （`MihonManager` 写库时是 `p.join('extensions', '<pkg>.apk')`，读时由
  //     `resolveApkPath` 现场 join `rootDirectory`）。数据根一动，`rootDirectory`
  //     跟着 `databaseDirectory` 自然变，相对段无需改写——这正是相对存储的意义。
  //     谁要是把它改回绝对路径，就必须同时改成 supportRooted 并在
  //     DataRootMigrator 里补改写，否则换数据根后全部已装扩展当场失效。
  PathRebaseColumn('MangaExtensionStores', 'indexUrl', PathRebaseKind.notAPath,
      '扩展仓库的远端 https 索引地址（同时是主键），不是本机路径。'),
  PathRebaseColumn('MangaExtensionStores', 'extensionListUrl',
      PathRebaseKind.notAPath, '仓库可选的远端扩展清单地址，不是本机路径。'),
  PathRebaseColumn('MangaExtensionStores', 'contactJson',
      PathRebaseKind.notAPath, '仓库维护者联系方式 JSON（远端字段），无本机路径。'),
  PathRebaseColumn('MangaExtensions', 'storeUrl', PathRebaseKind.notAPath,
      '该扩展来自哪个远端仓库索引地址，不是本机路径。'),
  PathRebaseColumn(
      'MangaExtensions',
      'apkPath',
      PathRebaseKind.notAPath,
      '**相对** mihon 根的相对路径（`extensions/<pkg>.apk`），读时由 '
          'MihonManager.resolveApkPath 现场 join rootDirectory；数据根移动后相对段'
          '不变，无需 rebase。改成绝对路径就必须改判 supportRooted。'),
  PathRebaseColumn('MangaOnlineSources', 'sourceId', PathRebaseKind.notAPath,
      '扩展内的来源数字 ID（字符串化），不是路径。'),
  PathRebaseColumn('MangaOnlineSources', 'baseUrl', PathRebaseKind.notAPath,
      '来源站点的远端 https 地址，不是本机路径。'),
  PathRebaseColumn('MangaSourcePreferences', 'sourceId',
      PathRebaseKind.notAPath, '同上，来源数字 ID，不是路径。'),
  PathRebaseColumn('MangaSourcePreferences', 'valueJson',
      PathRebaseKind.notAPath, '扩展自定义偏好值的 JSON 编码（扩展私有语义），无本机路径。'),
];

/// Drift preferences（以及它在 profile_settings 里的每 Profile 快照副本）中承载路径的
/// 键。守卫比对 preferences_repository.dart 里的路径形 key 字面量。
/// **不是 const**：字体 key 必须经单一真相编码器 [dbSourcePrefKey] 生成，绝不硬编码
/// media_source 的私有 key 前缀格式（守卫 `test/media/db_source_pref_key_test.dart`）。
final List<PathRebasePref> kPathRebasePrefs = <PathRebasePref>[
  PathRebasePref(
      dbSourcePrefKey('reader_ttu', 'font_catalog'),
      PathRebaseKind.documentsRooted,
      PathValueShape.fontCatalogJson,
      '自定义字体 catalog，path 落 <documents>/custom_fonts。无 PrefCodec tag。'),
  PathRebasePref(
      dbSourcePrefKey('reader_ttu', 'custom_fonts'),
      PathRebaseKind.documentsRooted,
      PathValueShape.fontListJson,
      '旧影子字体列表，path 落 <documents>/custom_fonts。'),
  PathRebasePref(
      dbSourcePrefKey('reader_ttu', 'app_ui_fonts'),
      PathRebaseKind.documentsRooted,
      PathValueShape.fontListJson,
      '同上（App UI 字体）。'),
  PathRebasePref(dbSourcePrefKey('reader_ttu', 'dict_fonts'),
      PathRebaseKind.documentsRooted, PathValueShape.fontListJson, '同上（词典字体）。'),
  PathRebasePref(
      dbSourcePrefKey('reader_ttu', 'video_sub_fonts'),
      PathRebaseKind.documentsRooted,
      PathValueShape.fontListJson,
      '同上（视频字幕字体）。'),
  PathRebasePref(
      'local_audio_dbs',
      PathRebaseKind.supportRooted,
      PathValueShape.localAudioDbsJson,
      '内部副本 local_audio_<ts>.db 落 support 根；按**文件名**重挂（天然幂等），外部'
          '引用（BUG-483）原样保留。'),
  PathRebasePref(
      'audio_source_configs',
      PathRebaseKind.supportRooted,
      PathValueShape.audioSourceConfigsJson,
      'typed 音频来源配置，仅 localAudio 条目带 path；必须与 local_audio_dbs 同步重挂，'
          '否则 AppModel 的 path 相等匹配会断（TODO-1171）。'),
  PathRebasePref(
      'local_audio_db_path',
      PathRebaseKind.supportRooted,
      PathValueShape.bare,
      'BUG-1174 漏项：旧单库绝对路径。只要用户从未调过 setEntries，local_audio_dbs 为空'
          '时它仍被当回退读（local_audio_manager.dart:140-146）。与 local_audio_dbs 同款'
          '按文件名重挂。'),
  PathRebasePref(
      'galgame_library',
      PathRebaseKind.documentsRooted,
      PathValueShape.legacyGalgameLibraryJson,
      'BUG-1174 漏项：v55 legacy 游戏库 JSON，其中 coverPath 指 <documents>/game_covers。'
          'v55 迁移刻意只读不删（回滚兜底，database.dart:1523-1526），所以存量数据里它'
          '还在。同条目的 exePath / workdir 是外部路径，作用域谓词天然跳过。'),
  PathRebasePref(
      'video_remote_subtitle',
      PathRebaseKind.documentsRooted,
      PathValueShape.subtitleSourceMapJson,
      'BUG-1174 漏项（原调研清单未列出，实查补入）：远端/流媒体视频手选字幕来源 map，'
          'value 是 subtitleSource 四态编码，本地已下载态是 <documents>/video_subtitles '
          '下的绝对路径（jimaku_batch_dialog.dart:268 等）。与 video_books.subtitle_source '
          '同型，只是落在 KV 而非列上。'),
  PathRebasePref(
      'download_save_root',
      PathRebaseKind.documentsRooted,
      PathValueShape.bare,
      'BUG-1174 漏项：下载保存根。空串 = 用默认 <documents>/anime_downloads/content；'
          '用户第一次改设置时那个 documents 派生的默认值会被显式写进来。anime_downloads '
          '在搬移白名单里（会被物理搬走），不改写就指向不存在的旧位置。用户挑的外部盘不在'
          '旧根下 → 作用域谓词天然跳过。'),
  PathRebasePref(
      'download_save_root_history',
      PathRebaseKind.documentsRooted,
      PathValueShape.jsonStringList,
      'BUG-1174 漏项：下载根历史（JSON 字符串数组），含被压栈的旧默认根；不改写 → 迁移后'
          '这些历史根下的老任务在下载页整批失认。'),
  PathRebasePref('video_mpv_shader_dir', PathRebaseKind.externalUserPath,
      PathValueShape.none, '用户本机 mpv 着色器目录，外部路径，不随数据根走。'),
  PathRebasePref('manga_external_mokuro_path', PathRebaseKind.externalUserPath,
      PathValueShape.none, '系统安装的 mokuro 可执行文件路径，外部路径。'),
  PathRebasePref(
      'manga_reading_direction',
      PathRebaseKind.notAPath,
      PathValueShape.none,
      '阅读方向枚举（dir 是 direction 不是 directory）。守卫的 key 正则刻意宽松、宁可'
          '多要求几条声明，也不放过一个真路径 key。'),
  PathRebasePref('active_profile_id', PathRebaseKind.notAPath,
      PathValueShape.none, '当前 Profile 的自增 id（撞正则是因为 profile 里含 file）。不是路径。'),
  PathRebasePref('local_audio_db_display_name', PathRebaseKind.notAPath,
      PathValueShape.none, '旧单库显示名（与 local_audio_db_path 同族），不是路径。'),
];

/// 按 key 查处置；未登记返回 null。
PathRebasePref? pathRebasePrefFor(String key) {
  for (final PathRebasePref pref in kPathRebasePrefs) {
    if (pref.key == key) return pref;
  }
  return null;
}
