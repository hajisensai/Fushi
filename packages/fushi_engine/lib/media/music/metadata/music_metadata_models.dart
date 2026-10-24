/// 音乐刮削的数据模型（音乐方案 §8，`docs/specs/2026-10-23-music-module-design.md`）。
///
/// 只是 provider 响应的结构化视图——不持久化成独立表：原始响应进
/// `music_metadata_raw_snapshots`，识别结论进 `music_scrape_meta`（schema v129）。
library;

/// 资料源。[wire] 落进 `music_scrape_meta.provider` / `music_metadata_raw_snapshots.provider`，
/// **冻结不改名**。
enum MusicMetadataProviderKind {
  musicbrainz('musicbrainz'),
  acoustid('acoustid'),
  coverArtArchive('caa'),
  vgmdb('vgmdb');

  const MusicMetadataProviderKind(this.wire);

  final String wire;

  static MusicMetadataProviderKind? fromWire(String? wire) {
    for (final MusicMetadataProviderKind k in values) {
      if (k.wire == wire) return k;
    }
    return null;
  }
}

/// 识别途径（音乐方案 §8.1 的识别顺序）。[wire] 落进 `music_scrape_meta.method`，冻结。
enum MusicIdentificationMethod {
  /// 文件标签里已有 MusicBrainz 录音 id，直接取。
  mbidTag('mbid_tag'),

  /// 标签（艺人 + 标题 + 专辑 + 时长）精确查 MusicBrainz，唯一命中。
  tagSearch('tag_search'),

  /// AcoustID 声纹查询。
  acoustid('acoustid'),

  /// 用户从候选里手选 / 手填 MBID。
  manual('manual');

  const MusicIdentificationMethod(this.wire);

  final String wire;

  static MusicIdentificationMethod? fromWire(String? wire) {
    for (final MusicIdentificationMethod m in values) {
      if (m.wire == wire) return m;
    }
    return null;
  }
}

/// MusicBrainz 艺人署名里的一项（`artist-credit[]`）。
class MusicArtistCredit {
  const MusicArtistCredit({
    required this.name,
    this.mbArtistId,
    this.joinPhrase = '',
    this.sortName,
  });

  /// 署名名（as credited）。
  final String name;
  final String? mbArtistId;
  final String joinPhrase;
  final String? sortName;
}

/// 署名拼回一行（`A feat. B`）。
String musicArtistCreditText(List<MusicArtistCredit> credits) => <String>[
  for (final MusicArtistCredit c in credits) '${c.name}${c.joinPhrase}',
].join().trim();

/// 一张发行（release）在某首录音视角下的摘要：含这首在盘里的位置。
class MusicReleaseRef {
  const MusicReleaseRef({
    required this.mbReleaseId,
    required this.title,
    this.releaseGroupId,
    this.primaryType,
    this.secondaryTypes = const <String>[],
    this.status,
    this.date,
    this.country,
    this.discPosition,
    this.trackPosition,
    this.trackCount,
    this.catalogNumbers = const <String>[],
    this.barcode,
    this.artistCredit = const <MusicArtistCredit>[],
  });

  final String mbReleaseId;
  final String title;
  final String? releaseGroupId;

  /// `Album` / `Single` / `EP` …（release-group primary type）。
  final String? primaryType;
  final List<String> secondaryTypes;

  /// `Official` / `Promotion` / `Bootleg` …
  final String? status;

  /// `YYYY` / `YYYY-MM` / `YYYY-MM-DD`（残缺日期原样保留，不补月日）。
  final String? date;
  final String? country;

  /// 盘号（media position，1 起）。
  final int? discPosition;

  /// 这首在该盘里的曲序（track number 数字化，1 起）。
  final int? trackPosition;
  final int? trackCount;
  final List<String> catalogNumbers;
  final String? barcode;
  final List<MusicArtistCredit> artistCredit;
}

/// 录音挂的作品（work）关系：`performance of`。
class MusicWorkLink {
  const MusicWorkLink({
    required this.mbWorkId,
    required this.title,
    this.attributes = const <String>[],
  });

  final String mbWorkId;
  final String title;

  /// 关系属性：`cover` / `live` / `instrumental` / `karaoke` / `partial` / `medley`。
  final List<String> attributes;
}

/// 录音的 URL 关系（`streaming` / `free streaming` / `purchase for download` …）。
class MusicUrlRelation {
  const MusicUrlRelation({required this.type, required this.url});

  final String type;
  final String url;
}

/// 一条 MusicBrainz 录音（recording）。
class MusicRecording {
  const MusicRecording({
    required this.mbRecordingId,
    required this.title,
    this.durationMs,
    this.artistCredit = const <MusicArtistCredit>[],
    this.firstReleaseDate,
    this.isVideo = false,
    this.disambiguation,
    this.releases = const <MusicReleaseRef>[],
    this.isrcs = const <String>[],
    this.works = const <MusicWorkLink>[],
    this.musicVideoRecordingIds = const <String>[],
    this.musicVideoOfRecordingIds = const <String>[],
    this.urls = const <MusicUrlRelation>[],
    this.searchScore,
  });

  final String mbRecordingId;
  final String title;
  final int? durationMs;
  final List<MusicArtistCredit> artistCredit;
  final String? firstReleaseDate;

  /// MusicBrainz 的「视频录音」（MV 本身是一条 video=true 的录音）。
  final bool isVideo;
  final String? disambiguation;
  final List<MusicReleaseRef> releases;
  final List<String> isrcs;
  final List<MusicWorkLink> works;

  /// 这首（音频录音）的 MV：recording-recording 关系 `music video`（本录音 → 视频录音）。
  final List<String> musicVideoRecordingIds;

  /// 反向：本录音是视频录音时，它是哪些音频录音的 MV。
  final List<String> musicVideoOfRecordingIds;
  final List<MusicUrlRelation> urls;

  /// 搜索接口的 `score`（0–100）；查详情得到的为 null。
  final int? searchScore;

  String get artistCreditText => musicArtistCreditText(artistCredit);
}

/// 作品（work）的一条录音（「其它版本」的一项）。
class MusicWorkRecording {
  const MusicWorkRecording({
    required this.mbRecordingId,
    required this.title,
    this.artistCreditText = '',
    this.durationMs,
    this.firstReleaseDate,
    this.attributes = const <String>[],
    this.isVideo = false,
  });

  final String mbRecordingId;
  final String title;
  final String artistCreditText;
  final int? durationMs;
  final String? firstReleaseDate;

  /// performance 关系属性（`cover` / `live` / …）。
  final List<String> attributes;
  final bool isVideo;

  bool get isCover => attributes.contains('cover');
  bool get isLive => attributes.contains('live');
}

/// 一首作品（work）及其全部录音。
class MusicWork {
  const MusicWork({
    required this.mbWorkId,
    required this.title,
    this.type,
    this.language,
    this.recordings = const <MusicWorkRecording>[],
  });

  final String mbWorkId;
  final String title;
  final String? type;
  final String? language;
  final List<MusicWorkRecording> recordings;
}

/// 标签精确查的请求。
class MusicRecordingSearchQuery {
  const MusicRecordingSearchQuery({
    required this.title,
    this.artist,
    this.album,
    this.durationMs,
    this.limit = 10,
  });

  final String title;
  final String? artist;
  final String? album;
  final int? durationMs;
  final int limit;
}

/// AcoustID 一条结果：一个声纹簇 + 它关联的 MusicBrainz 录音。
class AcoustidResult {
  const AcoustidResult({
    required this.acoustid,
    required this.score,
    this.recordingIds = const <String>[],
  });

  final String acoustid;

  /// 0..1。
  final double score;
  final List<String> recordingIds;
}

/// Cover Art Archive 的一张图。
class MusicCoverImage {
  const MusicCoverImage({
    required this.imageUrl,
    this.thumbnails = const <String, String>{},
    this.types = const <String>[],
    this.front = false,
    this.approved = true,
  });

  final String imageUrl;

  /// `250` / `500` / `1200` / `small` / `large` → URL。
  final Map<String, String> thumbnails;

  /// `Front` / `Back` / `Booklet` …
  final List<String> types;
  final bool front;
  final bool approved;

  /// 列表 / 卡片用的尺寸：优先 500 px 缩略图，没有就原图。
  String get displayUrl =>
      thumbnails['500'] ??
      thumbnails['large'] ??
      thumbnails['1200'] ??
      imageUrl;
}

/// VGMdb 专辑（社区 JSON 镜像 vgmdb.info 的 `album/<id>`）。
class VgmdbAlbum {
  const VgmdbAlbum({
    required this.id,
    required this.link,
    this.catalog,
    this.names = const <String, String>{},
    this.releaseDate,
    this.tracks = const <VgmdbTrack>[],
  });

  /// 数字 id（`album/79` → `79`）。
  final String id;

  /// `https://vgmdb.net/album/<id>`。
  final String link;
  final String? catalog;

  /// 语言码（`en` / `ja` / `ja-latn`）→ 专辑名。
  final Map<String, String> names;
  final String? releaseDate;
  final List<VgmdbTrack> tracks;

  String? get japaneseName => names['ja'] ?? names['ja-jp'];
}

/// VGMdb 专辑里的一首。
class VgmdbTrack {
  const VgmdbTrack({
    required this.disc,
    required this.track,
    this.names = const <String, String>{},
    this.durationMs,
  });

  final int disc;
  final int track;
  final Map<String, String> names;
  final int? durationMs;
}
