// 阶段2/3：EmbeddedTorrentHost 宿主接线验证——常驻 session 派发短命后端
// 视图（视图 close 不连累会话）、反吸血 sweep 遍历 peer 不抛、libtorrent 版本。
//
// 下载源 LocalSeedRig（127.0.0.1 本地做种，零外网）。缺 DLL 整组 skip。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/torrent/embedded_torrent_backend.dart';
import 'package:hibiki/src/media/torrent/embedded_torrent_host.dart';
import 'package:hibiki/src/media/torrent/torrent_backend.dart';
import 'package:hibiki_torrent/hibiki_torrent.dart';
import 'package:hibiki_torrent/testing.dart';
import 'package:path/path.dart' as p;

String? _resolveLibPath() {
  final String? env = Platform.environment['FUSHI_TORRENT_LIB'];
  if (env != null && env.isNotEmpty) {
    return File(env).existsSync() ? env : null;
  }
  return null;
}

void main() {
  final String? libPath = _resolveLibPath();
  final String? skip =
      libPath == null ? 'hibiki_torrent_ffi native lib not built' : null;

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ht_host_');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 偶发句柄未释放；留给系统清理。
    }
  });

  test(
    'host opens, hands out shared-session backend views, sweeps peers',
    () async {
      // 用非监听引擎给 rig 做种，另用 host 拿真实下载 session。
      final EmbeddedTorrentEngine rigEngine =
          EmbeddedTorrentEngine.open(libraryPath: libPath!);
      final LocalSeedRig rig = await LocalSeedRig.start(
          engine: rigEngine, workDir: tempDir, contentBytes: 1024 * 1024);
      addTearDown(rig.dispose);

      // host：监听回环（出站连接需要 listen socket），无 DHT（确定性）。
      final EmbeddedTorrentHost? host = EmbeddedTorrentHost.open(
        libraryPath: libPath,
        baseSavePath: p.join(tempDir.path, 'content'),
        resumeDir: p.join(tempDir.path, 'resume'),
        listenInterfaces: '127.0.0.1:0',
        enableDht: false,
        clockMs: () => _fakeClock,
      );
      expect(host, isNotNull);
      addTearDown(host!.dispose);

      expect(host.libtorrentVersion, startsWith('2.'));

      // backendView 是 TorrentBackend；其 close 不能销毁常驻 session。
      final TorrentBackend view1 = host.backendView();
      expect(view1, isA<EmbeddedTorrentBackend>());
      expect(await view1.probeConnection(), startsWith('libtorrent 2.'));
      expect(await view1.prepareCategory('hibiki-anime'), isTrue);
      expect(
        await view1.addTorrent(rig.magnetUri,
            category: 'hibiki-anime', sequential: true),
        isTrue,
      );
      view1.close(); // 关视图……

      // ……第二个视图仍能操作同一 session（证明会话没被 view1.close 销毁）。
      final TorrentBackend view2 = host.backendView();
      final List<TorrentSnapshot> listed =
          await view2.listTorrents(category: 'hibiki-anime');
      expect(listed, hasLength(1));
      expect(listed.single.hash, rig.infoHash);

      // 反吸血 sweep：遍历种子（此处 1 个、无已连 peer）→ torrentPeers 空
      // → evaluate 空 → 无新封段。全程不抛，返回 0（无新封禁）。多跑几轮
      // 幂等（不会因重复 applyIpFilter 报错）。
      expect(host.sweepAntiLeech(), 0);
      expect(host.sweepAntiLeech(), 0);
      expect(host.sweepAntiLeech(), 0);

      // 用户可调资源限制：全设 / 全 0（不限）/ 只设连接数，均应用成功不抛。
      expect(
          host.applyLimits(
              downloadKbps: 2048, uploadKbps: 512, maxConnections: 100),
          isTrue);
      expect(host.applyLimits(), isTrue);
      expect(host.applyLimits(maxConnections: 50), isTrue);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  // ── TODO-1961-a：resume 生命周期 ───────────────────────────────────
  //
  // 这里守的是「计划是真相源」这条不变量：用户删掉一个下载任务后，残留的
  // `.resume` 绝不能在下次启动把种子加回来 —— 那会变成 UI 里看不见、却在后台
  // 占带宽做种的幽灵任务。

  test(
    'resume snapshot persists live torrents and prunes plans the user deleted',
    () async {
      final EmbeddedTorrentEngine rigEngine =
          EmbeddedTorrentEngine.open(libraryPath: libPath!);
      final LocalSeedRig rig = await LocalSeedRig.start(
          engine: rigEngine, workDir: tempDir, contentBytes: 512 * 1024);
      addTearDown(rig.dispose);

      final String resumeDir = p.join(tempDir.path, 'resume');
      final EmbeddedTorrentHost? host = EmbeddedTorrentHost.open(
        libraryPath: libPath,
        baseSavePath: p.join(tempDir.path, 'content'),
        resumeDir: resumeDir,
        listenInterfaces: '127.0.0.1:0',
        enableDht: false,
        clockMs: () => _fakeClock,
      );
      expect(host, isNotNull);
      addTearDown(host!.dispose);

      // 用 rig 的 **.torrent 文件**添加而不是磁力：元数据现成，无需连 peer。
      // （resume data 只对已有元数据的种子有意义——磁力刚加时没有 info dict，
      // 引擎侧会跳过它，见 ht_save_resume_data。）
      final TorrentBackend view = host.backendView();
      expect(
        await view.addTorrent(rig.torrentPath, category: 'hibiki-anime'),
        isTrue,
      );
      await _pollUntil(
        () => host.backendView().listTorrents().then(
            (List<TorrentSnapshot> t) =>
                t.isNotEmpty && t.single.progress >= 0),
        timeout: const Duration(seconds: 30),
        what: 'torrent to appear',
      );

      final File resumeFile = File(p.join(resumeDir, '${rig.infoHash}.resume'));

      // ① 计划仍在 → resume 落盘保留。
      await _pollUntil(
        () async {
          host.saveResumeSnapshot(<String>{rig.infoHash}, force: true);
          return resumeFile.existsSync();
        },
        timeout: const Duration(seconds: 30),
        what: 'resume file for a live plan',
      );

      // ② 节流：非 force 的紧接一次调用应被跳过（返回 null），不写盘。
      expect(host.saveResumeSnapshot(<String>{rig.infoHash}), isNull);

      // ③ 计划被用户删掉（keepIds 里没有它）→ resume 文件必须被剪掉，
      //    否则下次启动这个种子会复活。
      host.saveResumeSnapshot(const <String>{}, force: true);
      expect(resumeFile.existsSync(), isFalse,
          reason: 'a deleted plan must not keep a resume file behind — '
              'otherwise it silently resurrects as an invisible seeding torrent');

      // ④ 剪光之后再恢复：没有任何东西可加回来。
      expect(host.restoreFromResume(const <String>{}), 0);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  // ── TODO-2526：awaiting 暂停记录 vs 用户本会话的最新动作 ─────────────
  //
  // 前置剧情都一样：上会话用户按过暂停（user_paused.json 记着），本次启动
  // 该种子的 .resume 还在但内容坏掉（瞬时加载失败）→ 记录进 awaiting 保留。
  // 随后用户把同一种子重新 add 回来 —— 用户最新动作必须赢过旧暂停记录。

  test(
    'an awaiting paused record must not override an explicit user resume',
    () async {
      final EmbeddedTorrentEngine rigEngine =
          EmbeddedTorrentEngine.open(libraryPath: libPath!);
      final LocalSeedRig rig = await LocalSeedRig.start(
          engine: rigEngine, workDir: tempDir, contentBytes: 256 * 1024);
      addTearDown(rig.dispose);

      final String resumeDir = p.join(tempDir.path, 'resume');
      Directory(resumeDir).createSync(recursive: true);
      writeUserPausedFile(resumeDir, <String>{rig.infoHash});
      // 非 bencode 内容：ht_load_resume_dir 加载必失败，但文件存在。
      File(p.join(resumeDir, '${rig.infoHash}.resume'))
          .writeAsBytesSync(<int>[0x58, 0x58, 0x58]);

      final EmbeddedTorrentHost? host = EmbeddedTorrentHost.open(
        libraryPath: libPath,
        baseSavePath: p.join(tempDir.path, 'content'),
        resumeDir: resumeDir,
        listenInterfaces: '127.0.0.1:0',
        enableDht: false,
        clockMs: () => _fakeClock,
      );
      expect(host, isNotNull);
      addTearDown(host!.dispose);

      // 启动恢复：加载 0 个，但暂停记录必须保留（.resume 还在 = 瞬时失败）。
      expect(host.restoreFromResume(<String>{rig.infoHash}), 0);
      expect(readUserPausedFile(resumeDir), contains(rig.infoHash));

      // 用户本会话把同一种子重新 add 回来。
      expect(
        await host
            .backendView()
            .addTorrent(rig.torrentPath, category: 'hibiki-anime'),
        isTrue,
      );
      await _pollUntil(
        () => host
            .backendView()
            .listTorrents()
            .then((List<TorrentSnapshot> t) => t.isNotEmpty),
        timeout: const Duration(seconds: 30),
        what: 'torrent to appear after re-add',
      );

      // 用户显式恢复：写盘后绝不能仍记着暂停 —— 否则下次启动把这次恢复
      // 吞掉、强制按回暂停。
      expect(host.resumeTorrentByUser(rig.infoHash), isTrue);
      expect(
        readUserPausedFile(resumeDir),
        isNot(contains(rig.infoHash)),
        reason: 'explicit user resume must clear the awaiting record too — '
            'the union persist would otherwise re-pause it on next boot',
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'sweep clears an awaiting paused record once the user re-adds the torrent',
    () async {
      final EmbeddedTorrentEngine rigEngine =
          EmbeddedTorrentEngine.open(libraryPath: libPath!);
      final LocalSeedRig rig = await LocalSeedRig.start(
          engine: rigEngine, workDir: tempDir, contentBytes: 256 * 1024);
      addTearDown(rig.dispose);

      final String resumeDir = p.join(tempDir.path, 'resume');
      Directory(resumeDir).createSync(recursive: true);
      writeUserPausedFile(resumeDir, <String>{rig.infoHash});
      File(p.join(resumeDir, '${rig.infoHash}.resume'))
          .writeAsBytesSync(<int>[0x58, 0x58, 0x58]);

      final EmbeddedTorrentHost? host = EmbeddedTorrentHost.open(
        libraryPath: libPath,
        baseSavePath: p.join(tempDir.path, 'content'),
        resumeDir: resumeDir,
        listenInterfaces: '127.0.0.1:0',
        enableDht: false,
        clockMs: () => _fakeClock,
      );
      expect(host, isNotNull);
      addTearDown(host!.dispose);

      expect(host.restoreFromResume(<String>{rig.infoHash}), 0);
      expect(readUserPausedFile(resumeDir), contains(rig.infoHash));

      expect(
        await host
            .backendView()
            .addTorrent(rig.torrentPath, category: 'hibiki-anime'),
        isTrue,
      );
      await _pollUntil(
        () => host
            .backendView()
            .listTorrents()
            .then((List<TorrentSnapshot> t) => t.isNotEmpty),
        timeout: const Duration(seconds: 30),
        what: 'torrent to appear after re-add',
      );

      // 种子重新出现在 session 里（只能是用户主动 add）——下一轮 sweep
      // 应把 awaiting 记录当场作废，而不是让它整个会话跑态、下次启动又被
      // 按回暂停。
      host.sweepUploadPolicy();
      expect(
        readUserPausedFile(resumeDir),
        isNot(contains(rig.infoHash)),
        reason: 'a re-added torrent means the user wants it running — the '
            'stale paused record must not survive the sweep',
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'restoreFromResume on an empty/missing resume dir is a no-op',
    () {
      final EmbeddedTorrentHost? host = EmbeddedTorrentHost.open(
        libraryPath: libPath,
        baseSavePath: p.join(tempDir.path, 'content'),
        resumeDir: p.join(tempDir.path, 'no-such-resume'),
        listenInterfaces: '',
        enableDht: false,
        clockMs: () => _fakeClock,
      );
      expect(host, isNotNull);
      addTearDown(host!.dispose);

      expect(host.restoreFromResume(<String>{'deadbeef'}), 0);
    },
    skip: skip,
  );
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

// 反吸血引擎的判定基准时钟（注入固定值；本测试不依赖时间推进）。
const int _fakeClock = 1000000;
