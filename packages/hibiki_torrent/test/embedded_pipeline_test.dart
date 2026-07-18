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
      final HtAddResult added = leecher.addMagnet(rig.magnetUri,
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
            .any((HtTorrentStatus t) => t.id == rig.infoHash && t.hasMetadata),
        timeout: const Duration(seconds: 30),
        what: 'metadata',
        onTick: () =>
            leecher.connectPeer(rig.infoHash, '127.0.0.1', rig.seederPort),
      );

      final List<HtFileEntry>? files = leecher.torrentFiles(rig.infoHash);
      expect(files, isNotNull);
      expect(files, hasLength(1));
      expect(files!.single.path, contains('rig-content'));
      expect(files.single.size, 8 * 1024 * 1024);

      // 元数据就绪后：首尾 piece 提优应用成功；末 piece 截止期可设。
      expect(leecher.applyFirstLastPriority(rig.infoHash), 1);
      final HtPieceMap? piecesBefore = leecher.torrentPieces(rig.infoHash);
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
          final List<HtTorrentStatus> ts = leecher.listTorrents();
          final HtTorrentStatus? t =
              ts.where((HtTorrentStatus e) => e.id == rig.infoHash).firstOrNull;
          return t != null && t.isFinished && t.progress >= 1.0 && t.left == 0;
        },
        timeout: const Duration(seconds: 120),
        what: 'download completion',
        onTick: () {
          for (final HtPieceEvent e in leecher.pollPieceEvents()) {
            if (e.id == rig.infoHash) pieceOrder.add(e.piece);
          }
        },
      );
      for (final HtPieceEvent e in leecher.pollPieceEvents()) {
        if (e.id == rig.infoHash) pieceOrder.add(e.piece);
      }

      // ── 完成后校验 ────────────────────────────────────────────────
      final HtPieceMap? piecesAfter = leecher.torrentPieces(rig.infoHash);
      expect(piecesAfter!.haveCount, piecesAfter.numPieces);

      final List<HtFileEntry>? filesDone = leecher.torrentFiles(rig.infoHash);
      expect(filesDone!.single.done, filesDone.single.size);

      final HtTorrentStatus snap = leecher
          .listTorrents()
          .firstWhere((HtTorrentStatus t) => t.id == rig.infoHash);
      expect(snap.contentPath, isNotEmpty);
      final File downloaded = File(snap.contentPath);
      expect(downloaded.existsSync(), isTrue,
          reason: 'content_path should point at the downloaded file');
      final Uint8List got = downloaded.readAsBytesSync();
      final Uint8List want = LocalSeedRig.deterministicBytes(8 * 1024 * 1024);
      expect(got.length, want.length);
      expect(got, want, reason: 'downloaded bytes must equal seeded bytes');

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

      // ── 移除（连数据） ────────────────────────────────────────────
      expect(leecher.removeTorrent(rig.infoHash, deleteFiles: true), isTrue);
      await _pollUntil(
        () => leecher.listTorrents().isEmpty,
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
    final HtAddResult r =
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
}
