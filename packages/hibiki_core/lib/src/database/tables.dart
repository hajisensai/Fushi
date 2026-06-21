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
