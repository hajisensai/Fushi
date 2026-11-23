/// 互联共享音乐库的 host 读写层（设计 docs/specs/2026-11-23-interconnect-music-library-design.md §4.1）。
///
/// app 当 host 与无头服务端构造**同一个**实现（拍板 design-imusic-q11 选 a：先放进引擎，不写两遍），只依赖
/// `fushi_core` 数据库与 `fushi_music`：
/// - `anime_episode` 类 MV 经视频库行展开成集（[themeSongFilesOf]，与主题曲比对同一个判据）；
/// - 内嵌封面经 `fushi_music` 在后台 isolate 读（原生库不在时只出目录封面）。
/// 两者都可由测试替换（[MusicHostAnimeEpisodeFile] / [MusicHostEmbeddedCover]）。
///
/// 曲目字节怎么给（[trackSource]，统一流票 `musicTrack`）：
/// - 本机文件：原样按 Range 直出（bit-perfect）；
/// - 网络来源（SFTP / WebDAV / AList，design-imusic-q4）：host 用自己的来源凭据代读，Range 透传
///   （[LibraryMediaUpstream]），凭据不出 host；
/// - 光盘标题 / CDDA（design-imusic-q5）：按章节 / 轨起止截成 FLAC 缓存文件（[MusicStreamMaterializer]）；
/// - client 带码率上限（design-imusic-q6）且源码率高于上限：转成 AAC 缓存文件。
/// 只有这台 host 确实给不出字节时才标 [RemoteMusicTrack.unplayableReason]（没装网络来源解析器的
/// 无头服务端、非 Windows 上的 CDDA）。
library;

import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/disc/music_disc_media.dart'
    show isMusicDiscTitlePath, musicDvdDemuxerSource;
import 'package:fushi_engine/media/music/host/music_stream_materializer.dart';
import 'package:fushi_engine/media/music/lyrics/music_lyrics_sources.dart';
import 'package:fushi_engine/media/music/metadata/music_video_match.dart'
    show MusicVideoKind, kMusicVideoExtensions, parseAnimeEpisodeMusicVideoRef;
import 'package:fushi_engine/media/video/dvd/dvd_ffmpeg_input.dart'
    show DvdTitleInput, encodeDvdTitleInput;
import 'package:fushi_engine/media/video/dvd/dvd_title_path.dart'
    show dvdDiscRootForTitlePath, dvdTitleNumberForPath, isDvdTitlePath;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_local_files.dart'
    show themeSongFilesOf;
import 'package:fushi_engine/sync/library_media_streams.dart';
import 'package:fushi_engine/sync/remote_music_dto.dart';
import 'package:fushi_music/fushi_music.dart' show readMusicEmbeddedCover;
import 'package:path/path.dart' as p;

/// `anime_episode` 类 MV 引用 → host 本机文件；解析不到为 null。
typedef MusicHostAnimeEpisodeFile =
    Future<File?> Function(String bookUid, int episodeIndex);

/// 曲目文件的内嵌封面字节；没有为 null。
typedef MusicHostEmbeddedCover = Future<Uint8List?> Function(String audioPath);

/// 网络来源曲目 → host 能读的上游地址（+ 头部）。app 当 host 装它（来源解析器在 app 里）；
/// 无头服务端没有网络来源，不装 → 这类曲目标 `networkSource`。解析不出回 null。
typedef MusicHostNetworkSource =
    Future<({Uri url, Map<String, String> headers})?> Function(
      MusicTrackRow track,
    );

/// 封面：文件或内存字节，二选一。
typedef MusicHostCover = ({File? file, Uint8List? bytes});

/// 歌单写操作的错误（路由映射成 4xx）。
class MusicHostWriteError implements Exception {
  const MusicHostWriteError(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => 'MusicHostWriteError($status, $message)';
}

class EngineMusicLibraryHost {
  EngineMusicLibraryHost({
    required FushiDatabase? Function() database,
    MusicHostAnimeEpisodeFile? animeEpisodeFile,
    MusicHostEmbeddedCover? embeddedCover,
    MusicHostNetworkSource? networkSource,
    MusicStreamMaterializer? materializer,
    bool? cddaSupported,
    DateTime Function()? now,
  }) : _database = database,
       _animeEpisodeFile = animeEpisodeFile,
       _embeddedCover = embeddedCover ?? _readEmbeddedCover,
       _networkSource = networkSource,
       _materializer = materializer ?? MusicStreamMaterializer(),
       _cddaSupported = cddaSupported ?? Platform.isWindows,
       _now = now ?? DateTime.now;

  final MusicHostNetworkSource? _networkSource;
  final MusicStreamMaterializer _materializer;

  /// CDDA 能不能截：只有 Windows 有按扇区读光驱的实现（macOS 的 CD 挂成 AIFF 文件，入库就是本机文件）。
  final bool _cddaSupported;

  /// 这首经互联放不了的原因（这台 host 给不出字节）；能放为 null。
  String? unplayableReason(MusicTrackRow t) => switch (musicHostTrackOrigin(
    t,
  )) {
    MusicHostTrackOrigin.localFile || MusicHostTrackOrigin.discTitle => null,
    MusicHostTrackOrigin.networkSource =>
      _networkSource == null ? RemoteMusicUnplayable.networkSource : null,
    MusicHostTrackOrigin.cdda =>
      _cddaSupported ? null : RemoteMusicUnplayable.cdda,
  };

  final FushiDatabase? Function() _database;
  final MusicHostAnimeEpisodeFile? _animeEpisodeFile;
  final MusicHostEmbeddedCover _embeddedCover;
  final DateTime Function() _now;

  int get _nowMs => _now().millisecondsSinceEpoch;

  FushiDatabase get _db {
    final FushiDatabase? db = _database();
    if (db == null) throw StateError('music database not ready');
    return db;
  }

  /// 数据库就绪（能力位据此报 `music`）。
  bool get available => _database() != null;

  // ── 专辑 ────────────────────────────────────────────────────────────────

  Future<RemoteMusicPage<RemoteMusicAlbum>> listAlbums({
    int offset = 0,
    int limit = kRemoteMusicPageLimit,
    String sort = 'name',
  }) async {
    final List<RemoteMusicAlbum> all = await _albumsWhere(null);
    switch (sort) {
      case 'newest':
        all.sort(
          (RemoteMusicAlbum a, RemoteMusicAlbum b) =>
              (b.updatedAt ?? 0).compareTo(a.updatedAt ?? 0),
        );
      case 'artist':
        all.sort(
          (RemoteMusicAlbum a, RemoteMusicAlbum b) => _cmp(
            a.artist ?? '',
            b.artist ?? '',
            then: () => _cmp(a.title, b.title),
          ),
        );
      case 'year':
        all.sort(
          (RemoteMusicAlbum a, RemoteMusicAlbum b) =>
              (b.year ?? 0).compareTo(a.year ?? 0) != 0
              ? (b.year ?? 0).compareTo(a.year ?? 0)
              : _cmp(a.title, b.title),
        );
      default:
        break; // 库里已按 title_sort / title 排好。
    }
    return _page(all, offset, limit);
  }

  Future<List<RemoteMusicAlbum>> _albumsWhere(Set<String>? onlyUids) async {
    final FushiDatabase db = _db;
    final Map<String, _AlbumAgg> agg = await _albumAggregates(db);
    final List<MusicAlbumRow> rows = await db.listMusicAlbums();
    return <RemoteMusicAlbum>[
      for (final MusicAlbumRow a in rows)
        if (onlyUids == null || onlyUids.contains(a.albumUid))
          _albumDto(a, agg[a.albumUid]),
    ];
  }

  RemoteMusicAlbum _albumDto(MusicAlbumRow a, _AlbumAgg? agg) =>
      RemoteMusicAlbum(
        id: a.albumUid,
        title: a.title,
        artist: a.albumArtistCredit,
        artistId: agg?.albumArtistUid,
        year: agg?.year ?? _yearOf(a.releaseDate),
        trackCount: agg?.count,
        durationMs: agg?.durationMs,
        coverRef: musicHostAlbumCoverRef(a.albumUid),
        updatedAt: a.updatedAt,
      );

  /// 一张专辑的曲目（按碟号 / 轨号）。
  Future<List<RemoteMusicTrack>> albumTracks(String albumUid) async {
    final FushiDatabase db = _db;
    final MusicAlbumRow? album = await db.getMusicAlbum(albumUid);
    final List<MusicTrackRow> rows = await db.listMusicTracks(
      albumUid: albumUid,
    );
    rows.sort(_trackOrder);
    return _tracksDto(
      db,
      rows,
      albums: <String, MusicAlbumRow>{if (album != null) albumUid: album},
    );
  }

  // ── 艺人 ────────────────────────────────────────────────────────────────

  Future<RemoteMusicPage<RemoteMusicArtist>> listArtists({
    int offset = 0,
    int limit = kRemoteMusicPageLimit,
  }) async {
    final FushiDatabase db = _db;
    final List<MusicArtistRow> rows = await db.listMusicArtists();
    final Map<String, int> albumCounts = await _artistAlbumCounts(db);
    return _page(
      <RemoteMusicArtist>[
        for (final MusicArtistRow a in rows)
          RemoteMusicArtist(
            id: a.artistUid,
            name: a.name,
            albumCount: albumCounts[a.artistUid],
          ),
      ],
      offset,
      limit,
    );
  }

  Future<List<RemoteMusicAlbum>> artistAlbums(String artistUid) async {
    final List<MusicTrackRow> tracks = await _db.listMusicTracksByArtist(
      artistUid,
    );
    final Set<String> albumUids = <String>{
      for (final MusicTrackRow t in tracks) ?t.albumUid,
    };
    if (albumUids.isEmpty) return const <RemoteMusicAlbum>[];
    return _albumsWhere(albumUids);
  }

  // ── 歌单 ────────────────────────────────────────────────────────────────

  Future<RemoteMusicPage<RemoteMusicPlaylist>> listPlaylists({
    int offset = 0,
    int limit = kRemoteMusicPageLimit,
  }) async {
    final FushiDatabase db = _db;
    final Map<String, int> counts = await db.countMusicPlaylistEntries();
    return _page(
      <RemoteMusicPlaylist>[
        for (final MusicPlaylistRow pl in await db.listMusicPlaylists())
          _playlistDto(pl, counts[pl.playlistUid]),
      ],
      offset,
      limit,
    );
  }

  RemoteMusicPlaylist _playlistDto(MusicPlaylistRow pl, int? count) =>
      RemoteMusicPlaylist(
        id: pl.playlistUid,
        title: pl.name,
        trackCount: count,
        editable: pl.rulesJson == null,
        updatedAt: pl.updatedAt,
      );

  /// 歌单曲目（歌单自身顺序）。引用到 host 本机曲库以外（YouTube / 插件 / 服务器）的条目跳过：
  /// 那些在客户端各有自己的来源与合规门，不借互联绕开（设计 §4.2）。
  Future<List<RemoteMusicTrack>> playlistTracks(String playlistUid) async {
    final FushiDatabase db = _db;
    final List<MusicPlaylistEntryRow> entries = await db
        .listMusicPlaylistEntries(playlistUid);
    final Map<String, MusicTrackRow> byUid = await db.listMusicTracksByUid(
      entries.map((MusicPlaylistEntryRow e) => e.trackUid),
    );
    final List<(MusicPlaylistEntryRow, MusicTrackRow)> live =
        <(MusicPlaylistEntryRow, MusicTrackRow)>[
          for (final MusicPlaylistEntryRow e in entries)
            if (byUid[e.trackUid] case final MusicTrackRow t
                when t.deletedAt == null)
              (e, t),
        ];
    final List<RemoteMusicTrack> dtos = await _tracksDto(db, <MusicTrackRow>[
      for (final (MusicPlaylistEntryRow _, MusicTrackRow t) in live) t,
    ]);
    return <RemoteMusicTrack>[
      for (int i = 0; i < live.length; i++)
        _withEntry(dtos[i], live[i].$1.id.toString()),
    ];
  }

  // ── 搜索 / 单曲 ─────────────────────────────────────────────────────────

  Future<RemoteMusicSearchResult> search(String query, {int limit = 30}) async {
    final String q = query.trim().toLowerCase();
    if (q.isEmpty) return const RemoteMusicSearchResult();
    final int cap = limit.clamp(1, kRemoteMusicPageLimit);
    final FushiDatabase db = _db;
    bool hit(String? s) => s != null && s.toLowerCase().contains(q);
    final List<RemoteMusicAlbum> albums = <RemoteMusicAlbum>[
      for (final RemoteMusicAlbum a in await _albumsWhere(null))
        if (hit(a.title) || hit(a.artist)) a,
    ].take(cap).toList();
    final List<RemoteMusicArtist> artists = <RemoteMusicArtist>[
      for (final MusicArtistRow a in await db.listMusicArtists())
        if (hit(a.name)) RemoteMusicArtist(id: a.artistUid, name: a.name),
    ].take(cap).toList();
    final String like = '%${q.replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
    final List<MusicTrackRow> trackRows =
        await (db.select(db.musicTracks)
              ..where(
                ($MusicTracksTable t) =>
                    t.deletedAt.isNull() &
                    (t.title.lower().like(like) |
                        t.artistCredit.lower().like(like)),
              )
              ..orderBy(<OrderingTerm Function($MusicTracksTable)>[
                ($MusicTracksTable t) => OrderingTerm(expression: t.title),
              ])
              ..limit(cap))
            .get();
    final List<RemoteMusicPlaylist> playlists = <RemoteMusicPlaylist>[
      for (final MusicPlaylistRow pl in await db.listMusicPlaylists())
        if (hit(pl.name)) _playlistDto(pl, null),
    ].take(cap).toList();
    return RemoteMusicSearchResult(
      albums: albums,
      artists: artists,
      tracks: await _tracksDto(db, trackRows),
      playlists: playlists,
    );
  }

  /// 单曲详情（客户端解析歌单 / 历史里的 uid 时用）；不在库 / 已删为 null。
  Future<RemoteMusicTrack?> track(String trackUid) async {
    final FushiDatabase db = _db;
    final MusicTrackRow? row = await db.getMusicTrack(trackUid);
    if (row == null || row.deletedAt != null) return null;
    return (await _tracksDto(db, <MusicTrackRow>[row])).single;
  }

  // ── 流 / 封面 ───────────────────────────────────────────────────────────

  /// 统一流票 `musicTrack` 的「请求 → 字节来源」：只认在库、这台 host 给得出字节的曲目。
  ///
  /// 回的说明（随签票响应给 client）：`transcoded` / `codec` / `bitrateKbps`（转了码）、
  /// `segmentApplied`（文件就是这一首，CUE / 章节起止已截好，client 不再拼 EDL 段）。
  Future<LibraryMediaSource?> trackSource(LibraryMediaRequest request) async {
    final MusicTrackRow? row = await _db.getMusicTrack(request.id);
    if (row == null || row.deletedAt != null) return null;
    if (unplayableReason(row) != null) return null;
    final int? cap = _bitrateCap(request.options);
    // 源本身就不超过上限（有损小码率）时不转：转了只会更差。
    final int? sourceKbps = row.bitrate == null
        ? null
        : (row.bitrate! / 1000).round();
    final int? kbps = cap != null && (sourceKbps == null || sourceKbps > cap)
        ? cap
        : null;
    final int? start = row.cueStartMs;
    final int? end = row.cueEndMs;
    final String version = '${row.fileMtimeAt}|${row.fileSize}';
    Map<String, Object?> info({required bool segment}) => <String, Object?>{
      'transcoded': kbps != null,
      if (kbps != null) 'codec': 'aac',
      if (kbps != null) 'bitrateKbps': kbps,
      'segmentApplied': segment,
    };
    Future<LibraryMediaSource> cut(MusicMaterializeInput input) async {
      try {
        final File f = await _materializer.materialize(
          input,
          startMs: start,
          endMs: end,
          bitrateKbps: kbps,
        );
        return LibraryMediaFile(f, info: info(segment: true));
      } on MusicMaterializeException catch (e) {
        throw LibraryMediaUnavailable(500, e.message);
      } on Exception catch (e) {
        throw LibraryMediaUnavailable(500, '$e');
      }
    }

    switch (musicHostTrackOrigin(row)) {
      case MusicHostTrackOrigin.localFile:
        final File f = File(row.path);
        if (!await f.exists()) return null;
        // 下载要整首（CUE 虚拟曲目也截成单独的文件）；播放时整文件 + client 拼 EDL 段即可。
        final bool wantSegment =
            request.options[kMusicStreamOptionSegment] == true && start != null;
        if (kbps == null && !wantSegment) {
          return LibraryMediaFile(f, info: info(segment: false));
        }
        return cut(MusicFfmpegInput(f.path, version: version));
      case MusicHostTrackOrigin.networkSource:
        final ({Uri url, Map<String, String> headers})? up;
        try {
          up = await _networkSource!(row);
        } on Object catch (e) {
          throw LibraryMediaUnavailable(502, 'Source unreachable: $e');
        }
        if (up == null) {
          throw const LibraryMediaUnavailable(502, 'Source unavailable');
        }
        if (kbps == null &&
            !(request.options[kMusicStreamOptionSegment] == true &&
                start != null)) {
          return LibraryMediaUpstream(
            up.url,
            headers: up.headers,
            info: info(segment: false),
          );
        }
        return cut(
          MusicFfmpegInput(
            up.url.toString(),
            headers: up.headers,
            version: version,
          ),
        );
      case MusicHostTrackOrigin.discTitle:
        final String? input = _discTitleInput(row.path);
        if (input == null) return null;
        return cut(MusicFfmpegInput(input, version: version));
      case MusicHostTrackOrigin.cdda:
        return cut(
          MusicCddaInput(
            row.path.substring('cdda://'.length),
            discId: row.albumUid ?? row.trackUid,
          ),
        );
    }
  }

  static int? _bitrateCap(Map<String, Object?> options) {
    final Object? v = options[kMusicStreamOptionMaxBitrate];
    if (v is! num) return null;
    final int k = v.toInt();
    // 不合理的值当没给（不让 client 把 host 拖去转 8 kbps）。
    return k >= 32 && k <= 1411 ? k : null;
  }

  /// 光盘标题曲目的 ffmpeg 输入：DVD → `dvdvideo` title 输入；BD → `.mpls` 本身（原盘适配器改写）。
  static String? _discTitleInput(String path) {
    if (isDvdTitlePath(path)) {
      final String? root = dvdDiscRootForTitlePath(path);
      final int? title = dvdTitleNumberForPath(path);
      if (root == null || title == null) return null;
      return encodeDvdTitleInput(
        DvdTitleInput(disc: musicDvdDemuxerSource(root), title: title),
      );
    }
    return path;
  }

  /// 统一流票 `musicVideo` 的「id → 文件」：host 本机能解析成文件的绑定（`local` 含蓝光 `.m2ts`、
  /// `anime_episode`）。YouTube 绑定没有 host 字节，不签票。
  Future<File?> videoFile(String videoId) async {
    final int? id = int.tryParse(videoId);
    if (id == null) return null;
    final FushiDatabase db = _db;
    final MusicVideoRow? row = await (db.select(
      db.musicVideos,
    )..where(($MusicVideosTable t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return null;
    return _videoRowFile(row);
  }

  Future<File?> _videoRowFile(MusicVideoRow row) async {
    switch (row.kind) {
      case MusicVideoKind.local:
        final File f = File(row.ref);
        return await f.exists() ? f : null;
      case MusicVideoKind.animeEpisode:
        final ({String bookUid, int episodeIndex})? ref =
            parseAnimeEpisodeMusicVideoRef(row.ref);
        if (ref == null) return null;
        final File? f = await (_animeEpisodeFile ?? _animeEpisode)(
          ref.bookUid,
          ref.episodeIndex,
        );
        return f != null && await f.exists() ? f : null;
      default:
        return null;
    }
  }

  /// 封面（[musicHostAlbumCoverRef] / [musicHostTrackCoverRef]）：专辑目录封面优先，没有再取代表
  /// 曲目的内嵌封面。都没有为 null。
  Future<MusicHostCover?> cover(String ref) async {
    final FushiDatabase db = _db;
    String? albumUid;
    String? trackUid;
    if (ref.startsWith(_kAlbumCoverPrefix)) {
      albumUid = ref.substring(_kAlbumCoverPrefix.length);
    } else if (ref.startsWith(_kTrackCoverPrefix)) {
      trackUid = ref.substring(_kTrackCoverPrefix.length);
      albumUid = (await db.getMusicTrack(trackUid))?.albumUid;
    } else {
      return null;
    }
    final MusicAlbumRow? album = albumUid == null
        ? null
        : await db.getMusicAlbum(albumUid);
    final String? coverPath = album?.coverPath;
    if (coverPath != null && coverPath.isNotEmpty) {
      final File f = File(coverPath);
      if (await f.exists()) return (file: f, bytes: null);
    }
    final String? fromUid = trackUid ?? album?.coverTrackUid;
    MusicTrackRow? source = fromUid == null
        ? null
        : await db.getMusicTrack(fromUid);
    if (source == null && albumUid != null) {
      final List<MusicTrackRow> tracks = await db.listMusicTracks(
        albumUid: albumUid,
      );
      for (final MusicTrackRow t in tracks) {
        if (t.hasEmbeddedCover) {
          source = t;
          break;
        }
      }
    }
    if (source == null || !source.hasEmbeddedCover) return null;
    if (musicHostTrackOrigin(source) != MusicHostTrackOrigin.localFile) {
      return null;
    }
    final Uint8List? bytes = await _embeddedCover(source.path);
    return bytes == null || bytes.isEmpty ? null : (file: null, bytes: bytes);
  }

  /// 视频库 bookUid + 集号 → 本机文件（[themeSongFilesOf] 展开播放列表，只留本机路径）。
  Future<File?> _animeEpisode(String bookUid, int episodeIndex) async {
    final VideoBookRow? row = await VideoBookRepository(
      _db,
    ).getByBookUid(bookUid);
    if (row == null) return null;
    for (final ({int index, String path}) f in themeSongFilesOf(row)) {
      if (f.index == episodeIndex) return File(f.path);
    }
    return null;
  }

  // ── 歌词 ────────────────────────────────────────────────────────────────

  /// host 上这首生效的歌词（引擎层，不联网）：库里的行按 [preferredMusicLyricRow]（用户手动指定 >
  /// sidecar > 内嵌 > 生成字幕 > 插件 > LRCLIB …）取；库里没有时现读同目录 sidecar 原文（客户端自己解析）。
  /// 都没有为 null（路由回 204）。
  Future<RemoteMusicLyrics?> lyrics(String trackUid) async {
    final FushiDatabase db = _db;
    final MusicTrackRow? track = await db.getMusicTrack(trackUid);
    if (track == null || track.deletedAt != null) return null;
    final List<MusicLyricRow> rows = await (db.select(
      db.musicLyrics,
    )..where(($MusicLyricsTable l) => l.trackUid.equals(trackUid))).get();
    final MusicLyricRow? best = preferredMusicLyricRow(rows);
    if (best != null) {
      return RemoteMusicLyrics(
        source: best.source,
        format: best.format,
        raw: best.raw,
        offsetMs: best.offsetMs,
        timingQuality: best.timingQuality,
        isUserEdited: best.isUserEdited,
        updatedAt: best.updatedAt,
      );
    }
    // CUE 虚拟曲目与非本机文件没有 sidecar（与 `MusicLyricsTrackRef.readsLocalLyrics` 同口径）。
    if (track.cueStartMs != null ||
        musicHostTrackOrigin(track) != MusicHostTrackOrigin.localFile) {
      return null;
    }
    final LyricSidecarFile? side = await _sidecarOf(track.path);
    if (side == null) return null;
    final Uint8List raw;
    try {
      raw = await File(side.path).readAsBytes();
    } on FileSystemException {
      return null;
    }
    return RemoteMusicLyrics(
      source: MusicLyricsSource.sidecar,
      format: side.ext,
      raw: raw,
      updatedAt: _nowMs,
    );
  }

  Future<LyricSidecarFile?> _sidecarOf(String audioPath) async {
    final Directory dir = File(audioPath).parent;
    final List<String> siblings = <String>[];
    try {
      await for (final FileSystemEntity e in dir.list(followLinks: false)) {
        if (e is File) siblings.add(e.path);
      }
    } on FileSystemException {
      return null;
    }
    return pickLyricSidecars(audioPath, siblings).primary;
  }

  /// 写回整首歌词偏移（design-imusic-q3）：改 [source] 那一行，按 [updatedAt] LWW——比库里旧的写入
  /// 不生效（另一台设备后调的为准）。返回生效后的偏移；这一行不存在时 null（404）。
  Future<int?> setLyricsOffset(
    String trackUid, {
    required String source,
    required int offsetMs,
    required int updatedAt,
  }) async {
    final FushiDatabase db = _db;
    return db.transaction(() async {
      final MusicLyricRow? row =
          await (db.select(db.musicLyrics)..where(
                ($MusicLyricsTable l) =>
                    l.trackUid.equals(trackUid) & l.source.equals(source),
              ))
              .getSingleOrNull();
      if (row == null) return null;
      if (updatedAt < row.updatedAt) return row.offsetMs;
      await (db.update(db.musicLyrics)..where(
            ($MusicLyricsTable l) =>
                l.trackUid.equals(trackUid) & l.source.equals(source),
          ))
          .write(
            MusicLyricsCompanion(
              offsetMs: Value<int>(offsetMs),
              updatedAt: Value<int>(updatedAt),
            ),
          );
      return offsetMs;
    });
  }

  /// 写回「换歌词来源」（design-imusic-q3）：客户端选定的一份写成 host 上的手动指定（`user` 行，
  /// `is_user_edited`）。原文由客户端按本机同一写法备好（TTML；ASS / SSA 原样），时间轴缓存留空，
  /// host 用到时现解析。曲目不在库回 false。
  Future<bool> chooseLyrics(
    String trackUid, {
    required String format,
    required Uint8List raw,
    required int offsetMs,
  }) async {
    final FushiDatabase db = _db;
    final MusicTrackRow? track = await db.getMusicTrack(trackUid);
    if (track == null || track.deletedAt != null) return false;
    await db
        .into(db.musicLyrics)
        .insertOnConflictUpdate(
          MusicLyricsCompanion(
            trackUid: Value<String>(trackUid),
            source: const Value<String>(MusicLyricsSource.user),
            format: Value<String>(format),
            raw: Value<Uint8List>(raw),
            timelineCache: const Value<Uint8List?>(null),
            timelineVersion: const Value<int>(0),
            isUserEdited: const Value<bool>(true),
            offsetMs: Value<int>(offsetMs),
            updatedAt: Value<int>(_nowMs),
          ),
        );
    return true;
  }

  // ── MV ─────────────────────────────────────────────────────────────────

  /// 一首曲目在 host 上的 MV 绑定：`local` / `anime_episode` 只出解析得到文件的（文件不在、光盘没插
  /// 的不出）；`youtube` 带地址下发（design-imusic-q7），由客户端按自己的 YouTube 合规门取流。
  Future<List<RemoteMusicVideo>> videos(String trackUid) async {
    final FushiDatabase db = _db;
    final List<RemoteMusicVideo> out = <RemoteMusicVideo>[];
    for (final MusicVideoRow row in await db.listMusicVideos(trackUid)) {
      if (row.kind == MusicVideoKind.youtube) {
        out.add(_videoDto(row, youtubeRef: row.ref));
        continue;
      }
      if (await _videoRowFile(row) != null) out.add(_videoDto(row));
    }
    return out;
  }

  RemoteMusicVideo _videoDto(MusicVideoRow row, {String? youtubeRef}) =>
      RemoteMusicVideo(
        videoId: row.id,
        kind: row.kind,
        offsetMs: row.offsetMs,
        confidence: row.confidence,
        isUserBound: row.isUserBound,
        youtubeRef: youtubeRef,
        updatedAt: row.updatedAt,
      );

  /// 写回 MV 对齐微调（design-imusic-q3），按 [updatedAt] LWW。绑定不存在回 null。
  Future<int?> setVideoOffset(
    int videoId, {
    required int offsetMs,
    required int updatedAt,
  }) async {
    final FushiDatabase db = _db;
    return db.transaction(() async {
      final MusicVideoRow? row =
          await (db.select(db.musicVideos)
                ..where(($MusicVideosTable t) => t.id.equals(videoId)))
              .getSingleOrNull();
      if (row == null) return null;
      if (updatedAt < row.updatedAt) return row.offsetMs;
      await (db.update(
        db.musicVideos,
      )..where(($MusicVideosTable t) => t.id.equals(videoId))).write(
        MusicVideosCompanion(
          offsetMs: Value<int>(offsetMs),
          updatedAt: Value<int>(updatedAt),
        ),
      );
      return offsetMs;
    });
  }

  // ── 歌单写回（design-imusic-q3：照合集，客户端的修改写回 host）───────────

  Future<RemoteMusicPlaylist> createPlaylist(
    String name, {
    List<String> trackUids = const <String>[],
  }) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) throw const MusicHostWriteError(400, 'empty name');
    final FushiDatabase db = _db;
    final List<String> uids = await _knownTrackUids(db, trackUids);
    final MusicPlaylistRow row = await db.createMusicPlaylist(
      trimmed,
      at: _nowMs,
      trackUids: uids,
    );
    return _playlistDto(row, uids.length);
  }

  Future<void> addToPlaylist(String playlistUid, List<String> trackUids) async {
    final FushiDatabase db = _db;
    await _editablePlaylist(db, playlistUid);
    final List<String> uids = await _knownTrackUids(db, trackUids);
    if (uids.isEmpty) return;
    await db.addMusicPlaylistEntries(playlistUid, uids, at: _nowMs);
  }

  Future<void> removeFromPlaylist(
    String playlistUid,
    List<String> entryIds,
  ) async {
    final FushiDatabase db = _db;
    await _editablePlaylist(db, playlistUid);
    await db.removeMusicPlaylistEntries(playlistUid, <int>[
      for (final String id in entryIds) ?int.tryParse(id),
    ], at: _nowMs);
  }

  Future<void> movePlaylistEntry(
    String playlistUid,
    String entryId,
    int newIndex,
  ) async {
    final FushiDatabase db = _db;
    await _editablePlaylist(db, playlistUid);
    final int? id = int.tryParse(entryId);
    final List<int> order = <int>[
      for (final MusicPlaylistEntryRow e in await db.listMusicPlaylistEntries(
        playlistUid,
      ))
        e.id,
    ];
    if (id == null || !order.remove(id)) {
      throw const MusicHostWriteError(404, 'entry not found');
    }
    order.insert(newIndex.clamp(0, order.length), id);
    await db.reorderMusicPlaylist(playlistUid, order, at: _nowMs);
  }

  Future<void> renamePlaylist(String playlistUid, String name) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) throw const MusicHostWriteError(400, 'empty name');
    final FushiDatabase db = _db;
    await _editablePlaylist(db, playlistUid, allowSmart: true);
    await db.renameMusicPlaylist(playlistUid, trimmed, at: _nowMs);
  }

  Future<void> deletePlaylist(String playlistUid) async {
    final FushiDatabase db = _db;
    await _editablePlaylist(db, playlistUid, allowSmart: true);
    await db.deleteMusicPlaylist(playlistUid, at: _nowMs);
  }

  Future<MusicPlaylistRow> _editablePlaylist(
    FushiDatabase db,
    String playlistUid, {
    bool allowSmart = false,
  }) async {
    final MusicPlaylistRow? row = await db.getMusicPlaylist(playlistUid);
    if (row == null) throw const MusicHostWriteError(404, 'playlist not found');
    if (!allowSmart && row.rulesJson != null) {
      throw const MusicHostWriteError(409, 'smart playlist');
    }
    return row;
  }

  /// 只收 host 曲库里在的曲目（客户端不能借歌单往 host 里塞 host 不认识的 uid）。
  Future<List<String>> _knownTrackUids(
    FushiDatabase db,
    List<String> trackUids,
  ) async {
    final Map<String, MusicTrackRow> rows = await db.listMusicTracksByUid(
      trackUids,
    );
    return <String>[
      for (final String uid in trackUids)
        if (rows[uid] case final MusicTrackRow t when t.deletedAt == null) uid,
    ];
  }

  // ── 内部 ────────────────────────────────────────────────────────────────

  Future<List<RemoteMusicTrack>> _tracksDto(
    FushiDatabase db,
    List<MusicTrackRow> rows, {
    Map<String, MusicAlbumRow>? albums,
  }) async {
    if (rows.isEmpty) return const <RemoteMusicTrack>[];
    final Map<String, MusicAlbumRow> albumRows = <String, MusicAlbumRow>{
      ...?albums,
    };
    for (final String uid in <String>{
      for (final MusicTrackRow t in rows) ?t.albumUid,
    }) {
      if (albumRows.containsKey(uid)) continue;
      final MusicAlbumRow? a = await db.getMusicAlbum(uid);
      if (a != null) albumRows[uid] = a;
    }
    final Set<String> withVideos = await _tracksWithVideos(db, <String>[
      for (final MusicTrackRow t in rows) t.trackUid,
    ]);
    return <RemoteMusicTrack>[
      for (final MusicTrackRow t in rows)
        _trackDto(
          t,
          t.albumUid == null ? null : albumRows[t.albumUid],
          hasVideos: withVideos.contains(t.trackUid),
        ),
    ];
  }

  RemoteMusicTrack _trackDto(
    MusicTrackRow t,
    MusicAlbumRow? album, {
    required bool hasVideos,
  }) {
    final String ext = p.extension(t.path).replaceFirst('.', '').toLowerCase();
    return RemoteMusicTrack(
      id: t.trackUid,
      title: t.title,
      artist: t.artistCredit,
      album: album?.title,
      albumId: t.albumUid,
      discNo: t.discNo,
      trackNo: t.trackNo,
      durationMs: t.durationMs,
      container: ext.isEmpty ? null : ext,
      codec: t.codec,
      bitrateKbps: t.bitrate == null ? null : (t.bitrate! / 1000).round(),
      sampleRate: t.sampleRate,
      bitDepth: t.bitDepth,
      channels: t.channels,
      sizeBytes: t.cueStartMs == null ? t.fileSize : null,
      coverRef: t.albumUid != null
          ? musicHostAlbumCoverRef(t.albumUid!)
          : (t.hasEmbeddedCover ? musicHostTrackCoverRef(t.trackUid) : null),
      cueStartMs: t.cueStartMs,
      cueEndMs: t.cueEndMs,
      isVideo: kMusicVideoExtensions.contains(ext),
      unplayableReason: unplayableReason(t),
      hasVideos: hasVideos,
      updatedAt: t.fileMtimeAt,
    );
  }

  Future<Set<String>> _tracksWithVideos(
    FushiDatabase db,
    List<String> trackUids,
  ) async {
    final Set<String> out = <String>{};
    for (int i = 0; i < trackUids.length; i += 500) {
      final List<String> chunk = trackUids.sublist(
        i,
        i + 500 > trackUids.length ? trackUids.length : i + 500,
      );
      final List<MusicVideoRow> rows = await (db.select(
        db.musicVideos,
      )..where(($MusicVideosTable t) => t.trackUid.isIn(chunk))).get();
      out.addAll(<String>[for (final MusicVideoRow r in rows) r.trackUid]);
    }
    return out;
  }

  Future<Map<String, _AlbumAgg>> _albumAggregates(FushiDatabase db) async {
    final Set<ResultSetImplementation<dynamic, dynamic>> tables =
        <ResultSetImplementation<dynamic, dynamic>>{
          db.musicTracks,
          db.musicTrackCredits,
        };
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT album_uid, COUNT(*) AS n, SUM(duration_ms) AS dur, '
          'MAX(year) AS year FROM music_tracks WHERE deleted_at IS NULL '
          'AND album_uid IS NOT NULL GROUP BY album_uid',
          readsFrom: tables,
        )
        .get();
    // 专辑艺人：该专辑任一在库曲目上 role = album_artist 的署名（按 ord 取第一个）。
    final List<QueryRow> credits = await db
        .customSelect(
          'SELECT t.album_uid AS album_uid, c.artist_uid AS artist_uid '
          'FROM music_track_credits c JOIN music_tracks t '
          'ON t.track_uid = c.track_uid WHERE t.deleted_at IS NULL '
          "AND t.album_uid IS NOT NULL AND c.role = 'album_artist' "
          'ORDER BY t.album_uid, c.ord',
          readsFrom: tables,
        )
        .get();
    final Map<String, String> albumArtist = <String, String>{};
    for (final QueryRow r in credits) {
      albumArtist.putIfAbsent(
        r.read<String>('album_uid'),
        () => r.read<String>('artist_uid'),
      );
    }
    return <String, _AlbumAgg>{
      for (final QueryRow r in rows)
        r.read<String>('album_uid'): _AlbumAgg(
          count: r.read<int>('n'),
          durationMs: r.readNullable<int>('dur'),
          year: r.readNullable<int>('year'),
          albumArtistUid: albumArtist[r.read<String>('album_uid')],
        ),
    };
  }

  Future<Map<String, int>> _artistAlbumCounts(FushiDatabase db) async {
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT c.artist_uid AS artist_uid, '
          'COUNT(DISTINCT t.album_uid) AS n FROM music_track_credits c '
          'JOIN music_tracks t ON t.track_uid = c.track_uid '
          'WHERE t.deleted_at IS NULL AND t.album_uid IS NOT NULL '
          "AND c.role IN ('artist', 'album_artist') GROUP BY c.artist_uid",
          readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
            db.musicTracks,
            db.musicTrackCredits,
          },
        )
        .get();
    return <String, int>{
      for (final QueryRow r in rows)
        r.read<String>('artist_uid'): r.read<int>('n'),
    };
  }

  static RemoteMusicPage<T> _page<T>(List<T> all, int offset, int limit) {
    final int start = offset.clamp(0, all.length);
    final int size = limit.clamp(1, kRemoteMusicPageLimit);
    final int end = (start + size).clamp(0, all.length);
    return RemoteMusicPage<T>(
      items: all.sublist(start, end),
      nextOffset: end < all.length ? end : null,
      total: all.length,
    );
  }

  static RemoteMusicTrack _withEntry(RemoteMusicTrack t, String entryId) =>
      RemoteMusicTrack(
        id: t.id,
        title: t.title,
        artist: t.artist,
        album: t.album,
        albumId: t.albumId,
        discNo: t.discNo,
        trackNo: t.trackNo,
        durationMs: t.durationMs,
        container: t.container,
        codec: t.codec,
        bitrateKbps: t.bitrateKbps,
        sampleRate: t.sampleRate,
        bitDepth: t.bitDepth,
        channels: t.channels,
        sizeBytes: t.sizeBytes,
        coverRef: t.coverRef,
        playlistEntryId: entryId,
        cueStartMs: t.cueStartMs,
        cueEndMs: t.cueEndMs,
        isVideo: t.isVideo,
        unplayableReason: t.unplayableReason,
        hasVideos: t.hasVideos,
        updatedAt: t.updatedAt,
      );

  static int _trackOrder(MusicTrackRow a, MusicTrackRow b) {
    final int d = (a.discNo ?? 0).compareTo(b.discNo ?? 0);
    if (d != 0) return d;
    final int n = (a.trackNo ?? 1 << 20).compareTo(b.trackNo ?? 1 << 20);
    return n != 0 ? n : a.title.compareTo(b.title);
  }

  static int _cmp(String a, String b, {int Function()? then}) {
    final int c = a.toLowerCase().compareTo(b.toLowerCase());
    return c != 0 || then == null ? c : then();
  }

  static int? _yearOf(String? releaseDate) =>
      releaseDate == null || releaseDate.length < 4
      ? null
      : int.tryParse(releaseDate.substring(0, 4));
}

class _AlbumAgg {
  const _AlbumAgg({
    required this.count,
    this.durationMs,
    this.year,
    this.albumArtistUid,
  });

  final int count;
  final int? durationMs;
  final int? year;
  final String? albumArtistUid;
}

const String _kAlbumCoverPrefix = 'a:';
const String _kTrackCoverPrefix = 't:';

/// 专辑封面的 wire 引用。
String musicHostAlbumCoverRef(String albumUid) =>
    '$_kAlbumCoverPrefix$albumUid';

/// 没有专辑的散曲的内嵌封面引用。
String musicHostTrackCoverRef(String trackUid) =>
    '$_kTrackCoverPrefix$trackUid';

/// 曲目字节从哪来。
enum MusicHostTrackOrigin { localFile, networkSource, discTitle, cdda }

/// 按路径判曲目来源：`cdda://` 整盘、光盘 title 身份路径、网络来源（有 sourceId 的远程地址）、本机文件。
MusicHostTrackOrigin musicHostTrackOrigin(MusicTrackRow t) {
  final String lower = t.path.toLowerCase();
  if (lower.startsWith('cdda://')) return MusicHostTrackOrigin.cdda;
  if (isMusicDiscTitlePath(t.path)) return MusicHostTrackOrigin.discTitle;
  if (t.sourceId != null &&
      (lower.startsWith('sftp://') ||
          lower.startsWith('https://') ||
          lower.startsWith('http://'))) {
    return MusicHostTrackOrigin.networkSource;
  }
  return MusicHostTrackOrigin.localFile;
}

/// 内嵌封面（读整个文件头里的图片块，放后台 isolate）。`fushi_music` 原生库不在（未随包的服务端）
/// 时没有内嵌封面，只出目录封面。
Future<Uint8List?> _readEmbeddedCover(String audioPath) async {
  try {
    return await Isolate.run(() => readMusicEmbeddedCover(audioPath));
  } on Object {
    return null;
  }
}
