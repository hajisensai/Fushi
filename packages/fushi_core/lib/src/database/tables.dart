import 'package:drift/drift.dart';

// ── media_open_history（v80：取代 jidoujisho 血统的 media_items） ────
/// 「最近打开流」：一行 = 一个媒体条目最近一次被打开的事实。旧 media_items 把
/// 身份（uniqueKey/mediaIdentifier 双轨）、展示快照（title/author/**base64 图片
/// 进 SQLite 行**）、播放状态（position/duration）、UI 能力位（canDelete/canEdit）
/// 四种东西摊成 19 列；本表只留身份 + 时刻 + 排序/换算要用的两个进度数，其余
/// 全部收进 [snapshotJson]（重开外部媒体的必要载荷——在线漫画/网页/流媒体没有
/// 库表行可 join，title/封面/源参数只能随历史行走；库内媒体的快照只是打开当时
/// 的展示缓存，真相仍在专表）。
///
/// 主键 (mediaSource, mediaId) 与旧 uniqueKey（'$source/$id'）同构，去掉自增
/// id 与派生列。UI 能力位回归运行时按 source 推导，不再持久化。新写入不再产生
/// base64 图片（无活写入方）；v80 前遗留的 base64 随 snapshot 平移，随行被
/// trim 自然消亡。
@DataClassName('MediaOpenHistoryRow')
class MediaOpenHistory extends Table {
  /// 媒体类型 key（冻结值域 = 旧 mediaTypeIdentifier：'reader' / 'player' / …）。
  TextColumn get mediaType => text()();

  /// 媒体源 key（旧 mediaSourceIdentifier）。
  TextColumn get mediaSource => text()();

  /// 源内身份（旧 mediaIdentifier：库内 = bookKey 派生 URI，外部 = URL）。
  TextColumn get mediaId => text()();

  /// 最后打开毫秒戳（排序与 trim 的键；旧 imported_at 平移）。
  IntColumn get openedAt => integer().withDefault(const Constant(0))();

  /// 进度两数（互联 host 的百分比换算要在 SQL 面上可用，故留列不进 JSON）。
  IntColumn get position => integer().withDefault(const Constant(0))();
  IntColumn get duration => integer().withDefault(const Constant(0))();

  /// 其余展示/重开载荷（MediaItem.toJson 去掉列化字段后的 JSON）。
  TextColumn get snapshotJson => text().withDefault(const Constant('{}'))();

  @override
  Set<Column> get primaryKey => {mediaSource, mediaId};
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

  /// v88：字幕书/有声书的内容语言（BCP-47）。SRT 文件本身不声明语言，所以这一列
  /// 只能由用户指定；null = 未知，正文不写 font-family（不猜）。
  TextColumn get language => text().nullable()();
}

// ── reader_positions ────────────────────────────────────────────────
@DataClassName('ReaderPositionRow')
class ReaderPositions extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// v82 起的书稳定身份:epub 书 = EpubBooks.uid(本机稳定,标题改名不丢位置);
  /// 非 epub 域(SRT 书等)沿用其既有稳定键。刻意无 FK——本表跨书族,孤儿防线
  /// 在应用层(host service 写入闸门 + deleteEpubBook 显式清理)。
  TextColumn get bookUid => text().unique()();
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

  /// v82:= EpubBooks.uid。无 SQL FK(uid 唯一性是 partial 索引,FK 会
  /// mismatch);删书清理走 deleteEpubBook 显式级联,守卫测试兜底。
  TextColumn get bookUid => text()();
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

  /// v67：写入面身份（`BookFormat.dbValue`：'epub' / 'pdf' / 'manga'）。此前没有
  /// 任何身份列，EPUB / PDF / 漫画同一小时的时长在写入时就被加成一行，永久分不开；
  /// 日级 `reading_statistics` 靠 title→format 反查能拆，时段表拆不开只因缺这列。
  /// `''` = v67 前的历史行（写入时信息已丢，如实标未区分）以及云同步里旧端贡献的
  /// 无法归因差额（见 aggregate_sync_service 的 deficit-lift）。
  TextColumn get format => text().withDefault(const Constant(''))();

  @override
  List<Set<Column>> get uniqueKeys => [
        {dateKey, hour, format},
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

  /// 该行最后一次写入的毫秒戳（v84 / BUG-1502）——**跨端 LWW 的比较键**。
  ///
  /// 绝大多数偏好是设备设置、从不跨端合并，这一列对它们只是无害的记账。它存在
  /// 是因为**有些偏好行是内容**：书的改名（`override_title://` 覆盖行，BUG-1488）
  /// 跟着书走、必须跨端合并，而 `preferences` 原先只有 key/value 两列，合并端
  /// 无从判断「谁更新」，只能退化成 insert-if-absent —— 母设备**第二次**改名
  /// 就传不到已有 override 的子设备了。
  ///
  /// **默认 0 = 「时刻未知」，是刻意的取舍**：v84 迁移不给存量行填迁移时刻。
  /// 填迁移时刻会让「谁赢」由两台设备各自的升级时间决定（后升级的一侧无条件
  /// 覆盖先升级的一侧，用户什么都没做却发生覆盖）；取 0 则存量行彼此平局，
  /// 而 LWW 的平局规则是「保留本机」——正好等于升级前的 insert-if-absent 行为，
  /// 零回归；任何一侧**真正改过一次名**之后（时刻 > 0）立刻胜出。同理，旧对端
  /// 发来的无时刻数据一律按 0 收，永远不会覆盖本机改过的名字。
  ///
  /// 写入方：[FushiDatabase.setPref] / `setPrefs` / `compareAndSetPref` 填
  /// `now`；跨端采纳走 [FushiDatabase.setPrefIfNewer]，**填对端的时刻而不是
  /// now**（填 now 会让本机永远最新，母设备的下一次改名再也传不进来）。
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

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

  /// v96：用户**显式展开**这本词典的语言列表（BCP-47，与 [collapsedLanguagesJson]
  /// 同形）。BUG-2158。
  ///
  /// 为什么必须是独立的第二列而不是把 collapsed 当布尔用：折叠有**三**个态，
  /// 一个列表只装得下两个。
  ///   * 在 collapsed 名单里 → 显式折叠；
  ///   * 在本名单里 → 显式展开；
  ///   * 两个名单都不在 → **继承**（自动展开窗口 + 全局 `collapse_dictionaries`）。
  /// 修复前只有 collapsed 一个名单，「不在名单里」被 UI 当成「展开」呈现（那个
  /// unfold_more / unfold_less 双态按钮），实际却是「继承」——而全局默认是折叠，
  /// 于是用户给自动展开窗口之外的词典点「展开」，视觉上毫无反应。UI 在撒谎。
  ///
  /// 两个名单**互斥**，由唯一写入点 `DictionaryRepository.setDictionaryCollapseState`
  /// 维持；读取侧（[Dictionary.isCollapsed]）仍把「显式展开」排在「显式折叠」之前，
  /// 所以即使外部写入弄出重叠，行为也是确定的而不是未定义。
  ///
  /// 存量数据零迁移：旧库升级后本列为 `[]` = 全部继承 = 逐字节保持 v96 前的行为。
  TextColumn get expandedLanguagesJson =>
      text().withDefault(const Constant('[]'))();

  /// v87：用户**手动指定**的词典内容语言（BCP-47，如 `ja` / `zh-Hant`）。
  ///
  /// null = 未指定，按自动来源推断（yomitan `index.json` 的 `sourceLanguage`，
  /// 落在 [metadataJson] 里）。非 null 为用户覆盖，压过一切自动判断。
  ///
  /// 为什么不塞进 [metadataJson]：重导/在线更新词典时 metadata 会被包内 index.json
  /// **整体重建**（见 `dictionary_import_manager` 的两处 persistDictionary），
  /// 用户的手动指定会随之蒸发。它属于「用户设置」，必须与 hidden/collapsedLanguages
  /// 走同一条继承通道（`preservedSettings`）。
  TextColumn get languageOverride => text().nullable()();

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
// 建表由 database.dart onUpgrade v50 负责；写入走 ClipboardHistoryRepository 的
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

  /// v81（P3 Stage 1，数据层重构 2026-08）：书的**本机稳定身份**。bookKey 由
  /// 用户可见可改的标题派生（改名 = 身份变 = 十来张子表连坐改键，这正是它当
  /// 头号根因的原因）；本列是导入时生成一次、此后永不变的机器局域 uid
  /// （`book_<rowid/时刻>` 形，[generateEpubBookUid]），为后续把
  /// ReaderPositions/Bookmarks/RevealedImages/BookCustomCss 等子表键切过来
  /// （Stage 1b）与最终支持改名铺地基——v39 给视频先落 bookUid 列、v76 展示层
  /// 才收尾的同款两步走。**wire/sync/备份仍走 bookKey**（title 派生键契约冻
  /// 结），本列不进 wire；跨库合并经 bookKey 对齐后各自保留本机 uid。
  /// 唯一性由独立唯一索引保证（迁移路径 ADD COLUMN 不能带 UNIQUE）；插入时
  /// 未携带则由 [insertEpubBook] 单点自动生成，调用方零改动。
  TextColumn get uid => text().withDefault(const Constant(''))();
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

  /// v87：书的内容语言（BCP-47，如 `ja` / `zh-Hant`），决定正文用哪条字体链。
  ///
  /// 导入时从 EPUB OPF 的 `dc:language` 回填（`EpubParser` 早就解析出来了，此前
  /// 无人消费）；用户可在书籍设置里手动改，手动值压过自动值。null = 既没解析到
  /// 也没指定 → 阅读器不写 `font-family`，保持浏览器默认（不猜，见
  /// `content_font_chain.dart`）。
  ///
  /// 与 [mangaReadingMode] 同款「null=自动 / 非 null=用户覆盖」语义。
  TextColumn get language => text().nullable()();

  /// 书身份格式判别（PDF 阅读器 Phase 1）：`'epub'`（默认，含 EPUB / TextToEpub /
  /// 有声书配对壳）、`'pdf'`（pdfrx 渲染的真 PDF）或 `'manga'`（漫画 OCR，第三种书）。
  /// 默认 `'epub'` 让既有全部行零破坏（Never break userspace，v51 迁移 addColumn 自动
  /// 回填），书架/进度/删除按此列区分而非另建平行表。PDF 行：`format='pdf'`、
  /// `epubPath`=PDF 绝对路径、`extractDir`=占位、`chapterCount`=页数、`chaptersJson`=`'[]'`。
  TextColumn get format => text().withDefault(const Constant('epub'))();

  /// 漫画阅读模式覆盖（漫画 OCR，v53）：`null`=按页图长宽比自动判定（默认，横长跨页
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

// ── tag_assignments（v79：五张标签映射表合一） ─────────────────────
/// 标签 ↔ 宿主 的统一多对多映射，取代 v79 前的五张同形表
/// （book/srt/video/collection/galgame *_tag_mappings）。标签定义仍是共享的
/// [BookTags] 池。
///
/// 设计拍板（2026-08 数据层重构，用户令合并并重新决策差异）：
///  - **[mediaKind] + [entryKey] 逻辑外键**（仓库既定惯例，同
///    [ShelfEntries].entryKey / [MediaCollectionItems].entryKey）：epub=bookKey /
///    srt=SrtBooks.uid（v79 起弃本机自增 int id，换跨设备稳定的 uid）/
///    video=bookUid / collection=MediaCollections.id 字符串化 / game=Galgames.id。
///    宿主删除经各删除路径显式清理（不再依赖五张表各自的 DB cascade），读取期
///    过滤兜底；[tagId] 对 [BookTags] 的真 FK 保留（删标签仍 cascade）。
///  - **[addedAt] 统一都记**：记的是「何时打的标签」这一事实，写入成本为零。
///    旧决策让 game/collection 不带时钟（怕被误读成在同步），代价是把「不进
///    sync」编码进表的形状里、真要同步时只能回填 0 丢失真实时间。哪些 kind
///    参与 sync 由合并层一处写死（当前仅 epub/video；game/collection 不进
///    live-sync 的事实不变）。旧行迁移填 0（最古 add，语义同旧 book/video 表）。
///  - 墓碑不变：[BookTagMembershipTombstones] 本就是 (itemKey, mediaType,
///    tagName) 通用形，天然覆盖全部 kind。
@DataClassName('TagAssignmentRow')
class TagAssignments extends Table {
  /// 宿主种类：'epub' | 'srt' | 'video' | 'collection' | 'game'。
  TextColumn get mediaKind => text()();

  /// 宿主稳定身份（值域见类 doc）。
  TextColumn get entryKey => text()();

  IntColumn get tagId =>
      integer().references(BookTags, #id, onDelete: KeyAction.cascade)();

  /// 该映射被加入的毫秒戳（epub/video 域是 LWW-element-set 的 add 时钟——与
  /// [BookTagMembershipTombstones].deletedAt 比较决定 add-wins/remove-wins）。
  IntColumn get addedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {mediaKind, entryKey, tagId};
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

  /// v88：视频的内容语言（BCP-47），决定字幕用哪条字体链。
  ///
  /// null = 未指定 → 字幕层退回「当前字幕轨的 language」，再没有则用历史兜底链。
  /// 非 null 为用户手动指定，压过字幕轨声明——外挂 SRT 基本都不带语言标记，
  /// 而内嵌轨的 language 又常被打包者写错，所以必须留一个用户说了算的入口。
  TextColumn get language => text().nullable()();

  TextColumn get subtitleSource => text().nullable()();

  /// 副字幕源（TODO-857 视频双字幕 Path A）：与 [subtitleSource] 同款四态编码
  /// （外挂存绝对路径；内嵌存 `embedded:<n>`；关闭存 `off:`；无副字幕存 null）。
  /// TODO-1312 起副字幕走独立 Dart cue 流（Flutter overlay 副层渲染，可逐字符
  /// 查词），**不再**由 libmpv `secondary-sid` 自渲染；持久化编码沿用不变。
  TextColumn get secondarySubtitleSource => text().nullable()();
  TextColumn get subtitleFormat => text().nullable()();
  IntColumn get embeddedSubtitleTrack => integer().nullable()();
  TextColumn get coverPath => text().nullable()();
  IntColumn get lastPositionMs => integer().withDefault(const Constant(0))();

  /// 最近一次播放的毫秒时刻（schema v85，BUG-1542）；null = 从未播放 / v85 前旧行
  /// 回填不到。与 [lastPositionMs] **成对写入**（同一个 `updateVideoBookPosition`
  /// 事务），使「这一行有进度」和「这进度是什么时候留下的」不可能失配。
  ///
  /// 有了它，合集续播的锚点才能是「用户刚才在看哪一集」。此前 `VideoBooks` 只有
  /// 位置没有时刻，`continueMemberIndex` 只能拿「排序位置最靠后的有痕迹成员」当
  /// 代理——等价于假设用户永远按集号单调前进，用户回头看 PV/补看早期某集后就选错
  /// （BUG-1542：刚退出 PV 第 1 集，头部显示「继续看 第233集」）。
  ///
  /// 为什么不复用 `video_watch_statistics.lastModified`：那是**按天聚合**行的
  /// mtime，且云聚合合并（`setVideoWatchStatistic`）会改写它 → 不是「本机最近播放
  /// 这一集」的可靠事实；远端进度经 sync 写进 [lastPositionMs] 时也根本不产生统计
  /// 行。v85 迁移仍从它回填存量库（唯一可得的历史近似），新写入一律走本列。
  IntColumn get lastPlayedAt => integer().nullable()();

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

  /// 副字幕独立调轴（毫秒，schema v86，TODO-2837 主副字幕分开调轴）。**nullable**
  /// （区别于 [delayMs] 的 withDefault(0)）：NULL = 未单独设置 = 副字幕跟随
  /// [delayMs]（与 v86 前「主副共用一个 offset」逐字节一致，Never break
  /// userspace——旧库升级后全 NULL，行为零变化）；非 NULL = 副字幕独立于主字幕
  /// 调轴（主副字幕轴不同源时各调各的）。含义与 [delayMs] 同向（正值=字幕延后）。
  IntColumn get secondaryDelayMs => integer().nullable()();

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

// （v79：video_book_tag_mappings / collection_tag_mappings 已并入
// [TagAssignments]，旧表只活在迁移阶梯的冻结 SQL 里。）

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
///
/// [bookKey] 自 v76 起从可空改 NOT NULL DEFAULT ''，且**进唯一键**——v39 给
/// video_watch_statistics 修的「同名不同视频互串」在本表是同一个病：旧唯一键
/// {title, sourceType, dateKey} 不含身份，两个同名视频的查词/制卡计数合进同一行。
/// '' = 无书查词（title 也 ''）或 v76 前无法唯一归因的遗留行；''+title 仍在唯一键内，
/// 遗留行按 title 互不合并。迁移按 epub_books/video_books 的 title 唯一匹配回填
/// （v39 同判据），歧义保持 ''（读取端按 title 回退归并，见 stat_shared）。
@DataClassName('LookupMiningCounterRow')
class LookupMiningCounters extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get bookKey => text().withDefault(const Constant(''))();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get sourceType => text()(); // 'book' | 'video'
  TextColumn get dateKey => text()();
  IntColumn get lookupCount => integer().withDefault(const Constant(0))();
  IntColumn get mineCount => integer().withDefault(const Constant(0))();

  /// 列序 {title, sourceType, dateKey, bookKey}（而非 bookKey 打头）：唯一索引
  /// 要同时服务 add*（四列全等）与 set*/按 title 删除（三列前缀）——bookKey 打头
  /// 会让全部 title 粒度查询退化成全表扫描（sync 应用逐 record 扫两遍）。
  @override
  List<Set<Column>> get uniqueKeys => [
        {title, sourceType, dateKey, bookKey},
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
/// （fushi/lib/src/media/source_library/source_library_row.dart），与 UI 媒体源
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

  /// 条目稳定身份（v83 起 epub 域 = epub_books.uid,导入时刻定死、改标题不再
  /// 漂移,旧的下载后改键迁移已删）：本地 = epubUid / srtUid / videoBookUid；
  /// 远端 = 对端 bookKey（照抄透传,本地无行）/ video.id。**逻辑外键**（不对
  /// 本地三表加 FK：远端 entryKey 无本地表行，写 FK 会在插远端归属时违反
  /// 约束）。孤儿由删除路径主动清理 + 读取期过滤兜底。
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
  /// 联合视图 §2.3）。仅 [FushiDatabase.reorderCollectionItems]（用户拖拽落盘）
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

  /// 系列级**副字幕**独立调轴（毫秒，schema v86，TODO-2837）。与 [subtitleDelayMs]
  /// 同款「系列共享」语义：合集内任一集调副轨轴即写这里，任一集加载优先读这里
  /// （回退各集自己行的 [VideoBooks.secondaryDelayMs]）。两层都 NULL = 副字幕跟随
  /// 主字幕调轴（v86 前行为）。无损迁移：nullable 无 default → 旧库既有行全 NULL =
  /// 行为与旧版一致（Never break userspace）。
  IntColumn get secondarySubtitleDelayMs => integer().nullable()();

  /// 系列级默认字幕语言代码（`ja` / `en` …，schema v91）。与 [subtitleDelayMs]
  /// 同款「系列共享、nullable」语义：非 NULL 时覆盖合集内每一集的字幕语言选择。
  /// **NULL = 没人配过 → 消费方回退视频内容语言链（`resolveContentLanguage`），
  /// 绝不是 ja**——语言未知不许替用户猜。无损迁移：nullable 无 default → 旧库既有
  /// 行全 NULL = 行为与旧版一致（Never break userspace）。
  TextColumn get subtitleLanguage => text().nullable()();

  /// 系列级偏好的字幕版本组键（schema v91）。值是
  /// `subtitle_version_groups.dart` 的分组键（一个字符串），合集内多版本字幕
  /// （不同字幕组/发布版本）时优先选这一组。与 [subtitleLanguage] 同款语义：
  /// **NULL = 没人配过**（消费方走默认选轨），非 NULL 覆盖每集。无损迁移：
  /// nullable 无 default → 旧库既有行全 NULL = 行为与旧版一致。
  TextColumn get subtitleReleaseGroup => text().nullable()();
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
// 重新加入清同键墓碑（[FushiDatabase.addToCollection]）；重建同名合集清合集级
// 墓碑（[FushiDatabase.createMediaCollection]），同插书清书墓碑一律。
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

// ── fushi_paired_peers ─────────────────────────────
// TODO-1017 阶段1：互联（Fushi server 局域网配对）的 per-peer 授权凭据表。每个
// 已配对设备一行，token 是该设备访问本机 Fushi server 的长期凭据。范式仿
// [MediaSources]（自增 id + text().unique() 身份列 + int 毫秒戳时间列）。
// SQL 表名走 drift 默认 snake_case（fushi_paired_peers）；旧名 hibiki_paired_peers
// 由 v69 迁移一次性 ALTER TABLE RENAME（终局清算：运行时/持久化零旧名，旧名只
// 允许活在迁移步里）。
@DataClassName('FushiPairedPeerRow')
class FushiPairedPeers extends Table {
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
  /// 书稳定身份（v82 起 = EpubBooks.uid，本机稳定；跨设备/备份合并经
  /// epub_books 双侧 JOIN 换键）。删书清理走 deleteEpubBook 显式级联。
  TextColumn get bookUid => text()();

  /// 书内 CSS 文件相对路径（extractDir 内，正斜杠归一，同 [CssFileEntry].relativePath）。
  TextColumn get relativePath => text()();

  /// 用户自定义的 CSS 全文（[deleted]=true 时无意义，留空）。
  TextColumn get content => text().withDefault(const Constant(''))();

  /// true = 已重置回原始（重置墓碑）；false = 有自定义内容。
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  /// 最后修改毫秒戳（LWW 比较键；保存/重置都刷新）。
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {bookUid, relativePath};
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
// WebView（JS __fushiImageRevealKey）与图片库 IllustrationsViewerPage（File 相对路径）
// 都归一到这同一个 key，实现「书内揭开↔图片库揭开」双向同步（同一张图只存一行）。
// 揭开即 insertOnConflictUpdate 一行（幂等）；空表 = 全部保持遮罩（旧库升级后行为与旧版
// 完全一致，Never break userspace）。删书经 EpubBooks FK cascade 连带清本表。范式仿
// [BookCustomCss]（text 复合键 + int 毫秒戳，为将来 sync/backup 留 LWW 口）。
@DataClassName('RevealedImageRow')
class RevealedImages extends Table {
  /// 书稳定身份（v82 起 = EpubBooks.uid）。无 SQL FK（uid 唯一性是 partial
  /// 索引），删书清理走 deleteEpubBook 显式级联，守卫测试兜底。
  TextColumn get bookUid => text()();

  /// 图片稳定 key（extractDir 相对、解码、正斜杠路径，如 `OEBPS/images/foo.jpg`）。
  TextColumn get imageKey => text()();

  /// 揭开毫秒戳（LWW 比较键；备份合并取较新）。
  IntColumn get revealedAt => integer()();

  @override
  Set<Column> get primaryKey => {bookUid, imageKey};
}

// ── collection_scrape_meta ──────────────────────────────────────────
// 合集条目刮削元数据（schema v64，BUG-1310）：一个合集一行。
//
// 为什么不是复用 [VideoScrapeMeta]：那张表主键是 bookUid、外键指向 VideoBooks，
// 承载的是**单集**资料。而简介 / 评分 / 放送日期 / 标签本质属于「一部作品」——
// 在统一合集模型里，「一部作品」就是合集，不是它的第 7 集。合集此前没有元数据
// 宿主，于是旧合集封面匹配流程只能下一张海报就结束，
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
  IntColumn get collectionId => integer()
      .references(MediaCollections, #id, onDelete: KeyAction.cascade)();

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

  /// 集号（v66 / TODO-2491）：集级刮削按文件名解析的集号与源的分集列表对齐后写入
  /// （TMDB `episode_number` / Bangumi `sort`）。NULL = 本行是旧的**作品级**资料
  /// （v54~v64 的自动刮削把整部作品的简介写进每个文件），或集级刮削未能从文件名
  /// 解出集号。存对齐后的**源侧集号**而非文件名原文，便于重刮时按号更新。
  IntColumn get episodeNumber => integer().nullable()();

  /// 本行写入时间（重刮判据 / 展示「资料更新于」）。
  DateTimeColumn get scrapedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {bookUid};
}

// ── collection_relations ────────────────────────────────────────────
// 合集相关作品（v66 / TODO-2484）：一行 = 「某合集 → 一部相关作品」的有向边，
// 来自刮削源的关联数据（Bangumi subject relations / TMDB tv seasons 与
// movie belongs_to_collection）。目标两态：
//   - 纯刮削：只有 (source, subjectId, title, coverUrl/coverPath)，本地库里还没有
//     对应合集，UI 只能展示 + 跳源详情页；
//   - 已绑定：targetCollectionId 非空，点击可直接跳本地合集。
// 两态不是两张表：绑定只是在纯刮削行上补一个本地 id（「升级绑定」），身份仍由
// (collectionId, source, subjectId) 决定。
//
// 与 [CollectionScrapeMeta] 同族：可重建的刮削缓存（删了重刮即回填），删除合集
// FK cascade 连带清边；目标合集被删则 setNull 退回纯刮削态（刮削事实还在，只是
// 本地绑定失效——这正是「目标两态」的语义，不需要墓碑）。
@DataClassName('CollectionRelationRow')
class CollectionRelations extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 边的起点：本地合集。删合集 cascade 清边。
  IntColumn get collectionId => integer()
      .references(MediaCollections, #id, onDelete: KeyAction.cascade)();

  /// 关系类型，wire 值固定小写下划线：`prequel`（前传）/ `sequel`（续集）/
  /// `side_story`（番外/外传）/ `movie`（剧场版）/ `spin_off`（衍生）/ `other`。
  /// 源侧的中文/自由文本关系词在抓取层映射成这六个值再落库，UI 不解析源词。
  TextColumn get relationType => text()();

  /// 同一合集内的展示顺序（抓取层按源返回顺序编号，0-based 致密）。
  IntColumn get sortIndex => integer().withDefault(const Constant(0))();

  /// 已绑定态：目标在本地库中的合集 id。纯刮削态为 NULL；目标合集被删自动
  /// setNull 退回纯刮削态。
  IntColumn get targetCollectionId => integer()
      .nullable()
      .references(MediaCollections, #id, onDelete: KeyAction.setNull)();

  /// 目标条目来源（`ScrapeSource.name`：bangumi / tmdb）。
  TextColumn get source => text()();

  /// 目标条目在源内的 id（Bangumi subject id / TMDB id 或季 id），字符串化。
  TextColumn get subjectId => text()();

  /// 目标条目标题（源侧中文优先）。
  TextColumn get title => text()();

  /// 目标封面远程 URL（未下载时 UI 可按需拉取）。
  TextColumn get coverUrl => text().nullable()();

  /// 目标封面本地路径（抓取层下载落地后回填）。
  TextColumn get coverPath => text().nullable()();

  /// 同一合集下同一源内条目只此一边（重复刮削按此去重）。
  @override
  List<Set<Column>> get uniqueKeys => [
        {collectionId, source, subjectId},
      ];
}

// ── media_images ────────────────────────────────────────────────────
// 媒体附加图组（v68，Jellyfin 图组对齐）：一行 = 一张附加图（横版背景 backdrop /
// 标题 logo / 带字横图 title_card），归属**二选一**——合集（collectionId）或单视频
// （bookUid），CHECK 约束在 DB 层锁死单一归属。主封面**不进本表**：仍是
// `MediaCollections.coverPath` / `VideoBooks.coverPath`（冻结契约，书架/GC/同步
// 全部围绕它）。
//
// 为什么是一张表而不是逐列加（对齐 Jellyfin `ItemImageInfo[]` 扁平数组）：
// backdrop 允许多张（position 排序，详情页 10 秒轮换），列模型装不下；且合集与
// 散装电影两个归属方各拷一套列就是四份特例。只有 backdrop 允许 position>0
// （Jellyfin `AllowsMultipleImages` 同拍板），logo / title_card 每归属一张。
//
// 与 [CollectionScrapeMeta] 同族：可重建的刮削缓存（重刮即回填）。v64 的
// `CollectionScrapeMeta.backdropPath` 由 v68 迁移搬进本表（kind='backdrop',
// position=0），旧列冻结为遗留残留（Series 先例）——读写一律走本表，勿再碰旧列。
// 删合集 / 删视频经 FK cascade 清行；磁盘文件回收走 collection_asset_reclaim /
// VideoBookRepository 的既有单一入口（文件不在 gcOrphanCovers 的扫描面内，见
// VideoStorage 子目录免疫说明）。
@DataClassName('MediaImageRow')
class MediaImages extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 归属合集（与 [bookUid] 二选一）。删合集 cascade 清行。
  IntColumn get collectionId => integer()
      .nullable()
      .references(MediaCollections, #id, onDelete: KeyAction.cascade)();

  /// 归属单视频（与 [collectionId] 二选一；散装电影的图组）。删视频 cascade 清行。
  TextColumn get bookUid => text()
      .nullable()
      .references(VideoBooks, #bookUid, onDelete: KeyAction.cascade)();

  /// 图种类（`MediaImageKind.dbValue`：backdrop / logo / title_card）。
  TextColumn get kind => text()();

  /// 同归属同种类内的排序位（仅 backdrop 允许 >0；其余恒 0）。
  IntColumn get position => integer().withDefault(const Constant(0))();

  /// 本地文件绝对路径（合集图落 `video_covers/collections/`，视频图落
  /// `video_covers/images/`——两个子目录都在 gcOrphanCovers 扫描面外）。
  TextColumn get path => text()();

  /// 来源远程 URL（重下/诊断用；手动设置的图为 null）。
  TextColumn get sourceUrl => text().nullable()();

  /// 单一归属：合集与视频二选一，恰好一个非空。
  @override
  List<String> get customConstraints => <String>[
        'CHECK ((collection_id IS NULL) != (book_uid IS NULL))',
      ];

  /// 同归属同种类同槽位唯一（重复刮削整组替换按此幂等）。两条唯一键分别覆盖两种
  /// 归属——SQLite 的 UNIQUE 对 NULL 不判等，各自只约束自己那种归属的行。
  @override
  List<Set<Column>> get uniqueKeys => [
        {collectionId, kind, position},
        {bookUid, kind, position},
      ];
}

// ── video_metadata_works（v77：视频规范作品资料）─────────────────────
// MoviePilot 风格来源刮削的规范宿主。一行是一部作品，归属本地合集（电视剧）或
// 独立视频（电影）二选一；旧 CollectionScrapeMeta / VideoScrapeMeta 继续作为兼容
// 投影，避免详情页一次性迁移。整组表均是可重建、本机路径相关缓存，不进入 live-sync。
@DataClassName('VideoMetadataWorkRow')
class VideoMetadataWorks extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 电视剧作品通常绑定合集；与 [bookUid] 恰好一个非空。
  IntColumn get collectionId => integer()
      .nullable()
      .references(MediaCollections, #id, onDelete: KeyAction.cascade)();

  /// 独立电影通常绑定视频；与 [collectionId] 恰好一个非空。
  TextColumn get bookUid => text()
      .nullable()
      .references(VideoBooks, #bookUid, onDelete: KeyAction.cascade)();

  /// `movie` | `tv`。值域由视频刮削域枚举维护，DB 保持前向兼容。
  TextColumn get mediaType => text()();
  TextColumn get title => text()();
  TextColumn get originalTitle => text().nullable()();
  TextColumn get overview => text().nullable()();
  TextColumn get tagline => text().nullable()();
  TextColumn get premiereDate => text().nullable()();
  TextColumn get endDate => text().nullable()();
  IntColumn get year => integer().nullable()();
  RealColumn get rating => real().nullable()();
  IntColumn get ratingCount => integer().nullable()();
  IntColumn get runtimeMinutes => integer().nullable()();
  TextColumn get contentRating => text().nullable()();
  TextColumn get status => text().nullable()();
  TextColumn get originalLanguage => text().nullable()();
  TextColumn get homepage => text().nullable()();

  /// TMDB 电视剧分组规则；NULL = 使用源默认季集编排。
  TextColumn get episodeGroupId => text().nullable()();
  IntColumn get updatedAt => integer()();

  @override
  List<String> get customConstraints => <String>[
        'CHECK ((collection_id IS NULL) != (book_uid IS NULL))',
      ];

  @override
  List<Set<Column>> get uniqueKeys => <Set<Column>>[
        <Column>{collectionId},
        <Column>{bookUid},
      ];
}

// ── video_metadata_seasons ──────────────────────────────────────────
@DataClassName('VideoMetadataSeasonRow')
class VideoMetadataSeasons extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get workId => integer()
      .references(VideoMetadataWorks, #id, onDelete: KeyAction.cascade)();
  IntColumn get seasonNumber => integer()();
  TextColumn get title => text().nullable()();
  TextColumn get overview => text().nullable()();
  TextColumn get premiereDate => text().nullable()();
  TextColumn get endDate => text().nullable()();
  IntColumn get year => integer().nullable()();
  IntColumn get episodeCount => integer().nullable()();
  RealColumn get rating => real().nullable()();
  IntColumn get updatedAt => integer()();

  @override
  List<Set<Column>> get uniqueKeys => <Set<Column>>[
        <Column>{workId, seasonNumber},
      ];
}

// ── video_metadata_episodes ─────────────────────────────────────────
@DataClassName('VideoMetadataEpisodeRow')
class VideoMetadataEpisodes extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get seasonId => integer()
      .references(VideoMetadataSeasons, #id, onDelete: KeyAction.cascade)();

  /// 可选的本地分集绑定。删视频只解绑，源侧季集骨架继续保留供重链。
  TextColumn get bookUid => text()
      .nullable()
      .unique()
      .references(VideoBooks, #bookUid, onDelete: KeyAction.setNull)();
  IntColumn get episodeNumber => integer()();
  IntColumn get absoluteNumber => integer().nullable()();
  TextColumn get title => text().nullable()();
  TextColumn get overview => text().nullable()();
  TextColumn get airDate => text().nullable()();
  IntColumn get year => integer().nullable()();
  RealColumn get rating => real().nullable()();
  IntColumn get ratingCount => integer().nullable()();
  IntColumn get runtimeMinutes => integer().nullable()();
  IntColumn get updatedAt => integer()();

  @override
  List<Set<Column>> get uniqueKeys => <Set<Column>>[
        <Column>{seasonId, episodeNumber},
      ];
}

// ── video_metadata_people / characters ──────────────────────────────
// TEXT 主键由抓取层生成（首个可用 provider + 外部 id；无 id 时使用规范化内容 hash），
// 让一次事务可在插入 credit 前确定引用，并允许多个 provider identity 汇聚到同一人。
@DataClassName('VideoMetadataPersonRow')
class VideoMetadataPeople extends Table {
  TextColumn get personKey => text()();
  TextColumn get name => text()();
  TextColumn get originalName => text().nullable()();
  TextColumn get biography => text().nullable()();
  TextColumn get birthday => text().nullable()();
  TextColumn get deathday => text().nullable()();
  IntColumn get gender => integer().nullable()();
  TextColumn get placeOfBirth => text().nullable()();
  TextColumn get profileUrl => text().nullable()();
  TextColumn get profilePath => text().nullable()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => <Column>{personKey};
}

@DataClassName('VideoMetadataCharacterRow')
class VideoMetadataCharacters extends Table {
  TextColumn get characterKey => text()();
  TextColumn get name => text()();
  TextColumn get description => text().nullable()();
  TextColumn get imageUrl => text().nullable()();
  TextColumn get imagePath => text().nullable()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => <Column>{characterKey};
}

// ── video_metadata_provider_identities / raw_snapshots ───────────────
@DataClassName('VideoMetadataProviderIdentityRow')
class VideoMetadataProviderIdentities extends Table {
  /// 抓取层稳定键：`<owner-kind>:<owner-key>:<provider>`。
  TextColumn get identityKey => text()();
  IntColumn get workId => integer()
      .nullable()
      .references(VideoMetadataWorks, #id, onDelete: KeyAction.cascade)();
  IntColumn get seasonId => integer()
      .nullable()
      .references(VideoMetadataSeasons, #id, onDelete: KeyAction.cascade)();
  IntColumn get episodeId => integer()
      .nullable()
      .references(VideoMetadataEpisodes, #id, onDelete: KeyAction.cascade)();
  TextColumn get personKey =>
      text().nullable().references(VideoMetadataPeople, #personKey,
          onDelete: KeyAction.cascade)();
  TextColumn get characterKey =>
      text().nullable().references(VideoMetadataCharacters, #characterKey,
          onDelete: KeyAction.cascade)();
  TextColumn get provider => text()();
  TextColumn get externalId => text()();
  TextColumn get externalUrl => text().nullable()();
  BoolColumn get isPrimary => boolean().withDefault(const Constant(false))();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => <Column>{identityKey};

  @override
  List<String> get customConstraints => <String>[
        'CHECK ((work_id IS NOT NULL) + (season_id IS NOT NULL) + '
            '(episode_id IS NOT NULL) + (person_key IS NOT NULL) + '
            '(character_key IS NOT NULL) = 1)',
      ];

  @override
  List<Set<Column>> get uniqueKeys => <Set<Column>>[
        <Column>{workId, provider},
        <Column>{seasonId, provider},
        <Column>{episodeId, provider},
        <Column>{personKey, provider},
        <Column>{characterKey, provider},
      ];
}

@DataClassName('VideoMetadataRawSnapshotRow')
class VideoMetadataRawSnapshots extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get identityKey =>
      text().references(VideoMetadataProviderIdentities, #identityKey,
          onDelete: KeyAction.cascade)();

  /// `details` / `credits` / `images` / `season` / `episode` 等响应类别。
  TextColumn get snapshotKind => text()();
  TextColumn get locale => text().nullable()();
  TextColumn get etag => text().nullable()();
  TextColumn get rawJson => text()();
  IntColumn get fetchedAt => integer()();
  IntColumn get expiresAt => integer().nullable()();

  @override
  List<Set<Column>> get uniqueKeys => <Set<Column>>[
        <Column>{identityKey, snapshotKind},
      ];
}

// ── video_metadata_terms / work_terms ───────────────────────────────
@DataClassName('VideoMetadataTermRow')
class VideoMetadataTerms extends Table {
  /// 抓取层稳定键：`<kind>:<normalized-name>`。
  TextColumn get termKey => text()();
  TextColumn get kind => text()(); // genre / studio / country / keyword
  TextColumn get name => text()();
  TextColumn get normalizedName => text()();

  @override
  Set<Column> get primaryKey => <Column>{termKey};

  @override
  List<Set<Column>> get uniqueKeys => <Set<Column>>[
        <Column>{kind, normalizedName},
      ];
}

@DataClassName('VideoMetadataWorkTermRow')
class VideoMetadataWorkTerms extends Table {
  IntColumn get workId => integer()
      .references(VideoMetadataWorks, #id, onDelete: KeyAction.cascade)();
  TextColumn get termKey => text()
      .references(VideoMetadataTerms, #termKey, onDelete: KeyAction.cascade)();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => <Column>{workId, termKey};
}

// ── video_metadata_credits ──────────────────────────────────────────
@DataClassName('VideoMetadataCreditRow')
class VideoMetadataCredits extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get workId => integer()
      .nullable()
      .references(VideoMetadataWorks, #id, onDelete: KeyAction.cascade)();
  IntColumn get seasonId => integer()
      .nullable()
      .references(VideoMetadataSeasons, #id, onDelete: KeyAction.cascade)();
  IntColumn get episodeId => integer()
      .nullable()
      .references(VideoMetadataEpisodes, #id, onDelete: KeyAction.cascade)();
  TextColumn get personKey => text().references(VideoMetadataPeople, #personKey,
      onDelete: KeyAction.cascade)();
  TextColumn get characterKey =>
      text().nullable().references(VideoMetadataCharacters, #characterKey,
          onDelete: KeyAction.setNull)();

  /// director / writer / actor / guest / voice_actor / producer 等。
  TextColumn get creditKind => text()();
  TextColumn get roleName => text().withDefault(const Constant(''))();
  TextColumn get department => text().nullable()();
  TextColumn get job => text().nullable()();
  TextColumn get language => text().nullable()();
  TextColumn get providerCreditId => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  List<String> get customConstraints => <String>[
        'CHECK ((work_id IS NOT NULL) + (season_id IS NOT NULL) + '
            '(episode_id IS NOT NULL) = 1)',
      ];

  @override
  List<Set<Column>> get uniqueKeys => <Set<Column>>[
        <Column>{workId, personKey, creditKind, roleName},
        <Column>{seasonId, personKey, creditKind, roleName},
        <Column>{episodeId, personKey, creditKind, roleName},
      ];
}

// ── video_metadata_images ───────────────────────────────────────────
// 保存远端候选与已落地图片。现有 MediaImages / coverPath 仍是 UI 兼容投影。
@DataClassName('VideoMetadataImageRow')
class VideoMetadataImages extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get workId => integer()
      .nullable()
      .references(VideoMetadataWorks, #id, onDelete: KeyAction.cascade)();
  IntColumn get seasonId => integer()
      .nullable()
      .references(VideoMetadataSeasons, #id, onDelete: KeyAction.cascade)();
  IntColumn get episodeId => integer()
      .nullable()
      .references(VideoMetadataEpisodes, #id, onDelete: KeyAction.cascade)();
  TextColumn get personKey =>
      text().nullable().references(VideoMetadataPeople, #personKey,
          onDelete: KeyAction.cascade)();
  TextColumn get characterKey =>
      text().nullable().references(VideoMetadataCharacters, #characterKey,
          onDelete: KeyAction.cascade)();
  TextColumn get provider => text()();

  /// poster / backdrop / logo / disc / banner / thumb / landscape / clearart。
  TextColumn get kind => text()();
  IntColumn get position => integer().withDefault(const Constant(0))();
  TextColumn get language => text().nullable()();
  TextColumn get remoteUrl => text()();
  TextColumn get localPath => text().nullable()();
  IntColumn get width => integer().nullable()();
  IntColumn get height => integer().nullable()();
  RealColumn get rating => real().nullable()();
  IntColumn get voteCount => integer().nullable()();
  TextColumn get sha256 => text().nullable()();
  IntColumn get updatedAt => integer()();

  @override
  List<String> get customConstraints => <String>[
        'CHECK ((work_id IS NOT NULL) + (season_id IS NOT NULL) + '
            '(episode_id IS NOT NULL) + (person_key IS NOT NULL) + '
            '(character_key IS NOT NULL) = 1)',
      ];

  @override
  List<Set<Column>> get uniqueKeys => <Set<Column>>[
        <Column>{workId, kind, position},
        <Column>{seasonId, kind, position},
        <Column>{episodeId, kind, position},
        <Column>{personKey, kind, position},
        <Column>{characterKey, kind, position},
      ];
}

// ── video_metadata_extras（v77：作品预告片 / 花絮）────────────────────
// 在线附件不创建 VideoBook；本地附件复用已经入库的 VideoBook 并以 bookUid 关联。
// extraKey 由上层生成稳定身份：`local:<bookUid>` 或 `<provider>:<video-id>`。
@DataClassName('VideoMetadataExtraRow')
class VideoMetadataExtras extends Table {
  TextColumn get extraKey => text()();
  IntColumn get workId => integer()
      .references(VideoMetadataWorks, #id, onDelete: KeyAction.cascade)();
  TextColumn get bookUid => text()
      .nullable()
      .unique()
      .references(VideoBooks, #bookUid, onDelete: KeyAction.setNull)();

  /// trailer / teaser / clip / featurette / interview / behind_the_scenes /
  /// deleted_scene / short / scene / sample / extra。
  TextColumn get kind => text()();
  TextColumn get sourceKind => text()(); // local / online
  TextColumn get title => text()();
  TextColumn get provider => text().nullable()();
  TextColumn get providerVideoId => text().nullable()();
  TextColumn get site => text().nullable()();
  TextColumn get remoteUrl => text().nullable()();
  TextColumn get thumbnailUrl => text().nullable()();
  TextColumn get thumbnailPath => text().nullable()();
  IntColumn get durationMs => integer().nullable()();
  BoolColumn get official => boolean().withDefault(const Constant(false))();
  TextColumn get language => text().nullable()();
  TextColumn get publishedAt => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => <Column>{extraKey};

  @override
  List<String> get customConstraints => <String>[
        "CHECK (source_kind IN ('local', 'online'))",
        "CHECK ((source_kind = 'local' AND book_uid IS NOT NULL) OR "
            "(source_kind = 'online' AND remote_url IS NOT NULL))",
      ];
}

// ── video_source_scrape_settings / runs ─────────────────────────────
@DataClassName('VideoSourceScrapeSettingRow')
class VideoSourceScrapeSettings extends Table {
  IntColumn get sourceId =>
      integer().references(MediaSources, #id, onDelete: KeyAction.cascade)();

  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  /// NULL = 继承全局默认；非空 = tmdb / douban / bangumi / anilist。
  TextColumn get providerOverride => text().nullable()();
  BoolColumn get autoAfterScan =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get writeNfo => boolean().withDefault(const Constant(true))();
  BoolColumn get writeImages => boolean().withDefault(const Constant(true))();
  BoolColumn get fanartEnabled => boolean().withDefault(const Constant(true))();
  TextColumn get nfoPolicy =>
      text().withDefault(const Constant('missingOnly'))();
  TextColumn get imagePolicy =>
      text().withDefault(const Constant('missingOnly'))();
  BoolColumn get allowExternalOverwrite =>
      boolean().withDefault(const Constant(false))();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => <Column>{sourceId};
}

@DataClassName('VideoSourceScrapeRunRow')
class VideoSourceScrapeRuns extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// NULL 表示「全部来源」批次，或来源行删除后保留的审计摘要。
  IntColumn get sourceId => integer()
      .nullable()
      .references(MediaSources, #id, onDelete: KeyAction.setNull)();
  TextColumn get scope => text()(); // source / all
  TextColumn get status => text()(); // queued / running / completed / ...
  TextColumn get provider => text().nullable()();
  TextColumn get phase => text().nullable()();
  IntColumn get totalWorks => integer().withDefault(const Constant(0))();
  IntColumn get processedWorks => integer().withDefault(const Constant(0))();
  IntColumn get succeededWorks => integer().withDefault(const Constant(0))();
  IntColumn get failedWorks => integer().withDefault(const Constant(0))();
  IntColumn get pendingConfirmations =>
      integer().withDefault(const Constant(0))();
  TextColumn get currentWorkTitle => text().nullable()();
  TextColumn get summaryJson => text().nullable()();
  TextColumn get lastError => text().nullable()();
  IntColumn get startedAt => integer()();
  IntColumn get updatedAt => integer()();
  IntColumn get finishedAt => integer().nullable()();
}

// ── video_sidecar_artifacts ─────────────────────────────────────────
@DataClassName('VideoSidecarArtifactRow')
class VideoSidecarArtifacts extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 来源移除只解除关联；媒体旁已有文件及本行 hash/所有权记录全部保留。
  IntColumn get sourceId => integer()
      .nullable()
      .references(MediaSources, #id, onDelete: KeyAction.setNull)();
  IntColumn get runId => integer()
      .nullable()
      .references(VideoSourceScrapeRuns, #id, onDelete: KeyAction.setNull)();
  IntColumn get workId => integer()
      .nullable()
      .references(VideoMetadataWorks, #id, onDelete: KeyAction.setNull)();
  IntColumn get seasonId => integer()
      .nullable()
      .references(VideoMetadataSeasons, #id, onDelete: KeyAction.setNull)();
  IntColumn get episodeId => integer()
      .nullable()
      .references(VideoMetadataEpisodes, #id, onDelete: KeyAction.setNull)();
  TextColumn get artifactKind => text()(); // nfo / poster / backdrop / ...

  /// 规范绝对路径；同一个物理 sidecar 只保留一条所有权记录。
  TextColumn get path => text().unique()();
  TextColumn get sha256 => text()();
  IntColumn get fileSize => integer().nullable()();
  TextColumn get generatorVersion => text()();
  TextColumn get writePolicy => text()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  /// owner 被删后三个 FK 可全部 setNull，artifact 审计行仍有效；但任一时刻不能同时
  /// 冒充多个层级的资产。
  @override
  List<String> get customConstraints => <String>[
        'CHECK ((work_id IS NOT NULL) + (season_id IS NOT NULL) + '
            '(episode_id IS NOT NULL) <= 1)',
      ];
}

// ── durable video download pipeline（v78）────────────────────────────
//
// 下载任务是跨进程、跨重启的工作流真相源。`lifecycle` 只表达任务是否还能推进，
// `stage` 只表达当前推进到哪一步；失败/需关注不能靠把 stage 改成 `failed` 来编码，
// 否则恢复时无法知道该从下载、字幕还是整理阶段继续。
abstract final class VideoDownloadJobLifecycle {
  static const String active = 'active';
  static const String needsAttention = 'needsAttention';
  static const String completed = 'completed';
  static const String failed = 'failed';
  static const String cancelled = 'cancelled';
}

abstract final class VideoDownloadJobStage {
  static const String enqueue = 'enqueue';
  static const String download = 'download';
  static const String organize = 'organize';
  static const String subtitle = 'subtitle';
  static const String import = 'import';
  static const String scrape = 'scrape';
}

/// 网页播放器自动制卡队列（schema v93）。
///
/// 观看网页流媒体（Netflix 等）时点「制卡」**只入队**：观看档可能是硬件 DRM 的 4K 窗口宿主
/// 模式（画面不可捕获、无本地媒体源），录不了句子音频/截不了帧。之后在可捕获的 1080p
/// 内置档里按队列逐句重放：seek → 播 → WASAPI loopback 录音 + 截帧 → 走沉浸制卡引擎落卡。
/// 每行冻结点击那一刻的 Anki 字段 JSON（词典释义等）与 cue 时间窗；重放只补媒体。
///
/// 设备本地：含站点页 URL、本机重放状态，不进备份/同步（与 `video_download_jobs` 同列
/// 于 backup 的 device-local 清单）。
@DataClassName('WebMineQueueRow')
class WebMineQueue extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 书架流媒体书 uid（`video/stream/…`）。
  TextColumn get bookUid => text()();

  /// 站点内视频身份（`fushiVideoKey`，如 Netflix 的 `/watch/<id>`）与页面 URL（重放时导航）。
  TextColumn get videoKey => text()();
  TextColumn get href => text()();

  IntColumn get cueStartMs => integer()();
  IntColumn get cueEndMs => integer()();

  /// 制卡句（多句合并后的整句）与锚点 cue 原句。
  TextColumn get sentence => text()();
  TextColumn get cueSentence => text().nullable()();

  /// 弹窗点击时的 Anki 字段映射（`Map<String,String>` JSON），重放时原样喂引擎。
  TextColumn get fieldsJson => text()();

  /// [WebMineQueueStatus]。
  TextColumn get status => text().withDefault(const Constant('pending'))();
  TextColumn get error => text().nullable()();

  /// 成功后的 Anki note id（AnkiDroid 后端恒 null）。
  IntColumn get noteId => integer().nullable()();

  IntColumn get createdAt => integer()();
  IntColumn get minedAt => integer().nullable()();
}

abstract final class WebMineQueueStatus {
  static const String pending = 'pending';
  static const String done = 'done';
  static const String failed = 'failed';
}

@DataClassName('VideoDownloadJobRow')
class VideoDownloadJobs extends Table {
  /// 调用方生成的稳定任务 id；不能用自增 id 充当跨崩溃幂等键。
  TextColumn get jobId => text()();

  /// 资源来源与用户选中的来源条目身份（例如 provider + torrent item id）。
  TextColumn get resourceProvider => text()();
  TextColumn get selectedResourceId => text()();

  /// 允许持久化的下载 locator 只有 magnet。Torznab 临时 HTTP/metainfo URL 含短期
  /// token，绝不能落库；需要时用 selectedResourceId 向 provider 重新 resolve。
  TextColumn get magnetUri => text().nullable()();
  TextColumn get resourceTitle => text().nullable()();

  /// torrent 在后端确认 enqueue 后才一定可得，故保持 nullable。
  TextColumn get torrentHash => text().nullable()();

  /// 发现/元数据身份。两列必须同时为空或同时有值。
  TextColumn get metadataProvider => text().nullable()();
  TextColumn get externalId => text().nullable()();
  TextColumn get mediaKind => text()();
  TextColumn get discoveryCategory => text().nullable()();
  TextColumn get title => text()();
  IntColumn get year => integer().nullable()();
  IntColumn get season => integer().nullable()();
  TextColumn get coverUrl => text().nullable()();

  /// v94：发现页完整身份快照（`VideoMediaReference` 的 JSON：原名/别名/全部
  /// 外部 id）。修 BUG-2003——修前入队只留显示名 + 单 provider id，刮削与字幕
  /// 在下游各自从残渣重新猜身份。NULL = 旧任务/手动任务，走旧行为。
  TextColumn get identityJson => text().nullable()();

  /// 后端连接身份与去重身份。敏感凭据不进数据库；backendProfileId 是下载配置档
  /// 的字符串身份，不是 Hibiki 用户 Profile，故没有 FK 到 Profiles。
  TextColumn get backendKind => text()();
  TextColumn get backendTaskId => text().nullable()();
  TextColumn get backendProfileId => text().nullable()();
  TextColumn get fingerprint => text()();
  TextColumn get category => text().nullable()();

  /// 目标来源库/合集被删时任务审计仍保留，只解除绑定。
  IntColumn get targetSourceId => integer()
      .nullable()
      .references(MediaSources, #id, onDelete: KeyAction.setNull)();
  IntColumn get collectionId => integer()
      .nullable()
      .references(MediaCollections, #id, onDelete: KeyAction.setNull)();
  TextColumn get organizationPolicy =>
      text().withDefault(const Constant('library'))();
  TextColumn get subtitlePolicy =>
      text().withDefault(const Constant('bestEffort'))();

  /// 下载后端观察到的保存根与最终应落到 source library 下的相对根。
  TextColumn get observedSavePath => text().nullable()();
  TextColumn get targetRelativeRoot => text().nullable()();

  TextColumn get lifecycle =>
      text().withDefault(const Constant(VideoDownloadJobLifecycle.active))();
  TextColumn get stage =>
      text().withDefault(const Constant(VideoDownloadJobStage.enqueue))();
  RealColumn get stageProgress => real().withDefault(const Constant(0.0))();
  IntColumn get priority => integer().withDefault(const Constant(0))();

  /// attemptCount 只在可重试错误时递增；正常轮询/lease claim 不消耗重试预算。
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();
  IntColumn get maxAttempts => integer().withDefault(const Constant(3))();
  IntColumn get nextAttemptAt => integer().nullable()();
  TextColumn get claimedBy => text().nullable()();
  IntColumn get claimExpiresAt => integer().nullable()();
  TextColumn get lastError => text().nullable()();

  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  IntColumn get completedAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => <Column>{jobId};

  @override
  List<String> get customConstraints => <String>[
        "CHECK (job_id != '' AND resource_provider != '' AND "
            "selected_resource_id != '' AND media_kind != '' AND title != '' "
            "AND backend_kind != '' AND fingerprint != '')",
        'CHECK ((metadata_provider IS NULL) = (external_id IS NULL))',
        "CHECK (lifecycle IN ('active', 'needsAttention', 'completed', "
            "'failed', 'cancelled'))",
        "CHECK (stage IN ('enqueue', 'download', 'organize', 'subtitle', "
            "'import', 'scrape'))",
        'CHECK (stage_progress >= 0.0 AND stage_progress <= 1.0)',
        'CHECK (attempt_count >= 0 AND max_attempts > 0)',
        'CHECK (year IS NULL OR year >= 0)',
        'CHECK (season IS NULL OR season >= 0)',
        "CHECK (magnet_uri IS NULL OR magnet_uri LIKE 'magnet:%')",
        'CHECK ((claimed_by IS NULL) = (claim_expires_at IS NULL))',
        "CHECK (claimed_by IS NULL OR lifecycle = 'active')",
      ];
}

abstract final class VideoDownloadJobFileStatus {
  static const String pending = 'pending';
  static const String downloading = 'downloading';
  static const String downloaded = 'downloaded';
  static const String organized = 'organized';
  static const String imported = 'imported';
  static const String skipped = 'skipped';
  static const String failed = 'failed';
}

@DataClassName('VideoDownloadJobFileRow')
class VideoDownloadJobFiles extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get jobId => text()
      .references(VideoDownloadJobs, #jobId, onDelete: KeyAction.cascade)();
  IntColumn get backendFileIndex => integer().nullable()();
  TextColumn get originalRelativePath => text()();
  TextColumn get currentRelativePath => text()();
  TextColumn get targetRelativePath => text().nullable()();
  TextColumn get finalAbsolutePath => text().nullable()();
  TextColumn get kind => text().withDefault(const Constant('other'))();
  IntColumn get season => integer().nullable()();
  IntColumn get episode => integer().nullable()();
  IntColumn get sizeBytes => integer().nullable()();
  BoolColumn get selected => boolean().withDefault(const Constant(true))();
  TextColumn get status =>
      text().withDefault(const Constant(VideoDownloadJobFileStatus.pending))();
  TextColumn get error => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  List<Set<Column>> get uniqueKeys => <Set<Column>>[
        <Column>{jobId, originalRelativePath},
        <Column>{jobId, backendFileIndex},
      ];

  @override
  List<String> get customConstraints => <String>[
        "CHECK (original_relative_path != '' AND current_relative_path != '')",
        "CHECK (kind IN ('video', 'subtitle', 'extra', 'other'))",
        "CHECK (status IN ('pending', 'downloading', 'downloaded', "
            "'organized', 'imported', 'skipped', 'failed'))",
        'CHECK (backend_file_index IS NULL OR backend_file_index >= 0)',
        'CHECK (season IS NULL OR season >= 0)',
        'CHECK (episode IS NULL OR episode >= 0)',
        'CHECK (size_bytes IS NULL OR size_bytes >= 0)',
      ];
}

abstract final class VideoDownloadJobSubtitleStatus {
  static const String pending = 'pending';
  static const String resolving = 'resolving';
  static const String staged = 'staged';
  static const String placed = 'placed';
  static const String unavailable = 'unavailable';
  static const String skipped = 'skipped';
  static const String failed = 'failed';
}

@DataClassName('VideoDownloadJobSubtitleRow')
class VideoDownloadJobSubtitles extends Table {
  TextColumn get subtitleId => text()();
  TextColumn get jobId => text()
      .references(VideoDownloadJobs, #jobId, onDelete: KeyAction.cascade)();
  IntColumn get jobFileId => integer()
      .nullable()
      .references(VideoDownloadJobFiles, #id, onDelete: KeyAction.setNull)();
  TextColumn get provider => text()();
  TextColumn get selectedSubtitleId => text().nullable()();
  TextColumn get language => text().nullable()();
  IntColumn get season => integer().nullable()();
  IntColumn get episode => integer().nullable()();
  TextColumn get originalFileName => text().nullable()();
  TextColumn get stagedPath => text().nullable()();
  TextColumn get finalPath => text().nullable()();
  TextColumn get status => text()
      .withDefault(const Constant(VideoDownloadJobSubtitleStatus.pending))();
  TextColumn get error => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => <Column>{subtitleId};

  @override
  List<String> get customConstraints => <String>[
        "CHECK (subtitle_id != '' AND provider != '')",
        "CHECK (status IN ('pending', 'resolving', 'staged', 'placed', "
            "'unavailable', 'skipped', 'failed'))",
        'CHECK (season IS NULL OR season >= 0)',
        'CHECK (episode IS NULL OR episode >= 0)',
      ];
}

@DataClassName('VideoDownloadSubscriptionRow')
class VideoDownloadSubscriptions extends Table {
  TextColumn get subscriptionId => text()();
  TextColumn get resourceProvider => text()();
  TextColumn get metadataProvider => text().nullable()();
  TextColumn get externalId => text().nullable()();
  TextColumn get mediaKind => text()();
  TextColumn get discoveryCategory => text().nullable()();
  TextColumn get title => text()();
  IntColumn get year => integer().nullable()();
  IntColumn get season => integer().nullable()();
  TextColumn get coverUrl => text().nullable()();

  /// v94：发现页完整身份快照（同 `video_download_jobs.identity_json`）。订阅
  /// 轮询用它恢复原名/别名做多名字资源搜索兜底。NULL = 旧订阅，走旧行为。
  TextColumn get identityJson => text().nullable()();

  /// searchQuery + filterJson 是来源无关的订阅选择快照；filterJson 禁止放凭据。
  TextColumn get searchQuery => text()();
  TextColumn get filterJson => text().withDefault(const Constant('{}'))();
  TextColumn get mode => text().withDefault(const Constant('ongoing'))();
  IntColumn get startAfterEpisode => integer().nullable()();

  TextColumn get backendKind => text()();
  TextColumn get backendProfileId => text().nullable()();
  TextColumn get fingerprint => text()();
  TextColumn get category => text().nullable()();
  IntColumn get targetSourceId => integer()
      .nullable()
      .references(MediaSources, #id, onDelete: KeyAction.setNull)();
  IntColumn get collectionId => integer()
      .nullable()
      .references(MediaCollections, #id, onDelete: KeyAction.setNull)();
  TextColumn get organizationPolicy =>
      text().withDefault(const Constant('library'))();
  TextColumn get subtitlePolicy =>
      text().withDefault(const Constant('bestEffort'))();

  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  IntColumn get nextCheckAt => integer().nullable()();
  TextColumn get claimedBy => text().nullable()();
  IntColumn get claimExpiresAt => integer().nullable()();
  IntColumn get retryCount => integer().withDefault(const Constant(0))();
  IntColumn get lastCheckedAt => integer().nullable()();
  IntColumn get lastMatchedAt => integer().nullable()();
  IntColumn get fulfilledAt => integer().nullable()();
  TextColumn get lastError => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => <Column>{subscriptionId};

  @override
  List<String> get customConstraints => <String>[
        "CHECK (subscription_id != '' AND resource_provider != '' AND "
            "media_kind != '' AND title != '' AND search_query != '' AND "
            "backend_kind != '' AND fingerprint != '')",
        'CHECK ((metadata_provider IS NULL) = (external_id IS NULL))',
        "CHECK (mode IN ('oneShot', 'ongoing'))",
        'CHECK (year IS NULL OR year >= 0)',
        'CHECK (season IS NULL OR season >= 0)',
        'CHECK (start_after_episode IS NULL OR start_after_episode >= 0)',
        'CHECK (retry_count >= 0)',
        'CHECK ((claimed_by IS NULL) = (claim_expires_at IS NULL))',
        "CHECK (fulfilled_at IS NULL OR (mode = 'oneShot' AND enabled = 0))",
      ];
}

abstract final class VideoDownloadSubscriptionItemStatus {
  static const String discovered = 'discovered';
  static const String queued = 'queued';
  static const String processed = 'processed';
  static const String skipped = 'skipped';
  static const String failed = 'failed';
}

@DataClassName('VideoDownloadSubscriptionItemRow')
class VideoDownloadSubscriptionItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get subscriptionId =>
      text().references(VideoDownloadSubscriptions, #subscriptionId,
          onDelete: KeyAction.cascade)();
  TextColumn get logicalItemKey => text()();
  TextColumn get resourceProvider => text()();
  TextColumn get selectedResourceId => text()();
  TextColumn get torrentHash => text().nullable()();
  TextColumn get title => text()();
  IntColumn get season => integer().nullable()();
  IntColumn get episode => integer().nullable()();
  IntColumn get publishedAt => integer().nullable()();
  TextColumn get jobId => text()
      .nullable()
      .references(VideoDownloadJobs, #jobId, onDelete: KeyAction.setNull)();
  TextColumn get status => text().withDefault(
      const Constant(VideoDownloadSubscriptionItemStatus.discovered))();
  TextColumn get error => text().nullable()();
  IntColumn get discoveredAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  List<Set<Column>> get uniqueKeys => <Set<Column>>[
        <Column>{subscriptionId, logicalItemKey},
        <Column>{subscriptionId, resourceProvider, selectedResourceId},
      ];

  @override
  List<String> get customConstraints => <String>[
        "CHECK (logical_item_key != '' AND resource_provider != '' AND "
            "selected_resource_id != '' AND title != '')",
        "CHECK (status IN ('discovered', 'queued', 'processed', 'skipped', "
            "'failed'))",
        'CHECK (season IS NULL OR season >= 0)',
        'CHECK (episode IS NULL OR episode >= 0)',
      ];
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

  /// v88：游戏文本的内容语言（BCP-47），决定 hook 文本浮窗与查词卡用哪条字体链。
  ///
  /// hook 出来的文本没有任何语言声明可读，所以这一列只能由用户指定；null = 未知。
  /// 不要因为「galgame 多半是日文」就默认 ja——那是全局假设，本仓不做这种假设。
  TextColumn get language => text().nullable()();

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

  /// 该游戏的「日语区域（转区）」档位：`'auto'` / `'on'` / `'off'`（BUG-1477）。
  ///
  /// 空串 = 用户没设过，解析层回落 `auto`（**不是** off —— 转区是用户明确要过的
  /// 功能，老行/老用户不能因为加了这一列就被莫名关掉）。
  ///
  /// 与 [upscalingMode] / [launchArgs] 同类，都是「用户为该游戏设的启动期配置」。
  /// 为什么必须每游戏一档而不是全局开关：同一个库里日文原版和汉化版并存，
  /// 汉化版转区会直接闪退，日文原版不转区会乱码，全局值两边都不对。
  TextColumn get japaneseLocaleMode => text().withDefault(const Constant(''))();

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

// ── study_segments ──────────────────────────────────────────────────
/// v92（统计域根本性重构）：学习时长 / 字数 / 页数的**唯一事实表**。
///
/// 此前同一段学习被并行写进 `reading_statistics` / `video_watch_statistics`（日聚合）、
/// `reading_hourly_logs` / `video_hourly_logs`（小时桶）、`activity_events`（session
/// 行）三种投影，全部 `+=` 累加、无任何幂等键——任何写入路径 flush 两次（dispose 与
/// 进程退出并发、生命周期抖动、hot restart）日汇总就永久翻倍，且身份用 title
/// （同名书 / 裸集号 `S01E01` 跨作品互串）。本表照 [GalgameSessions] 的模式重做：
/// 一段一行、按稳定媒体身份键控、**绝对值 upsert**。
///
/// 写法只有一种：[FushiDatabase.upsertStudySegment] —— `INSERT ... ON CONFLICT(uid)
/// DO UPDATE` 写**绝对值**。写入方持有自己当前打开段的内存累计器，每个 tick 把绝对值
/// 写回同一 [uid]；重复 flush = 同值覆盖 = no-op，重复计数在数据结构上不可能。
///
/// 段不跨本地小时边界（写入方在边界换新 uid），故 [dateKey] / [hour] 精确，小时图与
/// 日总量从同一批行派生、永不打架。一个 3 小时 session ≈ 3~4 行，年级数据千行量级，
/// 读取端直接 GROUP BY。
///
/// 旧四张投影表**冻结为 legacy**：v92 起本地写入面永不再写（守卫测试钉死），读取侧
/// 把 legacy 行（v92 前日期）与本表并集（时间上不相交，零合成零双计）。不迁移旧数据：
/// 日汇总行没 hour、小时行没 title，任何合成都得丢一维或双计。
@DataClassName('StudySegmentRow')
class StudySegments extends Table {
  /// 写入方生成的幂等键（32 位 hex，见 [FushiDatabase.newStudySegmentUid]）。
  TextColumn get uid => text()();

  /// 产生本段的设备（`sync_device_id` 偏好，见 [FushiDatabase.getOrCreateStudyDeviceId]）。
  /// 同步 v2 按 (uid) 并集时它是 provenance，不进任何合并判据。
  TextColumn get deviceId => text()();

  /// 'book' | 'video' | 'game'（[ActivityMediaKind.dbValue] 同值域）。
  TextColumn get mediaKind => text()();

  /// 稳定媒体身份：书=bookKey，视频=bookUid，游戏=galgames.id。**永不用 title**。
  TextColumn get mediaKey => text()();

  /// 写入面：'epub' | 'pdf' | 'manga'（[BookFormat.dbValue]），非书面 ''。
  TextColumn get format => text().withDefault(const Constant(''))();

  /// 展示快照：库表 join 不到（媒体已删）时回退显示，不参与任何分组。
  TextColumn get title => text()();

  /// 段起始 / 结束毫秒戳。[endAt] 随 tick 前进；`endAt - startAt >= durationMs`。
  IntColumn get startAt => integer()();
  IntColumn get endAt => integer()();

  /// [startAt] 的本地 `yyyy-MM-dd` 与小时（段不跨小时边界，故两者精确）。
  TextColumn get dateKey => text()();
  IntColumn get hour => integer()();

  /// 活跃时长（毫秒，已过前台 / 播放态 / 空闲 / 断档守卫）。
  IntColumn get durationMs => integer().withDefault(const Constant(0))();

  /// 字数（书 / 漫画 OCR = 实义字符；视频 = 字幕字符；游戏 = hook 文本）。
  IntColumn get chars => integer().withDefault(const Constant(0))();

  /// 页数（漫画 / PDF；EPUB 恒 0）。
  IntColumn get pages => integer().withDefault(const Constant(0))();

  /// 最后写入毫秒戳：同步 v2 同 uid 取大者（LWW），墓碑仲裁用它与 deletedAt 比。
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {uid};
}

// ── study_segment_tombstones ────────────────────────────────────────
/// v92：按**媒体身份**的统计删除墓碑，取代按 (title, sourceType) 的
/// [StatisticsTombstones]（那张只为 legacy 表的 title 粒度 wire 服务，冻结）。
///
/// 删某媒体统计 = 删其全部 [StudySegments] + 立本碑。仲裁（BUG-2214 / BUG-2220）：
/// 段 `startAt < deletedAt` → 被压制（同步 / 备份里的旧段不复活）；`startAt >= deletedAt`
/// 的段（删后又读）照常存活。**碑永不退场**、时间戳只增不减——旧口径「段
/// `updatedAt > deletedAt` 则段胜」已废：同步回写会刷新 `updatedAt`，让删掉的旧段
/// 借道复活。真实实现见 `database_statistics.part.dart` 的 `_isStudySegmentTombstoned`
/// 与 `aggregate_merge_service.dart`。
@DataClassName('StudySegmentTombstoneRow')
class StudySegmentTombstones extends Table {
  TextColumn get mediaKind => text()();
  TextColumn get mediaKey => text()();
  IntColumn get deletedAt => integer()();

  @override
  Set<Column> get primaryKey => {mediaKind, mediaKey};
}

// （v79：galgame_tag_mappings 已并入 [TagAssignments]。与游戏**元数据标签**
// （bgm/vndb 刮削字符串，存 [GalgameSources].dataJson + [Galgames].customDataJson）
// 仍是两条正交轴，刻意不合并：元数据标签是外部事实、动辄上百个且随刮削变动，
// 塞进用户标签池会污染书/视频共享的那份手工标签。游戏标签依旧不进 live-sync /
// 备份合并导入（合并层按 kind 过滤），全量备份恢复走整库文件拷贝原样还原。）

// ── manga_extension_stores ──────────────────────────────────────────
/// v65：用户自行添加的 Mihon 扩展仓库。Fushi 不预置第三方仓库。
/// （本迁移在 PR 分支上先后写作 v63 / v64，两次都与 develop 已落地的迁移撞号，
///  最终顺延到 v65；见 database.dart 的 `if (from < 65)` 块。）
@DataClassName('MangaExtensionStoreRow')
class MangaExtensionStores extends Table {
  /// 仓库入口 URL 同时是稳定身份；更新时 URL 不随仓库显示名变化。
  TextColumn get indexUrl => text()();
  TextColumn get name => text()();
  TextColumn get badgeLabel => text().nullable()();
  TextColumn get signingKey => text().nullable()();
  TextColumn get contactJson => text().nullable()();
  TextColumn get format => text()();
  TextColumn get extensionListUrl => text().nullable()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  TextColumn get etag => text().nullable()();
  TextColumn get lastModified => text().nullable()();
  IntColumn get lastSyncAt => integer().nullable()();
  TextColumn get lastError => text().nullable()();

  @override
  Set<Column> get primaryKey => {indexUrl};
}

// ── manga_extensions ────────────────────────────────────────────────
/// 已安装的私有 Mihon 扩展。APK 只放应用私有目录，本表保存相对路径与校验身份。
@DataClassName('MangaExtensionRow')
class MangaExtensions extends Table {
  TextColumn get packageName => text()();
  TextColumn get storeUrl => text().nullable()();
  TextColumn get name => text()();
  IntColumn get versionCode => integer()();
  TextColumn get versionName => text()();
  TextColumn get libVersion => text()();
  TextColumn get language => text()();
  IntColumn get contentWarning => integer().withDefault(const Constant(0))();
  TextColumn get apkPath => text()();
  TextColumn get apkSha256 => text()();
  TextColumn get signerSha256 => text()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  IntColumn get installedAt => integer()();

  @override
  Set<Column> get primaryKey => {packageName};
}

// ── manga_online_sources ────────────────────────────────────────────
/// 一个扩展可以通过 SourceFactory 暴露多个来源，故按 packageName + sourceId 复合键。
@DataClassName('MangaOnlineSourceRow')
class MangaOnlineSources extends Table {
  TextColumn get extensionPackage => text()();

  /// Mihon 的 Long ID 以十进制字符串保存，避免跨 MethodChannel/JSON 精度损失。
  TextColumn get sourceId => text()();
  TextColumn get name => text()();
  TextColumn get language => text()();
  TextColumn get baseUrl => text().withDefault(const Constant(''))();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {extensionPackage, sourceId};
}

// ── manga_source_preferences ────────────────────────────────────────
/// 来源偏好的平台无关快照。Cookie/请求头不进本表，也禁止写日志。
@DataClassName('MangaSourcePreferenceRow')
class MangaSourcePreferences extends Table {
  TextColumn get extensionPackage => text()();
  TextColumn get sourceId => text()();
  TextColumn get preferenceKey => text()();
  TextColumn get preferenceType => text()();
  TextColumn get valueJson => text()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {extensionPackage, sourceId, preferenceKey};
}

// ── manga_trusted_signers ───────────────────────────────────────────
/// 用户明确确认过的扩展签名证书 SHA-256；首次安装和换签都必须经过信任门。
@DataClassName('MangaTrustedSignerRow')
class MangaTrustedSigners extends Table {
  TextColumn get fingerprint => text()();
  TextColumn get label => text()();
  TextColumn get origin => text()();
  IntColumn get trustedAt => integer()();

  @override
  Set<Column> get primaryKey => {fingerprint};
}

// ── manga_chapter_states ────────────────────────────────────────────
/// 在线漫画的**每章**阅读状态。
///
/// 为什么必须是独立一张表：`ReaderPositions.bookUid` 是 `unique()`——一本书恒一
/// 条位置。在线漫画一本书下有几十上百章，那一条位置只能表达「当前章读到第几
/// 页」，于是换章时只能把它清零（v88 前 `MihonLibraryService.selectChapter` 正是
/// 这么做的），上一章的位置永久丢失，也无从知道哪些章读过。
///
/// 本表把「章」升成一等实体，同时解决三件事：
/// - **已读标记**：`readAt != null` = 这章读完了（作品页章节列表据此分实心/空心）。
/// - **换章不丢进度**：切回旧章时从 `lastPage` 恢复，不再归零。
/// - **继续阅读**：作品页据 `updatedAt` 最大的一条决定「继续阅读」落到哪章哪页。
///
/// 身份用 `(bookUid, chapterKey)`：`bookUid` 对齐 v82 起的书稳定身份（与
/// `ReaderPositions` 同族，改名不丢位置）；`chapterKey` 是**源内**章节身份
/// （Mihon = `chapter.url`，Aidoku = `chapter['key']`）。源刷新后章节顺序和索引
/// 都可能变，但 key 稳定——所以这里刻意不存 index。
///
/// 刻意无 FK：与 `ReaderPositions` 同样跨书族，孤儿防线在应用层
/// （`deleteEpubBook` 显式清理）。
@DataClassName('MangaChapterStateRow')
class MangaChapterStates extends Table {
  /// 书稳定身份，= `EpubBooks.uid`（与 `ReaderPositions.bookUid` 同一族）。
  TextColumn get bookUid => text()();

  /// 源内章节身份。Mihon = `chapter.url`；Aidoku = `chapter['key']`。
  TextColumn get chapterKey => text()();

  /// 该章读到的 0-based 页码。
  IntColumn get lastPage => integer().withDefault(const Constant(0))();

  /// webtoon 页内分数（千分比 0..1000），与 `ReaderPositions.charOffset` 同编码。
  /// -1 = 无精确偏移。
  IntColumn get lastFraction => integer().withDefault(const Constant(-1))();

  /// 该章总页数；拉过页表才知道，未知为 NULL。
  IntColumn get pageCount => integer().nullable()();

  /// 读完时刻（毫秒）。NULL = 未读完（可能读了一部分，看 [lastPage]）。
  IntColumn get readAt => integer().nullable()();

  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {bookUid, chapterKey};
}

// ── video_file_specs ──────────────────────────────────────────────────
/// 本地视频文件的技术规格探测缓存（schema v95）。
///
/// 库页卡片与作品详情页要标注清晰度 / HDR / 编码 / 音轨，而这些事实此前**在库里一个
/// 字节都没有**——`VideoBooks` 连 duration 列都没有，规格只在播放时活在 mpv 的内存里
/// （`video_hdr_output.dart` 的 HDR 判据），播完即丢。列表要显示就必须能在**不播放**的
/// 前提下拿到，于是有了这张表。
///
/// **身份键是文件路径，不是 bookUid**，这是本表唯一重要的设计决定：一个 `VideoBooks`
/// 行可能是多集播放列表（`playlist_json` 里若干条路径），各集的分辨率/音轨完全可以不同。
/// 把规格挂到 book 上，多集就只剩一份规格，必然是错的；挂到文件上，单文件与多集走同一
/// 条路径，不需要为「这本书是不是播放列表」写任何分支。
///
/// **纯缓存，可随时重建**：所有列都能由 ffprobe 从文件本身重新探出来。因此
/// - 探测失败不写行（宁可下次重试，不缓存一个空壳）；
/// - 文件大小或修改时刻变了就重探（用户换了个片源、补了音轨）；
/// - [probeVersion] 变了也重探（探测器扩了字段集，旧行的新字段是空的）。
///
/// 设备本地：路径与探测结果都只对本机有意义，不进备份/同步（与 `video_download_jobs`
/// 同列于 backup 的 device-local 清单）。
@DataClassName('VideoFileSpecRow')
class VideoFileSpecs extends Table {
  /// 视频文件绝对路径 = 身份。与 `VideoBooks.videoPath` 同语义（数据根内副本 / 用户
  /// 原位外部文件两态；流 URL 不入本表——探的是本地文件）。
  TextColumn get filePath => text()();

  /// 探测当时的文件大小（字节）。失效判据之一。
  IntColumn get fileSizeBytes => integer()();

  /// 探测当时的文件修改时刻（毫秒）。失效判据之一。
  IntColumn get fileModifiedAt => integer()();

  /// 本行写入时刻（毫秒）。
  IntColumn get probedAt => integer()();

  /// 探测器字段集版本（`kVideoProbeFieldSetVersion`）。失效判据之一。
  IntColumn get probeVersion => integer()();

  /// 容器时长（毫秒）。探不到为 NULL。
  IntColumn get durationMs => integer().nullable()();

  /// 容器平均码率（bit/s）。展示码率通常只能用它——mkv 不给流级码率。
  IntColumn get containerBitrate => integer().nullable()();

  /// ffprobe `codec_name`，如 `h264` / `hevc` / `av1`。
  TextColumn get videoCodec => text().nullable()();

  IntColumn get width => integer().nullable()();
  IntColumn get height => integer().nullable()();

  /// 如 `yuv420p10le`。色深主要由它推出（10-bit HEVC 不给 bits_per_raw_sample）。
  TextColumn get pixelFormat => text().nullable()();

  /// 每分量位深（8 / 10 / 12）。
  IntColumn get bitDepth => integer().nullable()();

  /// 帧率 ×1000（23.976fps → 23976）。整数存储避免浮点比较误差。
  IntColumn get frameRateMilli => integer().nullable()();

  /// 视频流码率（bit/s）。mkv 通常没有，见 [containerBitrate]。
  IntColumn get videoBitrate => integer().nullable()();

  /// ffprobe 原样的色彩标签。**不存归一后的「是不是 HDR」**：那是派生值，
  /// 判据收口在 `video_dynamic_range.dart`，存派生值等于把同一事实放两处，
  /// 判据一改这里就成了过期副本。
  TextColumn get colorPrimaries => text().nullable()();
  TextColumn get colorTransfer => text().nullable()();
  TextColumn get colorSpace => text().nullable()();

  /// 音轨数组 JSON（编码/声道/语言/标题/default·forced·comment 标志）。
  TextColumn get audioTracksJson => text().withDefault(const Constant('[]'))();

  /// 内封字幕轨数组 JSON。
  TextColumn get subtitleTracksJson =>
      text().withDefault(const Constant('[]'))();

  @override
  Set<Column> get primaryKey => {filePath};
}
