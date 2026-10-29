import 'package:drift/drift.dart';

// ── 音乐模块（schema v130，docs/specs/2026-10-23-music-module-design.md §10）──
//
// 曲库目录由 Rust 胖核心 `native/fushi_music` 扫描产出、Dart 落 Drift（同步 / 备份 /
// Profile / 墓碑设施都在 Drift 上，这是 IO / 编排而不是计算）。P0 只建表与曲库读写；
// 刮削三表（scrape_meta / raw_snapshots / locked_fields）随 P4 的 provider 一起定形，
// 届时单独加表——现在按视频刮削抄一份表结构只会把还没设计的东西冻结进 schema。
//
// 身份全部是**内容派生**的字符串 uid（Rust 侧算，见 `fushi_music` 的 `track_uid`）：
// 曲目 = 路径 + CUE 起点 + 文件指纹；专辑 = 归一化（专辑艺人, 专辑名）；艺人 =
// 归一化名字。表之间是逻辑外键：重扫按 uid upsert，不依赖自增 id。
//
// 备份：P0 全部登记为设备本地（`backupTableRules`）——曲库目录可由重扫重建、且装的
// 是本机绝对路径；歌词编辑 / 歌单 / MV 绑定随备份走需要单独的「音乐」备份类别与
// 合并规则，跟 P1（歌词编辑）/ 歌单 UI 一起做。

/// 一首曲目（普通文件一行；整轨 + CUE / 内嵌 CUESHEET 拆出的虚拟曲目各一行）。
@DataClassName('MusicTrackRow')
class MusicTracks extends Table {
  TextColumn get trackUid => text()();

  /// 来源库（`MediaSources.id`，`media_kind = 'music'`）；手动导入的散曲为 NULL。
  IntColumn get sourceId => integer().nullable()();

  /// 音频文件绝对路径（CUE 虚拟曲目指向整轨文件）。
  TextColumn get path => text()();

  /// CUE 虚拟曲目在整轨里的起止（毫秒）；普通文件为 NULL。[cueEndMs] 为 NULL 表示
  /// 播到文件尾（最后一轨）。
  IntColumn get cueStartMs => integer().nullable()();
  IntColumn get cueEndMs => integer().nullable()();

  IntColumn get durationMs => integer().nullable()();

  /// 编码（`flac` / `alac` / `ape` / `wavpack` / `dsd` / `mp3` / `aac` / `opus` …）。
  TextColumn get codec => text().nullable()();
  IntColumn get sampleRate => integer().nullable()();
  IntColumn get bitDepth => integer().nullable()();
  IntColumn get channels => integer().nullable()();

  /// 平均码率（kbps）。
  IntColumn get bitrate => integer().nullable()();
  BoolColumn get isLossless => boolean().withDefault(const Constant(false))();

  TextColumn get title => text()();
  TextColumn get titleSort => text().nullable()();

  /// 曲目艺人的显示串（标签原文）；结构化署名在 [MusicTrackCredits]。
  TextColumn get artistCredit => text().nullable()();

  /// 所属专辑（`MusicAlbums.albumUid`）；无专辑标签的散曲为 NULL。
  TextColumn get albumUid => text().nullable()();
  IntColumn get discNo => integer().nullable()();
  IntColumn get trackNo => integer().nullable()();
  IntColumn get year => integer().nullable()();
  TextColumn get genre => text().nullable()();

  /// ReplayGain（dB / 线性峰值），来自标签；缺标签时由 R128 扫描补（P2）。
  RealColumn get rgTrackGain => real().nullable()();
  RealColumn get rgTrackPeak => real().nullable()();
  RealColumn get rgAlbumGain => real().nullable()();
  RealColumn get rgAlbumPeak => real().nullable()();

  /// EBU R128 现扫完成时刻（毫秒）；NULL = 没扫过。
  IntColumn get r128ScannedAt => integer().nullable()();

  TextColumn get mbRecordingId => text().nullable()();
  TextColumn get mbWorkId => text().nullable()();
  TextColumn get acoustid => text().nullable()();

  /// 文件修改时刻（毫秒）与大小：重扫时判「文件没动过」。
  IntColumn get fileMtimeAt => integer()();
  IntColumn get fileSize => integer()();

  /// 文件是否带内嵌封面（扫描时由标签判定，封面字节按需再取）。
  BoolColumn get hasEmbeddedCover =>
      boolean().withDefault(const Constant(false))();

  IntColumn get addedAt => integer()();

  /// 软删时刻（毫秒）：重扫发现文件消失时置位，歌单 / 播放记录仍能解析到行。
  IntColumn get deletedAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => <Column>{trackUid};
}

/// 专辑（由曲目标签聚合：同一归一化（专辑艺人, 专辑名）是同一张专辑）。
@DataClassName('MusicAlbumRow')
class MusicAlbums extends Table {
  TextColumn get albumUid => text()();
  TextColumn get title => text()();
  TextColumn get titleSort => text().nullable()();
  TextColumn get albumArtistCredit => text().nullable()();
  TextColumn get mbReleaseId => text().nullable()();
  TextColumn get mbReleaseGroupId => text().nullable()();
  TextColumn get catalogNo => text().nullable()();

  /// 发行日期原文（`YYYY` / `YYYY-MM` / `YYYY-MM-DD`；残缺日期不补全）。
  TextColumn get releaseDate => text().nullable()();

  /// 封面本地文件路径：同目录 `cover.*` / `folder.*`，或从曲目内嵌封面抽出的缓存。
  /// 设计稿写的是 `cover_image_id → media_images`；那张表的 CHECK 只允许合集 / 视频
  /// 两种归属，接音乐要重建表，P0 先用路径列。
  TextColumn get coverPath => text().nullable()();

  /// 封面取自哪首曲目的内嵌图（[coverPath] 是抽出的缓存时）；NULL = 目录图或没有。
  TextColumn get coverTrackUid => text().nullable()();
  IntColumn get totalDiscs => integer().nullable()();

  /// 光盘来源（`MusicDiscSources.discUid`）：盘在曲库里就是一张带角标的专辑
  /// （§9.2，不设光盘分区）。
  TextColumn get discUid => text().nullable()();
  IntColumn get addedAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => <Column>{albumUid};
}

@DataClassName('MusicArtistRow')
class MusicArtists extends Table {
  TextColumn get artistUid => text()();
  TextColumn get name => text()();
  TextColumn get sortName => text().nullable()();
  TextColumn get mbArtistId => text().nullable()();

  /// `person` | `group` | `character`（未知为 NULL）。
  TextColumn get kind => text().nullable()();
  IntColumn get addedAt => integer()();

  @override
  Set<Column> get primaryKey => <Column>{artistUid};
}

/// 曲目署名（一首歌多个艺人 / 多种角色）。
@DataClassName('MusicTrackCreditRow')
class MusicTrackCredits extends Table {
  TextColumn get trackUid => text()();
  TextColumn get artistUid => text()();

  /// `artist` / `album_artist` / `featured` / `composer` / `lyricist` / `arranger` /
  /// `vocal_cv` / `character`。
  TextColumn get role => text()();

  /// 标签里的原始署名（与 [MusicArtists.name] 可能大小写 / 全半角不同）。
  TextColumn get creditName => text()();
  IntColumn get ord => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => <Column>{trackUid, artistUid, role};
}

/// 歌词缓存与用户编辑（P1 填充）。一首歌每个来源一行。
@DataClassName('MusicLyricRow')
class MusicLyrics extends Table {
  TextColumn get trackUid => text()();

  /// `sidecar` / `embedded` / `provider:<name>` / `auto` / `user`。
  TextColumn get source => text()();

  /// 原格式（`lrc` / `ttml` / `ass` / `krc` …）。
  TextColumn get format => text()();
  BlobColumn get raw => blob()();

  /// Rust 侧统一时间轴的二进制缓存；[timelineVersion] 与当前解析器版本不符即重建。
  BlobColumn get timelineCache => blob().nullable()();
  IntColumn get timelineVersion => integer().withDefault(const Constant(0))();
  IntColumn get offsetMs => integer().withDefault(const Constant(0))();

  /// `line` | `word` | `syllable` | `syllable_pitch`。
  TextColumn get timingQuality => text().withDefault(const Constant('line'))();
  BoolColumn get isUserEdited => boolean().withDefault(const Constant(false))();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => <Column>{trackUid, source};
}

/// MV 绑定（P4）。
@DataClassName('MusicVideoRow')
class MusicVideos extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get trackUid => text()();

  /// `local` | `youtube` | `disc_chapter` | `anime_episode`。
  TextColumn get kind => text()();

  /// 指向 MV 的引用（本地路径 / 视频 id / 盘 uid + 章节 / 视频库 bookUid + 区间）。
  TextColumn get ref => text()();

  /// MV 相对音频的偏移（毫秒）：MV 时间 = 音频时间 + offset。
  IntColumn get offsetMs => integer().withDefault(const Constant(0))();
  RealColumn get confidence => real().nullable()();
  BoolColumn get isUserBound => boolean().withDefault(const Constant(false))();
  IntColumn get updatedAt => integer()();

  @override
  List<Set<Column>> get uniqueKeys => <Set<Column>>[
    <Column>{trackUid, kind, ref},
  ];
}

/// 光盘来源（DVD / 蓝光 / 音频 CD / CD+G，P5）。
@DataClassName('MusicDiscSourceRow')
class MusicDiscSources extends Table {
  TextColumn get discUid => text()();
  TextColumn get path => text()();

  /// `dvd` | `bluray` | `cdda` | `cdg`。
  TextColumn get kind => text()();
  TextColumn get volumeId => text().nullable()();
  BoolColumn get hasMenu => boolean().withDefault(const Constant(false))();

  /// 标题 / 章节 → 曲目映射（JSON）。
  TextColumn get titleMapJson => text().nullable()();
  IntColumn get addedAt => integer()();

  @override
  Set<Column> get primaryKey => <Column>{discUid};
}

@DataClassName('MusicPlaylistRow')
class MusicPlaylists extends Table {
  TextColumn get playlistUid => text()();
  TextColumn get name => text()();

  /// 智能歌单规则（JSON）；普通歌单为 NULL。
  TextColumn get rulesJson => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  IntColumn get deletedAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => <Column>{playlistUid};
}

@DataClassName('MusicPlaylistEntryRow')
class MusicPlaylistEntries extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get playlistUid => text().references(
    MusicPlaylists,
    #playlistUid,
    onDelete: KeyAction.cascade,
  )();
  TextColumn get trackUid => text()();
  IntColumn get position => integer()();
  IntColumn get addedAt => integer()();
}

/// 最近播放流（history 唯一含义）：一次播放一行。
@DataClassName('MusicPlayEventRow')
class MusicPlayEvents extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get trackUid => text()();
  IntColumn get startedAt => integer()();

  /// 实际听了多久（毫秒，暂停 / 拖动不计）。
  IntColumn get listenedMs => integer().withDefault(const Constant(0))();
  BoolColumn get completed => boolean().withDefault(const Constant(false))();

  // ── 播放项快照（自 v139 起）──
  //
  // 在线插件曲目（`fushi-music-plugin://…`）与服务器曲目不进 `music_tracks`，最近播放
  // 只能靠这份快照显示与重播；本地曲目以曲库行为准，快照兜底（曲目被删 / 重扫换 uid）。
  // 存量行全部 NULL = 没有快照（只能靠 join 曲库）。

  /// 播放路径（本地文件绝对路径 / `fushi-music-plugin://<插件>/<曲目>` / 服务器流地址）。
  TextColumn get path => text().nullable()();

  /// CUE 虚拟曲目在整轨里的起止（毫秒，偏移量）。
  IntColumn get cueStartMs => integer().nullable()();
  IntColumn get cueEndMs => integer().nullable()();
  TextColumn get title => text().nullable()();
  TextColumn get artist => text().nullable()();
  TextColumn get album => text().nullable()();
  TextColumn get albumUid => text().nullable()();
  IntColumn get durationMs => integer().nullable()();

  /// 封面：在线 http(s) 地址或本地文件路径（同 `MusicPlayItem.coverPath`）。
  TextColumn get coverPath => text().nullable()();

  // ── 播放来源（自 v139 起）：这次播放所在的队列是从哪张专辑 / 哪个歌单点开的 ──

  /// 来源种类 wire 值（`album` / `playlist` / `plugin_album` / `plugin_playlist` /
  /// `server_album` / `server_playlist` / `artist` / `other`）；NULL = 不知道。
  TextColumn get sourceKind => text().nullable()();

  /// 来源在该种类下的身份（不透明串，编码由 app 侧 `MusicPlaySource` 定）。
  TextColumn get sourceId => text().nullable()();
  TextColumn get sourceTitle => text().nullable()();

  /// 来源封面（http(s) 地址或本地文件路径）。
  TextColumn get sourceCover => text().nullable()();
}
