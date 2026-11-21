// BUG-1293 行为闭环：「关上传」的正确原语不影响下载。
//
// 事故本体：旧实现用 torrent_flags::upload_mode 表达「关上传」，而该 flag 的
// libtorrent 语义是「不再发出任何 piece 请求」= 停止下载 —— 默认关上传的用户
// 内置引擎速度恒 ≈ 0。本测试用本地 rig 证明新原语（会话级 unchoke 槽位清零）
// 下下载仍能从 0 推进到完成；旧语义（置 upload_mode）下本用例必然超时红。
//
// 全本地确定性（127.0.0.1 做种、零外网）；缺 DLL 整组 skip。

import 'dart:io';

import 'package:fushi_torrent/fushi_torrent.dart';
import 'package:fushi_torrent/testing.dart';
import 'package:test/test.dart';

String? _resolveLibPath() {
  final String? env = Platform.environment['FUSHI_TORRENT_LIB'];
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
  final String? skip = engine == null
      ? 'fushi_torrent_ffi native lib not built'
      : null;

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ht_upload_off_');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 偶发句柄未释放；留给系统临时目录清理。
    }
  });

  test(
    'download completes with unchoke slots pinned to 0 (upload disabled)',
    () async {
      final LocalSeedRig rig = await LocalSeedRig.start(
        engine: engine!,
        workDir: tempDir,
        contentBytes: 2 * 1024 * 1024,
      );
      addTearDown(rig.dispose);

      final EmbeddedTorrentSession? leecher = EmbeddedTorrentSession.open(
        engine,
        listenInterfaces: '127.0.0.1:0',
      );
      expect(leecher, isNotNull);
      addTearDown(leecher!.close);

      expect(
        leecher.supportsUploadControl,
        isTrue,
        reason: '新构建的 DLL 必须带上传策略原语',
      );
      // 关上传（BUG-1293 的正确原语）：**下载开始前**就钉死 0 槽位。
      expect(leecher.setUnchokeSlots(0), isTrue);

      final Directory dlDir = Directory('${tempDir.path}/dl')..createSync();
      final FtAddResult added = leecher.addMagnet(
        rig.magnetUri,
        savePath: dlDir.path,
      );
      expect(added.ok, isTrue, reason: 'addMagnet: ${added.error}');
      expect(
        leecher.connectPeer(rig.infoHash, '127.0.0.1', rig.seederPort),
        isTrue,
      );

      // 旧语义（upload_mode 置位）下这里永远等不到：leecher 不再发 piece
      // 请求。新语义（unchoke=0）只停上传 payload，下载照常完成。
      await _pollUntil(
        () => leecher.listTorrents().any(
          (FtTorrentStatus t) => t.id == rig.infoHash && t.isFinished,
        ),
        timeout: const Duration(seconds: 60),
        what: 'download completion with upload disabled',
        onTick: () =>
            leecher.connectPeer(rig.infoHash, '127.0.0.1', rig.seederPort),
      );

      // 做种停止原语：完成后可 pause（清 auto_managed）与 resume，均成功。
      expect(leecher.pauseTorrent(rig.infoHash, pause: true), isTrue);
      expect(leecher.pauseTorrent(rig.infoHash, pause: false), isTrue);

      // 治愈入口：enabled=true 清 upload_mode 残留（幂等、恒成功）。
      expect(leecher.setUploadMode(enabled: true), isTrue);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // BUG-5071：单种子「停上传、续下载」（fRmEhU4XIK，分享率达标下载途中截停）
  // 旧实现是 set_upload_limit(1)——per-torrent 限速管的是该种子连接上的
  // **全部**出向字节（握手 / interested / request 都要排 1 B/s 的预算），
  // 下载随之饿死。新实现只拦 piece payload，控制消息照常。
  test(
    'download completes while the torrent itself is upload-blocked',
    () async {
      final LocalSeedRig rig = await LocalSeedRig.start(
        engine: engine!,
        workDir: tempDir,
        contentBytes: 2 * 1024 * 1024,
      );
      addTearDown(rig.dispose);

      final EmbeddedTorrentSession? leecher = EmbeddedTorrentSession.open(
        engine,
        listenInterfaces: '127.0.0.1:0',
      );
      expect(leecher, isNotNull);
      addTearDown(leecher!.close);
      expect(leecher.supportsTorrentUploadBlock, isTrue);

      final Directory dlDir = Directory('${tempDir.path}/dl')..createSync();
      final FtAddResult added = leecher.addMagnet(
        rig.magnetUri,
        savePath: dlDir.path,
      );
      expect(added.ok, isTrue, reason: 'addMagnet: ${added.error}');
      // 下载开始前就截停该种子的上传（= 生产里分享率在下载途中达标）。
      expect(
        leecher.setTorrentUploadBlocked(rig.infoHash, blocked: true),
        isTrue,
      );
      expect(
        leecher.connectPeer(rig.infoHash, '127.0.0.1', rig.seederPort),
        isTrue,
      );

      await _pollUntil(
        () => leecher.listTorrents().any(
          (FtTorrentStatus t) => t.id == rig.infoHash && t.isFinished,
        ),
        timeout: const Duration(seconds: 60),
        what: 'download completion with the torrent upload-blocked',
        onTick: () =>
            leecher.connectPeer(rig.infoHash, '127.0.0.1', rig.seederPort),
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // 截停的另一半语义：被截停的一方确实不再供出 payload；解除后对端立即
  // 能续上（截停期间被压住的 interested 要在解除时补回，否则对端以为自己
  // 已表态、本端却永远不 unchoke）。
  test(
    'upload-blocked seeder serves no payload until unblocked',
    () async {
      final LocalSeedRig rig = await LocalSeedRig.start(
        engine: engine!,
        workDir: tempDir,
        contentBytes: 2 * 1024 * 1024,
      );
      addTearDown(rig.dispose);
      expect(
        rig.seeder.setTorrentUploadBlocked(rig.infoHash, blocked: true),
        isTrue,
      );

      final EmbeddedTorrentSession? leecher = EmbeddedTorrentSession.open(
        engine,
        listenInterfaces: '127.0.0.1:0',
      );
      expect(leecher, isNotNull);
      addTearDown(leecher!.close);

      final Directory dlDir = Directory('${tempDir.path}/dl')..createSync();
      final FtAddResult added = leecher.addMagnet(
        rig.magnetUri,
        savePath: dlDir.path,
      );
      expect(added.ok, isTrue, reason: 'addMagnet: ${added.error}');

      FtTorrentStatus? leech() {
        for (final FtTorrentStatus t in leecher.listTorrents()) {
          if (t.id == rig.infoHash) return t;
        }
        return null;
      }

      // 先等连上并拿到元数据（ut_metadata 是控制面，截停不该挡它）。
      await _pollUntil(
        () => (leech()?.total ?? 0) > 0,
        timeout: const Duration(seconds: 30),
        what: 'metadata from the upload-blocked seeder',
        onTick: () =>
            leecher.connectPeer(rig.infoHash, '127.0.0.1', rig.seederPort),
      );
      // 截停期间给足请求窗口：一个 payload 字节都不该过来。
      final Stopwatch window = Stopwatch()..start();
      while (window.elapsed < const Duration(seconds: 5)) {
        leecher.connectPeer(rig.infoHash, '127.0.0.1', rig.seederPort);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(leech()!.done, 0, reason: 'blocked seeder leaked payload');

      expect(
        rig.seeder.setTorrentUploadBlocked(rig.infoHash, blocked: false),
        isTrue,
      );
      await _pollUntil(
        () => leech()?.isFinished ?? false,
        timeout: const Duration(seconds: 60),
        what: 'download completion after unblocking the seeder',
        onTick: () =>
            leecher.connectPeer(rig.infoHash, '127.0.0.1', rig.seederPort),
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
