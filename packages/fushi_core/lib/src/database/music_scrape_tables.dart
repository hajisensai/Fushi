import 'package:drift/drift.dart';

// ── 音乐刮削三表（schema v133，音乐方案 §8 / §10，P4）─────────────────────────
//
// 与视频刮削同模式：识别结论（`music_scrape_meta`）/ 原始响应快照
// （`music_metadata_raw_snapshots`）/ 字段锁（`music_locked_fields`）分开存。
//
// **文件标签是显示真相源**（Picard 模型）：识别结论不改写 `music_tracks` 的标题 / 艺人
// 等显示列——那几列是标签的镜像、每次重扫都会按标签重写。识别只把**身份**
// （录音 / 作品 MBID、AcoustID）与专辑缺项（发行 MBID、目录编号、封面）叠加上去
// （`FushiDatabase.reapplyMusicScrapeOverlay`，重扫批次落库后在同一事务里重放）；
// 刮到的标题 / 艺人 / 专辑名要进曲库，走「写回文件标签」这个显式操作（带 diff 预览）。
//
// 三张表都是**设备本地**：键是 `track_uid`（含本机路径）、内容可由重刮重建
// （`backupTableRules` / `_deviceLocalTables`）。

/// 一首曲目的识别结论（一行一首，重刮整行覆盖）。
@DataClassName('MusicScrapeMetaRow')
class MusicScrapeMeta extends Table {
  TextColumn get trackUid => text()();

  /// `matched`（已识别）/ `unmatched`（没认出来，[candidatesJson] 给手选）/
  /// `error`（资料源连不上，[warnings] 写原因）。
  TextColumn get status => text()();

  /// `MusicIdentificationMethod.wire`：`mbid_tag` / `tag_search` / `acoustid` / `manual`。
  TextColumn get method => text().nullable()();
  TextColumn get mbRecordingId => text().nullable()();
  TextColumn get mbReleaseId => text().nullable()();
  TextColumn get mbReleaseGroupId => text().nullable()();
  TextColumn get mbWorkId => text().nullable()();
  TextColumn get mbArtistId => text().nullable()();
  TextColumn get acoustid => text().nullable()();

  /// 0..1。
  RealColumn get confidence => real().nullable()();

  // 刮到的显示值（写回标签 diff 的「新值」；不直接改曲库显示列，见文件头）。
  TextColumn get title => text().nullable()();
  TextColumn get artistCredit => text().nullable()();
  TextColumn get albumTitle => text().nullable()();
  TextColumn get albumArtistCredit => text().nullable()();

  /// MusicBrainz 残缺日期原样（`YYYY` / `YYYY-MM` / `YYYY-MM-DD`）。
  TextColumn get releaseDate => text().nullable()();
  TextColumn get catalogNo => text().nullable()();
  IntColumn get trackNo => integer().nullable()();
  IntColumn get discNo => integer().nullable()();

  /// 原曲（§8.2）。[selfIsOriginal] = 这首就是原曲。
  TextColumn get originalRecordingId => text().nullable()();
  TextColumn get originalTitle => text().nullable()();
  TextColumn get originalArtistCredit => text().nullable()();
  TextColumn get originalReleaseDate => text().nullable()();
  BoolColumn get selfIsOriginal =>
      boolean().withDefault(const Constant(false))();

  /// 其它版本（同作品的其余录音）JSON 数组：`[{id,title,artist,date,attrs}]`。
  TextColumn get versionsJson => text().nullable()();

  /// MusicBrainz 关系给出的在线 MV JSON 数组：`[{url,videoRecordingId,title}]`。
  TextColumn get musicVideosJson => text().nullable()();

  /// Cover Art Archive 正面封面 URL（已下载到本地时专辑行 `cover_path` 指向本地文件）。
  TextColumn get coverUrl => text().nullable()();

  /// VGMdb 专辑 JSON：`{id,link,catalog,names}`。
  TextColumn get vgmdbJson => text().nullable()();

  /// 未识别 / 歧义时的候选 JSON 数组（手选用）：`[{id,title,artist,lengthMs,release,score}]`。
  TextColumn get candidatesJson => text().nullable()();

  /// 非致命问题（某个补全源连不上 / AcoustID 没配）换行分隔。
  TextColumn get warnings => text().nullable()();

  /// 刮削器版本（判据变了按它重刮）。
  IntColumn get scraperVersion => integer()();
  IntColumn get scrapedAt => integer()();

  @override
  Set<Column> get primaryKey => <Column>{trackUid};
}

/// 资料源原始响应快照（一个外部实体一行，重取覆盖）。
@DataClassName('MusicMetadataRawSnapshotRow')
class MusicMetadataRawSnapshots extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// `MusicMetadataProviderKind.wire`。
  TextColumn get provider => text()();

  /// `recording` / `work` / `work_recordings` / `release` / `lookup` / `catalog_search`。
  TextColumn get snapshotKind => text()();
  TextColumn get externalId => text()();
  TextColumn get rawJson => text()();
  IntColumn get fetchedAt => integer()();

  @override
  List<Set<Column>> get uniqueKeys => <Set<Column>>[
    <Column>{provider, snapshotKind, externalId},
  ];
}

/// 字段锁：用户在「写回标签」预览里取消勾选的字段——以后的写回 diff 不再提议改它，
/// 专辑级的 `cover` 锁住后刮削不再替换封面。
@DataClassName('MusicLockedFieldRow')
class MusicLockedFields extends Table {
  /// `track` / `album`。
  TextColumn get entityKind => text()();
  TextColumn get entityUid => text()();

  /// `MusicLockableField.wire`（与标签字段同名：`title` / `artist` / … / `cover`）。
  TextColumn get field => text()();
  IntColumn get lockedAt => integer()();

  @override
  Set<Column> get primaryKey => <Column>{entityKind, entityUid, field};
}
