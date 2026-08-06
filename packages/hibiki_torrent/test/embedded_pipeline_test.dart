// 阶段1b 端到端下载管线测试：磁力 → 元数据 → 顺序下载 → 进度 → 完成。
//
// 全本地确定性：LocalSeedRig 在 127.0.0.1 做种，被测 leecher session 用
// 纯 btih 磁力 + connect_peer 从它下载 —— 零外网、零 DHT/tracker，不 flaky。
// 顺序性证据 = leecher 的 piece_finished 事件序（不依赖限速时序）。
//
// 库路径解析同冒烟测试：HIBIKI_TORRENT_LIB 指向 DLL；缺库整组 skip。

import 'dart:io';
import 'dart:typed_data';

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
    tempDir = Directory.systemTemp.createTempSync('ht_pipeline_');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 上偶发句柄未释放；留给系统临时目录清理。
    }
  });

  test(
    'magnet → metadata → sequential download → completion (local rig)',
    () async {
      final LocalSeedRig rig = await LocalSeedRig.start(
          engine: engine!, workDir: tempDir, contentBytes: 8 * 1024 * 1024);
      addTearDown(rig.dispose);

      // Leecher：也要有 listen socket（libtorrent 出站连接绑定 listen
      // socket，全不监听时连不出去）；只绑回环、无 DHT —— 全确定性。
      final EmbeddedTorrentSession? leecher =
          EmbeddedTorrentSession.open(engine, listenInterfaces: '127.0.0.1:0');
      expect(leecher, isNotNull);
      addTearDown(leecher!.close);

      final Directory dlDir = Directory('${tempDir.path}/dl')..createSync();
      final FtAddResult added = leecher.addMagnet(rig.magnetUri,
          savePath: dlDir.path, sequential: true);
      expect(added.ok, isTrue, reason: 'addMagnet: ${added.error}');
      expect(added.id, rig.infoHash);

      expect(leecher.connectPeer(rig.infoHash, '127.0.0.1', rig.seederPort),
          isTrue);

      // ── 元数据 ────────────────────────────────────────────────────
      // connect_peer 在种子起始瞬间可能被丢弃且无从重发现（本地 rig 无
      // DHT/tracker），轮询期重试（已连上时重复 connect 是 no-op）。
      await _pollUntil(
        () => leecher
            .listTorrents()
            .any((FtTorrentStatus t) => t.id == rig.infoHash && t.hasMetadata),
        timeout: const Duration(seconds: 30),
        what: 'metadata',
        onTick: () =>
            leecher.connectPeer(rig.infoHash, '127.0.0.1', rig.seederPort),
      );

      final List<FtFileEntry>? files = leecher.torrentFiles(rig.infoHash);
      expect(files, isNotNull);
      expect(files, hasLength(1));
      expect(files!.single.path, contains('rig-content'));
      expect(files.single.size, 8 * 1024 * 1024);

      // 元数据就绪后：首尾 piece 提优应用成功；末 piece 截止期可设。
      expect(leecher.applyFirstLastPriority(rig.infoHash), 1);
      final FtPieceMap? piecesBefore = leecher.torrentPieces(rig.infoHash);
      expect(piecesBefore, isNotNull);
      expect(piecesBefore!.numPieces, greaterThan(0));
      expect(
          leecher.setPieceDeadline(
              rig.infoHash, piecesBefore.numPieces - 1, 1000),
          isTrue);

      // ── 下载至完成，沿途收集 piece 完成事件 ───────────────────────
      final List<int> pieceOrder = <int>[];
      await _pollUntil(
        () {
          final List<FtTorrentStatus> ts = leecher.listTorrents();
          final FtTorrentStatus? t =
              ts.where((FtTorrentStatus e) => e.id == rig.infoHash).firstOrNull;
          return t != null && t.isFinished && t.progress >= 1.0 && t.left == 0;
        },
        timeout: const Duration(seconds: 120),
        what: 'download completion',
        onTick: () {
          for (final FtPieceEvent e in leecher.pollPieceEvents()) {
            if (e.id == rig.infoHash) pieceOrder.add(e.piece);
          }
        },
      );
      for (final FtPieceEvent e in leecher.pollPieceEvents()) {
        if (e.id == rig.infoHash) pieceOrder.add(e.piece);
      }

      // ── 完成后校验 ────────────────────────────────────────────────
      final FtPieceMap? piecesAfter = leecher.torrentPieces(rig.infoHash);
      expect(piecesAfter!.haveCount, piecesAfter.numPieces);

      final List<FtFileEntry>? filesDone = leecher.torrentFiles(rig.infoHash);
      expect(filesDone!.single.done, filesDone.single.size);

      final FtTorrentStatus snap = leecher
          .listTorrents()
          .firstWhere((FtTorrentStatus t) => t.id == rig.infoHash);
      expect(snap.contentPath, isNotEmpty);
      final String contentPath = snap.contentPath;

      // ── 顺序性：完成事件序应基本递增 ──────────────────────────────
      // 首尾提优/截止期会把个别 piece 拉到前面；剔除每文件首尾 piece 后，
      // 相邻事件递增占比应显著偏向顺序（阈值放宽到 0.8 抗调度抖动）。
      expect(pieceOrder.toSet(), hasLength(piecesAfter.numPieces),
          reason: 'every piece must be seen exactly once');
      final Set<int> boosted = <int>{0, piecesAfter.numPieces - 1};
      final List<int> ordinary = pieceOrder
          .where((int p) => !boosted.contains(p))
          .toList(growable: false);
      int ascending = 0;
      for (int i = 1; i < ordinary.length; i++) {
        if (ordinary[i] > ordinary[i - 1]) ascending++;
      }
      final double ratio =
          ordinary.length > 1 ? ascending / (ordinary.length - 1) : 1.0;
      expect(ratio, greaterThan(0.8),
          reason: 'sequential download should complete pieces mostly in '
              'order (got ratio $ratio, order sample: '
              '${pieceOrder.take(16).toList()})');

      // ── 落盘校验：比对前必须先关掉 session ────────────────────────
      // isFinished / progress==1.0 / left==0 / haveCount==numPieces 说的都是
      // 「piece 已在内存里校验通过」，**不是**「字节已经躺在文件系统里」：
      // 写盘 job 还排在 libtorrent 的 disk io 线程上，且 2.x 的 mmap 磁盘后端
      // 写进去的是映射视图 —— Windows 明确不保证映射视图与 ReadFile
      // 之间的一致性，而内容文件又是稀疏的，于是尚未落实的尾部区域会被读成 0。
      // CI 上约 24% 的跑次就挂在下面这条比对上（失败偏移恒在距文件尾
      // ~114KB 处，读出一串 0）。
      //
      // 唯一确定性的落盘完成信号是**销毁 session**：lt::session 析构会走完
      // 关停流程，等 disk io 线程把所有写盘 job 做完、解除映射并关句柄，之
      // 后普通文件读才看得到全部字节。不得用 sleep / 重试去「等它落盘」
      // —— 那只是把概率压小，并没消除竞态。
      leecher.close();

      final File downloaded = File(contentPath);
      expect(downloaded.existsSync(), isTrue,
          reason: 'content_path should point at the downloaded file');
      final Uint8List got = downloaded.readAsBytesSync();
      final Uint8List want = LocalSeedRig.deterministicBytes(8 * 1024 * 1024);
      expect(got.length, want.length);
      expect(got, want, reason: 'downloaded bytes must equal seeded bytes');

      // ── 移除（连数据） ────────────────────────────────────────────
      // 上面的比对已经把下载 session 关了，数据完整躺在 dlDir 里：直接用
      // rig 的 .torrent 把同一个种子加回一个不联网的新 session（listenInterfaces
      // 为空 = 零 peer，也不需要再换元数据），再验「连数据删除」。删除路径的
      // 覆盖面一点没少，又不会反过来把待比对的文件删掉。
      final EmbeddedTorrentSession? remover =
          EmbeddedTorrentSession.open(engine, listenInterfaces: '');
      expect(remover, isNotNull);
      addTearDown(remover!.close);

      final FtAddResult readded =
          remover.addTorrentFile(rig.torrentPath, savePath: dlDir.path);
      expect(readded.ok, isTrue, reason: 'addTorrentFile: ${readded.error}');
      expect(readded.id, rig.infoHash);

      expect(remover.removeTorrent(rig.infoHash, deleteFiles: true), isTrue);
      await _pollUntil(
        () => remover.listTorrents().isEmpty,
        timeout: const Duration(seconds: 10),
        what: 'torrent removal',
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test('bad magnet is rejected with error, not crash', () {
    final EmbeddedTorrentSession? session =
        EmbeddedTorrentSession.open(engine!);
    addTearDown(session!.close);
    final FtAddResult r =
        session.addMagnet('not-a-magnet', savePath: tempDir.path);
    expect(r.ok, isFalse);
    expect(r.error, isNotNull);
  }, skip: skip);

  test('rate limit setter round-trips', () {
    final EmbeddedTorrentSession? session =
        EmbeddedTorrentSession.open(engine!);
    addTearDown(session!.close);
    expect(session.setRateLimits(downloadBps: 1024 * 1024), isTrue);
    expect(session.setRateLimits(), isTrue);
  }, skip: skip);

  test('applyLimits (rate + connections) round-trips', () {
    final EmbeddedTorrentSession? session =
        EmbeddedTorrentSession.open(engine!);
    addTearDown(session!.close);
    // 全设。
    expect(
        session.applyLimits(
            downloadBps: 2 * 1024 * 1024,
            uploadBps: 512 * 1024,
            connectionsLimit: 100),
        isTrue);
    // 全 0 = 不限，也应成功（connections<=0 保持默认，不误设成禁连）。
    expect(session.applyLimits(), isTrue);
    // 只设连接数。
    expect(session.applyLimits(connectionsLimit: 50), isTrue);
  }, skip: skip);

  test('applyLimits(limitLocalPeers:) drives the local peer class', () {
    final EmbeddedTorrentSession? session =
        EmbeddedTorrentSession.open(engine!);
    addTearDown(session!.close);
    // 刚编出来的 DLL 必须带 ht_apply_limits_ex；不带说明 native 没重编，
    // 后面几条断言就毫无意义了，先在这里失败。
    expect(session.supportsLocalPeerRateLimit, isTrue,
        reason: 'this DLL predates ht_apply_limits_ex — rebuild it');
    // 真 libtorrent 上的 get_peer_class → 改 rate → set_peer_class 往返：
    // local_peer_class_id 必须存在且可写，否则 native 会吞异常返回 0。
    expect(
        session.applyLimits(
            downloadBps: 2 * 1024 * 1024,
            uploadBps: 512 * 1024,
            limitLocalPeers: true),
        isTrue);
    // 关回去（把 local peer class 的上限写回「不限」）也必须成功。
    expect(session.applyLimits(downloadBps: 2 * 1024 * 1024), isTrue);
  }, skip: skip);

  test(
    'ip_filter blocks the seeder, then clearing it lets the download start',
    () async {
      final LocalSeedRig rig = await LocalSeedRig.start(
          engine: engine!, workDir: tempDir, contentBytes: 1024 * 1024);
      addTearDown(rig.dispose);

      final EmbeddedTorrentSession? leecher =
          EmbeddedTorrentSession.open(engine, listenInterfaces: '127.0.0.1:0');
      addTearDown(leecher!.close);
      // 限速让 1MiB 传输持续若干秒，peer 不会秒完即断——保证下面观察到它。
      leecher.setRateLimits(downloadBps: 64 * 1024);

      // 先封整个回环段：随后 connect_peer 到做种者应被 ip_filter 拒绝，
      // 30×0.1s 窗口内拿不到元数据（若不生效，1MiB 本地传输早该几百 ms 完成）。
      expect(leecher.applyIpFilter(<String>['127.0.0.0/8']), isTrue);
      final FtAddResult added = leecher.addMagnet(rig.magnetUri,
          savePath: '${tempDir.path}/dl', sequential: true);
      expect(added.ok, isTrue);
      for (int i = 0; i < 30; i++) {
        leecher.connectPeer(rig.infoHash, '127.0.0.1', rig.seederPort);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        leecher.listTorrents().single.hasMetadata,
        isFalse,
        reason: 'ip_filter should have blocked the only available peer',
      );

      // 清空过滤器后同一 peer 应可连上并拿到元数据。
      expect(leecher.applyIpFilter(const <String>[]), isTrue);
      await _pollUntil(
        () => leecher.listTorrents().single.hasMetadata,
        timeout: const Duration(seconds: 30),
        what: 'metadata after clearing ip_filter',
        onTick: () =>
            leecher.connectPeer(rig.infoHash, '127.0.0.1', rig.seederPort),
      );

      // 连上后 peer 列表应 surface 做种者（反吸血判定输入）。限速 64KiB/s 让
      // 1MiB 传输持续约 16s，peer 全程连着——把 peer 观察绑在真实传输窗口上
      // 而非独立竞态：推进到进度过半期间，做种者应至少出现一次且喂过字节。
      int maxSeenDownload = 0;
      await _pollUntil(
        () {
          for (final FtPeerInfo pr
              in leecher.torrentPeers(rig.infoHash) ?? const <FtPeerInfo>[]) {
            if (pr.ip == '127.0.0.1' && pr.totalDownload > maxSeenDownload) {
              maxSeenDownload = pr.totalDownload;
            }
          }
          return leecher.listTorrents().single.progress >= 0.5;
        },
        timeout: const Duration(seconds: 60),
        what: 'download to reach 50% (peer feeding bytes)',
        onTick: () =>
            leecher.connectPeer(rig.infoHash, '127.0.0.1', rig.seederPort),
      );
      // 做种者在传输窗口内出现过并给我们喂了字节。
      expect(maxSeenDownload, greaterThan(0),
          reason: 'seeder peer must surface in peer_info with bytes fed to us');
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
