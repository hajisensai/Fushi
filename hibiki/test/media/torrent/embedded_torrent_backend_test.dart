// EmbeddedTorrentBackend（内置 libtorrent 后端）对 TorrentBackend 契约的
// 端到端验证：分类目录语义、magnet 添加、按分类过滤、快照/文件映射、
// isComplete 判定。下载源是 LocalSeedRig（127.0.0.1 本地做种，零外网）。
//
// 库路径解析：HIBIKI_TORRENT_LIB 指向 hibiki_torrent_ffi.dll；缺库整组 skip
// —— CI/未构建环境不因缺 DLL 而红。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/torrent/embedded_torrent_backend.dart';
import 'package:hibiki/src/media/torrent/torrent_backend.dart';
import 'package:hibiki_torrent/hibiki_torrent.dart';
import 'package:hibiki_torrent/testing.dart';
import 'package:path/path.dart' as p;

String? _resolveLibPath() {
  final String? env = Platform.environment['HIBIKI_TORRENT_LIB'];
  if (env != null && env.isNotEmpty) {
    return File(env).existsSync() ? env : null;
  }
  return null;
}

Future<void> _pollUntil(
  Future<bool> Function() done, {
  required Duration timeout,
  required String what,
}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (!await done()) {
    if (sw.elapsed > timeout) fail('timeout waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  final String? libPath = _resolveLibPath();

  EmbeddedTorrentEngine? tryOpen() {
    if (libPath == null) return null;
    try {
      return EmbeddedTorrentEngine.open(libraryPath: libPath);
    } on ArgumentError {
      return null;
    }
  }

  final EmbeddedTorrentEngine? engine = tryOpen();
  final String? skip =
      engine == null ? 'hibiki_torrent_ffi native lib not built' : null;

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ht_backend_');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 上偶发句柄未释放；留给系统临时目录清理。
    }
  });

  test(
    'EmbeddedTorrentBackend fulfils the TorrentBackend contract end-to-end',
    () async {
      final LocalSeedRig rig = await LocalSeedRig.start(
          engine: engine!, workDir: tempDir, contentBytes: 2 * 1024 * 1024);
      addTearDown(rig.dispose);

      // 出站连接需要 listen socket（只绑回环，确定性）。
      final EmbeddedTorrentSession? session =
          EmbeddedTorrentSession.open(engine, listenInterfaces: '127.0.0.1:0');
      expect(session, isNotNull);
      final EmbeddedTorrentBackend backend = EmbeddedTorrentBackend(
        session: session!,
        baseSavePath: p.join(tempDir.path, 'downloads'),
      );
      addTearDown(backend.close);

      // probe = libtorrent 版本串。
      expect(await backend.probeConnection(), startsWith('libtorrent 2.'));

      // 分类目录语义。
      expect(await backend.prepareCategory('hibiki-anime'), isTrue);
      expect(
          Directory(p.join(tempDir.path, 'downloads', 'hibiki-anime'))
              .existsSync(),
          isTrue);

      // 非 magnet/.torrent 输入直接拒绝。
      expect(
          await backend.addTorrent('https://example.com/x.torrent',
              category: 'hibiki-anime'),
          isFalse);

      // magnet 添加（顺序 + 首尾块优先，走真实边下边播参数组合）。
      expect(
        await backend.addTorrent(rig.magnetUri,
            category: 'hibiki-anime',
            sequential: true,
            firstLastPiecePrio: true),
        isTrue,
      );
      expect(session.connectPeer(rig.infoHash, '127.0.0.1', rig.seederPort),
          isTrue);

      // 分类过滤：目标分类看得见，其他分类为空。
      final List<TorrentSnapshot> mine =
          await backend.listTorrents(category: 'hibiki-anime');
      expect(mine, hasLength(1));
      expect(mine.single.hash, rig.infoHash);
      expect(await backend.listTorrents(category: 'other'), isEmpty);

      // 下载到完成：快照 isComplete 且文件进度打满。
      await _pollUntil(
        () async {
          final List<TorrentSnapshot> ts =
              await backend.listTorrents(category: 'hibiki-anime');
          return ts.isNotEmpty && ts.single.isComplete;
        },
        timeout: const Duration(seconds: 120),
        what: 'backend snapshot to report completion',
      );

      final TorrentSnapshot done =
          (await backend.listTorrents(category: 'hibiki-anime')).single;
      expect(done.progress, 1.0);
      expect(done.amountLeft, 0);
      expect(File(done.contentPath).existsSync(), isTrue,
          reason: 'contentPath must point at the downloaded file');

      final List<TorrentFileEntry> files =
          await backend.listFiles(rig.infoHash);
      expect(files, hasLength(1));
      expect(files.single.progress, 1.0);
      expect(files.single.size, 2 * 1024 * 1024);
      expect(files.single.name, contains('rig-content'));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
