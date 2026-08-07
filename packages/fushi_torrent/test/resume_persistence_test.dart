// TODO-1961-a：resume data 持久化端到端测试 —— 关掉 session 再开，种子能加
// 回来、**不重新下载**、直接进入做种。
//
// 这个测试的说服力全在「第二个 session 从头到尾没有任何 peer」：
// - 不调 connectPeer；
// - session 不开 DHT（ht_session_create 传 enableDht: false），
//   LSD/UPnP/NAT-PMP 在 bridge 里恒关；
// - 纯 btih 磁力本就没有 tracker。
// 所以第二个 session 里出现「有元数据 + 进度 1.0 + 做种」只可能来自 resume
// 文件与磁盘上已有的数据，不可能是重下的。这正是 TODO-1961-a 要证明的东西
// （在此之前，重启 app = 所有种子蒸发，做种和续传都断）。
//
// 库路径解析同其它 native 测试：HIBIKI_TORRENT_LIB 指向 DLL；缺库整组 skip。

import 'dart:io';

import 'package:fushi_torrent/fushi_torrent.dart';
import 'package:fushi_torrent/testing.dart';
import 'package:test/test.dart';

String? _resolveLibPath() {
  final String? env = Platform.environment['HIBIKI_TORRENT_LIB'];
  if (env != null && env.isNotEmpty) {
    return File(env).existsSync() ? env : null;
  }
  return null;
}

Future<void> _pollUntil(
  bool Function() done, {
  required Duration timeout,
  required String what,
  void Function()? onTick,
}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (!done()) {
    if (sw.elapsed > timeout) fail('timeout waiting for $what');
    onTick?.call();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  final String? explicit = _resolveLibPath();

  EmbeddedTorrentEngine? tryOpen() {
    try {
      return EmbeddedTorrentEngine.open(libraryPath: explicit);
    } on ArgumentError {
      return null;
    }
  }

  final EmbeddedTorrentEngine? engine = tryOpen();
  final String? skip =
      engine == null ? 'hibiki_torrent_ffi native lib not built' : null;

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ht_resume_');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 上偶发句柄未释放；留给系统临时目录清理。
    }
  });

  test(
    'resume data survives session restart: re-added, seeding, not re-downloaded',
    () async {
      const int contentSize = 2 * 1024 * 1024;
      final LocalSeedRig rig = await LocalSeedRig.start(
          engine: engine!, workDir: tempDir, contentBytes: contentSize);
      addTearDown(rig.dispose);

      final Directory dlDir = Directory('${tempDir.path}/dl')..createSync();
      final Directory resumeDir = Directory('${tempDir.path}/resume');

      // ── 第一段会话：正常下完 ──────────────────────────────────────
      final EmbeddedTorrentSession? first =
          EmbeddedTorrentSession.open(engine, listenInterfaces: '127.0.0.1:0');
      expect(first, isNotNull);

      final FtAddResult added =
          first!.addMagnet(rig.magnetUri, savePath: dlDir.path);
      expect(added.ok, isTrue, reason: 'addMagnet: ${added.error}');
      expect(added.id, rig.infoHash);
      expect(first.connectPeer(rig.infoHash, '127.0.0.1', rig.seederPort),
          isTrue);

      await _pollUntil(
        () {
          final FtTorrentStatus? t = first
              .listTorrents()
              .where((FtTorrentStatus e) => e.id == rig.infoHash)
              .firstOrNull;
          return t != null && t.isFinished && t.progress >= 1.0 && t.left == 0;
        },
        timeout: const Duration(seconds: 120),
        what: 'first session download completion',
        onTick: () =>
            first.connectPeer(rig.infoHash, '127.0.0.1', rig.seederPort),
      );

      // ── 存 resume ────────────────────────────────────────────────
      final FtResumeSaveResult saveResult =
          first.saveResumeData(resumeDir.path);
      expect(saveResult.saved, 1,
          reason: 'exactly one torrent should be persisted '
              '(failed=${saveResult.failed}, timedOut=${saveResult.timedOut})');
      expect(saveResult.failed, 0);
      expect(saveResult.timedOut, 0);

      final File resumeFile =
          File('${resumeDir.path}/${rig.infoHash}.resume');
      expect(resumeFile.existsSync(), isTrue,
          reason: 'resume file must be named <infohash>.resume');
      expect(resumeFile.lengthSync(), greaterThan(0));
      // 原子写：不得留下 .tmp 残骸。
      expect(
          resumeDir
              .listSync()
              .whereType<File>()
              .where((File f) => f.path.endsWith('.tmp'))
              .isEmpty,
          isTrue,
          reason: 'atomic write must not leave .tmp files behind');

      // ── 关掉整个会话（等价于 app 退出） ──────────────────────────
      first.close();

      // ── 第二段会话：只从 resume 恢复，全程零 peer ────────────────
      final EmbeddedTorrentSession? second = EmbeddedTorrentSession.open(
        engine,
        listenInterfaces: '127.0.0.1:0',
        enableDht: false,
      );
      expect(second, isNotNull);
      addTearDown(second!.close);

      expect(second.listTorrents(), isEmpty,
          reason: 'fresh session must start with no torrents — this is the '
              'pre-TODO-1961-a behaviour that silently killed all seeding');

      final List<String> restored = second.loadResumeDir(resumeDir.path);
      expect(restored, <String>[rig.infoHash]);

      await _pollUntil(
        () {
          final FtTorrentStatus? t = second
              .listTorrents()
              .where((FtTorrentStatus e) => e.id == rig.infoHash)
              .firstOrNull;
          return t != null && t.isFinished && t.progress >= 1.0;
        },
        timeout: const Duration(seconds: 60),
        what: 'restored torrent to finish checking and report complete',
      );

      final FtTorrentStatus restoredStatus = second
          .listTorrents()
          .firstWhere((FtTorrentStatus t) => t.id == rig.infoHash);
      // 元数据来自 resume 里的 info dict（save_info_dict），不是从 peer 取的
      // —— 本会话根本没有 peer。
      expect(restoredStatus.hasMetadata, isTrue);
      expect(restoredStatus.numPeers, 0,
          reason: 'no peer may be involved — completeness must come from disk');
      expect(restoredStatus.left, 0);
      expect(restoredStatus.savePath, isNotEmpty);

      final FtPieceMap? pieces = second.torrentPieces(rig.infoHash);
      expect(pieces, isNotNull);
      expect(pieces!.haveCount, pieces.numPieces,
          reason: 'every piece must be recovered from disk');

      // 做种态（上传能力恢复）——完成后 libtorrent 进 seeding。
      await _pollUntil(
        () {
          final FtTorrentStatus? t = second
              .listTorrents()
              .where((FtTorrentStatus e) => e.id == rig.infoHash)
              .firstOrNull;
          return t != null && t.isSeeding;
        },
        timeout: const Duration(seconds: 30),
        what: 'restored torrent to enter seeding state',
      );

      // 幂等：再 load 一次不产生重复种子。
      final List<String> again = second.loadResumeDir(resumeDir.path);
      expect(again, <String>[rig.infoHash]);
      expect(second.listTorrents(), hasLength(1));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'loadResumeDir on a missing directory is a no-op, not an error',
    () {
      final EmbeddedTorrentSession? session =
          EmbeddedTorrentSession.open(engine!, listenInterfaces: '');
      expect(session, isNotNull);
      addTearDown(session!.close);

      expect(session.loadResumeDir('${tempDir.path}/nope'), isEmpty);
      expect(session.listTorrents(), isEmpty);
    },
    skip: skip,
  );

  test(
    'saveResumeData with no torrents writes nothing and reports zero',
    () {
      final EmbeddedTorrentSession? session =
          EmbeddedTorrentSession.open(engine!, listenInterfaces: '');
      expect(session, isNotNull);
      addTearDown(session!.close);

      final Directory outDir = Directory('${tempDir.path}/empty-resume');
      final FtResumeSaveResult result = session.saveResumeData(outDir.path);
      expect(result.saved, 0);
      expect(result.failed, 0);
      expect(result.timedOut, 0);
      // 目录被建出来（下次保存直接可用），但里面没有 resume 文件。
      expect(outDir.existsSync(), isTrue);
      expect(outDir.listSync(), isEmpty);
    },
    skip: skip,
  );
}
