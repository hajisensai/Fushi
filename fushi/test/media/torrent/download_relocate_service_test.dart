// TODO-1961-c+d：改名/移动的原子性与库路径重映射规则。
//
// 这里钉死几件在真机上很难复现、错了又是静默数据损坏的事：
// ① 引擎失败时**库一个字节都不许动**（否则库指向一个磁盘上不存在的新路径）；
// ② 字幕列的哨兵值（`embedded:<n>` / `off:`）与流媒体 URL **绝不能**当路径重写；
// ③ 只重映射引擎**真实搬动**的文件：不在种子里的字幕 sidecar 原地不动，库也不改
//    它（BUG-3538）；
// ④ 后端坐标与本机坐标之间只认路径映射契约：远端 qBittorrent 的 save_path 映射
//    不到本机就在动引擎前拒绝，本机挑的目的地经映射换成后端坐标再发（BUG-3539）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/torrent/download_relocate_service.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/video/download/video_download_path_mapping.dart';
import 'package:fushi_engine/media/video/video_path_migration.dart';
import 'package:path/path.dart' as p;

/// 可编程后端：记录收到的调用，按需返回成功/失败。
class _FakeBackend implements TorrentBackend {
  _FakeBackend({
    this.result = const TorrentStorageResult(ok: true, path: 'x'),
    this.files = const <TorrentFileEntry>[],
  });

  TorrentStorageResult result;
  final List<TorrentFileEntry> files;
  final List<String> calls = <String>[];
  bool closed = false;

  @override
  Future<TorrentStorageResult> renameFile(
    String torrentId,
    int fileIndex,
    String newPath,
  ) async {
    calls.add('rename($torrentId,$fileIndex,$newPath)');
    return result;
  }

  @override
  Future<TorrentStorageResult> moveStorage(
    String torrentId,
    String newSavePath,
  ) async {
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
  Future<bool> addTorrent(
    String magnetOrUrl, {
    required String category,
    String? savePath,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) async => true;

  @override
  Future<List<TorrentSnapshot>> listTorrents({String? category}) async =>
      const <TorrentSnapshot>[];

  @override
  Future<List<TorrentFileEntry>> listFiles(String torrentId) async => files;
}

TorrentFileEntry _file(String name, int index) =>
    TorrentFileEntry(name: name, size: 1, progress: 1, index: index);

void main() {
  group('MovedMediaFiles / remapVideoBookPaths — 只改真被搬走的文件', () {
    final String root = p.join(p.rootPrefix(p.current), 'dl');
    final String moved = p.join(p.rootPrefix(p.current), 'moved');
    final MovedMediaFiles files = MovedMediaFiles(<String, String>{
      p.join(root, 'S1', 'ep01.mkv'): p.join(moved, 'S1', 'ep01.mkv'),
      p.join(root, 'S1', 'ep01.ja.ass'): p.join(moved, 'S1', 'ep01.ja.ass'),
    });

    test('被搬走的文件 → 新路径', () {
      expect(
        files.newPathFor(p.join(root, 'S1', 'ep01.mkv')),
        p.join(moved, 'S1', 'ep01.mkv'),
      );
    });

    test('同目录下没被搬的 sidecar 不动（BUG-3538）', () {
      expect(files.newPathFor(p.join(root, 'S1', 'ep01.zh.srt')), isNull);
    });

    test('目录本身 / 兄弟目录 / 范围外都不动', () {
      expect(files.newPathFor(root), isNull);
      expect(
        files.newPathFor('${root}x${p.separator}S1${p.separator}ep01.mkv'),
        isNull,
      );
      expect(
        files.newPathFor(p.join(p.rootPrefix(p.current), 'else.mkv')),
        isNull,
      );
    });

    test('哨兵 / 流媒体 URL / null / 相对路径都不当路径重写', () {
      expect(files.newPathFor('embedded:2'), isNull);
      expect(files.newPathFor('off:'), isNull);
      expect(files.newPathFor('https://example.com/v.m3u8'), isNull);
      expect(files.newPathFor(null), isNull);
      expect(files.newPathFor('  '), isNull);
      expect(files.newPathFor('S1/ep01.mkv'), isNull);
      expect(isRemappableMediaPath('embedded:2'), isFalse);
      expect(isRemappableMediaPath('off:'), isFalse);
    });

    test('三列各自独立：视频与种子内字幕跟着走，sidecar 与内嵌轨原样', () {
      final VideoPathRemap withSidecar = remapVideoBookPaths(
        videoPath: p.join(root, 'S1', 'ep01.mkv'),
        subtitleSource: p.join(root, 'S1', 'ep01.zh.srt'),
        secondarySubtitleSource: 'embedded:0',
        moved: files,
      );
      expect(withSidecar.videoPath, p.join(moved, 'S1', 'ep01.mkv'));
      expect(
        withSidecar.subtitleSource,
        isNull,
        reason: '引擎不搬 sidecar，库不能把它改到没有文件的新位置',
      );
      expect(withSidecar.secondarySubtitleSource, isNull);

      final VideoPathRemap bundled = remapVideoBookPaths(
        videoPath: p.join(root, 'S1', 'ep01.mkv'),
        subtitleSource: p.join(root, 'S1', 'ep01.ja.ass'),
        secondarySubtitleSource: null,
        moved: files,
      );
      expect(bundled.subtitleSource, p.join(moved, 'S1', 'ep01.ja.ass'));
    });

    test('全不命中时 isEmpty 为真（不发无谓 UPDATE）', () {
      final VideoPathRemap remap = remapVideoBookPaths(
        videoPath: 'https://example.com/v.m3u8',
        subtitleSource: 'off:',
        secondarySubtitleSource: null,
        moved: files,
      );
      expect(remap.isEmpty, isTrue);
    });
  });

  group('DownloadRelocateService — 引擎与库必须成对', () {
    late Directory tmp;
    late String root;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fushi_relocate_');
      root = p.join(tmp.path, 'dl');
      Directory(root).createSync(recursive: true);
    });
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    DownloadRelocateService serviceFor(
      _FakeBackend backend, {
      List<VideoDownloadPathMapping> mappings =
          const <VideoDownloadPathMapping>[],
      Future<int> Function(DownloadRelocation relocation)? apply,
    }) => DownloadRelocateService(
      backendFactory: () => backend,
      pathMappings: () async => mappings,
      applyRelocation: apply ?? (DownloadRelocation _) async => 0,
    );

    test('引擎失败 → 库一个字节都不动，且原因原样带回', () async {
      final _FakeBackend backend = _FakeBackend(
        result: const TorrentStorageResult.failure('target already exists'),
      );
      bool libraryTouched = false;
      final DownloadRelocateService service = serviceFor(
        backend,
        apply: (DownloadRelocation _) async {
          libraryTouched = true;
          return 1;
        },
      );

      final RelocateOutcome outcome = await service.moveTorrent(
        infoHash: 'abc',
        backendSaveRoot: root,
        newLocalSaveRoot: p.join(tmp.path, 'elsewhere'),
      );

      expect(outcome.status, RelocateStatus.engineFailed);
      expect(outcome.error, 'target already exists');
      expect(libraryTouched, isFalse, reason: '引擎没动，库绝不能动 —— 否则库会指向磁盘上不存在的路径');
      expect(backend.closed, isTrue, reason: '后端连接必须释放');
    });

    test('同机移动：逐文件登记种子里的文件，带回迁移行数与新后端位置', () async {
      final _FakeBackend backend = _FakeBackend(
        result: const TorrentStorageResult(ok: true),
        files: <TorrentFileEntry>[
          _file('Show/ep01.mkv', 0),
          _file('Show/ep01.ja.ass', 1),
        ],
      );
      DownloadRelocation? seen;
      final DownloadRelocateService service = serviceFor(
        backend,
        apply: (DownloadRelocation relocation) async {
          seen = relocation;
          return 3;
        },
      );

      final String target = p.join(tmp.path, 'moved');
      final RelocateOutcome outcome = await service.moveTorrent(
        infoHash: 'abc',
        backendSaveRoot: root,
        newLocalSaveRoot: target,
      );

      expect(outcome.isSuccess, isTrue);
      expect(outcome.rowsMigrated, 3);
      final String expectedRemote = videoDownloadLocalToRemote(
        effectiveVideoDownloadPathMappings(
          const <VideoDownloadPathMapping>[],
          sameMachineAnchors: <String?>[root],
        ),
        target,
      )!;
      expect(backend.calls.single, 'move(abc,$expectedRemote)');
      expect(seen!.infoHash, 'abc');
      expect(seen!.newBackendSavePath, expectedRemote);
      expect(
        seen!.movedFiles.newPathFor(p.join(root, 'Show', 'ep01.mkv')),
        p.join(target, 'Show', 'ep01.mkv'),
      );
      expect(
        seen!.movedFiles.newPathFor(p.join(root, 'Show', 'ep01.ja.ass')),
        p.join(target, 'Show', 'ep01.ja.ass'),
      );
      expect(
        seen!.movedFiles.newPathFor(p.join(root, 'Show', 'ep01.zh.srt')),
        isNull,
        reason: '不在种子里的 sidecar 引擎不搬（BUG-3538）',
      );
    });

    test('远端 qB + 显式映射：本机目的地换成后端坐标再发，库按本机坐标登记', () async {
      final String mount = p.join(tmp.path, 'nas');
      Directory(mount).createSync(recursive: true);
      final _FakeBackend backend = _FakeBackend(
        result: const TorrentStorageResult(ok: true),
        files: <TorrentFileEntry>[_file('Show/ep01.mkv', 0)],
      );
      DownloadRelocation? seen;
      final DownloadRelocateService service = serviceFor(
        backend,
        mappings: <VideoDownloadPathMapping>[
          VideoDownloadPathMapping(remoteRoot: '/srv/qb', localRoot: mount),
        ],
        apply: (DownloadRelocation relocation) async {
          seen = relocation;
          return 1;
        },
      );

      final RelocateOutcome outcome = await service.moveTorrent(
        infoHash: 'abc',
        backendSaveRoot: '/srv/qb/downloads',
        newLocalSaveRoot: p.join(mount, 'archive'),
      );

      expect(outcome.isSuccess, isTrue);
      expect(
        backend.calls.single,
        'move(abc,/srv/qb/archive)',
        reason: '发给远端的必须是它自己的坐标，不是本机挑的路径',
      );
      expect(seen!.newBackendSavePath, '/srv/qb/archive');
      expect(
        seen!.movedFiles.newPathFor(
          p.join(mount, 'downloads', 'Show', 'ep01.mkv'),
        ),
        p.join(mount, 'archive', 'Show', 'ep01.mkv'),
      );
    });

    test('远端 qB 没配映射：动引擎前就拒绝，引擎与库都不碰', () async {
      final _FakeBackend backend = _FakeBackend(
        files: <TorrentFileEntry>[_file('ep01.mkv', 0)],
      );
      bool libraryTouched = false;
      final DownloadRelocateService service = serviceFor(
        backend,
        apply: (DownloadRelocation _) async {
          libraryTouched = true;
          return 1;
        },
      );

      const String remote = '/fushi-remote-qb-test/downloads';
      final RelocateOutcome moved = await service.moveTorrent(
        infoHash: 'abc',
        backendSaveRoot: remote,
        newLocalSaveRoot: p.join(tmp.path, 'moved'),
      );
      final RelocateOutcome renamed = await service.renameFile(
        infoHash: 'abc',
        fileIndex: 0,
        currentRelativePath: 'ep01.mkv',
        newRelativePath: 'Show - 01.mkv',
        backendSaveRoot: remote,
      );

      for (final RelocateOutcome outcome in <RelocateOutcome>[moved, renamed]) {
        expect(outcome.status, RelocateStatus.engineFailed);
        expect(outcome.error, contains('path mapping'));
      }
      expect(backend.calls, isEmpty);
      expect(libraryTouched, isFalse);
    });

    test('目的地不在任何映射里：拒绝，不把本机路径发给远端', () async {
      final String mount = p.join(tmp.path, 'nas');
      Directory(mount).createSync(recursive: true);
      final _FakeBackend backend = _FakeBackend();
      final DownloadRelocateService service = serviceFor(
        backend,
        mappings: <VideoDownloadPathMapping>[
          VideoDownloadPathMapping(remoteRoot: '/srv/qb', localRoot: mount),
        ],
      );

      final RelocateOutcome outcome = await service.moveTorrent(
        infoHash: 'abc',
        backendSaveRoot: '/srv/qb/downloads',
        newLocalSaveRoot: p.join(tmp.path, 'local-only'),
      );

      expect(outcome.status, RelocateStatus.engineFailed);
      expect(outcome.error, contains('outside every download path mapping'));
      expect(backend.calls, isEmpty);
    });

    test('引擎成功但库迁移抛错 → libraryFailed，不许报成功', () async {
      final _FakeBackend backend = _FakeBackend(
        result: const TorrentStorageResult(ok: true, path: 'newname.mkv'),
      );
      final DownloadRelocateService service = serviceFor(
        backend,
        apply: (DownloadRelocation _) async => throw StateError('db is locked'),
      );

      final RelocateOutcome outcome = await service.renameFile(
        infoHash: 'abc',
        fileIndex: 0,
        currentRelativePath: 'old.mkv',
        newRelativePath: 'newname.mkv',
        backendSaveRoot: root,
      );

      expect(outcome.status, RelocateStatus.libraryFailed);
      expect(outcome.error, contains('db is locked'));
      expect(outcome.isSuccess, isFalse, reason: '磁盘动了库没跟上 —— 用户必须知道，不能当成功');
    });

    test('改名拒绝绝对路径和逃出种子目录的路径，且不触碰后端或库', () async {
      final _FakeBackend backend = _FakeBackend();
      bool libraryTouched = false;
      final DownloadRelocateService service = serviceFor(
        backend,
        apply: (DownloadRelocation _) async {
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
          backendSaveRoot: root,
        );
        expect(
          outcome.status,
          RelocateStatus.engineFailed,
          reason: '应拒绝 $newPath',
        );
        expect(outcome.error, contains('inside the torrent'));
      }

      expect(backend.calls, isEmpty);
      expect(backend.closed, isFalse, reason: '校验失败前不应创建后端');
      expect(libraryTouched, isFalse);
    });

    test('目标与现状相同 → unchanged，不打扰引擎也不动库', () async {
      final _FakeBackend backend = _FakeBackend();
      bool libraryTouched = false;
      final DownloadRelocateService service = serviceFor(
        backend,
        apply: (DownloadRelocation _) async {
          libraryTouched = true;
          return 0;
        },
      );

      final RelocateOutcome renamed = await service.renameFile(
        infoHash: 'abc',
        fileIndex: 0,
        currentRelativePath: 'same.mkv',
        newRelativePath: 'same.mkv',
        backendSaveRoot: root,
      );
      expect(renamed.status, RelocateStatus.unchanged);

      final RelocateOutcome moved = await service.moveTorrent(
        infoHash: 'abc',
        backendSaveRoot: root,
        newLocalSaveRoot: root,
      );
      expect(moved.status, RelocateStatus.unchanged);

      expect(backend.calls, isEmpty);
      expect(libraryTouched, isFalse);
    });

    test('改名把种子内相对路径拼成本机绝对路径再迁库（同一坐标系）', () async {
      final _FakeBackend backend = _FakeBackend(
        result: const TorrentStorageResult(ok: true, path: 'S1/new.mkv'),
      );
      DownloadRelocation? seen;
      final DownloadRelocateService service = serviceFor(
        backend,
        apply: (DownloadRelocation relocation) async {
          seen = relocation;
          return 1;
        },
      );

      await service.renameFile(
        infoHash: 'abc',
        fileIndex: 2,
        currentRelativePath: 'old.mkv',
        newRelativePath: 'S1/new.mkv',
        backendSaveRoot: root,
      );

      // 库里存的是绝对路径，所以重映射必须在绝对路径坐标系里做。
      expect(
        seen!.movedFiles.newPathFor(p.join(root, 'old.mkv')),
        p.join(root, 'S1', 'new.mkv'),
      );
      expect(seen!.renamedFileIndex, 2);
      expect(seen!.renamedRelativePath, 'S1/new.mkv');
      expect(seen!.newBackendSavePath, isNull);
      expect(
        backend.calls.single,
        'rename(abc,2,S1/new.mkv)',
        reason: '种子内路径跨平台固定使用 POSIX 分隔符',
      );
    });
  });
}
