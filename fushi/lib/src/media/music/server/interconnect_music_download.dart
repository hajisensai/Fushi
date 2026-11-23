/// 把互联 host 的曲目下载成本机曲目，离线听（design-imusic-q12）。
///
/// 文件管线与在线音源插件下载是同一条（[MusicPluginDownloadService]：落点按专辑分目录、`.part` + Range
/// 续传、文件头嗅探扩展名、写标签、目录封面、「仅此一次」导入曲库、任务进度 / 暂停 / 重试都在下载中心），
/// 这里只换掉三个来源：
/// - 取流：向 host 签 `musicTrack` 票，原样音质；CUE 虚拟曲目由 host 无损截成单独的文件
///   （[InterconnectMusicBrowser.openTrack] 的 `forDownload`）；
/// - 封面：经同一条钉扎通道取 host 的封面字节；
/// - 歌词：host 上生效的那份写成同名 sidecar（与用户自己放在音频旁的歌词同一条读取规则）。
///
/// 身份（design-imusic-q1 选 a 的延续）：本机曲目的 uid 按本机路径算，与 host 的 `track_uid` 不同。
/// 导入后把 host uid 记成本机曲目的别名并把引用改指过来（[adoptInterconnectMusicDownload]，
/// `mergeMusicTrackInto`）：之前用 host 曲目建的歌单项、播放记录、断点、歌词偏移都跟到本机这一首，
/// 「加入音乐库」时落的那条 `fushi_host` 远程曲目行删掉（本机已有真文件）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_music/fushi_music.dart'
    show MusicPluginArtistRef, MusicPluginStream, MusicPluginTrack;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/music/plugin/music_plugin_download.dart';
import 'package:fushi/src/media/music/server/interconnect_music_client.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';

/// 下载落点里互联 host 曲目的「来源目录名」（与插件 id 同一层：`<下载根>/music/fushi-host/…`）。
const String kInterconnectMusicDownloadSource = 'fushi-host';

/// 导入成功后把 host 曲目并进本机曲目（[adoptInterconnectMusicDownload] 的注入点）。
typedef InterconnectMusicAdopter =
    Future<void> Function({required String hostUid, required String localPath});

class InterconnectMusicDownloadService {
  InterconnectMusicDownloadService({
    required InterconnectDownloadManager downloads,
    required Future<Directory> Function() root,
    required MusicPluginDownloadImporter import,
    required InterconnectMusicAdopter adopt,
    MusicPluginDownloadTransfer? transfer,
    MusicPluginDownloadTagWriter? writeTags,
    MusicPluginDownloadSoftError? softError,
  }) : _import = import,
       _adopt = adopt {
    _files = MusicPluginDownloadService(
      downloads: downloads,
      root: root,
      stream: _stream,
      import: _importAndAdopt,
      transfer: transfer,
      fetchBytes: _coverBytes,
      writeTags: writeTags,
      softError: softError,
    );
  }

  final MusicPluginDownloadImporter _import;
  final InterconnectMusicAdopter _adopt;
  late final MusicPluginDownloadService _files;

  /// 下载里的条目 id（`<serverId>\u0000<trackUid>`）→ 它的 host 与 uid。
  final Map<String, ({InterconnectMusicBrowser browser, String uid})> _jobs =
      <String, ({InterconnectMusicBrowser browser, String uid})>{};

  /// 成品「目录 + 主名」→ 下载条目 id（导入回调只拿到路径）。
  final Map<String, String> _byStem = <String, String>{};

  /// 下载一首（不等下载结束；结果以下载中心的任务状态为准）。
  Future<MusicPluginDownloadStart> download(
    InterconnectMusicBrowser browser,
    MusicServerTrack track, {
    String? albumTitle,
  }) async {
    final String key = '${browser.serverId}\u0000${track.id}';
    _jobs[key] = (browser: browser, uid: track.id);
    final MusicPluginTrack asTrack = MusicPluginTrack(
      id: key,
      title: track.title,
      artists: <MusicPluginArtistRef>[
        if (track.artist != null) MusicPluginArtistRef(name: track.artist!),
      ],
      albumId: track.albumId,
      albumTitle: albumTitle ?? track.album,
      durationMs: track.durationMs,
      coverUrl: track.coverRef == null
          ? null
          : fushiHostMusicCoverPath(browser.serverId, track.coverRef!),
      trackNo: track.trackNo,
      discNo: track.discNo,
    );
    final MusicPluginDownloadTarget target = await _files.targetFor(
      kInterconnectMusicDownloadSource,
      asTrack,
    );
    _byStem[p.join(target.dir.path, target.stem)] = key;
    return _files.download(kInterconnectMusicDownloadSource, asTrack);
  }

  Future<MusicPluginStream> _stream(String _, String key) async {
    final ({InterconnectMusicBrowser browser, String uid})? job = _jobs[key];
    if (job == null) throw StateError('unknown host track $key');
    final InterconnectMusicOpenedTrack opened = await job.browser.openTrack(
      job.uid,
      forDownload: true,
    );
    return MusicPluginStream(url: opened.url);
  }

  Future<Uint8List> _coverBytes(String url) async {
    final ({String hostId, String trackUid})? id = parseFushiHostMusicCoverPath(
      url,
    );
    if (id == null) throw ArgumentError.value(url, 'url');
    for (final ({InterconnectMusicBrowser browser, String uid}) j
        in _jobs.values) {
      if (j.browser.serverId == id.hostId) {
        return j.browser.coverBytes(id.trackUid);
      }
    }
    throw StateError('host ${id.hostId} not available');
  }

  Future<String?> _importAndAdopt(String path) async {
    final String? key =
        _byStem[p.join(p.dirname(path), p.basenameWithoutExtension(path))];
    final ({InterconnectMusicBrowser browser, String uid})? job = key == null
        ? null
        : _jobs[key];
    if (job != null) await _writeLyrics(job.browser, job.uid, path);
    final String? error = await _import(path);
    if (error != null || job == null) return error;
    await _adopt(hostUid: job.uid, localPath: path);
    return null;
  }

  /// host 上生效的歌词写成同名 sidecar（已有同名文件不覆盖：可能是用户自己放的）。
  Future<void> _writeLyrics(
    InterconnectMusicBrowser browser,
    String uid,
    String audioPath,
  ) async {
    try {
      final MusicServerLyrics? l = await browser.lyricsFor(uid);
      if (l == null || l.raw.isEmpty) return;
      final File side = File(
        p.join(
          p.dirname(audioPath),
          '${p.basenameWithoutExtension(audioPath)}.${l.format.toLowerCase()}',
        ),
      );
      if (!await side.exists()) await side.writeAsBytes(l.raw, flush: true);
    } on Object {
      // 歌词取不到不让下载失败（音频已经完整落地）；本机曲目照常经在线歌词来源找。
    }
  }
}

/// 导入后把 host 曲目 [hostUid] 并进本机路径 [localPath] 上的曲目：记别名、引用改指本机这一首，
/// 删掉那条 `fushi_host` 远程曲目行。本机还没有这条路径的曲目（导入失败）时什么也不做。
Future<void> adoptInterconnectMusicDownload(
  FushiDatabase db, {
  required String hostUid,
  required String localPath,
}) async {
  final MusicTrackRow? local =
      await (db.select(db.musicTracks)
            ..where(($MusicTracksTable t) => t.path.equals(localPath))
            ..limit(1))
          .getSingleOrNull();
  if (local == null || local.trackUid == hostUid) return;
  await db.mergeMusicTrackInto(loser: hostUid, winner: local.trackUid);
  await (db.delete(
    db.musicRemoteTracks,
  )..where(($MusicRemoteTracksTable t) => t.trackUid.equals(hostUid))).go();
}
