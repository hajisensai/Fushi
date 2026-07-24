import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/galgame_play_tracker.dart';
import 'package:path/path.dart' as p;

/// [GalgamePlaySessionMachine] 状态机守卫：假时钟 + 假 probe 驱动，覆盖前台/后台
/// 切换累加、Launcher→本体切换、逃逸检测、连续失活切 PID、门槛丢弃、两种计时模式。
///
/// 状态机是**平台无关纯逻辑**（不读系统时钟、不碰 Win32），这些用例在 Linux CI 上
/// 照跑。路径一律 [p.join] 构造，不硬编码 `C:\`（Linux 上 `\` 不是分隔符，
/// 见 `16b981c63`）。
void main() {
  final String gamesRoot = p.join(p.rootPrefix(p.current), 'Games');
  final String gameDir = p.join(gamesRoot, 'Anemoi');
  final String siblingDir = p.join(gamesRoot, 'Anemoi2');
  final String launcherExe = p.join(gameDir, 'Launcher.exe');
  final String mainExe = p.join(gameDir, 'bin', 'SiglusEngine.exe');
  final String siblingExe = p.join(siblingDir, 'SiglusEngine.exe');
  final String browserExe =
      p.join(p.rootPrefix(p.current), 'Programs', 'browser.exe');

  test('playtime：只累计前台活跃秒；后台/无前台窗口不计', () async {
    final _Harness h = _Harness(gameDir, <int, String>{100: launcherExe});
    // 前 90 秒游戏在前台，后 60 秒切到别的进程，再 10 秒无前台窗口。
    h.run(90, (int _) => 100);
    expect(h.machine.activeSeconds, 90);
    h.run(60, (int _) => 777);
    expect(h.machine.activeSeconds, 90, reason: '切到别的进程不该继续累加');
    h.run(10, (int _) => null);
    expect(h.machine.activeSeconds, 90);

    await h.stop();
    expect(h.results, hasLength(1));
    expect(h.results.single.gameId, 'g1');
    expect(h.results.single.durationSeconds, 90);
    expect(h.results.single.startMs, 0);
    expect(h.results.single.endMs, h.nowMs);
  });

  test('elapsed：墙钟计时，后台时间照算', () async {
    final _Harness h = _Harness(
      gameDir,
      <int, String>{100: launcherExe},
      mode: GalgamePlayTimingMode.elapsed,
    );
    h.run(10, (int _) => 100);
    h.run(170, (int _) => 777);
    await h.stop();

    expect(h.machine.activeSeconds, 0, reason: 'elapsed 模式不走前台活跃累加');
    expect(h.results.single.durationSeconds, 180);
  });

  test('不足 kMinSessionSeconds 的会话直接丢弃；刚好达标则落库', () async {
    final _Harness short = _Harness(gameDir, <int, String>{100: launcherExe});
    short.run(kMinSessionSeconds - 1, (int _) => 100);
    await short.stop();
    expect(short.results, isEmpty);

    final _Harness exact = _Harness(gameDir, <int, String>{100: launcherExe});
    exact.run(kMinSessionSeconds, (int _) => 100);
    await exact.stop();
    expect(exact.results.single.durationSeconds, kMinSessionSeconds);
  });

  test('Launcher → 本体：3 秒后的候选组扫描纳入本体 PID，前台时间不丢账', () async {
    final _Harness h = _Harness(gameDir, <int, String>{100: launcherExe});
    // 前 2 秒只有 Launcher（还没到候选组扫描时刻）。
    h.run(2, (int _) => 100);
    expect(h.machine.candidatePids, <int>{100});
    expect(h.machine.activeSeconds, 2);

    // 本体起来了：新 PID，仍在游戏目录下。之后前台一直是它。
    h.probe.processes[200] = mainExe;
    h.run(100, (int _) => 200);

    expect(h.machine.candidatePids, containsAll(<int>[100, 200]));
    expect(h.machine.activeSeconds, 102, reason: '切到本体后每秒都该继续记账（2 + 100）');
    await h.stop();
    expect(h.results.single.durationSeconds, 102);
  });

  test('逃逸检测：候选集外的前台进程按路径组件判归属，兄弟目录不误命中', () async {
    final _Harness h = _Harness(gameDir, <int, String>{
      100: launcherExe,
      300: siblingExe, // 兄弟目录 Anemoi2 —— 裸 startsWith 会把它误判成自己人
      400: browserExe,
    });

    h.run(1, (int _) => 300);
    expect(h.machine.foregroundIsGame, isFalse);
    expect(h.machine.candidatePids.contains(300), isFalse);
    expect(h.machine.activeSeconds, 0);

    // 游戏中途 spawn 的新窗口进程（候选组扫描还没跑）→ 逃逸检测当场收编。
    h.probe.processes[500] = p.join(gameDir, 'movie', 'player.exe');
    h.run(1, (int _) => 500);
    expect(h.machine.candidatePids.contains(500), isTrue);
    expect(h.machine.foregroundIsGame, isTrue);
    expect(h.machine.activeSeconds, 1);

    // 无关进程：查过一次路径后进负缓存，不再每 200ms 重复查询。
    h.run(5, (int _) => 400);
    expect(h.machine.foregroundIsGame, isFalse);
    expect(h.probe.imagePathQueries[400], 1);

    await h.stop();
  });

  test('主进程连续失活 $kMaxConsecutiveFailures 次才切 PID：单次抖动不打断会话', () async {
    final _Harness h = _Harness(gameDir, <int, String>{100: launcherExe});
    h.run(5, (int _) => 100);

    // 抖动：单次判活失败后立刻恢复，主 PID 不变。
    h.probe.deadPids.add(100);
    h.run(1, (int _) => 100);
    h.probe.deadPids.remove(100);
    h.run(1, (int _) => 100);
    expect(h.machine.mainPid, 100);
    expect(h.machine.isRunning, isTrue);

    // 真死：Launcher 退出，本体（PID 200）在游戏目录下 → 第 3 次失败时重扫切过去。
    h.probe.processes.remove(100);
    h.probe.deadPids.add(100);
    h.probe.processes[200] = mainExe;
    h.run(kMaxConsecutiveFailures, (int _) => 200);
    expect(h.machine.mainPid, 200);
    expect(h.machine.isRunning, isTrue);

    h.run(90, (int _) => 200);
    await h.stop();
    expect(h.results.single.durationSeconds, greaterThanOrEqualTo(90));
  });

  test('重扫也找不到活进程 → 会话自行结束并结算（结算幂等）', () async {
    final _Harness h = _Harness(gameDir, <int, String>{100: launcherExe});
    h.run(120, (int _) => 100);
    expect(h.machine.activeSeconds, 120);

    h.probe.processes.remove(100);
    h.probe.deadPids.add(100);
    h.run(kMaxConsecutiveFailures, (int _) => null);

    expect(h.machine.isRunning, isFalse);
    expect(h.machine.isEnded, isTrue);
    await h.machine.pendingWrite;
    expect(h.results, hasLength(1));
    expect(h.results.single.durationSeconds, 120);

    await h.stop();
    expect(h.results, hasLength(1), reason: '重复 stop 不得重复落库');
  });

  test('候选组重建会剔除已退出的 PID，防 PID 回收后误判前台', () async {
    final _Harness h = _Harness(
      gameDir,
      <int, String>{100: launcherExe, 200: mainExe},
    );
    h.run(4, (int _) => 100); // 跨过 3 秒扫描点
    expect(h.machine.candidatePids, containsAll(<int>[100, 200]));

    // 本体退出，PID 200 被系统回收给一个毫无关系的进程；主进程也死了。
    h.probe.processes[200] = browserExe;
    h.probe.processes.remove(100);
    h.probe.deadPids.add(100);
    h.run(kMaxConsecutiveFailures, (int _) => null);

    expect(h.machine.candidatePids.contains(200), isFalse,
        reason: '回收后的 PID 必须被重扫剔除，否则会被当成本游戏继续计时');
    expect(h.machine.isEnded, isTrue);
  });

  test('canonicalize 兜底：游戏装在符号链接后面时仍判为本游戏', () {
    final String realDir = p.join(gamesRoot, 'Real', 'Anemoi');
    final String linkDir = p.join(gamesRoot, 'Link');
    final _Harness h = _Harness(
      linkDir,
      <int, String>{100: p.join(realDir, 'game.exe')},
      mainPid: 999,
      canonicalMap: <String, String>{linkDir: realDir},
    );

    h.run(1, (int _) => 100);
    expect(h.machine.foregroundIsGame, isTrue);
    expect(h.machine.candidatePids.contains(100), isTrue);
  });

  test('非 Windows 平台整体 no-op：不建状态机、不回调、stop 安全', () async {
    final List<GalgamePlaySessionResult> results = <GalgamePlaySessionResult>[];
    final GalgamePlayTracker tracker = GalgamePlayTracker(
      gameId: 'g1',
      gameDirectory: gameDir,
      isWindows: false,
      onSessionEnded: (GalgamePlaySessionResult result) async {
        results.add(result);
      },
    );
    tracker.start(mainPid: 100);
    expect(tracker.isRunning, isFalse);
    expect(tracker.machine, isNull);
    await tracker.stop();
    expect(results, isEmpty);
  });
}

/// 假时钟 + 假 probe 的驱动夹具：[run] 按「每秒先采一次前台、再走一次 1s tick」
/// 推进状态机，全部时间由 [nowMs] 显式控制，不依赖真实定时器。
class _Harness {
  _Harness(
    String gameDirectory,
    Map<int, String> processes, {
    GalgamePlayTimingMode mode = GalgamePlayTimingMode.playtime,
    int mainPid = 100,
    Map<String, String> canonicalMap = const <String, String>{},
  })  : probe = _FakeProcessProbe(
          processes: processes,
          canonicalMap: canonicalMap,
        ),
        results = <GalgamePlaySessionResult>[] {
    machine = GalgamePlaySessionMachine(
      gameId: 'g1',
      gameDirectory: gameDirectory,
      probe: probe,
      mode: mode,
      onSessionEnded: (GalgamePlaySessionResult result) async {
        results.add(result);
      },
    );
    machine.start(nowMs: 0, mainPid: mainPid);
  }

  final _FakeProcessProbe probe;
  final List<GalgamePlaySessionResult> results;
  late final GalgamePlaySessionMachine machine;

  int nowMs = 0;

  /// 推进 [seconds] 秒；[foregroundPid] 按「第几秒」返回该秒的前台 PID。
  void run(int seconds, int? Function(int second) foregroundPid) {
    for (int i = 0; i < seconds; i++) {
      nowMs += 1000;
      machine.onForegroundSample(nowMs: nowMs, foregroundPid: foregroundPid(i));
      machine.onSecondTick(nowMs: nowMs);
    }
  }

  Future<void> stop() => machine.stop(nowMs: nowMs);
}

/// 假 probe：进程表 = `{pid: exe 路径}`；[deadPids] 里的 pid 判活返回 false。
class _FakeProcessProbe implements GalgameProcessProbe {
  _FakeProcessProbe({
    required this.processes,
    this.canonicalMap = const <String, String>{},
  });

  final Map<int, String> processes;

  /// 符号链接映射：`{链接路径: 真实路径}`，前缀匹配。
  final Map<String, String> canonicalMap;

  final Set<int> deadPids = <int>{};

  /// 每个 pid 被查询 exe 路径的次数（用于断言负缓存生效）。
  final Map<int, int> imagePathQueries = <int, int>{};

  @override
  int? foregroundProcessId() => null; // 前台由用例显式喂给状态机

  @override
  bool isProcessAlive(int pid) =>
      processes.containsKey(pid) && !deadPids.contains(pid);

  @override
  String? processImagePath(int pid) {
    imagePathQueries[pid] = (imagePathQueries[pid] ?? 0) + 1;
    return processes[pid];
  }

  @override
  List<GalgameProcessInfo> listProcesses() => processes.entries
      .map(
        (MapEntry<int, String> entry) =>
            GalgameProcessInfo(pid: entry.key, imagePath: entry.value),
      )
      .toList(growable: false);

  @override
  String? canonicalize(String path) {
    for (final MapEntry<String, String> entry in canonicalMap.entries) {
      if (path == entry.key) return entry.value;
      if (path.startsWith('${entry.key}${p.separator}')) {
        return entry.value + path.substring(entry.key.length);
      }
    }
    return path;
  }
}
