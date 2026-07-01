import 'package:drift/drift.dart';

// ── media_items ─────────────────────────────────────────────────────
@DataClassName('MediaItemRow')
class MediaItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get mediaIdentifier => text()();
  TextColumn get title => text()();
  TextColumn get mediaTypeIdentifier => text()();
  TextColumn get mediaSourceIdentifier => text()();
  TextColumn get uniqueKey => text().unique()();
  TextColumn get base64Image => text().nullable()();
  TextColumn get imageUrl => text().nullable()();
  TextColumn get audioUrl => text().nullable()();
  TextColumn get author => text().nullable()();
  TextColumn get authorIdentifier => text().nullable()();
  TextColumn get extraUrl => text().nullable()();
  TextColumn get extra => text().nullable()();
  TextColumn get sourceMetadata => text().nullable()();
  IntColumn get position => integer()();
  IntColumn get duration => integer()();
  BoolColumn get canDelete => boolean()();
  BoolColumn get canEdit => boolean()();
  IntColumn get importedAt => integer().withDefault(const Constant(0))();
}

// ── anki_mappings ──────────────────────────────────────────────────
@DataClassName('AnkiMappingRow')
class AnkiMappings extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get label => text().unique()();
  TextColumn get model => text()();
  TextColumn get exportFieldKeysJson => text()();
  TextColumn get creatorFieldKeysJson => text()();
  TextColumn get creatorCollapsedFieldKeysJson => text()();
  IntColumn get order => integer()();
  TextColumn get tagsJson => text()();
  TextColumn get enhancementsJson => text()();
  TextColumn get actionsJson => text()();
  BoolColumn get exportMediaTags =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get useBrTags => boolean().withDefault(const Constant(true))();
  BoolColumn get prependDictionaryNames =>
      boolean().withDefault(const Constant(true))();
}

// ── search_history_items ────────────────────────────────────────────
@DataClassName('SearchHistoryItemRow')
class SearchHistoryItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get historyKey => text()();
  TextColumn get searchTerm => text()();
  TextColumn get uniqueKey => text().unique()();
}

// ── audiobooks ──────────────────────────────────────────────────────
@DataClassName('AudiobookRow')
class Audiobooks extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get bookKey => text().unique()();
  TextColumn get audioRoot => text().nullable()();
  TextColumn get audioPathsJson => text().nullable()();
  TextColumn get alignmentFormat => text()();
  TextColumn get alignmentPath => text()();
  TextColumn get healthKindRaw => text().nullable()();
  IntColumn get matchRatePct => integer().nullable()();
  DateTimeColumn get healthMeasuredAt => dateTime().nullable()();
  TextColumn get healthReason => text().nullable()();
  BoolColumn get followAudio => boolean().nullable()();
}

// ── audio_cues ──────────────────────────────────────────────────────
@DataClassName('AudioCueRow')
class AudioCues extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get bookKey => text()();
  TextColumn get chapterHref => text()();
  IntColumn get sentenceIndex => integer()();
  TextColumn get textFragmentId => text()();
  TextColumn get cueText => text()();
  IntColumn get startMs => integer()();
  IntColumn get endMs => integer()();
  IntColumn get audioFileIndex => integer()();
}

// ── srt_books ───────────────────────────────────────────────────────
@DataClassName('SrtBookRow')
class SrtBooks extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get uid => text().unique()();
  TextColumn get title => text()();
  TextColumn get author => text().nullable()();
  TextColumn get audioRoot => text().nullable()();
  TextColumn get audioPathsJson => text().nullable()();
  TextColumn get srtPath => text()();
  TextColumn get coverPath => text().nullable()();
  IntColumn get importedAt => integer()();
  // Standalone SRT books (no backing epub) use the empty-string sentinel.
  TextColumn get bookKey => text().withDefault(const Constant(''))();
}

// ── reader_positions ────────────────────────────────────────────────
@DataClassName('ReaderPositionRow')
class ReaderPositions extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get bookKey => text().unique()();
  IntColumn get sectionIndex => integer()();
  IntColumn get normCharOffset => integer()();
  // BUG-162: section 内精确绝对字符偏移（退出再进的恢复锚）。-1 = 无精确偏移
  // （恢复回退 normCharOffset 分数）。取代了原 ttuCharOffset（sync 精确缓存列，
  // 已随云同步精度退化为 normCharOffset 分数而删除，合并为单一阅读位置精确列）。
  IntColumn get charOffset => integer().withDefault(const Constant(-1))();
  IntColumn get updatedAt => integer()();
}

// ── bookmarks ─────────────────────────────────────────────────────
@DataClassName('BookmarkRow')
class Bookmarks extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get bookKey =>
      text().references(EpubBooks, #bookKey, onDelete: KeyAction.cascade)();
  IntColumn get sectionIndex => integer()();
  IntColumn get normCharOffset => integer()();
  TextColumn get label => text()();
  IntColumn get createdAt => integer()();
  TextColumn get bookTitle => text().nullable()();
  IntColumn get pageInChapter => integer().nullable()();
  IntColumn get totalPagesInChapter => integer().nullable()();
}

// ── reading_statistics ──────────────────────────────────────────────
@DataClassName('ReadingStatisticRow')
class ReadingStatistics extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text()();
  TextColumn get dateKey => text()();
  IntColumn get charactersRead => integer()();
  IntColumn get readingTimeMs => integer()();
  IntColumn get lastStatisticModified => integer()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {title, dateKey},
      ];
}

// ── reading_hourly_logs ────────────────────────────���────────────────
@DataClassName('ReadingHourlyLogRow')
class ReadingHourlyLogs extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get dateKey => text()();
  IntColumn get hour => integer()();
  IntColumn get readingTimeMs => integer()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {dateKey, hour},
      ];
}

// ── video_watch_statistics ──────────────────────────────────────────
@DataClassName('VideoWatchStatisticRow')
class VideoWatchStatistics extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text()();
  TextColumn get dateKey => text()();
  IntColumn get subtitleChars => integer()();
  IntColumn get watchTimeMs => integer()();
  IntColumn get lastModified => integer()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {title, dateKey},
      ];
}

// ── video_hourly_logs ───────────────────────────────────────────────
@DataClassName('VideoHourlyLogRow')
class VideoHourlyLogs extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get dateKey => text()();
  IntColumn get hour => integer()();
  IntColumn get watchTimeMs => integer()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {dateKey, hour},
      ];
}

// ── preferences (key-value) ─────────────────────────────���───────────
@DataClassName('PreferenceRow')
class Preferences extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

// ── dictionary_metadata ─────────────────────────────────────────────
@DataClassName('DictionaryMetaRow')
class DictionaryMetadata extends Table {
  TextColumn get name => text()();
  TextColumn get formatKey => text()();
  IntColumn get order => integer()();
  TextColumn get type => text().withDefault(const Constant('term'))();
  TextColumn get metadataJson => text().withDefault(const Constant('{}'))();
  TextColumn get hiddenLanguagesJson =>
      text().withDefault(const Constant('[]'))();
  TextColumn get collapsedLanguagesJson =>
      text().withDefault(const Constant('[]'))();

  @override
  Set<Column> get primaryKey => {name};
}

// ── dictionary_history ──────────────────────────────────────────────
@DataClassName('DictionaryHistoryRow')
class DictionaryHistory extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get position => integer()();
  TextColumn get resultJson => text()();
}

// ── epub_books ─────────────────────────────────────────────────────
@DataClassName('EpubBookRow')
class EpubBooks extends Table {
  // bookKey = sanitizeTtuFilename(title): the cross-device book identity.
  TextColumn get bookKey => text()();
  TextColumn get title => text()();
  TextColumn get author => text().nullable()();
  TextColumn get coverPath => text().nullable()();
  TextColumn get epubPath => text()();
  TextColumn get extractDir => text()();
  IntColumn get chapterCount => integer()();
  TextColumn get chaptersJson => text()();
  TextColumn get tocJson => text().nullable()();
  TextColumn get sourceMetadata => text().nullable()();
  IntColumn get importedAt => integer()();

  /// TODO-817：归属的网络/本地来源库（[MediaSources].id）。可空 = 手动导入无来源。
  /// onDelete:setNull = 移除来源时保留书目（归 NULL），不连坐删条目。
  IntColumn get sourceId => integer()
      .nullable()
      .references(MediaSources, #id, onDelete: KeyAction.setNull)();

  @override
  Set<Column> get primaryKey => {bookKey};
}

// ── book_tags ──────────────────────────────────────────────────────
@DataClassName('BookTagRow')
class BookTags extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().unique()();
  IntColumn get colorValue =>
      integer().withDefault(const Constant(0xFF9E9E9E))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer()();
}

// ── book_tag_mappings ─────────────────────────────────────────────
@DataClassName('BookTagMappingRow')
class BookTagMappings extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get bookKey =>
      text().references(EpubBooks, #bookKey, onDelete: KeyAction.cascade)();
  IntColumn get tagId =>
      integer().references(BookTags, #id, onDelete: KeyAction.cascade)();

  @override
  List<Set<Column>> get uniqueKeys => [
        {bookKey, tagId},
      ];
}

// ── srt_book_tag_mappings ─────────────────────────────────────────
@DataClassName('SrtBookTagMappingRow')
class SrtBookTagMappings extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get srtBookId =>
      integer().references(SrtBooks, #id, onDelete: KeyAction.cascade)();
  IntColumn get tagId =>
      integer().references(BookTags, #id, onDelete: KeyAction.cascade)();

  @override
  List<Set<Column>> get uniqueKeys => [
        {srtBookId, tagId},
      ];
}

// ── profiles ────────────────────────────────────────────────────────
@DataClassName('ProfileRow')
class Profiles extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().unique()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
}

// ── profile_settings ────────────────────────────────────────────────
@DataClassName('ProfileSettingRow')
class ProfileSettings extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get profileId =>
      integer().references(Profiles, #id, onDelete: KeyAction.cascade)();
  TextColumn get category => text()();
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {profileId, category, key},
      ];
}

// ── media_type_profiles ─────────────────────────────────────────────
@DataClassName('MediaTypeProfileRow')
class MediaTypeProfiles extends Table {
  TextColumn get mediaType => text()();
  IntColumn get profileId =>
      integer().references(Profiles, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {mediaType};
}

// ── book_profiles ───────────────────────────────────────────────────
@DataClassName('BookProfileRow')
class BookProfiles extends Table {
  TextColumn get bookKey => text()();
  IntColumn get profileId =>
      integer().references(Profiles, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {bookKey};
}

// ── sync_baselines ──────────────────────────────────────────────────
// 每本书每个同步维度「上次同步成功时双方一致的版本」（共同祖先），
// 用于三方分叉检测。assetKey = sanitizeTtuFilename(book.title)（跨设备稳定）。
@DataClassName('SyncBaselineRow')
class SyncBaselines extends Table {
  TextColumn get assetKey => text()();
  TextColumn get dimension => text()(); // 'progress'（Phase 2 再加 'audiobook'）
  IntColumn get baseVersion => integer()();

  @override
  Set<Column> get primaryKey => {assetKey, dimension};
}

// ── video_books ─────────────────────────────────────────────────────
@DataClassName('VideoBookRow')
class VideoBooks extends Table {
  // Primary key is book_uid (content-derived), aligned with the name-PK model
  // (EpubBooks keys on bookKey). No autoincrement id: a video book's identity
  // is its book_uid so it stays stable across devices/reimports.
  TextColumn get bookUid => text()();
  TextColumn get title => text()();
  TextColumn get videoPath => text()();
  TextColumn get subtitleSource => text().nullable()();

  /// 副字幕源（TODO-857 视频双字幕 Path A）：与 [subtitleSource] 同款四态编码
  /// （外挂存绝对路径；内嵌存 `embedded:<n>`；关闭存 `off:`；无副字幕存 null）。
  /// 副字幕由 libmpv `secondary-sid` 自渲染，不进 Dart cue 流，不可查词。
  TextColumn get secondarySubtitleSource => text().nullable()();
  TextColumn get subtitleFormat => text().nullable()();
  IntColumn get embeddedSubtitleTrack => integer().nullable()();
  TextColumn get coverPath => text().nullable()();
  IntColumn get lastPositionMs => integer().withDefault(const Constant(0))();
  DateTimeColumn get importedAt => dateTime().nullable()();

  /// m3u8 多集播放列表 JSON：`[{title,path}]`（绝对路径）。单视频导入时为 null。
  TextColumn get playlistJson => text().nullable()();

  /// 当前播放到的集索引（对应 [playlistJson] 数组下标）；单视频恒 0。
  IntColumn get currentEpisode => integer().withDefault(const Constant(0))();

  /// 用户选中的音轨（libmpv `AudioTrack.id`）；null=未选过，跟随 libmpv 默认。
  /// 多集播放列表换集时复用同一值（如选了日语音轨，每集都用日语）。
  TextColumn get audioTrackId => text().nullable()();

  /// 音画延迟（毫秒）：正值=画面先于文字，查 cue 时把位置往回拨，让字幕与画面对齐。
  /// 跨重启保留；多集播放列表换集时复用同一值（手动校准一次全片受用）。
  IntColumn get delayMs => integer().withDefault(const Constant(0))();

  /// 视频首次播放进度 ≥ 90% 的时间戳（完成标记）；null = 未完成。统计去重计数用。
  DateTimeColumn get completedAt => dateTime().nullable()();

  /// TODO-817：归属的网络/本地来源库（[MediaSources].id）。可空 = 手动导入无来源。
  /// onDelete:setNull = 移除来源时保留视频（归 NULL），不连坐删条目。
  IntColumn get sourceId => integer()
      .nullable()
      .references(MediaSources, #id, onDelete: KeyAction.setNull)();

  @override
  Set<Column> get primaryKey => {bookUid};
}

// ── video_book_tag_mappings ───────────────────────────────────────
// 视频书 ↔ 标签 多对多映射。标签定义复用共享的 [BookTags]，与 EPUB
// （[BookTagMappings]）、SRT（[SrtBookTagMappings]）共用同一标签池。
@DataClassName('VideoBookTagMappingRow')
class VideoBookTagMappings extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get videoBookUid =>
      text().references(VideoBooks, #bookUid, onDelete: KeyAction.cascade)();
  IntColumn get tagId =>
      integer().references(BookTags, #id, onDelete: KeyAction.cascade)();

  @override
  List<Set<Column>> get uniqueKeys => [
        {videoBookUid, tagId},
      ];
}

// ── favorite_words ──────────────────────────────────────────────────
/// 查词弹窗「收藏」的词条（书内阅读与视频共用同一套，按 [sourceType] 区分）。
/// 存完整词条（expression/reading/glossary）以支持「再次打开显示已收藏 ✓」的
/// 去重判定与「取消收藏」删除；同时按 dateKey + sourceType 计入各自统计。
@DataClassName('FavoriteWordRow')
class FavoriteWords extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get expression => text()();
  TextColumn get reading => text().withDefault(const Constant(''))();
  TextColumn get glossary => text().withDefault(const Constant(''))();
  TextColumn get sourceType => text()(); // 'book' | 'video'
  TextColumn get dateKey => text()();
  IntColumn get createdAt => integer()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {expression, reading, sourceType},
      ];
}

// ── mining_statistics ───────────────────────────────────────────────
/// 制卡计数：卡片本体落在 Anki（外部），这里只按 dateKey + sourceType 记成功制卡
/// 次数，供阅读/视频统计页展示。与时长/字数统计表同构（按日期累加）。
@DataClassName('MiningStatisticRow')
class MiningStatistics extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get sourceType => text()(); // 'book' | 'video'
  TextColumn get dateKey => text()();
  IntColumn get count => integer().withDefault(const Constant(0))();

  @override
  List<Set<Column>> get uniqueKeys => [
        {sourceType, dateKey},
      ];
}

// ── mined_sentences ──────────────────────────────────────────────────
/// 制卡历史：每成功制一张卡，落一条逐条记录（与 [MiningStatistics] 的按日计数互补——
/// 计数供统计页画图，本表供「收藏夹」页跨媒体全局查看每一次制卡的句子并跳回原文）。
///
/// **不存图/音频副本**：制卡用的封面 GIF / 句子音频是临时缓存（会清），这里只存定位
/// 锚点（[bookKey]/[sectionIndex]/[normCharOffset]/[normCharLength]）。展示侧据
/// [source] 分流（书内 → 阅读器、视频 → 视频页），跳转锚点与收藏句完全同构，故
/// collections_page 可零改复用 `_openBook` / `_openVideoSentence`。
///
/// [noteId] 仅 AnkiConnect（桌面）成功制卡时非空，AnkiDroid 恒 null（优雅降级），故可空。
/// 书内/视频制卡才有定位锚点；独立查词页 / 首页词典制卡无书无章，定位列存 null（展示为
/// 不可跳转条目，与收藏夹现有非视频纯查词条目一致）。
@DataClassName('MinedSentenceRow')
class MinedSentences extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get expression => text().withDefault(const Constant(''))();
  TextColumn get reading => text().withDefault(const Constant(''))();
  TextColumn get glossary => text().withDefault(const Constant(''))();
  TextColumn get sentence => text().withDefault(const Constant(''))();

  /// 跳转/分流来源标识，与 `kFavoriteSentenceSourceBook` / `Video` 等同值（'book' |
  /// 'video' | 'audiobook' | 'lyrics'）。统计语义（book/video 桶）也由它派生。
  TextColumn get source => text()();
  TextColumn get documentTitle => text().nullable()();
  TextColumn get chapterLabel => text().nullable()();

  /// 定位锚点（与收藏句同构）：书内是 bookKey，视频是 bookUid。
  TextColumn get bookKey => text().nullable()();
  IntColumn get sectionIndex => integer().nullable()();

  /// 书内是归一化字符偏移；视频来源里复用为 cue 起点 ms（与收藏句一致）。
  IntColumn get normCharOffset => integer().nullable()();

  /// 视频来源里复用为 cue 时长 ms（书内为选区长度）。
  IntColumn get normCharLength => integer().nullable()();

  /// AnkiConnect 成功制卡带回的 note id；AnkiDroid 恒 null。
  IntColumn get noteId => integer().nullable()();
  TextColumn get dateKey => text()();
  IntColumn get createdAt => integer()();
}

// ── media_sources ─────────────────────────────────────────────────
/// TODO-817 网络/本地来源库：一个「来源」是一个媒体根（本地文件夹或网络根），
/// 扫描后产出多本书/视频（[EpubBooks].sourceId / [VideoBooks].sourceId 反向指向）。
///
/// 🔴 凭据红线：[configJson] **绝不裸存明文密码**。本地来源恒 NULL；网络来源（SFTP/
/// FTP/HTTP，M3 才落）只存凭据「引用（键）」而非密码本体，密码存储方案（复用 base64
/// vs 真 secure storage）是 M3 用户决策点，不在 M0 预判。
@DataClassName('MediaSourceRow')
class MediaSources extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 显示名，默认取 rootPath 末段文件夹名。
  TextColumn get label => text()();

  /// 媒体种类：'video' | 'book'。同一文件夹可分别建 video / book 两条来源，
  /// 故不对 rootPath 加 UNIQUE。
  TextColumn get mediaKind => text()();

  /// 传输方式：'local' | 'sftp' | 'ftp' | 'http'。M0 只写 'local'，
  /// 网络取值前瞻容纳（M3 才接入）。
  TextColumn get transport => text().withDefault(const Constant('local'))();

  /// 本地绝对路径或网络根（含 scheme）。
  TextColumn get rootPath => text()();

  /// 凭据引用（键）/ 网络配置 JSON。**绝不裸存明文密码**；本地恒 NULL。
  TextColumn get configJson => text().nullable()();

  /// 截图「媒体数」：上次扫描产出的条目数。
  IntColumn get mediaCount => integer().withDefault(const Constant(0))();

  /// 截图「上次扫描时间」。
  DateTimeColumn get lastScannedAt => dateTime().nullable()();

  /// 上次扫描失败原因（成功则 NULL）。
  TextColumn get lastScanError => text().nullable()();

  /// 是否递归扫描子目录。
  BoolColumn get recursive => boolean().withDefault(const Constant(true))();

  /// 列表排序权重（同 [BookTags].sortOrder 范式）。
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// 创建时间（毫秒戳，同 [EpubBooks].importedAt int 范式）。
  IntColumn get createdAt => integer()();
}

// ── series ───────────────────────────────────
// TODO-616 A 合集/系列：把多本独立书 / 多个视频条目折叠成一张「系列卡片」。
// 仿 [MediaSources] 范式（自增 id + sortOrder + createdAt int 毫秒戳）。
@DataClassName('SeriesRow')
class Series extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 系列名（必填）。
  TextColumn get name => text()();

  /// 系列封面来源：NULL = 自动取系列内 sortOrder 最小成员封面（拍板「首卷自动」）；
  /// 非空 = 手动指定（预留，本期恒 NULL）。不存首卷 entryKey 快照——首卷随增删 / 重排
  /// 变化，渲染时纯函数推导。
  TextColumn get coverSource => text().nullable()();

  /// 系列卡片之间的排序权重（同 [MediaSources].sortOrder 范式）。
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// 创建时间（毫秒戳，同 [EpubBooks].importedAt int 范式）。
  IntColumn get createdAt => integer()();
}

// ── shelf_entries ───────────────────────────────
// TODO-616 B 排序 + A 归属：以 (mediaType, entryKey) 为稳定身份统管本地 + 远端条目
// 的自定义排序权重与系列归属。三大媒体表不加 seriesId/sortOrder 列（避免双真相源）；
// 远端-only 条目无本地 row 可挂列，故用独立映射表。
@DataClassName('ShelfEntryRow')
class ShelfEntries extends Table {
  /// 媒体种类：'epub' | 'srt' | 'video'。
  TextColumn get mediaType => text()();

  /// 条目稳定身份：本地 = bookKey / srtUid / videoBookUid；远端 = downloadId /
  /// video.id。远端书下载后 bookKey 漂移 → 由 _downloadRemoteBook 改键迁移（独立
  /// 事务），归属延续。**逻辑外键**（不对本地三表加 FK：远端 entryKey 无本地表行，
  /// 写 FK 会在插远端归属时违反约束）。孤儿由删除路径主动清理 + 读取期过滤兜底。
  TextColumn get entryKey => text()();

  /// 自定义排序权重（拖拽回写）。无行的旧条目退化为 importedAt 倒序（向后兼容）。
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// 归属系列（NULL = 散书）。onDelete:setNull 仿 [EpubBooks].sourceId：移除系列时
  /// 成员归 NULL（散回书架），不连坐删条目。
  IntColumn get seriesId => integer()
      .nullable()
      .references(Series, #id, onDelete: KeyAction.setNull)();

  /// 复合主键：一条目一行。
  @override
  Set<Column> get primaryKey => {mediaType, entryKey};
}

// ── hibiki_paired_peers ─────────────────────────────
// TODO-1017 阶段1：互联（Hibiki server 局域网配对）的 per-peer 授权凭据表。每个
// 已配对设备一行，token 是该设备访问本机 Hibiki server 的长期凭据。范式仿
// [MediaSources]（自增 id + text().unique() 身份列 + int 毫秒戳时间列）。本阶段
// 仅建表 + DB 方法 + 迁移，不接线 auth（阶段2 再改 server controller），空表 =
// 无人读 = 行为零变化（Never break userspace）。
@DataClassName('HibikiPairedPeerRow')
class HibikiPairedPeers extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 对端设备的稳定身份（配对握手时对端上报的 device/installation id）。
  /// UNIQUE：一设备一行，[upsertPairedPeer] 靠它 insertOnConflictUpdate 幂等。
  TextColumn get peerId => text().unique()();

  /// 对端设备显示名（配对时上报，可为空）。
  TextColumn get deviceName => text().nullable()();

  /// 🔴 凭据红线：本列为敏感授权凭据，**当前明文列存**（与既有 MediaSources
  /// 密码引用「密码存储方案待定」的现状一致——per-peer token 加密方案同为后续
  /// 决策点，本阶段先落地表结构）。绝不写日志、绝不进 sync/backup 明文导出。
  TextColumn get token => text()();

  /// 配对时间（毫秒戳，同 [Series].createdAt / [MediaSources].createdAt int 范式）。
  IntColumn get pairedAtMs => integer()();

  /// 对端上次访问时的来源 IP（诊断/展示用，可为空）。
  TextColumn get lastSeenIp => text().nullable()();
}
