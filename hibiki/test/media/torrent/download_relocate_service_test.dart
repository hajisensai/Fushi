// TODO-1961-c+d：改名/移动的原子性与库路径重映射规则。
//
// 这里钉死两件在真机上很难复现、错了又是静默数据损坏的事：
// ① 引擎失败时**库一个字节都不许动**（否则库指向一个磁盘上不存在的新路径）；
// ② 字幕列的哨兵值（`embedded:<n>` / `off:`）与流媒体 URL **绝不能**当路径重写。

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/torrent/download_relocate_service.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/video/video_path_migration.dart';
import 'package:path/path.dart' as p;

/// 可编程后端：记录收到的调用，按需返回成功/失败。
class _FakeBackend implements TorrentBackend {
  _FakeBackend({this.result = const TorrentStorageResult(ok: true, path: 'x')});

  TorrentStorageResult result;
  final List<String> calls = <String>[];
  bool closed = false;

  @override
  Future<TorrentStorageResult> renameFile(
      String torrentId, int fileIndex, String newPath) async {
    calls.add('rename($torrentId,$fileIndex,$newPath)');
    return result;
  }

  @override
  Future<TorrentStorageResult> moveStorage(
      String torrentId, String newSavePath) async {
    calls.add('move($torrentId,$newSavePath)');
    return result;
  }

  @override
  void close() => closed = true;

  @override
  Future<String?> probeConnection() async => 'fake';

  @override
  Future<bool> prepareCategory(String category) async => true;

  @override
  Future<bool> addTorrent(String magnetOrUrl,
          {required String category,
          bool sequential = false,
          bool firstLastPiecePrio = false}) async =>
      true;

  @override
  Future<List<TorrentSnapshot>> listTorrents({String? category}) async =>
      const <TorrentSnapshot>[];

  @override
  Future<List<TorrentFileEntry>> listFiles(String torrentId) async =>
      const <TorrentFileEntry>[];
}

void main() {
  group('remapMediaPath — 什么该改、什么绝不能改', () {
    final String root = p.join(p.rootPrefix(p.current), 'dl');
    final String moved = p.join(p.rootPrefix(p.current), 'moved');

    test('全等匹配（改名）→ 换成新路径', () {
      expect(
        remapMediaPath(p.join(root, 'a.mkv'),
            fromPath: p.join(root, 'a.mkv'), toPath: p.join(root, 'b.mkv')),
        p.join(root, 'b.mkv'),
      );
    });

    test('前缀内（移动）→ 相对部分接到新根下', () {
      expect(
        remapMediaPath(p.join(root, 'S1', 'ep01.mkv'),
            fromPath: root, toPath: moved),
        p.join(moved, 'S1', 'ep01.mkv'),
      );
    });

    test('兄弟目录不被误当成前缀命中', () {
      // 手写 startsWith 会让 <root> 误匹配 <root>x —— 必须走 package:path。
      expect(
        remapMediaPath('${root}x${p.separator}ep.mkv',
            fromPath: root, toPath: moved),
        isNull,
      );
    });

    test('范围外路径不动', () {
      final String elsewhere =
          p.join(p.rootPrefix(p.current), 'somewhere', 'else.mkv');
      expect(remapMediaPath(elsewhere, fromPath: root, toPath: moved), isNull);
    });

    test('内嵌字幕哨兵 embedded:<n> 绝不当路径重写', () {
      expect(
          remapMediaPath('embedded:2', fromPath: root, toPath: moved), isNull);
      expect(isRemappableMediaPath('embedded:2'), isFalse);
    });

    test('显式关闭哨兵 off: 绝不当路径重写', () {
      expect(remapMediaPath('off:', fromPath: root, toPath: moved), isNull);
      expect(isRemappableMediaPath('off:'), isFalse);
    });

    test('流媒体 URL 不动（磁盘上没有对应文件）', () {
      expect(
        remapMediaPath('https://example.com/v.m3u8',
            fromPath: root, toPath: moved),
        isNull,
      );
    });

    test('null / 空串 / 相对路径都不动', () {
      expect(remapMediaPath(null, fromPath: root, toPath: moved), isNull);
      expect(remapMediaPath('  ', fromPath: root, toPath: moved), isNull);
      expect(remapMediaPath('relative/a.mkv', fromPath: root, toPath: moved),
          isNull);
    });

    test('三列各自独立：视频跟着走、内嵌字幕轨原样保留', () {
      final VideoPathRemap remap = remapVideoBookPaths(
        videoPath: p.join(root, 'ep01.mkv'),
        subtitleSource: 'embedded:0',
        secondarySubtitleSource: p.join(root, 'ep01.zh.srt'),
        fromPath: root,
        toPath: moved,
      );
      expect(remap.videoPath, p.join(moved, 'ep01.mkv'));
      expect(remap.subtitleSource, isNull, reason: '哨兵不该被重写');
      expect(remap.secondarySubtitleSource, p.join(moved, 'ep01.zh.srt'));
      expect(remap.isEmpty, isFalse);
    });

    test('全不命中时 isEmpty 为真（不发无谓 UPDATE）', () {
      final VideoPathRemap remap = remapVideoBookPaths(
        videoPath: 'https://example.com/v.m3u8',
        subtitleSource: 'off:',
        secondarySubtitleSource: null,
        fromPath: root,
        toPath: moved,
      );
      expect(remap.isEmpty, isTrue);
    });
  });

  group('DownloadRelocateService — 引擎与库必须成对', () {
    final String root = p.join(p.rootPrefix(p.current), 'dl');

    test('引擎失败 → 库一个字节都不动，且原因原样带回', () async {
      final _FakeBackend backend = _FakeBackend(
          result: const TorrentStorageResult.failure('target already exists'));
      bool libraryTouched = false;
      final DownloadRelocateService service = DownloadRelocateService(
        backendFactory: () => backend,
        migrateLibraryPaths: (
            {required String fromPath, required String toPath}) async {
          libraryTouched = true;
          return 1;
        },
      );

      final RelocateOutcome outcome = await service.moveTorrent(
        infoHash: 'abc',
        currentSaveRoot: root,
        newSaveRoot: p.join(p.rootPrefix(p.current), 'elsewhere'),
      );

      expect(outcome.status, RelocateStatus.engineFailed);
      expect(outcome.error, 'target already exists');
      expect(libraryTouched, isFalse, reason: '引擎没动，库绝不能动 —— 否则库会指向磁盘上不存在的路径');
      expect(backend.closed, isTrue, reason: '后端连接必须释放');
    });

    test('两步都成 → success，并带回迁移行数', () async {
      final _FakeBackend backend = _FakeBackend(
          result: TorrentStorageResult(
              ok: true, path: p.join(p.rootPrefix(p.current), 'moved')));
      String? seenFrom;
      String? seenTo;
      final DownloadRelocateService service = DownloadRelocateService(
        backendFactory: () => backend,
        migrateLibraryPaths: (
            {required String fromPath, required String toPath}) async {
          seenFrom = fromPath;
          seenTo = toPath;
          return 3;
        },
      );

      final String target = p.join(p.rootPrefix(p.current), 'moved');
      final RelocateOutcome outcome = await service.moveTorrent(
        infoHash: 'abc',
        currentSaveRoot: root,
        newSaveRoot: target,
      );

      expect(outcome.isSuccess, isTrue);
      expect(outcome.rowsMigrated, 3);
      expect(seenFrom, root);
      expect(seenTo, target);
      expect(backend.calls.single, 'move(abc,$target)');
    });

    test('引擎成功但库迁移抛错 → libraryFailed，不许报成功', () async {
      final _FakeBackend backend = _FakeBackend(
          result: const TorrentStorageResult(ok: true, path: 'newname.mkv'));
      final DownloadRelocateService service = DownloadRelocateService(
        backendFactory: () => backend,
        migrateLibraryPaths: (
                {required String fromPath, required String toPath}) async =>
            throw StateError('db is locked'),
      );

      final RelocateOutcome outcome = await service.renameFile(
        infoHash: 'abc',
        fileIndex: 0,
        currentRelativePath: 'old.mkv',
        newRelativePath: 'newname.mkv',
        saveRoot: root,
      );

      expect(outcome.status, RelocateStatus.libraryFailed);
      expect(outcome.error, contains('db is locked'));
      expect(outcome.isSuccess, isFalse, reason: '磁盘动了库没跟上 —— 用户必须知道，不能当成功');
    });

    test('改名拒绝绝对路径和逃出种子目录的路径，且不触碰后端或库', () async {
      final _FakeBackend backend = _FakeBackend();
      bool libraryTouched = false;
      final DownloadRelocateService service = DownloadRelocateService(
        backendFactory: () => backend,
        migrateLibraryPaths: (
            {required String fromPath, required String toPath}) async {
          libraryTouched = true;
          return 1;
        },
      );

      final List<String> invalid = <String>[
        p.join(p.rootPrefix(p.current), 'outside.mkv'),
        p.join('..', 'outside.mkv'),
        p.join('season', '..', '..', 'outside.mkv'),
      ];
      for (final String newPath in invalid) {
        final RelocateOutcome outcome = await service.renameFile(
          infoHash: 'abc',
          fileIndex: 0,
          currentRelativePath: 'old.mkv',
          newRelativePath: newPath,
          saveRoot: root,
        );
        expect(outcome.status, RelocateStatus.engineFailed,
            reason: '应拒绝 $newPath');
        expect(outcome.error, contains('inside the torrent'));
      }

      expect(backend.calls, isEmpty);
      expect(backend.closed, isFalse, reason: '校验失败前不应创建后端');
      expect(libraryTouched, isFalse);
    });

    test('目标与现状相同 → unchanged，不打扰引擎也不动库', () async {
      final _FakeBackend backend = _FakeBackend();
      bool libraryTouched = false;
      final DownloadRelocateService service = DownloadRelocateService(
        backendFactory: () => backend,
        migrateLibraryPaths: (
            {required String fromPath, required String toPath}) async {
          libraryTouched = true;
          return 0;
        },
      );

      final RelocateOutcome renamed = await service.renameFile(
        infoHash: 'abc',
        fileIndex: 0,
        currentRelativePath: 'same.mkv',
        newRelativePath: 'same.mkv',
        saveRoot: root,
      );
      expect(renamed.status, RelocateStatus.unchanged);

      final RelocateOutcome moved = await service.moveTorrent(
        infoHash: 'abc',
        currentSaveRoot: root,
        newSaveRoot: root,
      );
      expect(moved.status, RelocateStatus.unchanged);

      expect(backend.calls, isEmpty);
      expect(libraryTouched, isFalse);
    });

    test('改名把种子内相对路径拼成绝对路径再迁库（同一坐标系）', () async {
      final _FakeBackend backend = _FakeBackend(
          result: const TorrentStorageResult(ok: true, path: 'S1/new.mkv'));
      String? seenFrom;
      String? seenTo;
      final DownloadRelocateService service = DownloadRelocateService(
        backendFactory: () => backend,
        migrateLibraryPaths: (
            {required String fromPath, required String toPath}) async {
          seenFrom = fromPath;
          seenTo = toPath;
          return 1;
        },
      );

      await service.renameFile(
        infoHash: 'abc',
        fileIndex: 2,
        currentRelativePath: 'old.mkv',
        newRelativePath: 'S1/new.mkv',
        saveRoot: root,
      );

      // 库里存的是绝对路径，所以重映射必须在绝对路径坐标系里做。
      expect(seenFrom, p.join(root, 'old.mkv'));
      expect(seenTo, p.join(root, 'S1', 'new.mkv'));
      expect(backend.calls.single, 'rename(abc,2,S1/new.mkv)',
          reason: '种子内路径跨平台固定使用 POSIX 分隔符');
    });
  });
}
