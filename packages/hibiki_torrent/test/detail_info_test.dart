// TODO-2482：详情批次 C ABI 的真实 DLL 验证（trackers / 文件优先级读写 /
// 会话状态 / 快照新字段 / peer flags 字段形状）。
//
// 库路径解析同冒烟测试：HIBIKI_TORRENT_LIB 指向 DLL；缺库整组 skip
// （能力探测跳过而非假绿）。数据面全本地确定性（LocalSeedRig），零外网。

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
    tempDir = Directory.systemTemp.createTempSync('ht_detail_');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 偶发句柄未释放；留给系统清理。
    }
  });

  test('新 DLL 的详情符号组齐全（supportsDetailInfo）', () {
    final EmbeddedTorrentSession? session =
        EmbeddedTorrentSession.open(engine!);
    expect(session, isNotNull);
    addTearDown(session!.close);
    expect(session.supportsDetailInfo, isTrue,
        reason: '刚重编的 DLL 必须带 TODO-2482 的 4 个新符号');
  }, skip: skip);

  test('sessionStatus：非阻塞返回、设置位与端口如实', () {
    // 监听回环端口 0（系统分配），DHT 关。
    final EmbeddedTorrentSession? session = EmbeddedTorrentSession.open(
      engine!,
      listenInterfaces: '127.0.0.1:0',
    );
    addTearDown(session!.close);
    final HtSessionStatus? status = session.sessionStatus();
    expect(status, isNotNull);
    expect(status!.dhtRunning, isFalse);
    expect(status.lsdEnabled, isFalse, reason: 'bridge 建 session 默认关 LSD');
    expect(status.pexEnabled, isTrue);
    expect(status.listenPort, greaterThan(0));
    expect(status.portMappings, isEmpty, reason: 'UPnP/NAT-PMP 默认关');
    // 首轮统计可能 -1（非阻塞契约），但绝不能是别的负值。
    expect(status.dhtNodes, greaterThanOrEqualTo(-1));
    expect(status.downRate, greaterThanOrEqualTo(-1));
  }, skip: skip);

  test('文件优先级：默认 4、set 0/7 后读回一致、越界拒绝', () async {
    final EmbeddedTorrentSession? session = EmbeddedTorrentSession.open(
      engine!,
      listenInterfaces: '127.0.0.1:0',
    );
    addTearDown(session!.close);
    final LocalSeedRig rig = await LocalSeedRig.start(
      engine: engine,
      workDir: tempDir,
      contentBytes: 256 * 1024,
    );
    addTearDown(rig.dispose);
    final Directory saveDir = Directory('${tempDir.path}/dl')..createSync();
    final HtAddResult added = session.addTorrentFile(
      rig.torrentPath,
      savePath: saveDir.path,
    );
    expect(added.ok, isTrue);
    final String id = added.id!;

    // .torrent 文件路径添加：元数据现成，优先级立即可读。
    final List<int>? initial = session.getFilePriorities(id);
    expect(initial, isNotNull);
    expect(initial, isNotEmpty);
    expect(initial!.first, 4, reason: 'libtorrent 默认优先级 = 4');

    expect(session.setFilePriority(id, 0, 0), isTrue, reason: '0 = 不下载');
    await _pollUntil(
      () => session.getFilePriorities(id)?.first == 0,
      timeout: const Duration(seconds: 10),
      what: 'file priority to settle at 0',
    );
    expect(session.setFilePriority(id, 0, 7), isTrue);
    await _pollUntil(
      () => session.getFilePriorities(id)?.first == 7,
      timeout: const Duration(seconds: 10),
      what: 'file priority to settle at 7',
    );

    // 越界/非法参数拒绝。
    expect(session.setFilePriority(id, 999, 4), isFalse);
    expect(session.setFilePriority(id, 0, 8), isFalse);
    expect(session.setFilePriority(id, 0, -1), isFalse);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('TODO-2526：首尾提优在改文件优先级后被重放；priority=0 不被强下', () async {
    final EmbeddedTorrentSession? session = EmbeddedTorrentSession.open(
      engine!,
      listenInterfaces: '127.0.0.1:0',
    );
    addTearDown(session!.close);
    final LocalSeedRig rig = await LocalSeedRig.start(
      engine: engine,
      workDir: tempDir,
      contentBytes: 256 * 1024,
    );
    addTearDown(rig.dispose);
    final Directory saveDir = Directory('${tempDir.path}/dl')..createSync();
    final HtAddResult added = session.addTorrentFile(
      rig.torrentPath,
      savePath: saveDir.path,
    );
    expect(added.ok, isTrue);
    final String id = added.id!;

    // 起播优化落地：首尾 piece 提到 top(7)，中间保持默认(4)。
    expect(session.applyFirstLastPriority(id), 1);
    await _pollUntil(
      () {
        final List<int>? pieces = session.getPiecePriorities(id);
        return pieces != null &&
            pieces.length >= 3 &&
            pieces.first == 7 &&
            pieces.last == 7 &&
            pieces[1] == 4;
      },
      timeout: const Duration(seconds: 10),
      what: 'first/last boost to land (7,4,...,4,7)',
    );

    // 改文件优先级到 1：libtorrent 会把该文件覆盖的 piece 全重算成 1，
    // 桥必须在写入后重放首尾提优 —— 首尾仍是 7、中间落到 1。
    expect(session.setFilePriority(id, 0, 1), isTrue);
    await _pollUntil(
      () {
        final List<int>? pieces = session.getPiecePriorities(id);
        return pieces != null &&
            pieces.first == 7 &&
            pieces.last == 7 &&
            pieces[1] == 1;
      },
      timeout: const Duration(seconds: 10),
      what: 'boost replay after file priority change (7,1,...,1,7)',
    );

    // priority=0（不下载）：重放必须跳过该文件，首尾**不得**被强下 ——
    // 所有 piece 归 0（TODO-2526 复核点名的陷阱）。
    expect(session.setFilePriority(id, 0, 0), isTrue);
    await _pollUntil(
      () {
        final List<int>? pieces = session.getPiecePriorities(id);
        return pieces != null && pieces.every((int v) => v == 0);
      },
      timeout: const Duration(seconds: 10),
      what: 'all pieces drop to 0 when the only file is skipped',
    );
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('trackers：本地种子（无 tracker）返回空列表而非报错', () async {
    final EmbeddedTorrentSession? session = EmbeddedTorrentSession.open(
      engine!,
      listenInterfaces: '127.0.0.1:0',
    );
    addTearDown(session!.close);
    final LocalSeedRig rig = await LocalSeedRig.start(
      engine: engine,
      workDir: tempDir,
      contentBytes: 128 * 1024,
    );
    addTearDown(rig.dispose);
    final Directory saveDir = Directory('${tempDir.path}/dl')..createSync();
    final HtAddResult added = session.addTorrentFile(
      rig.torrentPath,
      savePath: saveDir.path,
    );
    expect(added.ok, isTrue);
    final List<HtTrackerInfo>? trackers = session.torrentTrackers(added.id!);
    expect(trackers, isNotNull);
    expect(trackers, isEmpty);
    // 不存在的种子 → null（不是空列表）。
    expect(session.torrentTrackers('0' * 40), isNull);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('快照新字段：num_seeds/num_connections/时长/is_paused 有值域', () async {
    final EmbeddedTorrentSession? session = EmbeddedTorrentSession.open(
      engine!,
      listenInterfaces: '127.0.0.1:0',
    );
    addTearDown(session!.close);
    final LocalSeedRig rig = await LocalSeedRig.start(
      engine: engine,
      workDir: tempDir,
      contentBytes: 128 * 1024,
    );
    addTearDown(rig.dispose);
    final Directory saveDir = Directory('${tempDir.path}/dl')..createSync();
    final HtAddResult added = session.addTorrentFile(
      rig.torrentPath,
      savePath: saveDir.path,
    );
    expect(added.ok, isTrue);
    final HtTorrentStatus status = session
        .listTorrents()
        .singleWhere((HtTorrentStatus t) => t.id == added.id);
    // 新 DLL 必须导出这些键（不再是 -1 缺省）。
    expect(status.numSeeds, greaterThanOrEqualTo(0));
    expect(status.numConnections, greaterThanOrEqualTo(0));
    expect(status.activeDurationSeconds, greaterThanOrEqualTo(0));
    expect(status.seedingDurationSeconds, greaterThanOrEqualTo(0));
    expect(status.finishedDurationSeconds, greaterThanOrEqualTo(0));
    expect(status.isPaused, isFalse, reason: 'add 即启动契约');
    // scrape 无 tracker：-1 = 未提供。
    expect(status.numComplete, -1);
    expect(status.numIncomplete, -1);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
