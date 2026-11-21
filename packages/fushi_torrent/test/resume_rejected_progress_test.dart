// 第三方报告「Bug 2」：已完成的种子重启后从 0% 重下。
//
// 链路（libtorrent 2.0.11 事实，见各断言旁注释）：
//   1. 完成 → 引擎侧 rename + move（与整理管线同序）→ resume 落盘（全 1 位图）；
//   2. 重启时 save_path 暂时不可达 → fast-resume 被拒 → 全量哈希检查在空路径上
//      全部失败 → 种子以 0 片进入 downloading；
//   3. 周期 resume 保存把「显式全长、全 0」的 pieces 位图写回 .resume，覆盖掉
//      原先全 1 的那份；
//   4. 路径恢复后再启动：verify_resume_data 只核对「位图里置 1 的片所在文件」，
//      全 0 位图无片可核 → fast-resume 被**接受** → 不做任何哈希检查，进度永久 0。
//
// 本文件第二个用例断言的是**正确行为**（路径回来后种子必须回到完整），修复前
// 的桥上是红的——红即复现（BUG-5072）。第一个用例是对照：串行的 rename/move/save 写出
// 的是新 save_path 与新文件名、重启可直接做种（排除「同步序列里的旧路径快照」）。
//
// 全本地确定性（127.0.0.1、零外网）；FUSHI_TORRENT_LIB 指向 DLL，缺库整组 skip。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
  String Function()? describe,
}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (!done()) {
    if (sw.elapsed > timeout) {
      fail(
        'timeout waiting for $what${describe == null ? '' : ': ${describe()}'}',
      );
    }
    onTick?.call();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// 最小 bencode 解码（int → int，string → Uint8List，list → List，dict →
/// Map<String, Object>），只用来读 `.resume` 顶层键。
class _Bdecoder {
  _Bdecoder(this._b);

  final Uint8List _b;
  int _i = 0;

  Object decode() {
    final int c = _b[_i];
    if (c == 0x69) {
      // i<num>e
      final int end = _b.indexOf(0x65, _i);
      final int v = int.parse(ascii.decode(_b.sublist(_i + 1, end)));
      _i = end + 1;
      return v;
    }
    if (c == 0x6c) {
      _i++;
      final List<Object> out = <Object>[];
      while (_b[_i] != 0x65) {
        out.add(decode());
      }
      _i++;
      return out;
    }
    if (c == 0x64) {
      _i++;
      final Map<String, Object> out = <String, Object>{};
      while (_b[_i] != 0x65) {
        final String key = utf8.decode(decode() as Uint8List);
        out[key] = decode();
      }
      _i++;
      return out;
    }
    final int colon = _b.indexOf(0x3a, _i);
    final int len = int.parse(ascii.decode(_b.sublist(_i, colon)));
    final Uint8List s = Uint8List.sublistView(_b, colon + 1, colon + 1 + len);
    _i = colon + 1 + len;
    return s;
  }
}

Map<String, Object> _readResume(File f) =>
    _Bdecoder(f.readAsBytesSync()).decode() as Map<String, Object>;

/// `.resume` 的 pieces 位图（每片 1 字节，bit0 = 持有）。
({int length, int have}) _resumePieces(Map<String, Object> resume) {
  final Uint8List? p = resume['pieces'] as Uint8List?;
  if (p == null) return (length: 0, have: 0);
  return (length: p.length, have: p.where((int b) => b & 1 == 1).length);
}

String _str(Map<String, Object> resume, String key) {
  final Object? v = resume[key];
  return v is Uint8List ? utf8.decode(v) : '<missing>';
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
    tempDir = Directory.systemTemp.createTempSync('ht_resume_rej_');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 偶发句柄未释放；留给系统临时目录清理。
    }
  });

  EmbeddedTorrentSession openSession() {
    final EmbeddedTorrentSession? s = EmbeddedTorrentSession.open(
      engine!,
      listenInterfaces: '127.0.0.1:0',
    );
    expect(s, isNotNull);
    addTearDown(s!.close);
    return s;
  }

  FtTorrentStatus? statusOf(EmbeddedTorrentSession s, String id) =>
      s.listTorrents().where((FtTorrentStatus t) => t.id == id).firstOrNull;

  String describe(EmbeddedTorrentSession s, String id) {
    final FtTorrentStatus? t = statusOf(s, id);
    final FtPieceMap? p = s.torrentPieces(id);
    return 'state=${t?.state} progress=${t?.progress} '
        'have=${p?.haveCount}/${p?.numPieces} savePath=${t?.savePath}';
  }

  /// 下完 → 引擎侧 rename + move（整理管线同序）→ 存 resume → 关 session。
  /// 返回 (infoHash, 整理后的 save_path, 整理后的文件名, 片数, resume 目录)。
  Future<(String, Directory, String, int, Directory)>
  completedAndOrganized() async {
    final LocalSeedRig rig = await LocalSeedRig.start(
      engine: engine!,
      workDir: tempDir,
      // 2 MiB / make_torrent 默认片长 → 多片，足以区分「全 0 位图」与空位图。
      contentBytes: 2 * 1024 * 1024,
    );
    final Directory dlDir = Directory('${tempDir.path}/dl')..createSync();
    final Directory resumeDir = Directory('${tempDir.path}/resume');
    final Directory library = Directory('${tempDir.path}/library/Show');

    final EmbeddedTorrentSession first = openSession();
    final FtAddResult added = first.addMagnet(
      rig.magnetUri,
      savePath: dlDir.path,
    );
    expect(added.ok, isTrue, reason: 'addMagnet: ${added.error}');
    await _pollUntil(
      () {
        final FtTorrentStatus? t = statusOf(first, rig.infoHash);
        return t != null && t.isFinished && t.left == 0;
      },
      timeout: const Duration(seconds: 120),
      what: 'download completion',
      onTick: () =>
          first.connectPeer(rig.infoHash, '127.0.0.1', rig.seederPort),
    );
    // 之后的阶段一个 peer 都不能有：重下 / 覆盖写只能来自本机状态。
    rig.dispose();

    const String organizedName = 'Show - S01E01.bin';
    final FtStorageOpResult renamed = first.renameFile(
      rig.infoHash,
      first.torrentFiles(rig.infoHash)!.single.index,
      organizedName,
    );
    expect(renamed.ok, isTrue, reason: 'rename: ${renamed.error}');
    final FtStorageOpResult moved = first.moveStorage(
      rig.infoHash,
      library.path,
    );
    expect(moved.ok, isTrue, reason: 'move: ${moved.error}');
    expect(File('${library.path}/$organizedName').existsSync(), isTrue);

    final FtResumeSaveResult saved = first.saveResumeData(resumeDir.path);
    expect(saved.saved, 1, reason: 'failed=${saved.failed}');
    final int numPieces = first.torrentPieces(rig.infoHash)!.numPieces;
    expect(numPieces, greaterThan(1));
    first.close();
    return (rig.infoHash, library, organizedName, numPieces, resumeDir);
  }

  test(
    'control: serial rename+move+save persists the new save_path and name',
    () async {
      final (
        String id,
        Directory library,
        String name,
        int numPieces,
        Directory resumeDir,
      ) = await completedAndOrganized();

      final Map<String, Object> resume = _readResume(
        File('${resumeDir.path}/$id.resume'),
      );
      expect(
        _str(resume, 'save_path').replaceAll('\\', '/'),
        library.path.replaceAll('\\', '/'),
      );
      expect(jsonEncode(resume['mapped_files'].toString()), isNotEmpty);
      final ({int length, int have}) bits = _resumePieces(resume);
      expect(bits.length, numPieces);
      expect(bits.have, numPieces);

      final EmbeddedTorrentSession again = openSession();
      expect(again.loadResumeDir(resumeDir.path), <String>[id]);
      await _pollUntil(
        () => statusOf(again, id)?.isSeeding ?? false,
        timeout: const Duration(seconds: 30),
        what: 'seeding from the organized location',
        describe: () => describe(again, id),
      );
      expect(again.torrentFiles(id)!.single.path, name);
      expect(again.torrentPieces(id)!.haveCount, numPieces);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'a transiently unreachable save_path must not permanently zero a '
    'completed torrent',
    () async {
      final (
        String id,
        Directory library,
        String name,
        int numPieces,
        Directory resumeDir,
      ) = await completedAndOrganized();
      final File resumeFile = File('${resumeDir.path}/$id.resume');
      expect(_resumePieces(_readResume(resumeFile)).have, numPieces);

      // ── 重启时目标暂不可达（未挂载 / 网络盘未重连）────────────────
      final Directory offline = Directory('${library.path}.offline');
      library.renameSync(offline.path);

      final EmbeddedTorrentSession degraded = openSession();
      expect(degraded.loadResumeDir(resumeDir.path), <String>[id]);
      // 等 fast-resume 判定 + （若有）全量检查结束。
      await _pollUntil(
        () {
          final FtTorrentStatus? t = statusOf(degraded, id);
          // 修复后：数据不可达 → 加载即暂停，停在 checking_resume_data 不前进。
          return t != null &&
              t.hasMetadata &&
              (t.isPaused || t.state != 'checking');
        },
        timeout: const Duration(seconds: 30),
        what: 'resume check to settle',
        describe: () => describe(degraded, id),
      );
      final String degradedState = describe(degraded, id);
      // BUG-5072：数据不可达时不开跑（开跑 = 在空路径上全检得 0 片）。
      expect(
        statusOf(degraded, id)!.isPaused,
        isTrue,
        reason:
            'unreachable save_path must keep the torrent paused: '
            '$degradedState',
      );
      // 周期保存（app_model 每分钟一次）。
      final FtResumeSaveResult periodic = degraded.saveResumeData(
        resumeDir.path,
      );
      final ({int length, int have}) afterDegraded = _resumePieces(
        _readResume(resumeFile),
      );
      degraded.close();
      // 不可逆的那一步：全长全 0 位图一旦落盘，下次加载即被信任、不再校验。
      expect(
        afterDegraded.length == numPieces && afterDegraded.have == 0,
        isFalse,
        reason: 'periodic save wrote a full-length all-zero pieces map',
      );

      // ── 目标恢复后再启动 ────────────────────────────────────────
      final Directory recreated = Directory(library.path);
      final List<String> recreatedEntries = recreated.existsSync()
          ? recreated
                .listSync(recursive: true)
                .map((FileSystemEntity e) => e.path)
                .toList()
          : const <String>[];
      if (recreated.existsSync()) recreated.deleteSync(recursive: true);
      offline.renameSync(library.path);
      expect(File('${library.path}/$name').existsSync(), isTrue);

      final EmbeddedTorrentSession healed = openSession();
      expect(healed.loadResumeDir(resumeDir.path), <String>[id]);
      final String evidence =
          'while offline: $degradedState; periodic save saved='
          '${periodic.saved}; .resume pieces after that save: '
          'length=${afterDegraded.length} have=${afterDegraded.have} '
          '(numPieces=$numPieces); engine recreated under the offline path: '
          '$recreatedEntries';
      await _pollUntil(
        () => statusOf(healed, id)?.isSeeding ?? false,
        timeout: const Duration(seconds: 20),
        what:
            'completed torrent to be recognised as complete once its data is '
            'reachable again ($evidence)',
        describe: () => describe(healed, id),
      );
      expect(healed.torrentPieces(id)!.haveCount, numPieces);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  // HBK-AUDIT-030：盘 / 网络挂载不在、空挂载点目录还在。只看 save_path
  // 目录存在会照常开跑、在空目录上全检得 0 片并把全 0 位图写回；暂停期间写
  // 出的空位图又会让下次启动（数据仍不可达）把它重新放出来。必须按真实数据
  // 判可达，且离线期间盘上的原 .resume 一字节都不动——连续两次启动都如此。
  test(
    'an empty mount point keeps the original resume across two offline '
    'restarts and the torrent seeds once the data is back',
    () async {
      final (
        String id,
        Directory library,
        String name,
        int numPieces,
        Directory resumeDir,
      ) = await completedAndOrganized();
      final File resumeFile = File('${resumeDir.path}/$id.resume');
      final List<int> original = resumeFile.readAsBytesSync();
      expect(_resumePieces(_readResume(resumeFile)).have, numPieces);

      final Directory offline = Directory('${library.path}.offline');
      library.renameSync(offline.path);
      library.createSync(); // 空挂载点：目录在，数据不在。

      for (int boot = 1; boot <= 2; boot++) {
        final EmbeddedTorrentSession s = openSession();
        expect(s.loadResumeDir(resumeDir.path), <String>[id]);
        await _pollUntil(
          () => statusOf(s, id)?.hasMetadata ?? false,
          timeout: const Duration(seconds: 30),
          what: 'torrent to be listed (boot $boot)',
          describe: () => describe(s, id),
        );
        expect(
          statusOf(s, id)!.isPaused,
          isTrue,
          reason:
              'boot $boot: data offline must stay paused: ${describe(s, id)}',
        );
        expect(s.sessionStatus()!.offlineResumeFrozen, 1);
        final FtResumeSaveResult saved = s.saveResumeData(resumeDir.path);
        expect(saved.saved, 0, reason: 'boot $boot: frozen resume was written');
        expect(
          resumeFile.readAsBytesSync(),
          original,
          reason: 'boot $boot: the original .resume must stay untouched',
        );
        s.close();
      }
      expect(library.listSync(), isEmpty, reason: 'nothing written offline');

      library.deleteSync(recursive: true);
      offline.renameSync(library.path);
      expect(File('${library.path}/$name').existsSync(), isTrue);
      final EmbeddedTorrentSession healed = openSession();
      expect(healed.loadResumeDir(resumeDir.path), <String>[id]);
      await _pollUntil(
        () => statusOf(healed, id)?.isSeeding ?? false,
        timeout: const Duration(seconds: 30),
        what: 'seeding once the data is reachable again',
        describe: () => describe(healed, id),
      );
      expect(healed.torrentPieces(id)!.haveCount, numPieces);
      expect(healed.sessionStatus()!.offlineResumeFrozen, 0);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  // 用户在离线状态下显式继续 = 接受按现状校验：解冻，resume 照常落盘。
  test(
    'an explicit resume of an offline torrent unfreezes its resume',
    () async {
      final (
        String id,
        Directory library,
        String _,
        int _,
        Directory resumeDir,
      ) = await completedAndOrganized();
      library.renameSync('${library.path}.offline');
      library.createSync();

      final EmbeddedTorrentSession s = openSession();
      expect(s.loadResumeDir(resumeDir.path), <String>[id]);
      expect(s.sessionStatus()!.offlineResumeFrozen, 1);
      expect(s.pauseTorrent(id, pause: false), isTrue);
      expect(s.sessionStatus()!.offlineResumeFrozen, 0);
      expect(s.saveResumeData(resumeDir.path).saved, 1);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  // HBK-AUDIT-030：上传闸登记表按种子生命周期精确增删（旧实现每加一颗种子
  // 持锁清扫整张表，N 颗累计 O(N²)，移除后的过期项还要等下一次加种子才清）。
  test('upload gate registry tracks exactly the live torrents', () async {
    final EmbeddedTorrentSession s = openSession();
    final Directory data = Directory('${tempDir.path}/gates')..createSync();
    final List<String> ids = <String>[];
    for (int i = 0; i < 20; i++) {
      final File f = File('${data.path}/f$i.bin')..writeAsStringSync('gate $i');
      final String t = '${data.path}/t$i.torrent';
      expect(
        engine!.makeTorrent(contentPath: f.path, outTorrentPath: t).ok,
        isTrue,
      );
      final FtAddResult added = s.addTorrentFile(t, savePath: data.path);
      expect(added.ok, isTrue, reason: added.error);
      ids.add(added.id!);
    }
    expect(s.sessionStatus()!.uploadGates, 20);
    for (final String id in ids.skip(5)) {
      expect(s.removeTorrent(id), isTrue);
    }
    await _pollUntil(
      () => s.sessionStatus()!.uploadGates == 5,
      timeout: const Duration(seconds: 10),
      what: 'removed torrents to leave the gate registry',
      describe: () => 'upload_gates=${s.sessionStatus()!.uploadGates}',
    );
    // 剩下的闸仍可用。
    for (final String id in ids.take(5)) {
      expect(s.setTorrentUploadBlocked(id, blocked: true), isTrue);
    }
  }, skip: skip);
}
