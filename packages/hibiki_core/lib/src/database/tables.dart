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
  IntColumn get ttuCharOffset => integer().withDefault(const Constant(-1))();
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
