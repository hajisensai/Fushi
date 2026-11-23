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

  /// [path] 的比较键（schema v145，`musicTrackPathKey`）：同一个文件不管拼成哪种写法
  /// （分隔符混用、Windows 大小写）都是同一个键。扫描落库按它认出「库里已有的同一首」
  /// 沿用旧 uid，曲库里一个文件只有一行。设备本地（随 [path] 是本机路径），由
  /// `writeMusicScanBatch` / 数据根迁移写，NULL 只出现在迁移回填之前。
  TextColumn get pathKey => text().nullable()();

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

  /// 扫描时按这首曲目自己的标签算出的专辑 uid（schema v167，HBK-AUDIT-027）：归组前的
  /// 原始归属。同一张 CD 只有部分曲目写了专辑艺人时，扫描落库按「同目录同名」把没写的
  /// 那几首改挂到带艺人的那张上（[albumUid] 是归组后的生效值），这一列不动——之后同一组
  /// 里艺人变了（新加第二位、带艺人的文件删了），没变的文件不重新解析也能从这里退回原专辑。
  /// 只有扫描落库写它；光盘导入等别的写入方为 NULL，归组按 [albumUid] 认。设备本地。
  TextColumn get scanAlbumUid => text().nullable()();
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

  /// 用户「从音乐库移除」的时刻（schema v158，拍板台 IDeN5PYaI7）：只从曲库隐藏、
  /// 不碰磁盘文件。非 NULL 时 [deletedAt] 也非 NULL（隐藏的行和软删一样不进任何
  /// 曲库查询）；它是墓碑——重扫见到同一个文件不清软删标记（`writeMusicScanBatch`
  /// 跳过这一行），曲目不会复活，只有「恢复」（`unhideMusicTracks`）或用户显式重新
  /// 导入光盘才清掉；移除它所属的音乐来源时，没有别的来源覆盖就清墓碑（保持软删，
  /// `releaseMusicTracksOfSource`）。边界：墓碑按曲目身份（uid / 路径键）认，同一路径
  /// 的文件被重新编码、音频指纹（时长 / 采样率 / 声道）变了会派生新 uid、认不回墓碑
  /// 行，重扫会作为一首新曲目入库——这符合「指纹不同 = 换了文件」的身份语义。
  /// 设备本地（同整张表）。
  IntColumn get hiddenAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => <Column>{trackUid};
}

/// 曲目 uid 别名（schema v145）：同一个文件在曲库里曾有两行（路径拼法不同，见
/// [MusicTracks.pathKey]），合并时败者 uid → 胜者 uid 记在这里。曲目是设备本地的，但歌单 /
/// 歌词 / 播放流随「音乐」备份类别走：别的设备或旧备份里仍是败者 uid 的行合入本机后，
/// 由 `applyMusicTrackUidAliases` 按这张表改指胜者，不留悬空条目、不在歌单里重复。
/// 设备本地（uid 含本机路径）。
@DataClassName('MusicTrackUidAliasRow')
class MusicTrackUidAliases extends Table {
  TextColumn get aliasUid => text()();
  TextColumn get trackUid => text()();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => <Column>{aliasUid};
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

/// 远程曲目（schema v148，反馈 0tRY-D2JgG）：只能串流、不进扫描曲库的曲目（YouTube 内置音源、
/// 在线音源插件）被用户「加入音乐库」或加进本地歌单后，在这里留一行元数据。
///
/// 身份 [trackUid] 就是这首在播放引擎里的那个 uid（YouTube = `musicServerTrackUid('youtube',
/// videoId)`、插件 = `musicPluginTrackUid(pluginId, trackId)`）：与本地曲库的内容派生 uid
/// 命名空间不同、不撞；从搜索结果直接播与从曲库 / 歌单播是同一个 uid，所以歌词缓存
/// （`music_lyrics`）、断点（`music_resume_points`）、最近播放 / 统计（`music_play_events`）、
/// 制卡来源都天然挂在同一首上，不需要再映射。
///
/// 播放路径不落库：由 [kind] + [sourceKey] + [itemId] 现推（`fushi-music-youtube://` /
/// `fushi-music-plugin://` 占位，真正的流起播时才取），表里没有会过期的直链、也没有凭据。
///
/// 媒体服务器（Jellyfin / Subsonic）曲目（v149，反馈 se3Fw8HmOX）：[kind] = `server`、
/// [sourceKey] = 服务器配置身份（`MusicServerBrowser.serverId`：Jellyfin = 媒体服务器配置的
/// sourceId，Subsonic = `subsonic-<配置 id>`）、[itemId] = 服务器侧曲目 id、封面只存服务器侧
/// 引用 [coverRef]。播放流与封面地址都带账号凭据（token / api_key / u+p），一律在起播 / 取封面
/// 时由当前配置的服务器客户端现算，**任何带凭据的地址都不落这张表**；这台设备上没配这台
/// 服务器（配置删了 / 歌单从别的设备同步来）时曲目显示为不可用。
///
/// 与歌单一起随「音乐」备份类别走（歌单条目可能引用这里的行），按 [updatedAt] LWW 合并；
/// 「从音乐库移除」只清 [libraryAddedAt]、不删行（别的设备 / 歌单可能还引用）。
@DataClassName('MusicRemoteTrackRow')
class MusicRemoteTracks extends Table {
  TextColumn get trackUid => text()();

  /// 来源种类 wire 值（冻结）：`youtube` | `plugin` | `server`（v149）。
  TextColumn get kind => text()();

  /// 来源宿主：YouTube 为 `youtube`；插件为插件 id；服务器为服务器配置身份。
  TextColumn get sourceKey => text()();

  /// 来源内的条目 id：YouTube videoId / 插件曲目 id / 服务器侧曲目 id。
  TextColumn get itemId => text()();

  TextColumn get title => text()();
  TextColumn get artist => text().nullable()();
  TextColumn get album => text().nullable()();
  IntColumn get durationMs => integer().nullable()();

  /// 封面的 http(s) 地址（来源给的缩略图）；没有为 NULL。服务器曲目恒为 NULL（地址带凭据，
  /// 见 [coverRef]）。
  TextColumn get coverUrl => text().nullable()();

  /// 服务器侧封面引用（v149，只有服务器曲目有：Jellyfin 条目 id / Subsonic `coverArt` id），
  /// 显示时由服务器客户端现算地址。
  TextColumn get coverRef => text().nullable()();

  /// 来源侧专辑 id（v149：插件专辑 id / 服务器专辑 id），「去专辑」跳转与专辑 uid 用。
  TextColumn get albumId => text().nullable()();

  /// 来源侧艺人引用（v149，JSON 数组 `[{"id": "…", "name": "…"}]`，`id` 可缺），「去艺人」
  /// 跳转用；没有为 NULL。
  TextColumn get artistRefs => text().nullable()();

  /// 加入音乐库的时刻（毫秒）；NULL = 不在曲库里（只被歌单引用）。
  IntColumn get libraryAddedAt => integer().nullable()();
  IntColumn get createdAt => integer()();

  /// 最后一次改动（元数据 / 入库 / 移出曲库）的时刻：备份合并按它 LWW。
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => <Column>{trackUid};
}

/// 服务器曲目的离线副本（schema v173）：Jellyfin / Subsonic 曲目下载到本机的原文件，一首
/// 一行。**设备本地**（不进备份、不同步）：[filePath] 是这台设备上的绝对路径。
///
/// 身份 [trackUid] 与 [MusicRemoteTracks] 同一个（`musicServerTrackUid(serverId, itemId)`），
/// 播放这首时只要这里有行、文件还在，就放本地文件而不串流——歌词缓存 / 断点 / 统计仍挂在
/// 同一个 uid 上；服务器离线或这台设备上的配置删了也照样能放。表里只有服务器配置身份与
/// 服务器侧条目 id（[sourceKey] / [itemId]），**不存任何带凭据的地址**。
///
/// 下完的曲目同时在音乐库里（[MusicRemoteTracks.libraryAddedAt] 非空，离线时从曲库进入）；
/// 本机「从音乐库移除」过了撤销窗口连带删掉离线副本。副本是设备本地的事实：覆盖恢复 / 合并
/// 导入 / 启动时，不在库的副本把曲目放回曲库（`reconcileMusicServerDownloadsIntoLibrary`），
/// 从不因此删文件。
@DataClassName('MusicServerDownloadRow')
class MusicServerDownloads extends Table {
  TextColumn get trackUid => text()();

  /// 服务器配置身份（`MusicServerBrowser.serverId`），与 [MusicRemoteTracks.sourceKey] 同义。
  TextColumn get sourceKey => text()();

  /// 服务器侧曲目 id。
  TextColumn get itemId => text()();

  /// 服务器的协议家族 wire 值（v174，`MusicServerKind.wire`：`jellyfin` | `subsonic`）。离线副本的
  /// 播放项凭它带上完整的服务器身份——这台设备上的服务器配置删了 / 连不上时，播放上报与收藏
  /// 照样能记进离线队列（[MusicServerPendingActions]）。v174 之前的行按 [sourceKey] 前缀回填
  /// （Jellyfin 家族 `jellyfin:`、Subsonic `subsonic-`）；NULL = 认不出。
  TextColumn get serverKind => text().nullable()();

  /// 离线副本的绝对路径（本机）。
  TextColumn get filePath => text()();

  /// 同目录里下好的专辑封面（本机绝对路径）；没有为 NULL。
  TextColumn get coverPath => text().nullable()();

  /// 文件大小（字节）。
  IntColumn get sizeBytes => integer().nullable()();

  /// 文件的容器 / 编码（按文件头认出的扩展名，`flac` / `mp3` …）。
  TextColumn get codec => text().nullable()();

  /// 下完的时刻（毫秒）。
  IntColumn get downloadedAt => integer()();

  @override
  Set<Column> get primaryKey => <Column>{trackUid};
}

/// 服务器曲目没送达的播放 / 收藏切换（schema v174，**设备本地**：不进备份、不同步——恢复
/// 别的设备的备份不该把那台设备的播放再报一遍）。服务器连不上、或这台设备上的服务器配置删了
/// 时记在这里，那台服务器重新配上且连得通时补发（app 启动、打开服务器页、对那台服务器的任何
/// 一次请求成功之后）：Jellyfin `POST /Users/{uid}/PlayedItems/{id}?datePlayed=`（按原播放时刻
/// 计一次播放），OpenSubsonic `scrobble time=<毫秒> submission=true`，收藏走各自的收藏接口。
///
/// 去重靠主键 [dedupeKey]：播放 = 服务器 + 条目 + 播放时刻（同一次播放只记一次），收藏 = 服务器
/// + 条目（同一首只留最后一次切换，后写覆盖）。没有凭据、没有地址，只有服务器配置身份与条目 id。
/// 上限与过期：见 app 侧 `music_server_offline_queue.dart`（条数上限、服务器一直没配回来的
/// 条目过了长 TTL 才丢）。
@DataClassName('MusicServerPendingActionRow')
class MusicServerPendingActions extends Table {
  /// 去重键（见类注释）。
  TextColumn get dedupeKey => text()();

  /// `play` | `favorite`（wire 值，冻结）。
  TextColumn get action => text()();

  /// 服务器协议家族 wire 值（`jellyfin` | `subsonic`）。
  TextColumn get serverKind => text()();

  /// 服务器配置身份（`MusicServerBrowser.serverId`）。
  TextColumn get serverId => text()();

  /// 服务器侧曲目 id。
  TextColumn get itemId => text()();

  /// 播放身份（`musicServerTrackUid(serverId, itemId)`），显示待送达的收藏状态用。
  TextColumn get trackUid => text()();

  /// 播放：开播时刻（epoch 毫秒，补发时作为服务器上的播放时刻）。收藏为 NULL。
  IntColumn get playedAt => integer().nullable()();

  /// 收藏：要设成的状态。播放为 NULL。
  BoolColumn get favorite => boolean().nullable()();

  /// 入队（收藏：最后一次切换）的时刻。
  IntColumn get createdAt => integer()();

  /// 服务器回了错误（不是连不上）的次数：到上限丢弃（条目在服务器上删了等）。
  IntColumn get attempts => integer().withDefault(const Constant(0))();

  /// 最近一次补发尝试的时刻；没试过为 NULL。
  IntColumn get lastAttemptAt => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{dedupeKey};
}

/// 服务器曲目在这台设备上记下的客户端状态（schema v174，**设备本地**，一首一行）：
/// - 收藏的最后已知状态（[favorite]）：服务器连不上 / 配置删了时「正在播放」的心形按它显示；
/// - 客户端测的响度（[measuredTrackGain] / [measuredTrackPeak]）：服务器没给响度（Jellyfin 没开
///   LUFS 扫描、纯 Subsonic）时，串流播过一次后在后台用 FFmpeg `ebur128` 从服务器流测一次
///   （离线副本的测量值存在音频旁的 `.loudness.json`，不在这里）。**服务器给的值永远优先**。
///
/// 设备本地而不同步：两样都是可再得的缓存（收藏的真相在服务器，响度随时可从服务器重测），
/// [serverId] 里的服务器身份也只对配着那台服务器的设备有意义；进备份还得给缓存配一套 LWW
/// 合并，换不来什么。表里没有凭据、没有地址。
@DataClassName('MusicServerTrackStateRow')
class MusicServerTrackStates extends Table {
  /// 播放身份（`musicServerTrackUid(serverId, itemId)`）。
  TextColumn get trackUid => text()();

  /// 服务器协议家族 wire 值（`jellyfin` | `subsonic`）。
  TextColumn get serverKind => text()();

  TextColumn get serverId => text()();
  TextColumn get itemId => text()();

  /// 最后已知的收藏状态（服务器报的 / 服务器确认过的 / 本机最后一次切换）；不知道为 NULL。
  BoolColumn get favorite => boolean().nullable()();

  /// [favorite] 记下的时刻。
  IntColumn get favoriteAt => integer().nullable()();

  /// 客户端测的曲目增益（dB，ReplayGain 2.0 参考 -18 LUFS）；静音 / 测不出为 NULL。
  RealColumn get measuredTrackGain => real().nullable()();

  /// 客户端测的曲目峰值（线性）。
  RealColumn get measuredTrackPeak => real().nullable()();

  /// 测量时刻；NULL = 没测过（非空而增益为 NULL = 测过、测不出，不再测）。
  IntColumn get loudnessMeasuredAt => integer().nullable()();

  IntColumn get updatedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{trackUid};
}

/// 逐曲断点续播（v146，反馈 QAondMh4M5）：每首曲目上次停在哪，一首一行。
///
/// 与 [MusicPlayEvents] 同一身份（`trackUid`：路径 + 起点 + 音频属性派生，改标签不换；
/// CUE 虚拟曲目各自一行，[positionMs] 相对本曲起点）。读的时候才按阈值判定从哪开始
/// （`music_resume.dart`）；听完 / 回到开头的直接删行，不留「位置 0」行。
@DataClassName('MusicResumePointRow')
class MusicResumePoints extends Table {
  TextColumn get trackUid => text()();

  /// 上次停在哪（毫秒，相对曲目起点）。
  IntColumn get positionMs => integer()();

  /// 写入时已知的曲长（毫秒）；在线 / 服务器曲目可能不知道。
  IntColumn get durationMs => integer().nullable()();

  /// 写入时刻（epoch 毫秒）：备份合并按它取较新的一方。
  IntColumn get updatedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{trackUid};
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
