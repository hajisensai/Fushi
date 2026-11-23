/// 服务器曲目（Jellyfin / Subsonic）的离线副本：把服务器上的**原文件**下到本机，之后这首
/// 一律放本地文件（不连服务器），服务器离线 / 重启后照样能放。
///
/// - 地址：浏览器实现 [MusicServerDownloading] 才能下（Jellyfin `/Items/{id}/Download`、
///   Subsonic `download`）。下的是服务器存的那份字节——不转码、不受串流码率上限影响，
///   标签 / 内嵌封面原样随文件走。带凭据的地址只在内存里拼、只交给传输原语；失败文本经
///   [musicServerDownloadErrorText] 脱敏后才进下载中心 / 错误日志。
/// - 传输：与在线音源插件下载同一个下载器（`AnimeEpisodeDownloader.download`：`.part` + Range
///   续传与流身份校验），任务交给 app 级 [InterconnectDownloadManager]——进度 / 暂停 / 取消 /
///   失败重试都在下载中心，离页照跑；来源标「自己的服务器」（[InterconnectDownloadOrigin.ownDevice]）。
/// - 落点：`<下载根>/music/media-servers/<服务器名> [<服务器哈希>]/<专辑名> [<专辑哈希>]/
///   <碟-曲序> <标题> [<曲目哈希>].<扩展名>`（[musicServerDownloadTarget]），同目录 `cover.<ext>`
///   是专辑封面（离线时显示）。扩展名按文件头嗅探，认不出才用服务器报的容器。
/// - 离线用的附带数据：下完时顺带取服务器的歌词（[MusicServerLyricsProvider]，存进歌词缓存
///   `music_lyrics`，经 [musicServerDownloadLyricsSaver]）与响度（列表给的 +
///   [MusicServerLoudnessLookup] 补查，存到音频旁 `.loudness.json`；服务器没给曲目增益时对
///   下好的文件用 FFmpeg `ebur128` 测一次，存进同一个文件的 `measured`）。取不到不让下载失败。
/// - 状态：下完在同一个事务里把这首写进音乐库并落 `music_server_downloads` 行（设备本地，
///   只有本机路径 + 服务器身份 + 条目 id，不存地址）；播放时由进程内索引
///   （`music_server_download_index.dart`）换成本地文件。uid 不变，歌词缓存 / 断点 / 统计照旧。
/// - 删除：[MusicServerDownloadService.removeDownloads] 删行再删文件（专辑目录里没有别的曲目时
///   连封面与空目录一起删）；本机「从音乐库移除」（[MusicServerDownloadIndex.removeTracksFromLibrary]：
///   同时取消在跑的下载，下完的也不加回曲库）过了撤销窗口后经
///   [MusicServerDownloadIndex.dropDownloadsOutsideLibrary] 连带删副本。恢复 / 合并 / 启动从不
///   删副本（[MusicServerDownloadIndex.reconcileIntoLibrary] 把曲目放回曲库）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_engine/media/music/server/music_server_loudness.dart';
import 'package:fushi_engine/media/music/server/subsonic_music_client.dart'
    show redactSubsonicCredentials;
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/music/music_loudness_scanner.dart'
    show MusicLoudnessOutcome, measureMusicLoudness;
import 'package:fushi/src/media/music/music_remote_tracks.dart'
    show musicServerKindStorable, musicServerRemoteTrackCompanion;
import 'package:fushi/src/media/music/plugin/music_plugin_download.dart'
    show
        MusicPluginDownloadTarget,
        kMusicPluginDownloadAudioExtensions,
        musicDownloadPathSegment,
        sniffAudioExtension,
        sniffCoverExtension;
import 'package:fushi/src/media/music/server/music_server_download_index.dart';
import 'package:fushi/src/media/video/online/anime_episode_downloader.dart';
import 'package:fushi/src/storage/download_layout.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi/src/sync/remote_video_client.dart'
    show RemoteDownloadCancelled;
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 下载根下服务器曲目的目录名（磁盘目录名，冻结）。
const String kMusicServerDownloadsDirName = 'media-servers';

const List<String> _kCoverExtensions = <String>['jpg', 'png', 'webp'];

/// 下载封面时请服务器缩放到的边长。
const int kMusicServerDownloadCoverSize = 1200;

/// 一首服务器曲目的下载任务键（下载中心 / 去重 / 进度角标用）。
String musicServerDownloadTaskId(String trackUid) => 'music-server:$trackUid';

/// 专辑 / 艺人「下载」的批键。
String musicServerDownloadBatchId(String serverId, String scope, String id) =>
    'music-server-batch:${_hash('$serverId\u0000$scope\u0000$id', 8)}';

String _hash(String s, int bytes) {
  final List<int> d = sha1.convert(utf8.encode(s)).bytes;
  final StringBuffer b = StringBuffer();
  for (int i = 0; i < bytes; i++) {
    b.write(d[i].toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

/// 这台服务器上这首曲目的落点（纯函数）。专辑取 `track.albumId`（没有时自成一个目录，键是
/// 曲目 id），专辑名优先取 [albumTitle]（专辑页传进来的），碟号 > 1 时曲序写成 `2-03`。
MusicPluginDownloadTarget musicServerDownloadTarget(
  Directory root,
  MusicServerBrowser browser,
  MusicServerTrack track, {
  String? albumTitle,
}) {
  final String server = browser.serverId;
  final String serverDir =
      '${musicDownloadPathSegment(browser.displayName, max: 48)} '
      '[${_hash(server, 3)}]';
  final String? albumId = track.albumId;
  final String albumKey = albumId != null
      ? 'album\u0000$albumId'
      : 'track\u0000${track.id}';
  final String albumName = albumTitle ?? track.album ?? track.title;
  final String albumDir =
      '${musicDownloadPathSegment(albumName)} '
      '[${_hash('$server\u0000$albumKey', 4)}]';
  final int? no = track.trackNo;
  final int? disc = track.discNo;
  final String number = no == null || no <= 0
      ? ''
      : '${disc != null && disc > 1 ? '$disc-' : ''}'
            '${no.toString().padLeft(2, '0')} ';
  final String stem =
      '$number${musicDownloadPathSegment(track.title)} '
      '[${_hash('$server\u0000${track.id}', 4)}]';
  return MusicPluginDownloadTarget(
    dir: Directory(
      p.join(root.path, kMusicServerDownloadsDirName, serverDir, albumDir),
    ),
    stem: stem,
  );
}

/// 传输 / 取封面失败的文本脱敏：把这次请求的地址（含 query 里的 token / u+t+s / apiKey）整段
/// 抹掉，再过一遍通用的凭据参数脱敏。服务器路径保留（排障要看得出是哪台服务器）。
String musicServerDownloadErrorText(Object error, Uri uri) {
  String text = error.toString();
  if (uri.hasQuery && uri.query.isNotEmpty) {
    text = text.replaceAll(uri.query, '<redacted>');
    text = text.replaceAll(Uri.decodeQueryComponent(uri.query), '<redacted>');
  }
  return redactSubsonicCredentials(text);
}

/// 下载失败（文本已脱敏）。
final class MusicServerDownloadFailed implements Exception {
  const MusicServerDownloadFailed(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 下完的字节认不出是什么音频（文件头 / 服务器报的容器都没线索）。
final class MusicServerDownloadUnknownFormat implements Exception {
  const MusicServerDownloadUnknownFormat();

  @override
  String toString() => 'unrecognized audio format';
}

/// 把 [url] 落到 [dest]（缺省 `AnimeEpisodeDownloader.download`）。
typedef MusicServerDownloadTransfer =
    Future<void> Function({
      required String url,
      required Map<String, String> headers,
      required File dest,
      void Function(double progress)? onProgress,
      void Function(int received, int? total)? onBytes,
      Future<void>? cancelSignal,
    });

/// 取一张图片的字节（封面）。
typedef MusicServerDownloadBytesFetcher = Future<Uint8List> Function(Uri uri);

/// 一次发起的结果。
enum MusicServerDownloadStart {
  /// 已交给下载管理器。
  started,

  /// 同一首已在下载中。
  alreadyRunning,

  /// 已经有离线副本（确保在音乐库里）。
  alreadyDownloaded,

  /// 这台服务器不支持下载原文件（不是 Jellyfin / Subsonic）。
  unsupported,
}

/// 整批下载的结果（整批跑完才返回）。
typedef MusicServerDownloadBatchResult = ({
  int started,
  int alreadyDownloaded,
  int failed,
});

/// 客户端测一份本机文件的响度（测试注入；生产 = [measureMusicLoudness]）。
typedef MusicServerDownloadLoudnessMeasure =
    Future<MusicLoudnessOutcome> Function(String input);

/// 服务器曲目下载的编排（无状态：进行中的任务在 [InterconnectDownloadManager]，下完的在
/// `music_server_downloads`）。
class MusicServerDownloadService {
  MusicServerDownloadService({
    required this.downloads,
    required this.db,
    required this.root,
    MusicServerDownloadIndex? index,
    MusicServerDownloadTransfer? transfer,
    MusicServerDownloadBytesFetcher? fetchBytes,
    MusicServerDownloadLyricsSaver? saveLyrics,
    MusicServerDownloadLoudnessMeasure? measureLoudness,
    int Function()? clock,
  }) : index = index ?? MusicServerDownloadIndex.instance,
       _saveLyrics = saveLyrics,
       _measureLoudness = measureLoudness ?? measureMusicLoudness,
       _transfer = transfer ?? AnimeEpisodeDownloader().download,
       _fetchBytes = fetchBytes ?? _httpBytes,
       _clock = clock ?? _now {
    // 本机「移出音乐库」要能取消这里发起的下载（没建过下载服务就没有下载任务）。
    this.index.cancelDownload = (String trackUid) =>
        downloads.cancel(musicServerDownloadTaskId(trackUid));
  }

  /// 生产装配：下载根 `<下载根>/music`。
  factory MusicServerDownloadService.forApp({
    required InterconnectDownloadManager downloads,
    required FushiDatabase db,
  }) => MusicServerDownloadService(
    downloads: downloads,
    db: db,
    root: () async => Directory((await DownloadRoot.current()).musicRoot),
  );

  final InterconnectDownloadManager downloads;
  final FushiDatabase db;
  final Future<Directory> Function() root;
  final MusicServerDownloadIndex index;
  final MusicServerDownloadTransfer _transfer;
  final MusicServerDownloadBytesFetcher _fetchBytes;
  final MusicServerDownloadLyricsSaver? _saveLyrics;
  final MusicServerDownloadLoudnessMeasure _measureLoudness;
  final int Function() _clock;

  /// 下完存歌词用哪个（构造时给的优先，否则进程级装配点）。
  MusicServerDownloadLyricsSaver? get _lyricsSaver =>
      _saveLyrics ?? musicServerDownloadLyricsSaver;

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  /// 这台服务器能不能下原文件（Jellyfin / Subsonic，且曲目能作为服务器曲目入库）。
  static bool supports(MusicServerBrowser browser) =>
      browser is MusicServerDownloading &&
      musicServerKindStorable(browser.kind);

  static Future<Uint8List> _httpBytes(Uri uri) async {
    final HttpClient client = createAppHttpClient();
    try {
      final HttpClientRequest req = await client.getUrl(uri);
      final HttpClientResponse res = await req.close().timeout(
        const Duration(seconds: 30),
      );
      if (res.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${res.statusCode}');
      }
      final BytesBuilder b = BytesBuilder(copy: false);
      await for (final List<int> chunk in res.timeout(
        const Duration(seconds: 30),
      )) {
        b.add(chunk);
      }
      return b.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  /// 下一首（不等下载结束；结果以下载中心的任务状态为准）。
  Future<MusicServerDownloadStart> download(
    MusicServerBrowser browser,
    MusicServerTrack track, {
    MusicServerAlbum? album,
  }) async {
    final ({MusicServerDownloadStart outcome, Future<void>? done}) r =
        await _begin(browser, track, album: album);
    r.done?.ignore();
    return r.outcome;
  }

  /// 整批下载（专辑 / 艺人）：串行，整批结束才返回；单首失败不挡后面的（原因在它的任务里，
  /// 下载中心可重试）；用户在下载中心暂停正在下的那首 = 停掉整批。
  Future<MusicServerDownloadBatchResult> downloadAll(
    MusicServerBrowser browser,
    List<MusicServerTrack> tracks, {
    required String batchId,
    required String batchTitle,
    MusicServerAlbum? album,
  }) async {
    int started = 0;
    int already = 0;
    int failed = 0;
    await downloads.startBatch(
      id: batchId,
      title: batchTitle,
      starters: <Future<void> Function()>[
        for (final MusicServerTrack track in tracks)
          () async {
            final ({MusicServerDownloadStart outcome, Future<void>? done}) r;
            try {
              r = await _begin(browser, track, album: album);
            } on Object {
              failed++;
              rethrow;
            }
            switch (r.outcome) {
              case MusicServerDownloadStart.alreadyDownloaded:
                already++;
                return;
              case MusicServerDownloadStart.unsupported:
                failed++;
                return;
              case MusicServerDownloadStart.started:
              case MusicServerDownloadStart.alreadyRunning:
                started++;
            }
            try {
              await r.done;
            } on RemoteDownloadCancelled {
              rethrow;
            } on Object {
              failed++;
              rethrow;
            }
          },
      ],
    );
    return (started: started, alreadyDownloaded: already, failed: failed);
  }

  /// 删一批离线副本（行 + 文件；曲目仍在音乐库里，之后串流）。返回删掉的个数。
  Future<int> removeDownloads(Iterable<String> trackUids) =>
      index.deleteDownloads(trackUids);

  Future<({MusicServerDownloadStart outcome, Future<void>? done})> _begin(
    MusicServerBrowser browser,
    MusicServerTrack track, {
    MusicServerAlbum? album,
  }) async {
    final MusicRemoteTracksCompanion? row = musicServerRemoteTrackCompanion(
      browser,
      track,
      albumTitle: album?.title,
    );
    final MusicServerDownloading? source = browser is MusicServerDownloading
        ? browser as MusicServerDownloading
        : null;
    if (source == null || row == null) {
      return (outcome: MusicServerDownloadStart.unsupported, done: null);
    }
    final String uid = row.trackUid.value;
    final String id = musicServerDownloadTaskId(uid);
    if (downloads.isRunning(id)) {
      return (outcome: MusicServerDownloadStart.alreadyRunning, done: null);
    }
    if (index.isDownloaded(uid)) {
      // 副本在：确保在音乐库里（下载 ⊂ 音乐库）。
      await db.addMusicRemoteTrackToLibrary(row, at: _clock());
      return (outcome: MusicServerDownloadStart.alreadyDownloaded, done: null);
    }
    // 上次没下完（暂停 / 失败）：同一份传输原语接着下。
    if (downloads.canRestart(id)) {
      return (
        outcome: MusicServerDownloadStart.started,
        done: downloads.resume(id),
      );
    }
    final MusicPluginDownloadTarget target = musicServerDownloadTarget(
      await root(),
      browser,
      track,
      albumTitle: album?.title,
    );
    final _ServerTrackDownload job = _ServerTrackDownload(
      service: this,
      browser: source,
      server: browser,
      track: track,
      album: album,
      target: target,
      row: row,
    );
    final Future<void> done = downloads.startMusicDownload(
      id: id,
      title: track.artist == null || track.artist!.isEmpty
          ? track.title
          : '${track.title} · ${track.artist}',
      dest: target.staging,
      run: job.run,
      onComplete: job.complete,
      discard: job.discard,
      origin: InterconnectDownloadOrigin.ownDevice,
    );
    return (outcome: MusicServerDownloadStart.started, done: done);
  }
}

/// 一首曲目的传输原语与收尾（下载管理器握着它的闭包：暂停后继续 / 失败重试都走这里）。
class _ServerTrackDownload {
  _ServerTrackDownload({
    required this.service,
    required this.browser,
    required this.server,
    required this.track,
    required this.album,
    required this.target,
    required this.row,
  });

  final MusicServerDownloadService service;
  final MusicServerDownloading browser;
  final MusicServerBrowser server;
  final MusicServerTrack track;
  final MusicServerAlbum? album;
  final MusicPluginDownloadTarget target;
  final MusicRemoteTracksCompanion row;

  File? _audio;
  String? _codec;
  File? _cover;

  /// 这一轮开跑时这首的「移出音乐库」计数（[MusicServerDownloadIndex.removalMark]）。
  int _removalMark = 0;

  Future<void> run(
    File staging, {
    void Function(double progress)? onProgress,
    void Function(int received, int? total)? onBytes,
    Future<void>? cancelSignal,
  }) async {
    _removalMark = service.index.removalMark(_uid);
    final MusicServerDownloadSource source = browser.downloadSourceFor(track);
    File? audio = await target.existingAudio();
    if (audio == null) {
      if (!await staging.exists()) {
        try {
          await service._transfer(
            url: source.uri.toString(),
            headers: source.headers,
            dest: staging,
            onProgress: onProgress,
            onBytes: onBytes,
            cancelSignal: cancelSignal,
          );
        } on RemoteDownloadCancelled {
          rethrow;
        } on Object catch (e) {
          throw MusicServerDownloadFailed(
            musicServerDownloadErrorText(e, source.uri),
          );
        }
      }
      final String? ext = await _formatOf(staging, source);
      if (ext == null) throw const MusicServerDownloadUnknownFormat();
      audio = await staging.rename(target.audio(ext).path);
    }
    _audio = audio;
    _codec = p.extension(audio.path).replaceFirst('.', '').toLowerCase();
    _cover = await _writeCover();
    await _saveLoudness(audio);
    await _saveLyrics();
    onProgress?.call(1);
  }

  String get _uid => row.trackUid.value;

  /// 服务器响度存到音频旁（离线时用）：列表给的为主，缺专辑增益时向服务器补查一次（与起播期
  /// 补查同一规则）。取不到不让下载失败。
  Future<void> _saveLoudness(File audio) async {
    MusicServerLoudness? l = track.loudness;
    final MusicServerBrowser s = server;
    if (l?.albumGainDb == null && s is MusicServerLoudnessLookup) {
      try {
        final MusicServerLoudness? extra =
            await (s as MusicServerLoudnessLookup).loudnessOf(
              MusicServerTrackRef(
                kind: s.kind,
                serverId: s.serverId,
                trackId: track.id,
                albumId: track.albumId,
              ),
            );
        if (extra != null) {
          l = MusicServerLoudness(
            trackGainDb: l?.trackGainDb ?? extra.trackGainDb,
            trackPeak: l?.trackGainDb != null ? l?.trackPeak : extra.trackPeak,
            albumGainDb: extra.albumGainDb,
            albumPeak: extra.albumPeak,
          );
        }
      } on Object catch (e) {
        debugPrint(
          '[music-download] loudness lookup failed: '
          '${redactSubsonicCredentials('$e')}',
        );
      }
    }
    try {
      if (l != null && !l.isEmpty) {
        await writeMusicServerDownloadLoudness(audio.path, l);
      }
      // 服务器没给曲目增益（Jellyfin 没开 LUFS 扫描、纯 Subsonic）：对下好的文件测一次，存进
      // 同一个 sidecar 的 `measured`（服务器的值永远优先，见 [MusicServerDownloadSidecar]）。
      if (l?.trackGainDb == null) {
        final MusicLoudnessOutcome m = await service._measureLoudness(
          audio.path,
        );
        if (!m.failed) {
          final double? gain = m.measurement?.replayGainDb;
          await writeMusicServerDownloadMeasuredLoudness(
            audio.path,
            trackGainDb: gain,
            trackPeak: gain == null ? null : m.measurement?.linearPeak,
            measuredAt: service._clock(),
          );
        }
      }
    } on FileSystemException catch (e, st) {
      ErrorLogService.instance.log('MusicServerDownload.loudness', e, st);
    }
  }

  /// 服务器歌词存进歌词缓存（离线时用）。服务器不存歌词 / 没装配存储时跳过；取不到不让下载
  /// 失败。
  Future<void> _saveLyrics() async {
    final MusicServerDownloadLyricsSaver? save = service._lyricsSaver;
    final MusicServerBrowser s = server;
    if (save == null || s is! MusicServerLyricsProvider) return;
    final MusicServerLyrics? lyrics;
    try {
      lyrics = await (s as MusicServerLyricsProvider).lyricsFor(track.id);
    } on Object catch (e) {
      debugPrint(
        '[music-download] lyrics fetch failed: '
        '${redactSubsonicCredentials('$e')}',
      );
      return;
    }
    try {
      await save(trackUid: _uid, durationMs: track.durationMs, lyrics: lyrics);
    } on Object catch (e, st) {
      ErrorLogService.instance.log('MusicServerDownload.lyrics', e, st);
    }
  }

  Future<String?> _formatOf(File file, MusicServerDownloadSource source) async {
    final RandomAccessFile raf = await file.open();
    final Uint8List head;
    try {
      head = await raf.read(4096);
    } finally {
      await raf.close();
    }
    final String? hint = source.extensionHint;
    return sniffAudioExtension(head) ??
        (hint != null && kMusicPluginDownloadAudioExtensions.contains(hint)
            ? hint
            : null);
  }

  /// 专辑封面落到同目录 `cover.<ext>`（已有就用现成的）；取不到不让下载失败，记错误日志。
  Future<File?> _writeCover() async {
    for (final String ext in _kCoverExtensions) {
      final File f = File(p.join(target.dir.path, 'cover.$ext'));
      if (await f.exists()) return f;
    }
    final Uri? uri = server.coverUri(
      album?.coverRef ?? track.coverRef,
      size: kMusicServerDownloadCoverSize,
    );
    if (uri == null) return null;
    try {
      final Uint8List bytes = await service._fetchBytes(uri);
      final String? ext = sniffCoverExtension(bytes);
      if (ext == null) {
        throw const FormatException('cover is not jpg/png/webp');
      }
      final File f = File(p.join(target.dir.path, 'cover.$ext'));
      await f.writeAsBytes(bytes, flush: true);
      return f;
    } on Object catch (e, s) {
      ErrorLogService.instance.log(
        'MusicServerDownload.cover',
        MusicServerDownloadFailed(musicServerDownloadErrorText(e, uri)),
        s,
      );
      return null;
    }
  }

  Future<void> complete(File staging) async {
    final File? audio = _audio ?? await target.existingAudio();
    if (audio == null) throw const MusicServerDownloadUnknownFormat();
    service.index.forgetPaths(<String>[audio.path]);
    final MusicServerDownloadsCompanion download =
        MusicServerDownloadsCompanion(
          trackUid: row.trackUid,
          sourceKey: row.sourceKey,
          itemId: row.itemId,
          serverKind: Value<String?>(server.kind.wire),
          filePath: Value<String>(audio.path),
          coverPath: Value<String?>(_cover?.path),
          sizeBytes: Value<int?>(await audio.length()),
          codec: Value<String?>(
            _codec ?? p.extension(audio.path).replaceFirst('.', ''),
          ),
        );
    final int at = service._clock();
    final bool recorded = await service.db.recordMusicServerDownload(
      download,
      track: row,
      at: at,
      stillWanted: () => service.index.removalMark(_uid) == _removalMark,
    );
    if (recorded) return;
    // 开跑之后这首被移出了音乐库：不落库、不加回曲库，删掉刚落地的文件，任务按「已取消」收。
    await deleteMusicServerDownloadFiles(<MusicServerDownloadRow>[
      MusicServerDownloadRow(
        trackUid: _uid,
        sourceKey: row.sourceKey.value,
        itemId: row.itemId.value,
        filePath: audio.path,
        coverPath: _cover?.path,
        downloadedAt: at,
      ),
    ]);
    service.index.forgetPaths(<String>[audio.path]);
    throw const RemoteDownloadCancelled('removed from music library');
  }

  /// 下载中心「删除并删文件」：暂存字节与断点、以及已落地但没记进库的成品。
  Future<bool> discard() async {
    bool deleted = await deleteAnimeEpisodeDownloadLeftovers(target.staging);
    final File? audio = await target.existingAudio();
    if (audio != null && !service.index.isDownloaded(row.trackUid.value)) {
      try {
        await audio.delete();
        deleted = true;
      } on FileSystemException catch (e, s) {
        ErrorLogService.instance.log('MusicServerDownload.discard', e, s);
      }
    }
    return deleted;
  }
}
