// TODO-1961-c：引擎侧改名 / 移动**不掐断做种**的端到端证明。
//
// 这正是用户诉求的核心：「我把下好的东西整理一下，别把上传搞断」。
// 在资源管理器里手动改名永远救不回来（app 收不到通知，引擎按旧路径读盘直接
// 失败）；能救的做法只有一条 —— 让引擎自己去改，它改完就知道数据在哪。
//
// 测试构造：本地 rig 下完一份内容 → 改名 / 移动 → 断言
//   ① 引擎报告成功且给出新路径；
//   ② 新路径**在磁盘上真的存在**、旧路径已消失；
//   ③ 种子仍然完整（每个 piece 都在）且仍处于做种态 —— 即上传能力没断。
// ③ 是关键：如果引擎丢了数据，libtorrent 会掉出 seeding 并把 piece 标成缺失。
//
// 库路径解析同其它 native 测试：HIBIKI_TORRENT_LIB 指向 DLL；缺库整组 skip。

import 'dart:io';

import 'package:hibiki_torrent/hibiki_torrent.dart';
import 'package:hibiki_torrent/testing.dart';
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
    tempDir = Directory.systemTemp.createTempSync('ht_rename_');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 上偶发句柄未释放；留给系统临时目录清理。
    }
  });

  /// 起一个已经下完（因而在做种）的 session，返回它与下载目录。
  Future<(EmbeddedTorrentSession, LocalSeedRig, Directory)>
      seedingSession() async {
    final LocalSeedRig rig = await LocalSeedRig.start(
        engine: engine!, workDir: tempDir, contentBytes: 512 * 1024);
    addTearDown(rig.dispose);

    final EmbeddedTorrentSession? leecher =
        EmbeddedTorrentSession.open(engine, listenInterfaces: '127.0.0.1:0');
    expect(leecher, isNotNull);
    addTearDown(leecher!.close);

    final Directory dlDir = Directory('${tempDir.path}/dl')..createSync();
    final FtAddResult added =
        leecher.addMagnet(rig.magnetUri, savePath: dlDir.path);
    expect(added.ok, isTrue, reason: 'addMagnet: ${added.error}');
    expect(
        leecher.connectPeer(rig.infoHash, '127.0.0.1', rig.seederPort), isTrue);

    await _pollUntil(
      () {
        final FtTorrentStatus? t = leecher
            .listTorrents()
            .where((FtTorrentStatus e) => e.id == rig.infoHash)
            .firstOrNull;
        return t != null && t.isFinished && t.progress >= 1.0 && t.left == 0;
      },
      timeout: const Duration(seconds: 120),
      what: 'download completion',
      onTick: () =>
          leecher.connectPeer(rig.infoHash, '127.0.0.1', rig.seederPort),
    );
    return (leecher, rig, dlDir);
  }

  /// 断言种子仍然完整且在做种 —— 即上传没断。
  Future<void> expectStillSeeding(
      EmbeddedTorrentSession session, String infoHash) async {
    await _pollUntil(
      () {
        final FtTorrentStatus? t = session
            .listTorrents()
            .where((FtTorrentStatus e) => e.id == infoHash)
            .firstOrNull;
        return t != null && t.isSeeding;
      },
      timeout: const Duration(seconds: 30),
      what: 'torrent to stay in seeding state',
    );
    final FtPieceMap? pieces = session.torrentPieces(infoHash);
    expect(pieces, isNotNull);
    expect(pieces!.haveCount, pieces.numPieces,
        reason: 'every piece must still be present — a broken rename/move '
            'would make libtorrent drop out of seeding with missing pieces');
  }

  test(
    'renameFile keeps seeding: engine follows the new name on disk',
    () async {
      final (
        EmbeddedTorrentSession session,
        LocalSeedRig rig,
        Directory dlDir
      ) = await seedingSession();

      final List<FtFileEntry>? before = session.torrentFiles(rig.infoHash);
      expect(before, hasLength(1));
      final String oldName = before!.single.path;
      final File oldFile = File('${dlDir.path}/$oldName');
      expect(oldFile.existsSync(), isTrue);

      const String newName = '整理过的名字.bin';
      final FtStorageOpResult result =
          session.renameFile(rig.infoHash, before.single.index, newName);
      expect(result.ok, isTrue, reason: 'rename failed: ${result.error}');
      expect(result.path, newName);

      // 磁盘上真的换了名字（不是只改了引擎内部的账本）。
      expect(File('${dlDir.path}/$newName').existsSync(), isTrue);
      expect(oldFile.existsSync(), isFalse);

      // 引擎的文件列表跟着变，且做种没断。
      final List<FtFileEntry>? after = session.torrentFiles(rig.infoHash);
      expect(after!.single.path, newName);
      expect(after.single.done, after.single.size);
      await expectStillSeeding(session, rig.infoHash);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'renameFile can move a file into a subdirectory of the torrent',
    () async {
      final (
        EmbeddedTorrentSession session,
        LocalSeedRig rig,
        Directory dlDir
      ) = await seedingSession();

      final List<FtFileEntry>? before = session.torrentFiles(rig.infoHash);
      const String nested = 'Season 1/ep01.bin';
      final FtStorageOpResult result =
          session.renameFile(rig.infoHash, before!.single.index, nested);
      expect(result.ok, isTrue, reason: 'rename failed: ${result.error}');

      expect(File('${dlDir.path}/Season 1/ep01.bin').existsSync(), isTrue,
          reason: 'engine must create the subdirectory and move data into it');
      await expectStillSeeding(session, rig.infoHash);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'moveStorage keeps seeding: content lands in the new save path',
    () async {
      final (
        EmbeddedTorrentSession session,
        LocalSeedRig rig,
        Directory dlDir
      ) = await seedingSession();

      final List<FtFileEntry>? files = session.torrentFiles(rig.infoHash);
      final String name = files!.single.path;
      expect(File('${dlDir.path}/$name').existsSync(), isTrue);

      final Directory target = Directory('${tempDir.path}/moved');
      final FtStorageOpResult result =
          session.moveStorage(rig.infoHash, target.path);
      expect(result.ok, isTrue, reason: 'move failed: ${result.error}');
      expect(result.path, isNotNull);

      expect(File('${target.path}/$name').existsSync(), isTrue,
          reason: 'content must exist under the new save path');
      expect(File('${dlDir.path}/$name').existsSync(), isFalse,
          reason:
              'move must not leave a copy behind (it is a move, not a copy)');

      // savePath 跟着变，做种没断。
      final FtTorrentStatus moved = session
          .listTorrents()
          .firstWhere((FtTorrentStatus t) => t.id == rig.infoHash);
      expect(File(moved.contentPath).existsSync(), isTrue);
      await expectStillSeeding(session, rig.infoHash);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'moveStorage refuses to overwrite an existing file at the destination',
    () async {
      final (
        EmbeddedTorrentSession session,
        LocalSeedRig rig,
        Directory dlDir
      ) = await seedingSession();

      final List<FtFileEntry>? files = session.torrentFiles(rig.infoHash);
      final String name = files!.single.path;

      // 目标目录里先放一个同名文件（模拟「那边已经有一份了」）。
      final Directory target = Directory('${tempDir.path}/occupied')
        ..createSync(recursive: true);
      final File squatter = File('${target.path}/$name')
        ..writeAsStringSync('do not clobber me');

      final FtStorageOpResult result =
          session.moveStorage(rig.infoHash, target.path);
      expect(result.ok, isFalse,
          reason: 'must refuse rather than overwrite user data');
      expect(result.error, isNotNull);

      // 用户的文件一个字节都没被动，源内容也还在（不是搬了一半）。
      expect(squatter.readAsStringSync(), 'do not clobber me');
      expect(File('${dlDir.path}/$name').existsSync(), isTrue);
      await expectStillSeeding(session, rig.infoHash);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'rename/move on an unknown torrent reports an error instead of crashing',
    () {
      final EmbeddedTorrentSession? session =
          EmbeddedTorrentSession.open(engine!, listenInterfaces: '');
      expect(session, isNotNull);
      addTearDown(session!.close);

      final FtStorageOpResult renamed =
          session.renameFile('0' * 40, 0, 'whatever.bin');
      expect(renamed.ok, isFalse);
      expect(renamed.error, isNotNull);

      final FtStorageOpResult moved =
          session.moveStorage('0' * 40, tempDir.path);
      expect(moved.ok, isFalse);
      expect(moved.error, isNotNull);
    },
    skip: skip,
  );
}
