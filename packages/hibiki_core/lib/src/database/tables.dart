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

  /// v60：当日读过的**页数**（漫画 / PDF 这类以页为单位的书；EPUB 恒 0）。
  ///
  /// 页数与字数是两个独立量纲，绝不互相顶替：漫画既落 OCR 字符数（与 EPUB 同口径）
  /// 又落页数，统计页两个维度分别展示。旧库迁移补 0，跨设备聚合同步的 wire 契约
  /// 不带此列（[StatBucket] 要求两端字段集一致，加字段会让新旧端互相抛错），页数
  /// 随整库备份/恢复走。
  IntColumn get pagesRead => integer().withDefault(const Constant(0))();
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

  /// v39：视频稳定身份（[VideoBooks].bookUid）。旧表按 (title,dateKey) 键控，
  /// 同名不同视频统计互串（用户拍板根治）。迁移按 title 唯一匹配回填；同名多
  /// 视频的旧行保持 NULL（读取端按 title 回退）。v39 起写入必带。
  TextColumn get bookUid => text().nullable()();
  TextColumn get dateKey => text()();
  IntColumn get subtitleChars => integer()();
  IntColumn get watchTimeMs => integer()();
  IntColumn get lastModified => integer()();

  @override
  List<Set<Column>> get uniqueKeys => [
        // v39：唯一键从 {title,dateKey} 换 {bookUid,dateKey}——同名不同视频当天
        // 各写各行不再撞约束/互串（SQLite UNIQUE 视 NULL 互异，旧 NULL 行不冲突）。
        {bookUid, dateKey},
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

// ── activity_events ─────────────────────────────────────────────────
/// v49（首页活动时间轴）：精确时间戳的事件流，喂新首页 [HomeDashboardPage] 的
/// Activity 面板（对齐 ReinaManager「8 小时前 · 1 session」精度）。与按天聚合的
/// [ReadingStatistics] / [VideoWatchStatistics] 互补——那些是「每天总量」，这张是
/// 「每次 session 一行」，保留精确时刻用于相对时间与按类别筛选。追加式，只增不改。
@DataClassName('ActivityEventRow')
class ActivityEvents extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 事件语义：'read'（读完一段）/ 'watch'（看了一段视频）/ 'added'（导入了媒体）
  /// / 'game'（galgame 游玩：时长行由前台窗口计时器写，字符行由 hook 文本累计器写）。
  TextColumn get eventType => text()();

  /// 媒体种类：'book' / 'video' / 'game'。与 [eventType] 分开，未来可扩展
  /// （如 'added' 的媒体既可能是 book 也可能是 video）。
  TextColumn get mediaType => text()();

  /// 展示标题（书名 / 视频名）。
  TextColumn get title => text()();

  /// 点击活动条打开媒体用的稳定身份：书=bookKey，视频=bookUid，导入不一定有。
  TextColumn get mediaKey => text().nullable()();

  /// 冗余的按天分组键（'YYYY-MM-DD'，本地时区），避免读取端为分组再从
  /// [timestampMs] 反算。与统计表 dateKey 同源（[statDateKey]）。
  TextColumn get dateKey => text()();

  /// 精确发生时刻（epoch 毫秒），Activity 相对时间与排序的真值。
  IntColumn get timestampMs => integer()();

  /// 本次 session 时长（毫秒），read/watch 有；added 为 null。
  IntColumn get durationMs => integer().nullable()();

  /// 本次读/看的字符数（阅读=字数，视频=字幕字数），added 为 null。
  IntColumn get charsDelta => integer().nullable()();
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

// ── clipboard_history ───────────────────────────────────────────────
// 桌面「剪贴板复制历史」——查词面板/瞬态浮窗的历史按钮读取。position 保存内存
// List 的顺序（tail=最新），content=去重后的复制文本，copiedAt=复制时刻毫秒戳。
// 建表由 database.dart onUpgrade v49 负责；写入走 ClipboardHistoryRepository 的
// replaceAll（delete + batch insert），无需 autoIncrement id。
@DataClassName('ClipboardHistoryRow')
class ClipboardHistory extends Table {
  IntColumn get position => integer()();
  TextColumn get content => text()();
  IntColumn get copiedAt => integer()();
}

// ── media tracking (Bangumi) ──────────────────────────────────────
/// 本地媒体/合集与外部条目的显式稳定映射。
///
/// 自动记录绝不按标题静默猜条目：用户确认一次映射后，播放/阅读事件只按
/// `(provider, media_type, media_key)` 命中本表。`progress_mode` 决定本地进度如何
/// 翻译到远端：episode（动画章节）/ chapter（书籍话数）/ volume（书籍卷数）。
@DataClassName('MediaTrackingMappingRow')
class MediaTrackingMappings extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get provider => text().withDefault(const Constant('bangumi'))();
  TextColumn get mediaType => text()();
  TextColumn get mediaKey => text()();
  TextColumn get mediaTitle => text()();
  TextColumn get kind => text()(); // anime / novel / manga
  IntColumn get subjectId => integer()();
  TextColumn get subjectName => text()();
  TextColumn get progressMode => text()(); // episode / chapter / volume

  /// 本地 0-based 序号加此偏移后得到远端 1-based 进度。单卷书可直接把卷号填在
  /// offset，并在完成事件里传 localProgress=0。
  IntColumn get progressOffset => integer().withDefault(const Constant(1))();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {provider, mediaType, mediaKey},
      ];
}

/// 事务性待同步队列。每个映射最多一行；新事件以 MAX(progress) + completed OR
/// 合并，离线/进程退出不会丢，且旧进度永远不能覆盖新进度。
@DataClassName('MediaTrackingOutboxRow')
class MediaTrackingOutbox extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get mappingId => integer()
      .unique()
      .references(MediaTrackingMappings, #id, onDelete: KeyAction.cascade)();
  IntColumn get progress => integer()();
  BoolColumn get completed => boolean().withDefault(const Constant(false))();
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();
  IntColumn get nextAttemptAt => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
  IntColumn get updatedAt => integer()();
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

  /// 书身份格式判别（PDF 阅读器 Phase 1）：`'epub'`（默认，含 EPUB / TextToEpub /
  /// 有声书配对壳）、`'pdf'`（pdfrx 渲染的真 PDF）或 `'manga'`（漫画 OCR，第三种书）。
  /// 默认 `'epub'` 让既有全部行零破坏（Never break userspace，v51 迁移 addColumn 自动
  /// 回填），书架/进度/删除按此列区分而非另建平行表。PDF 行：`format='pdf'`、
  /// `epubPath`=PDF 绝对路径、`extractDir`=占位、`chapterCount`=页数、`chaptersJson`=`'[]'`。
  TextColumn get format => text().withDefault(const Constant('epub'))();

  /// 漫画阅读模式覆盖（漫画 OCR，v52）：`null`=按页图长宽比自动判定（默认，横长跨页
  /// 走 `'spread'` 双页布局、纵长走 `'webtoon'` 长条纵向连读）；非 null 为用户手动覆盖，
  /// 取值 `'spread'`（跨页/翻页）或 `'webtoon'`（长条纵向）。仅 `format='manga'` 的行有意义，
  /// 其它书身份恒 null。null 语义即「跟随自动判定」，与显式取值区分。
  TextColumn get mangaReadingMode => text().nullable()();

  /// 书「读完」的时间戳（用户手动标记，或读到全书末尾自动写入）；null = 未完成。
  /// 镜像 [VideoBooks.completedAt]，书架概览「Completed」统计用。跳过后记/附录的
  /// 读者靠手动标记即可计入完成，不再受「必须读到最后一字」限制。
  DateTimeColumn get completedAt => dateTime().nullable()();

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

  /// 该映射被加入的毫秒戳（TODO tags-sync：LWW-element-set 的 add 时钟——与
  /// [BookTagMembershipTombstones].deletedAt 比较决定 add-wins/remove-wins，防跨设备
  /// 复活/误删）。旧行迁移填 0（最古 add，任何带时间戳的远端移除都能压过）。
  IntColumn get addedAt => integer().withDefault(const Constant(0))();

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

  /// 导入时间（毫秒戳，同 [EpubBooks].importedAt / [SrtBooks].importedAt int
  /// 范式）；null = 旧数据无导入时间。v57 前是 drift DateTime（Unix 秒存储），
  /// v57 迁移统一为 int 毫秒。
  IntColumn get importedAt => integer().nullable()();

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

  /// TODO-1157：流媒体书的重开规格（JSON）。非空当且仅当这是一条「粘贴 URL 导入」的
  /// 流媒体书（判据以 [videoPath] 是 http/https 为准，本列只补 videoPath 装不下的
  /// 外挂字幕 URL / 防盗链 header）：`{subtitleUrl,subtitleFileName,referer,userAgent}`。
  /// 本地文件视频恒 null。存的是「原始粘贴 URL」侧信息，重开时据此重建
  /// UrlStreamVideoClient（YouTube 按 videoPath 重解析），使流媒体像本地视频一样入库、
  /// 在书架持久、可重复打开。null = 无外挂字幕/header 的直链流或本地视频。
  TextColumn get streamSpecJson => text().nullable()();

  @override
  Set<Column> get primaryKey => {bookUid};
}

// ── video_book_tag_mappings ───────────────────────────────────────
// 视频书 ↔ 标签 多对多映射。标签定义复用共享的 [BookTags]，与 EPUB
// （[BookTagMappings]）、SRT（[SrtBookTagMappings]）共用同一标签池。
@DataClassName('VideoBookTagMappingRow')
class VideoBookTagMappings extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 视频书外键（v57 起与被引列 [VideoBooks].bookUid 同名；旧列名 video_book_uid）。
  TextColumn get bookUid =>
      text().references(VideoBooks, #bookUid, onDelete: KeyAction.cascade)();
  IntColumn get tagId =>
      integer().references(BookTags, #id, onDelete: KeyAction.cascade)();

  /// 该映射被加入的毫秒戳（LWW-element-set 的 add 时钟，见 [BookTagMappings].addedAt）。
  IntColumn get addedAt => integer().withDefault(const Constant(0))();

  @override
  List<Set<Column>> get uniqueKeys => [
        {bookUid, tagId},
      ];
}

// ── collection_tag_mappings ───────────────────────────────────────
// 合集 ↔ 标签 多对多映射。标签定义复用共享的 [BookTags]，与 EPUB
// （[BookTagMappings]）、SRT（[SrtBookTagMappings]）、视频（[VideoBookTagMappings]）
// 共用同一标签池。合集删除 / 标签删除经外键 cascade 自动清理本表。
@DataClassName('CollectionTagMappingRow')
class CollectionTagMappings extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get collectionId => integer()
      .references(MediaCollections, #id, onDelete: KeyAction.cascade)();
  IntColumn get tagId =>
      integer().references(BookTags, #id, onDelete: KeyAction.cascade)();

  @override
  List<Set<Column>> get uniqueKeys => [
        {collectionId, tagId},
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
  // TODO-1252：收藏归属的书 / 视频身份（[bookKey] 存书身份 / 视频 bookUid，[title] 存
  // 书 / 视频标题），在收藏那一刻从阅读器 / 视频页的书上下文写入，供统计页 per-book /
  // per-video tile 按 [title] 聚合展示「收藏 N」（与查词 / 制卡 tile 同源同样式）。
  // uniqueKey 不变（仍 {expression, reading, sourceType} 全局去重）→ 汇总面板计数与
  // 云同步 / 备份合并契约完全不变；无书上下文（首页 / 独立查词 / 歌词 / 外部覆盖窗 /
  // 同步回灌）时 [title]='' → 只进汇总，不落任何 per-book / per-video tile。收藏是可
  // 增删的集合（取消收藏即删行），tile 聚合活行 → 取消收藏后该书计数自然回落。
  TextColumn get bookKey => text().nullable()();
  TextColumn get title => text().withDefault(const Constant(''))();
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

// ── lookup_mining_counters ──────────────────
/// TODO-1204 查词 / 制卡 per-book 计数（终身累加，不 trim，区别于 [MinedSentences]
/// 的 1000 条滚动历史）。[lookupCount] 每次查词 +1（顶层 / 嵌套 / 重复查各算一次，
/// 不去重）；[mineCount] 每次成功制卡 +1，与 [MiningStatistics] 的全局按日计数**并行**
/// 写（后者维持全局汇总 / 备份合并 / 云同步契约不变，Never break userspace）。
///
/// 聚合键 (title, sourceType, dateKey)：per-book 行 [title]=书 / 视频标题、[bookKey]
/// 存书身份（视频存 bookUid）；无书查词（首页 / 独立查词窗 / 歌词）[title]=''、
/// [bookKey]=null——只进统计页「查词」汇总，不落任何 per-book / per-video tile。
/// title 聚合键与统计页现有 per-book/video tile（按 title 聚合）对齐。
///
/// setLookupCount / setMineCount 用 MAX-union 语义（非累加），为将来备份合并 / 云聚合
/// 幂等重导留口（本期 sync 不接）。
@DataClassName('LookupMiningCounterRow')
class LookupMiningCounters extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get bookKey => text().nullable()();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get sourceType => text()(); // 'book' | 'video'
  TextColumn get dateKey => text()();
  IntColumn get lookupCount => integer().withDefault(const Constant(0))();
  IntColumn get mineCount => integer().withDefault(const Constant(0))();

  @override
  List<Set<Column>> get uniqueKeys => [
        {title, sourceType, dateKey},
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
/// FTP，TODO-1274 已接入）只存**非敏感连接参数** JSON（host/port/username/useTls）；
/// 密码/私钥经 SourceLibraryCredentialStore 以 base64 单独落 Preferences（键
/// `media_source_secret_<id>`，按行 id 隐式引用），绝不进入 configJson。
///
/// 生成行类名 `MediaSourceRow` 是 DB 层历史命名（改名需动 database.g.dart 与全部
/// DAO 签名，不值得）；app 消费侧统一用别名 `SourceLibraryRow`
/// （hibiki/lib/src/media/source_library/source_library_row.dart），与 UI 媒体源
/// `abstract class MediaSource`（jidoujisho 血统）区分。表名/列名/落库值不动。
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

  /// 非敏感网络连接参数 JSON（host/port/username/useTls）。**绝不裸存明文密码/
  /// 私钥**（它们在 Preferences 单独 base64 落库）；本地来源恒 NULL。
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
  /// 媒体种类：'epub' | 'srt' | 'video'（'game' 不写本表——游戏库排序走
  /// `galgame_library_query.dart` 的视图偏好，合集归属见 [MediaCollectionItems]）。
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

// ── media_collections (统一合集：Jellyfin BoxSet/Playlist 式容器) ──────
// 取代旧 [Series] + [ShelfEntries.seriesId]（两者自 v38 起冻结为遗留残留，勿再读写
// 系列语义；[ShelfEntries.sortOrder] 书架排序职责保留）。collection = 无序跨媒体合集
// （展示时按成员 sortIndex → importedAt 排序）；playlist = 有序播放列表（sortIndex 即
// 播放序，点任一成员从该处连播）。删容器 cascade 只删成员引用 [MediaCollectionItems]，
// 绝不删条目本身（Jellyfin「删 BoxSet 不删 LinkedChild」语义）。
@DataClassName('MediaCollectionRow')
class MediaCollections extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 合集名（必填）。
  TextColumn get name => text()();

  /// 'collection' | 'playlist'。
  TextColumn get collectionType =>
      text().withDefault(const Constant('collection'))();

  /// 自定义封面成员 `'<mediaType>|<entryKey>'`；NULL = 自动（playlist 取前 4 成员封面
  /// 2×2 拼贴；collection 取首成员封面堆叠）。不存快照——成员增删/重排后渲染时纯函数推导。
  TextColumn get coverSource => text().nullable()();

  /// **合集自己的**封面图绝对路径（schema v61，BUG-1211）。与 [coverSource] 正交：
  /// 后者是「借哪个成员的封面」，本列是「合集自有一张图」，落在
  /// `<documents>/video_covers/collections/<id>.jpg`（[AppPaths.videoCoversDirectory]
  /// 的子目录 —— 与成员封面同池不同目录，文件名不可能与 `videoCoverFileName(bookUid)`
  /// 撞车）。
  ///
  /// 存在的理由：合集卡封面原先只能「遍历成员借第一张」，于是「给合集换封面」被迫
  /// 退化成「把同一张封面写进每一集」；用户明确否决该语义（BUG-1211：「匹配的是合集
  /// 的封面，谁说应用到本机里面的视频了」）。有了自有列，换合集封面就是改这一列，
  /// 一个成员都不动。
  ///
  /// 无损迁移：nullable 无 default → 旧库既有行全 NULL；渲染端 NULL 时**继续**走原来
  /// 的成员借用链（首个有本地封面的成员 → 远端成员 → 占位），老合集封面逐像素不变
  /// （Never break userspace）。
  ///
  /// 机器本地绝对路径：随数据根迁移改写（`data_root_migrator.dart`，与
  /// [VideoBooks].coverPath / [Galgames].coverPath 同型），且**不跨端同步**。
  TextColumn get coverPath => text().nullable()();

  /// 合集卡自身在库网格中的排序权重（与散条目同层混排，语义同旧 [Series.sortOrder]）。
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// 创建时间（毫秒戳，同 [EpubBooks].importedAt int 范式）。
  IntColumn get createdAt => integer()();

  /// 合集内手动序（成员 sortIndex）最后一次人为改动的毫秒戳（schema v40，多端库
  /// 联合视图 §2.3）。仅 [HibikiDatabase.reorderCollectionItems]（用户拖拽落盘）
  /// bump 为 now；同步应用对端顺序时**镜像对端时间戳而非 now**（否则同步会伪装成
  /// 更新的人为改序，两端时间戳互相追赶）。跨端手动序整合集 LWW 的比较键：新者
  /// 整表覆盖成员 sortIndex。默认 0 = 从未手动排序，任何真实改序都能盖过它。
  IntColumn get orderUpdatedAt => integer().withDefault(const Constant(0))();

  /// 该合集绑定的 AniList 系列 id（schema v45，字幕批量下载用）。用户在合集里确认过
  /// 一次正确的番后快照下来，后续「为整个合集获取字幕」直接按此 id 搜 Jimaku，跳过逐集
  /// 番名猜测。NULL = 未绑定（回退用合集名经 AniList 现解析）。无损迁移：nullable 无
  /// default，旧库既有行全 NULL = 行为与旧版一致。
  IntColumn get anilistId => integer().nullable()();

  /// 系列级音轨偏好（libmpv `AudioTrack.id`，schema v52）。统一合集迁移前多集视频
  /// 共享一行 [VideoBooks]，天然「整片一个音轨」；迁移后每集是独立行、换集不再共享 →
  /// 同系列音轨记忆退化（回归）。把偏好提升回系列容器修根：合集内任一集选音轨即写这里，
  /// 任一集加载优先读这里（回退各集自己行的 [VideoBooks.audioTrackId]，兼容迁移前已存的
  /// per-book 值）。NULL = 系列内没人选过（回退 per-book / libmpv 默认）。无损迁移：
  /// nullable 无 default → 旧库既有行全 NULL = 行为与旧版一致（Never break userspace）。
  TextColumn get audioTrackId => text().nullable()();

  /// 系列级字幕调轴（音画延迟，毫秒，schema v52）。与 [audioTrackId] 同款「系列共享」
  /// 语义，恢复统一合集迁移前多集共享一个调轴值的行为。合集内任一集调轴即写这里，任一集
  /// 加载优先读这里（回退各集自己行的 [VideoBooks.delayMs]）。**nullable**（区别于
  /// [VideoBooks.delayMs] 的 withDefault(0)）：NULL = 系列内没人调过（回退 per-book / 0），
  /// 与「显式调成 0」区分，避免 0 哨兵歧义。无损迁移：nullable 无 default → 旧库既有行全
  /// NULL = 行为与旧版一致（Never break userspace）。
  IntColumn get subtitleDelayMs => integer().nullable()();
}

// ── media_collection_items (合集成员引用 = Jellyfin LinkedChildren) ────
// 复合主键 (collectionId, mediaType, entryKey) 按合集去重：**同一条目可属于多个
// 合集**；删合集 cascade 只删本表引用行。entryKey 是逻辑外键（epub=bookKey / srt=uid /
// video=bookUid / game=galgames.id），不加本地媒体表 DB FK——与 [ShelfEntries].entryKey
// 同理由（远端条目无本地行，写 FK 会违反约束）。孤儿由删除路径主动清理 + 读取期过滤兜底。
@DataClassName('MediaCollectionItemRow')
class MediaCollectionItems extends Table {
  /// 所属合集（[MediaCollections].id）。onDelete:cascade = 删合集连带删本引用行。
  IntColumn get collectionId => integer()
      .references(MediaCollections, #id, onDelete: KeyAction.cascade)();

  /// 媒体种类：'epub' | 'srt' | 'video' | 'game'（前三者同 [ShelfEntries].mediaType
  /// 值域；'game' 仅存在于本表——游戏库无书架排序行）。自由 TextColumn，无 CHECK。
  TextColumn get mediaType => text()();

  /// 条目稳定身份：epub=bookKey / srt=uid / video=bookUid / game=galgames.id
  /// （game 的 id 是添加时刻微秒时间戳字符串，**本机局域身份**：与 exe 路径同为
  /// 本机事实，跨端同步时对端无对应行则该成员静默忽略）。
  TextColumn get entryKey => text()();

  /// 合集内序：playlist 的播放顺序 / collection 的展示顺序。
  IntColumn get sortIndex => integer().withDefault(const Constant(0))();

  /// 复合主键：同一合集内一条目一行（允许跨合集重复）。
  @override
  Set<Column> get primaryKey => {collectionId, mediaType, entryKey};
}

// ── collection_member_tombstones (合集成员移出/合集删除墓碑) ──────────
// schema v40（多端库联合视图 §2.3）：合集是跨端并集同步（成员 UNION），没有墓碑则
// A 端移出的成员会被 B 端并集复活——与书删除墓碑（[BookTombstones]）同一律。键用
// 合集**自然键 (collectionName, collectionType)** 而非自增 collection_id：两端 id
// 必冲突且无跨端意义（同 backup_merge_engine 的自然键对齐语义），且墓碑必须在
// 合集行被删（移空自删/显式删除）后继续存活。
//
// 两种行共用一张表（spec §2.3「合集级墓碑用同表哨兵」）：
//  - 成员移出墓碑：mediaType/entryKey = 真实成员键，deletedAt = 移出毫秒戳；
//  - 合集删除墓碑：mediaType = entryKey = ''（空哨兵，真实成员键恒非空，无歧义），
//    deletedAt = 删除毫秒戳。
//
// 主键不含 deletedAt（spec 原文把该时间戳列进复合键，但同一成员保留多条移出
// 事件对「防复活 + 重加清墓碑」毫无增益——同步只比较最新一条，重加要清的也是全部；
// 范式仿 [BookTombstones] 单行 LWW：重复移出 upsert 刷新 deletedAt）。
// v57 前列名 removed_at；v57 统一为 deleted_at（与 [BookTombstones] 等墓碑表对齐；
// sync 清单 wire JSON 的 `removedAt` 键是冻结的 wire 契约，与本列名解耦）。
// 重新加入清同键墓碑（[HibikiDatabase.addToCollection]）；重建同名合集清合集级
// 墓碑（[HibikiDatabase.createMediaCollection]），同插书清书墓碑一律。
@DataClassName('CollectionMemberTombstoneRow')
class CollectionMemberTombstones extends Table {
  /// 合集自然键：名字。
  TextColumn get collectionName => text()();

  /// 合集自然键：'collection' | 'playlist'（同 [MediaCollections].collectionType）。
  TextColumn get collectionType => text()();

  /// 成员媒体种类（'epub' | 'srt' | 'video'）；'' = 合集级删除墓碑哨兵。
  TextColumn get mediaType => text()();

  /// 成员稳定身份（同 [MediaCollectionItems].entryKey）；'' = 合集级删除墓碑哨兵。
  TextColumn get entryKey => text()();

  /// 移出/删除毫秒戳（LWW 比较键；重复移出 upsert 取新）。
  IntColumn get deletedAt => integer()();

  /// 一 (合集, 成员) 一行；合集级哨兵行天然也唯一。
  @override
  Set<Column> get primaryKey =>
      {collectionName, collectionType, mediaType, entryKey};
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

// ── book_tombstones ─────────────────────────────────────────────────
// TODO-1195 part B：已删书墓碑。用户从书架删除一本书时记一条 book_key（+删除时刻），
// 供备份「合并导入」跳过——避免把用户已删的书从旧备份里复活（reported bug：导入备份出现
// 不该有的书）。重新导入/新增同 book_key 的书会清除其墓碑（见 [insertEpubBook]）。仅
// 合并导入消费；覆盖导入是整库替换（用户明确选择用备份替换），故不看墓碑（Never break
// userspace：覆盖语义不变）。范式仿 [BookProfiles]（text book_key 主键 + int 毫秒戳）。
@DataClassName('BookTombstoneRow')
class BookTombstones extends Table {
  TextColumn get bookKey => text()();
  IntColumn get deletedAt => integer()();

  @override
  Set<Column> get primaryKey => {bookKey};
}

// ── statistics_tombstones ───────────────────────────────────────────
// TODO-1204 后续：per-book/video 统计删除墓碑。用户在统计页长按某本书/视频那一行
// 确认「删除该项统计」时，记一条 (title, sourceType) 墓碑（+删除时刻）。统计聚合表
// （reading_statistics / video_watch_statistics / lookup_mining_counters）都按
// title 聚合、跨设备/备份走 MAX-union 只增不减，若只本地删行、下次云同步 / 备份合并
// 会把 peer 快照里的旧数字加回来（复活）。墓碑让 aggregate_sync 的
// applySnapshotToLocal 与 backup_merge_engine 的 MAX-union INSERT 跳过被删的
// (title, sourceType)，删掉的书统计不复活。用户又读该书 / 查词（addReadingStatistic
// / addVideoWatchStatistic / addLookupCount / addMineCountPerBook 新建当日行）会清
// 除其墓碑，让该书统计重新生效（范式仿 [BookTombstones] 的插书清墓碑）。sourceType
// 与统计来源同值（'book' | 'video'）——同名书与视频各自独立立碑 / 清碑。
@DataClassName('StatisticsTombstoneRow')
class StatisticsTombstones extends Table {
  TextColumn get title => text()();
  TextColumn get sourceType => text()(); // 'book' | 'video'
  IntColumn get deletedAt => integer()();

  @override
  Set<Column> get primaryKey => {title, sourceType};
}

// ── book_tag_membership_tombstones ──────────────────────────────────
// tags 稳健档跨端同步（LWW-element-set）：用户从一本书/视频移除某标签时记一条
// (itemKey, mediaType, tagName) 墓碑（+移除时刻 deletedAt）。sync 合并按名把两端
// 当前标签并集，再用「该标签的最大 addedAt vs 最大 deletedAt」逐名裁决 add-wins/
// remove-wins——避免「A 移除标签 → B 没移除 → B 下轮把标签又并回 A」的复活，也避免
// 误删并发新增。重新给同一 (itemKey, tagName) 加标签会清除其墓碑（[addTagToBook]/
// [addTagToVideoBook]/[setTagsForBook]/[setTagsForVideoBook] 内清碑），让重加生效。
// 范式仿 [CollectionMemberTombstones]（自然键 + 单行 LWW deletedAt，重加清碑）。
// v57 前列名 removed_at；v57 统一为 deleted_at（与其余墓碑表对齐）。
@DataClassName('BookTagMembershipTombstoneRow')
class BookTagMembershipTombstones extends Table {
  /// 被移除标签的宿主稳定身份：EPUB 的 bookKey / 视频的 bookUid（跨设备一致）。
  TextColumn get itemKey => text()();

  /// 宿主媒体种类：'epub' | 'video'（同名书与视频各自独立立碑/清碑）。
  TextColumn get mediaType => text()();

  /// 被移除的标签名（标签跨设备身份 = name，与 [getOrCreateTagByName] 同语义）。
  TextColumn get tagName => text()();

  /// 移除毫秒戳（LWW 比较键；重复移除 upsert 取新）。
  IntColumn get deletedAt => integer()();

  @override
  Set<Column> get primaryKey => {itemKey, mediaType, tagName};
}

// ── book_custom_css ─────────────────────────────────────────────────
// per-book 自定义 CSS 跨端同步的时间戳载体。磁盘真相源是 extractDir 里被改写的 .css
// 文件（+ `.original` 备份，见 BookCssRepository），但磁盘无跨设备可比较的版本；本表按
// (bookKey, relativePath) 记录用户自定义的 CSS 文本 + updatedAt，让 sync 走 LWW（按
// updatedAt 取较新，整块文本不能并集）。[deleted]=true 表「已重置回原始」的墓碑（updatedAt
// 记重置时刻），使「reset」也能跨端传播（否则删行无法与「从未自定义」区分）。空表 =
// 从未自定义 = sync 零命中（Never break userspace）。范式仿 [BookProfiles]（text 复合键 +
// int 毫秒戳）。
@DataClassName('BookCustomCssRow')
class BookCustomCss extends Table {
  /// 书稳定身份（= EpubBooks.bookKey，内容派生跨设备一致）。
  TextColumn get bookKey => text()();

  /// 书内 CSS 文件相对路径（extractDir 内，正斜杠归一，同 [CssFileEntry].relativePath）。
  TextColumn get relativePath => text()();

  /// 用户自定义的 CSS 全文（[deleted]=true 时无意义，留空）。
  TextColumn get content => text().withDefault(const Constant(''))();

  /// true = 已重置回原始（重置墓碑）；false = 有自定义内容。
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  /// 最后修改毫秒戳（LWW 比较键；保存/重置都刷新）。
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {bookKey, relativePath};
}

// ── sync_deletion_tombstones ────────────────────────────────────────
// 显式确认式删除传播的墓碑：本地删除一个资产（书/有声书/视频/本地音频）时记一条
// (mediaType, itemKey, deletedAt)。同步时把墓碑发布到远端（云 __tombstones__ 标记 /
// 互联 host DELETE），并让 compare 对话框据此双向弹确认（「远端已删 X，本地也删？」/
// 「你删了 X，远端也删？」）。绝不静默自动删（与 union-only 的安全取舍一致，见
// sync_orchestrator「Deletes are never propagated」）。重新导入/新增同 (mediaType,
// itemKey) 清除其墓碑（防「删了又加、墓碑还在」的误删）。范式仿 [BookTombstones]。
// 与 backup 专用的 [BookTombstones]（只 bookKey+deletedAt、供合并导入防复活）区分：本表
// 是 sync 通道专用、跨资产统一、带 remotePublishedAt 发布状态。
@DataClassName('SyncDeletionTombstoneRow')
class SyncDeletionTombstones extends Table {
  /// 资产种类：'book' | 'audiobook' | 'video' | 'localaudio'。
  TextColumn get mediaType => text()();

  /// 资产跨设备稳定身份：book=bookKey / audiobook=bookKey / video=bookUid /
  /// localaudio=displayName。
  TextColumn get itemKey => text()();

  /// 本地删除毫秒戳。
  IntColumn get deletedAt => integer()();

  /// 已发布到远端的毫秒戳（0 = 尚未发布；发布后置为发布时刻，避免每轮重发）。
  IntColumn get remotePublishedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {mediaType, itemKey};
}

// ── revealed_images ─────────────────────────────────────────────────
// 图片防剧透遮罩「已揭开」状态的持久真相源。per-(bookKey, imageKey)：imageKey =
// extractDir 相对、解码、正斜杠归一的图片路径（如 `OEBPS/images/foo.jpg`）。阅读器
// WebView（JS __hoshiImageRevealKey）与图片库 IllustrationsViewerPage（File 相对路径）
// 都归一到这同一个 key，实现「书内揭开↔图片库揭开」双向同步（同一张图只存一行）。
// 揭开即 insertOnConflictUpdate 一行（幂等）；空表 = 全部保持遮罩（旧库升级后行为与旧版
// 完全一致，Never break userspace）。删书经 EpubBooks FK cascade 连带清本表。范式仿
// [BookCustomCss]（text 复合键 + int 毫秒戳，为将来 sync/backup 留 LWW 口）。
@DataClassName('RevealedImageRow')
class RevealedImages extends Table {
  /// 书稳定身份（= EpubBooks.bookKey，内容派生跨设备一致）。删书 cascade 清本表。
  TextColumn get bookKey =>
      text().references(EpubBooks, #bookKey, onDelete: KeyAction.cascade)();

  /// 图片稳定 key（extractDir 相对、解码、正斜杠路径，如 `OEBPS/images/foo.jpg`）。
  TextColumn get imageKey => text()();

  /// 揭开毫秒戳（LWW 比较键；将来跨端同步/备份合并取较新）。
  IntColumn get revealedAt => integer()();

  @override
  Set<Column> get primaryKey => {bookKey, imageKey};
}

// ── collection_scrape_meta ──────────────────────────────────────────
// 合集条目刮削元数据（schema v64，BUG-1310）：一个合集一行。
//
// 为什么不是复用 [VideoScrapeMeta]：那张表主键是 bookUid、外键指向 VideoBooks，
// 承载的是**单集**资料。而简介 / 评分 / 放送日期 / 标签本质属于「一部作品」——
// 在统一合集模型里，「一部作品」就是合集，不是它的第 7 集。合集此前没有元数据
// 宿主，于是合集刮削只能下一张海报就结束（`cover_match_dialog` 的合集分支），
// 用户看到的详情页除了标题和进度什么都没有。
//
// 也不是往 [MediaCollections] 加十来个可空列：与 VideoScrapeMeta 同一条理由——
// 刮削资料是**可重建的缓存**（删了重刮即可），合集主表是用户数据（名字/排序/
// 音轨偏好）。分表让「清空刮削缓存」= 一条 DELETE，且不撑大合集主表行宽。
//
// 删合集经 FK cascade 连带清本表。空表 = 全部未刮削（旧库升级后行为与旧版一致，
// Never break userspace）。
@DataClassName('CollectionScrapeMetaRow')
class CollectionScrapeMeta extends Table {
  /// 合集身份（= MediaCollections.id）。删合集 cascade 清本表。
  IntColumn get collectionId =>
      integer().references(MediaCollections, #id, onDelete: KeyAction.cascade)();

  /// 来源（`ScrapeSource.name`：bangumi / tmdb / offlineDb / manualUrl）。
  TextColumn get source => text()();

  /// 源内条目 id（Bangumi subject id / TMDB id），字符串化存储。
  TextColumn get subjectId => text()();

  /// 条目主标题（中文优先）。合集名回写用它，但**本列独立保存**：用户事后手动改
  /// 合集名不该篡改「刮到的条目叫什么」这一事实（重刮判据 / 展示原始条目名要它）。
  TextColumn get title => text()();

  /// 原名（日文原题）；与 [title] 相同或缺失时为 null。
  TextColumn get originalTitle => text().nullable()();

  /// 条目简介（含换行）。
  TextColumn get summary => text().nullable()();

  /// 放送开始日期 `YYYY-MM-DD`。存字符串而非 DateTime：源数据常见只精确到年或
  /// 年月的残缺日期，转 DateTime 会凭空补月/日造假（与 VideoScrapeMeta 同规矩）。
  TextColumn get airDate => text().nullable()();

  /// 评分（0~10）与评分人数。
  RealColumn get rating => real().nullable()();
  IntColumn get ratingCount => integer().nullable()();

  /// 总话数。
  IntColumn get episodeCount => integer().nullable()();

  /// 标签 JSON 数组：`[{"name":"日常","count":1234}]`（按热度降序）。
  TextColumn get tagsJson => text().nullable()();

  /// infobox JSON 数组：`[{"key":"导演","value":"..."}]`（摊平，值为数组时用 `/`
  /// 连接）。存原始 key 名，展示层不翻译。
  TextColumn get infoboxJson => text().nullable()();

  /// **横版背景图**绝对路径（BUG-1298 的数据层根治）。
  ///
  /// 详情页 hero 是约 2.7:1 的宽幅槽，而 [MediaCollections.coverPath] 存的是 2:3
  /// 竖版海报——把海报 cover 进宽槽要放大 4.5 倍、只剩中间 26%。根治办法是让宽槽
  /// 有自己的横版图源：TMDB 的 `backdrop_path` 就在搜索响应里（同一次请求，零额外
  /// 开销）。落在 `video_covers/collections/<id>_backdrop.jpg`。
  ///
  /// NULL = 该源没有横版图（Bangumi 只提供竖版海报，永远为 NULL）。此时 hero 回落
  /// 到海报 + `LandscapeCoverImage` 的模糊垫底——那不是补丁，是 Bangumi 源的常态路径。
  TextColumn get backdropPath => text().nullable()();

  /// 条目详情页 URL，供「查看条目」跳转。
  TextColumn get detailUrl => text().nullable()();

  /// 本行写入时间（重刮判据 / 展示「资料更新于」）。
  DateTimeColumn get scrapedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {collectionId};
}

// ── video_scrape_meta ───────────────────────────────────────────────
// 视频条目刮削元数据（「抄 Bangumi」）：一本视频书一行，存的是**条目级**资料
// （简介/评分/放送/话数/标签/制作人员），不是文件级资料。封面图仍落
// `video_covers/` 文件 + `cover_meta.json`（来源标记），本表只管文字资料，二者
// 按 bookUid 对齐、互不覆盖：封面可以是手动设置的而资料是刮来的。
//
// 为什么单独一张表而不是往 [VideoBooks] 加列：刮削资料是**可重建的缓存**（删了
// 重刮即可），而 VideoBooks 是用户数据（路径/进度/字幕选择）。分表让「清空刮削
// 缓存」= 一条 DELETE，且 VideoBooks 的行宽不被十来个可空列撑大。
//
// 删视频经 FK cascade 连带清本表。空表 = 全部未刮削（旧库升级后行为与旧版一致，
// 自动刮削会逐步回填，Never break userspace）。
@DataClassName('VideoScrapeMetaRow')
class VideoScrapeMeta extends Table {
  /// 视频书稳定身份（= VideoBooks.bookUid）。删视频 cascade 清本表。
  TextColumn get bookUid =>
      text().references(VideoBooks, #bookUid, onDelete: KeyAction.cascade)();

  /// 来源（`ScrapeSource.name`：bangumi / tmdb / offlineDb / manualUrl）。
  TextColumn get source => text()();

  /// 源内条目 id（Bangumi subject id / TMDB id），字符串化存储。
  TextColumn get subjectId => text()();

  /// 条目主标题（中文优先，= Bangumi `name_cn` 非空否则 `name`）。
  TextColumn get title => text()();

  /// 原名（日文原题，= Bangumi `name`）；与 [title] 相同或缺失时为 null。
  TextColumn get originalTitle => text().nullable()();

  /// 条目简介（Bangumi `summary` 原文，含换行）。
  TextColumn get summary => text().nullable()();

  /// 放送开始日期 `YYYY-MM-DD`（Bangumi `date`）。存字符串而非 DateTime：源数据
  /// 常见只精确到年或年月的残缺日期，转 DateTime 会凭空补月/日造假。
  TextColumn get airDate => text().nullable()();

  /// 评分（Bangumi `rating.score`，0~10）。
  RealColumn get rating => real().nullable()();

  /// 评分人数（Bangumi `rating.total`）。
  IntColumn get ratingCount => integer().nullable()();

  /// 总话数（Bangumi `eps` / `total_episodes`）。
  IntColumn get episodeCount => integer().nullable()();

  /// 标签 JSON 数组：`[{"name":"日常","count":1234}]`（Bangumi `tags`，按热度降序）。
  TextColumn get tagsJson => text().nullable()();

  /// infobox JSON 数组：`[{"key":"导演","value":"..."}]`（Bangumi `infobox` 摊平，
  /// 值为数组时用 `/` 连接）。存原始 key 名，展示层不翻译（源就是中文）。
  TextColumn get infoboxJson => text().nullable()();

  /// 条目详情页 URL（`https://bgm.tv/subject/<id>`），供「查看条目」跳转。
  TextColumn get detailUrl => text().nullable()();

  /// 本行写入时间（重刮判据 / 展示「资料更新于」）。
  DateTimeColumn get scrapedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {bookUid};
}

// ── galgames ────────────────────────────────────────────────────────
/// v55（游戏库对齐 ReinaManager，见 `docs/design/galgame-library-reina-parity.md`）：
/// galgame 游戏库的持久真相源，取代旧的偏好表单一 JSON key `galgame_library`
/// （那份 6 字段列表撑不起元数据、游玩状态与排序筛选）。
///
/// 主键**沿用旧 JSON 的 TEXT id**（添加时刻微秒时间戳字符串），不改成自增 int：
/// 封面文件按 `<documents>/game_covers/<gameId>.<ext>` 命名，换主键类型要连带重命名
/// 磁盘文件，纯粹是自找麻烦且零收益（Never break userspace）。
///
/// 元数据不落这张表的散列，而是走纵表 [GalgameSources]（一游戏多源）+ 本表的
/// [customDataJson] 用户覆盖层，展示值由 `galgame_metadata_merge.dart` 的纯函数
/// 按优先级合并。好处：加一个数据源零 schema 变更。
@DataClassName('GalgameRow')
class Galgames extends Table {
  /// 稳定标识，沿用旧 JSON 的微秒时间戳字符串。封面文件名与之绑定。
  TextColumn get id => text()();

  /// 本地默认显示名（exe 文件名去扩展名）。用户改名走 [customDataJson] 的 `name`，
  /// 不覆盖本列——这样「清空自定义名」能干净地回落到本地默认名。
  TextColumn get name => text()();

  /// 游戏可执行文件绝对路径（hook 注入目标）。
  TextColumn get exePath => text()();

  /// 工作目录（默认 exe 所在目录）。也是游玩计时判定「候选进程组」的范围依据。
  TextColumn get workdir => text()();

  /// v56：启动游戏时追加给 exe 的命令行参数，存**用户原样输入的一整行**
  /// （如 `-windowed --save="D:\My Saves"`），空串 = 不带任何参数。
  ///
  /// 刻意不存 `List<String>` 的 JSON：用户的心智模型就是「一行命令行」（从攻略、
  /// Steam 启动项里复制粘贴），存原文才能原样回显、原样再编辑。拆分成 argv 的规则
  /// 由 `parseGameLaunchArguments` 这个纯函数在启动时执行一次，与 Windows
  /// `CommandLineToArgvW` 同规则 —— 存拆分结果反而要多维护一套「拆了再拼回去给用户看」
  /// 的逆变换，且无法无损还原用户写的引号。
  TextColumn get launchArgs => text().withDefault(const Constant(''))();

  /// 该游戏的窗口超分档位（Magpie）。存稳定字符串 'auto' / 'installed_only' / 'off'；
  /// 空串 = 用户没设过，解析层回落到关闭。**每游戏独立**，没有全局开关。
  ///
  /// 与 [launchArgs] 同类：都是「用户为该游戏设的启动期配置」，随游戏行走、
  /// 由启动路径读一次。存稳定字符串而不是枚举 index：加档位不改既有值的含义，
  /// 且脏值/未来值读到时解析层直接回落关闭（不会因为 index 越界崩）。
  TextColumn get upscalingMode => text().withDefault(const Constant(''))();

  /// 本地封面绝对路径；null = 用默认手柄图标。
  TextColumn get coverPath => text().nullable()();

  /// 添加毫秒戳。
  IntColumn get addedAt => integer()();

  /// 游玩状态：0=未设置 / 1=想玩 / 2=玩过 / 3=在玩 / 4=搁置 / 5=弃坑。
  /// 1-5 的数值**故意对齐 Bangumi 收藏 type**，将来做云端收藏同步免一层映射。
  /// 旧数据迁移后一律 0（未设置），行为与旧版一致。
  IntColumn get playStatus => integer().withDefault(const Constant(0))();

  /// 主显示源：'bgm' / 'vndb' / 'mixed' / 'custom'；null = 尚未刮削过。
  TextColumn get primarySource => text().nullable()();

  /// 发行日期（'YYYY-MM-DD'），从元数据上提成列供排序，避免为排序反序列化 JSON。
  TextColumn get releaseDate => text().nullable()();

  /// 用户覆盖层 JSON（name/coverSource/aliases/summary/tags/developer/nsfw/
  /// userRating/userReview）。覆盖语义分两种：标量字段**覆盖**，aliases/tags **并集**。
  TextColumn get customDataJson => text().nullable()();

  /// 手动排序位（预留，M1 不做拖拽排序）。
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

// ── galgame_sources ─────────────────────────────────────────────────
/// v55：游戏元数据的**源纵表**（一游戏多源，`(gameId, source)` 复合主键）。
///
/// 为什么是纵表而不是每源两列：加一个数据源（ymgal / dlsite / …）只是多一行
/// `source` 取值，不动 schema、不写迁移。[dataJson] 存该源的完整 draft 快照，
/// [score] / [rank] 在写入时一并上提成普通列，让排序留在 SQL 层。
@DataClassName('GalgameSourceRow')
class GalgameSources extends Table {
  /// 所属游戏。删游戏 cascade 清本表。
  TextColumn get gameId =>
      text().references(Galgames, #id, onDelete: KeyAction.cascade)();

  /// 数据源 key：'bgm' / 'vndb'（未来直接加值，不加列）。
  TextColumn get source => text()();

  /// 外部条目 ID（bgm subject id / vndb 的 'v12345'）。
  TextColumn get externalId => text().nullable()();

  /// 该源完整快照（`GalgameMetadataDraft.toJson()`）。
  TextColumn get dataJson => text()();

  /// 从 draft 上提的评分（0-10 归一后），供 SQL 排序。
  RealColumn get score => real().nullable()();

  /// 从 draft 上提的排名（仅 bgm 有），供 SQL 排序。
  IntColumn get rank => integer().nullable()();

  /// 抓取毫秒戳（判断缓存新旧、决定是否重新刮削）。
  IntColumn get fetchedAt => integer()();

  @override
  Set<Column> get primaryKey => {gameId, source};
}

// ── galgame_sessions ────────────────────────────────────────────────
/// v55：游玩会话**事实表**，一次启动一行。由 `galgame_play_tracker.dart` 的
/// 前台窗口 + 候选进程组计时器写入。
///
/// 这张表存在的理由是修一个真实缺陷：旧实现把游玩时长记在通用 `activity_events`
/// 上、且由 **hook 抓到的文本行**驱动——没抓到文本就完全不计时（未适配引擎、
/// 纯语音场景、hook 失败全部丢账）。改为按进程计时后时长与 hook 解耦。
///
/// **刻意不建统计投影表**：上游 ReinaManager 有一张 `game_statistics` 投影，代价是
/// 「投影与事实表不一致」的一整类 bug（它为此写了增量更新 + 校验失败全量重算的兜底）。
/// 单机游戏库规模是几百游戏 × 几千会话，直接 GROUP BY 聚合即可，一次消掉整类问题。
@DataClassName('GalgameSessionRow')
class GalgameSessions extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 所属游戏。删游戏 cascade 清本表。
  TextColumn get gameId =>
      text().references(Galgames, #id, onDelete: KeyAction.cascade)();

  /// 会话起始毫秒戳。
  IntColumn get startMs => integer()();

  /// 会话结束毫秒戳。
  IntColumn get endMs => integer()();

  /// 计入时长（**秒**）。playtime 模式 = 前台活跃秒数；elapsed 模式 = 墙钟秒数。
  /// 上游存分钟，这里存秒——格式化是 UI 层的事，事实表不该先损失精度。
  IntColumn get durationSeconds => integer()();

  /// 冗余的按天分组键（'YYYY-MM-DD'，本地时区，取 [endMs] 的日期），
  /// 与其它统计表 dateKey 同源，避免读取端为分组反算。
  TextColumn get dateKey => text()();
}

// ── galgame_tag_mappings ────────────────────────────────────────────
/// v57（BUG-1113「游戏没有标签」）：游戏 ↔ **用户标签** 多对多映射。标签定义复用
/// 共享的 [BookTags]，与 EPUB（[BookTagMappings]）、SRT（[SrtBookTagMappings]）、
/// 视频（[VideoBookTagMappings]）、合集（[CollectionTagMappings]）**同一个标签池**
/// ——这正是本表存在的理由：上层筛选栏 / 标签管理页早已是四种媒体共用，唯独游戏
/// 没有落表，于是接不进来（不是 UI 忘接，是 schema 缺口）。
///
/// 与游戏**元数据标签**（bgm/vndb 刮削来的字符串，存 [GalgameSources].dataJson +
/// [Galgames].customDataJson，由 `galgame_library_query.dart` 按名筛选）是两个正交
/// 维度，刻意不合并：元数据标签是外部事实、动辄上百个且随刮削变动，塞进用户标签池
/// 会污染书/视频共享的那份手工标签。
///
/// **刻意不带 `addedAt`**（对比 [BookTagMappings] / [VideoBookTagMappings]）：那一列
/// 是 LWW-element-set 的 add 时钟，只为跨端同步裁决而存在。游戏身份 [Galgames].id 是
/// 添加时刻微秒戳，**本机局域身份**——`galgames` 整张表既不进 live-sync 清单也不进
/// 备份合并导入，故游戏标签同样不跨端传播、不需要墓碑（[BookTagMembershipTombstones]
/// 不覆盖游戏）。全量备份恢复走整库文件拷贝，本表随之原样还原。加一个没有消费者的
/// 时钟列只会让人误以为它在同步。同款取舍见 [CollectionTagMappings]。
///
/// 删游戏 / 删标签经外键 cascade 自动清理本表。
@DataClassName('GalgameTagMappingRow')
class GalgameTagMappings extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get gameId =>
      text().references(Galgames, #id, onDelete: KeyAction.cascade)();
  IntColumn get tagId =>
      integer().references(BookTags, #id, onDelete: KeyAction.cascade)();

  @override
  List<Set<Column>> get uniqueKeys => [
        {gameId, tagId},
      ];
}
