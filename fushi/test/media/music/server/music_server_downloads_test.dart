import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_loudness_scanner.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_remote_tracks.dart';
import 'package:fushi/src/media/music/server/music_server_download_index.dart';
import 'package:fushi/src/media/music/server/music_server_downloads.dart';
import 'package:fushi/src/media/music/server/music_server_play_item.dart';
import 'package:fushi/src/media/video/online/anime_episode_downloader.dart'
    show animeDownloadLogText;
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_engine/media/music/server/music_server_loudness.dart';
import 'package:path/path.dart' as p;

/// 服务器曲目离线副本（v175）：落点、凭据脱敏、下载 → 入库 + 副本行 → 播放项换成本地文件、
/// 删除副本 / 移出曲库连带删文件、没有服务器配置时仍能放。
void main() {
  Uint8List flacBytes() => Uint8List.fromList(<int>[
    ...'fLaC'.codeUnits,
    ...List<int>.filled(64, 7),
  ]);
  Uint8List jpegBytes() => Uint8List.fromList(<int>[
    0xFF,
    0xD8,
    0xFF,
    0xE0,
    ...List<int>.filled(16, 1),
  ]);

  const MusicServerAlbum album = MusicServerAlbum(
    id: 'alb1',
    title: '初恋テスト',
    artist: '宇多田テスト',
    coverRef: 'alb1',
  );
  const MusicServerTrack track = MusicServerTrack(
    id: 'trk1',
    title: 'Track 1',
    artist: '宇多田テスト',
    album: '初恋テスト',
    albumId: 'alb1',
    trackNo: 1,
    discNo: 1,
    container: 'flac',
    codec: 'flac',
    coverRef: 'alb1',
  );

  group('落点与脱敏（纯函数）', () {
    test('落点：服务器 / 专辑 / 曲序 标题，带哈希防撞名', () {
      final _FakeServer server = _FakeServer();
      final target = musicServerDownloadTarget(
        Directory('/root'),
        server,
        track,
        albumTitle: album.title,
      );
      final List<String> parts = p.split(target.dir.path);
      expect(parts, contains(kMusicServerDownloadsDirName));
      expect(parts.last, startsWith('初恋テスト ['));
      expect(parts[parts.length - 2], startsWith('Dev Jellyfin ['));
      expect(target.stem, startsWith('01 Track 1 ['));
      // 同名不同 id 的曲目落点不同。
      final other = musicServerDownloadTarget(
        Directory('/root'),
        server,
        const MusicServerTrack(id: 'trk2', title: 'Track 1', trackNo: 1),
      );
      expect(other.stem, isNot(target.stem));
    });

    test('失败文本抹掉 query 里的凭据（Jellyfin api_key / Subsonic u+t+s）', () {
      final Uri jf = Uri.parse(
        'http://127.0.0.1:8097/Items/x/Download?api_key=SECRET1',
      );
      expect(
        musicServerDownloadErrorText(HttpException('HTTP 403', uri: jf), jf),
        allOf(isNot(contains('SECRET1')), contains('/Items/x/Download')),
      );
      final Uri ss = Uri.parse(
        'https://nd.example/rest/download?u=bob&t=abcdef0123&s=salt99&v=1.16.1&id=7',
      );
      final String text = musicServerDownloadErrorText(
        Exception('failed for $ss'),
        ss,
      );
      expect(text, isNot(contains('abcdef0123')));
      expect(text, isNot(contains('salt99')));
      expect(text, isNot(contains('u=bob')));
    });

    test('下载器调试日志的异常文本脱敏（Jellyfin api_key / OpenSubsonic apiKey / t+s）', () {
      final String text = animeDownloadLogText(
        HttpException(
          'HTTP 500',
          uri: Uri.parse(
            'https://nd.example/rest/download?apiKey=KEY1&t=tok22&s=salt33'
            '&id=7&api_key=KEY4',
          ),
        ),
      );
      for (final String secret in <String>['KEY1', 'tok22', 'salt33', 'KEY4']) {
        expect(text, isNot(contains(secret)));
      }
      expect(text, contains('/rest/download'));
      final Uri ss = Uri.parse('https://nd.example/rest/download?apiKey=K9');
      expect(
        musicServerDownloadErrorText(Exception('boom t=x1&s=y2 $ss'), ss),
        allOf(isNot(contains('K9'))),
      );
    });
  });

  group('下载 → 离线副本 → 本地播放', () {
    late Directory root;
    late FushiDatabase db;
    late MusicServerDownloadIndex index;
    late InterconnectDownloadManager downloads;
    late MusicServerDownloadService service;
    late _FakeServer server;
    final List<String> transferred = <String>[];
    final List<String> measured = <String>[];

    Future<void> settle(bool Function() done) async {
      for (int i = 0; i < 200 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(done(), isTrue);
    }

    setUp(() async {
      root = await Directory.systemTemp.createTemp('musdl');
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      index = MusicServerDownloadIndex();
      index.attach(db);
      downloads = InterconnectDownloadManager();
      server = _FakeServer();
      transferred.clear();
      measured.clear();
      service = MusicServerDownloadService(
        downloads: downloads,
        db: db,
        root: () async => root,
        index: index,
        transfer:
            ({
              required String url,
              required Map<String, String> headers,
              required File dest,
              void Function(double progress)? onProgress,
              void Function(int received, int? total)? onBytes,
              Future<void>? cancelSignal,
            }) async {
              transferred.add(url);
              await dest.parent.create(recursive: true);
              await dest.writeAsBytes(flacBytes());
              onProgress?.call(1);
            },
        fetchBytes: (Uri uri) async => jpegBytes(),
        measureLoudness: (String input) async {
          measured.add(input);
          return (
            measurement: const MusicLoudnessMeasurement(
              integratedLufs: -12,
              truePeakDbtp: -1,
            ),
            failed: false,
            returnCode: 0,
          );
        },
        clock: () => 1000,
      );
    });

    tearDown(() async {
      index.dispose();
      musicServerLocalCopyLookup = null;
      downloads.dispose();
      await db.close();
      await root.delete(recursive: true);
    });

    test('下完：文件 + 封面落地，副本行与入库同一事务，播放项换成本地文件', () async {
      final String uid = musicServerTrackUid(server.serverId, track.id);
      expect(
        await service.download(server, track, album: album),
        MusicServerDownloadStart.started,
      );
      await settle(() => index.isDownloaded(uid));

      expect(transferred.single, contains('/Items/trk1/Download'));
      final MusicServerDownloadRow row = index.rowOf(uid)!;
      expect(row.filePath, endsWith('.flac'));
      expect(File(row.filePath).existsSync(), isTrue);
      expect(row.coverPath, endsWith('cover.jpg'));
      expect(File(row.coverPath!).existsSync(), isTrue);
      expect(row.codec, 'flac');
      expect(row.sourceKey, server.serverId);
      expect(row.itemId, 'trk1');
      // 不存任何带凭据的地址。
      expect(row.filePath, isNot(contains('api_key')));
      final MusicRemoteTrackRow lib = (await db.getMusicRemoteTrack(uid))!;
      expect(lib.libraryAddedAt, 1000);
      expect(lib.kind, MusicRemoteTrackKind.server.wire);

      // 服务器页直接点开：同一个 uid、本地文件。
      final MusicPlayItem item = musicServerPlayItem(
        server,
        track,
        maxBitrateKbps: 128,
        albumTitle: album.title,
      );
      expect(item.trackUid, uid);
      expect(item.path, row.filePath);
      expect(item.coverPath, row.coverPath);
      expect(item.codec, 'flac');

      // 曲库里那一行：没有服务器配置（服务器删了 / 离线）也能放、可用。
      final MusicPlayItem? offline = musicPlayItemOfRemote(lib);
      expect(offline?.path, row.filePath);
      expect(MusicRemoteEntry(lib).available, isTrue);
      expect(musicRemoteCoverUrlOf(lib), row.coverPath);

      // v176：副本行带服务器种类；服务器配置不在时的播放项照样带服务器身份（离线上报 / 收藏）。
      expect(row.serverKind, 'jellyfin');
      expect(offline?.serverTrack?.kind, MusicServerKind.jellyfin);
      expect(offline?.serverTrack?.serverId, server.serverId);
      expect(offline?.serverTrack?.trackId, 'trk1');
      // 服务器没给曲目增益：下完对本机文件测一次，存进 sidecar 的 measured（不进播放项的 rg）。
      expect(measured, <String>[row.filePath]);
      final MusicServerDownloadSidecar? sidecar =
          await readMusicServerDownloadLoudness(row.filePath);
      expect(sidecar?.server, isNull);
      expect(sidecar?.measured?.trackGainDb, closeTo(-6, 1e-9));
      expect(
        musicServerLocalCopyLookup!(uid)?.measuredLoudness?.trackGainDb,
        closeTo(-6, 1e-9),
      );
      expect(offline?.rgTrackGain, isNull);

      // 再点下载：已有副本。
      expect(
        await service.download(server, track, album: album),
        MusicServerDownloadStart.alreadyDownloaded,
      );
    });

    test('下完顺带存服务器歌词与响度：离线副本的播放项带服务器身份与增益', () async {
      final _RichServer rich = _RichServer();
      final List<String> saved = <String>[];
      final MusicServerDownloadService withLyrics = MusicServerDownloadService(
        downloads: downloads,
        db: db,
        root: () async => root,
        index: index,
        measureLoudness: (String _) async =>
            (measurement: null, failed: true, returnCode: null),
        transfer:
            ({
              required String url,
              required Map<String, String> headers,
              required File dest,
              void Function(double progress)? onProgress,
              void Function(int received, int? total)? onBytes,
              Future<void>? cancelSignal,
            }) async {
              await dest.parent.create(recursive: true);
              await dest.writeAsBytes(flacBytes());
            },
        fetchBytes: (Uri uri) async => jpegBytes(),
        saveLyrics:
            ({
              required String trackUid,
              required int? durationMs,
              required MusicServerLyrics? lyrics,
            }) async => saved.add('$trackUid ${lyrics?.lines.first.text}'),
        clock: () => 1000,
      );
      final String uid = musicServerTrackUid(rich.serverId, track.id);
      await withLyrics.download(rich, track, album: album);
      await settle(() => index.isDownloaded(uid));

      expect(saved, <String>['$uid 歌詞']);
      final MusicServerDownloadRow row = index.rowOf(uid)!;
      final File sidecar = File(musicServerDownloadLoudnessPath(row.filePath));
      expect(sidecar.existsSync(), isTrue);
      expect(sidecar.readAsStringSync(), isNot(contains('api_key')));
      expect(
        (await readMusicServerDownloadLoudness(row.filePath))?.server,
        const MusicServerLoudness(
          trackGainDb: -3,
          trackPeak: 0.9,
          albumGainDb: -4,
          albumPeak: 0.95,
        ),
      );

      final MusicServerLocalCopy copy = index.lookup(uid)!;
      expect(copy.serverId, rich.serverId);
      expect(copy.trackId, track.id);
      final MusicPlayItem item = musicServerPlayItem(rich, track);
      expect(item.path, row.filePath);
      expect(item.serverTrack?.trackId, track.id);
      expect(item.serverTrack?.serverId, rich.serverId);
      expect(item.rgTrackGain, -3);
      expect(item.rgAlbumGain, -4);

      // 曲库那行：服务器没配时也带服务器身份（副本记着服务器种类，播放 / 收藏能进补发队列），
      // 增益照样来自下载时存下的那份。
      final MusicRemoteTrackRow lib = (await db.getMusicRemoteTrack(uid))!;
      final MusicPlayItem? offline = musicPlayItemOfRemote(lib);
      expect(offline?.serverTrack?.serverId, rich.serverId);
      expect(offline?.serverTrack?.trackId, track.id);
      expect(offline?.serverTrack?.kind, rich.kind);
      expect(offline?.rgAlbumGain, -4);

      // 删副本：旁边的响度文件一起删。
      expect(await withLyrics.removeDownloads(<String>[uid]), 1);
      expect(sidecar.existsSync(), isFalse);
    });

    test('删除副本：行与文件都没了，之后串流；曲目仍在曲库', () async {
      final String uid = musicServerTrackUid(server.serverId, track.id);
      await service.download(server, track, album: album);
      await settle(() => index.isDownloaded(uid));
      final MusicServerDownloadRow row = index.rowOf(uid)!;

      expect(await service.removeDownloads(<String>[uid]), 1);
      await settle(() => !index.isDownloaded(uid));
      expect(File(row.filePath).existsSync(), isFalse);
      // 专辑目录只剩封面 → 连封面与空目录一起删。
      expect(Directory(p.dirname(row.filePath)).existsSync(), isFalse);
      expect((await db.getMusicRemoteTrack(uid))?.libraryAddedAt, 1000);
      expect(
        musicServerPlayItem(server, track).path,
        startsWith('http://jf.test/stream/'),
      );
      final MusicRemoteTrackRow lib = (await db.getMusicRemoteTrack(uid))!;
      expect(musicPlayItemOfRemote(lib), isNull);
    });

    test('移出曲库后：不在曲库的副本连文件一起删（下载 ⊂ 音乐库）', () async {
      final String uid = musicServerTrackUid(server.serverId, track.id);
      await service.download(server, track, album: album);
      await settle(() => index.isDownloaded(uid));
      final String path = index.rowOf(uid)!.filePath;

      await db.removeMusicRemoteTracksFromLibrary(<String>[uid], at: 2000);
      // 撤销窗口内：副本还在。
      expect(index.isDownloaded(uid), isTrue);
      expect(await index.dropDownloadsOutsideLibrary(<String>[uid]), 1);
      await settle(() => !index.isDownloaded(uid));
      expect(File(path).existsSync(), isFalse);
    });

    test('接上库（启动）：不在曲库的副本放回曲库，文件不删（副本是设备本地的事实）', () async {
      final String uid = musicServerTrackUid(server.serverId, track.id);
      await service.download(server, track, album: album);
      await settle(() => index.isDownloaded(uid));
      final String path = index.rowOf(uid)!.filePath;
      // 例如合并进来的较新一行清了入库时刻，或撤销窗口里进程被杀。
      await db.removeMusicRemoteTracksFromLibrary(<String>[uid], at: 2000);

      final MusicServerDownloadIndex fresh = MusicServerDownloadIndex();
      addTearDown(fresh.dispose);
      fresh.attach(db);
      await settle(() => fresh.isDownloaded(uid));
      expect(await fresh.reconcileIntoLibrary(), 0, reason: 'attach 时已放回');
      expect(File(path).existsSync(), isTrue);
      expect((await db.getMusicRemoteTrack(uid))!.libraryAddedAt, 1000);
    });

    test('下载开跑后移出曲库：任务取消，下完的不加回曲库，落地文件删掉', () async {
      final String uid = musicServerTrackUid(server.serverId, track.id);
      final Completer<void> entered = Completer<void>();
      final Completer<void> gate = Completer<void>();
      final MusicServerDownloadService slow = MusicServerDownloadService(
        downloads: downloads,
        db: db,
        root: () async => root,
        index: index,
        measureLoudness: (String _) async =>
            (measurement: null, failed: true, returnCode: null),
        transfer:
            ({
              required String url,
              required Map<String, String> headers,
              required File dest,
              void Function(double progress)? onProgress,
              void Function(int received, int? total)? onBytes,
              Future<void>? cancelSignal,
            }) async {
              await dest.parent.create(recursive: true);
              await dest.writeAsBytes(flacBytes());
              entered.complete();
              // 取消信号来了也把这一轮跑完：模拟「恰好下完」与移出撞在一起。
              await gate.future;
            },
        fetchBytes: (Uri uri) async => jpegBytes(),
        clock: () => 1000,
      );
      expect(
        await slow.download(server, track, album: album),
        MusicServerDownloadStart.started,
      );
      await entered.future;
      final Future<void> removal = index.removeTracksFromLibrary(db, <String>[
        uid,
      ], at: 2000);
      gate.complete();
      await removal;
      await settle(
        () => !downloads.tasks.containsKey(musicServerDownloadTaskId(uid)),
      );

      expect(await db.listMusicServerDownloadsOf(<String>[uid]), isEmpty);
      expect((await db.getMusicRemoteTrack(uid))?.libraryAddedAt, isNull);
      final List<File> left = root
          .listSync(recursive: true)
          .whereType<File>()
          .toList();
      expect(left, isEmpty, reason: '落地的音频 / 封面 / 半成品都删了：$left');
      expect(index.isDownloaded(uid), isFalse);
    });

    test('记副本：stillWanted 为假时什么都不写', () async {
      final String uid = musicServerTrackUid(server.serverId, track.id);
      final bool recorded = await db.recordMusicServerDownload(
        MusicServerDownloadsCompanion.insert(
          trackUid: uid,
          sourceKey: server.serverId,
          itemId: track.id,
          filePath: p.join(root.path, 'x.flac'),
          downloadedAt: 1,
        ),
        track: musicServerRemoteTrackCompanion(server, track)!,
        at: 1,
        stillWanted: () => false,
      );
      expect(recorded, isFalse);
      expect(await db.listMusicServerDownloadsOf(<String>[uid]), isEmpty);
      expect(await db.getMusicRemoteTrack(uid), isNull);
    });

    test('文件不在（盘没挂 / 被删）：索引不认，退回串流，行不删', () async {
      final String uid = musicServerTrackUid(server.serverId, track.id);
      await db.recordMusicServerDownload(
        MusicServerDownloadsCompanion.insert(
          trackUid: uid,
          sourceKey: server.serverId,
          itemId: track.id,
          filePath: p.join(root.path, 'missing.flac'),
          downloadedAt: 1,
        ),
        track: musicServerRemoteTrackCompanion(server, track)!,
        at: 1,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(index.isDownloaded(uid), isFalse);
      expect((await db.listMusicServerDownloadsOf(<String>[uid])).length, 1);
    });

    test('整批下载：串行，已有副本的计数跳过', () async {
      const MusicServerTrack second = MusicServerTrack(
        id: 'trk2',
        title: 'Track 2',
        albumId: 'alb1',
        trackNo: 2,
      );
      await service.download(server, track, album: album);
      await settle(
        () => index.isDownloaded(musicServerTrackUid(server.serverId, 'trk1')),
      );
      final MusicServerDownloadBatchResult r = await service.downloadAll(
        server,
        <MusicServerTrack>[track, second],
        batchId: 'b',
        batchTitle: album.title,
        album: album,
      );
      expect(r.alreadyDownloaded, 1);
      expect(r.started, 1);
      expect(r.failed, 0);
      await settle(
        () => index.isDownloaded(musicServerTrackUid(server.serverId, 'trk2')),
      );
      expect(
        downloads
            .tasks[musicServerDownloadTaskId(
              musicServerTrackUid(server.serverId, 'trk2'),
            )]
            ?.origin,
        InterconnectDownloadOrigin.ownDevice,
      );
    });
  });
}

class _FakeServer implements MusicServerBrowser, MusicServerDownloading {
  @override
  MusicServerKind get kind => MusicServerKind.jellyfin;

  @override
  String get serverId => 'jf-dev';

  @override
  String get displayName => 'Dev Jellyfin';

  @override
  MusicServerDownloadSource downloadSourceFor(MusicServerTrack track) =>
      MusicServerDownloadSource(
        uri: Uri.parse(
          'http://jf.test/Items/${track.id}/Download?api_key=TOKEN',
        ),
        extensionHint: track.container,
      );

  @override
  MusicServerStream streamFor(MusicServerTrack track, {int? maxBitrateKbps}) =>
      MusicServerStream(
        uri: Uri.parse('http://jf.test/stream/${track.id}?api_key=TOKEN'),
        transcoded: maxBitrateKbps != null,
      );

  @override
  Uri? coverUri(String? coverRef, {int size = kMusicServerCoverSize}) =>
      coverRef == null
      ? null
      : Uri.parse('http://jf.test/Items/$coverRef/Images/Primary?api_key=T');

  @override
  Future<MusicServerPage<MusicServerAlbum>> listAlbums({
    int offset = 0,
    int limit = kMusicServerPageSize,
    MusicServerAlbumSort sort = MusicServerAlbumSort.name,
  }) async =>
      const MusicServerPage<MusicServerAlbum>(items: <MusicServerAlbum>[]);

  @override
  Future<List<MusicServerTrack>> albumTracks(String albumId) async =>
      const <MusicServerTrack>[];

  @override
  Future<List<MusicServerArtist>> listArtists() async =>
      const <MusicServerArtist>[];

  @override
  Future<List<MusicServerAlbum>> artistAlbums(String artistId) async =>
      const <MusicServerAlbum>[];

  @override
  Future<MusicServerPage<MusicServerPlaylist>> listPlaylists({
    int offset = 0,
    int limit = kMusicServerPageSize,
  }) async => const MusicServerPage<MusicServerPlaylist>(
    items: <MusicServerPlaylist>[],
  );

  @override
  Future<List<MusicServerTrack>> playlistTracks(String playlistId) async =>
      const <MusicServerTrack>[];

  @override
  Future<MusicServerSearchResult> search(
    String query, {
    int limit = 30,
  }) async => const MusicServerSearchResult();

  @override
  void close() {}
}

/// 还存歌词、能补查响度的服务器（Jellyfin 家族）。
class _RichServer extends _FakeServer
    implements MusicServerLyricsProvider, MusicServerLoudnessLookup {
  @override
  String get serverId => 'jf-rich';

  @override
  MusicServerStreamRef? streamRefOf(Uri uri) => null;

  @override
  Future<MusicServerLyrics?> lyricsFor(String trackId) async =>
      const MusicServerLyrics(
        lines: <MusicServerLyricLine>[
          MusicServerLyricLine(text: '歌詞', startMs: 0),
        ],
      );

  @override
  Future<MusicServerLoudness?> loudnessOf(MusicServerTrackRef track) async =>
      const MusicServerLoudness(
        trackGainDb: -3,
        trackPeak: 0.9,
        albumGainDb: -4,
        albumPeak: 0.95,
      );
}
