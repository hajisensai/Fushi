import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_game_exit_watch.dart';
import 'package:fushi/src/mining/galgame_play_tracker.dart';
import 'package:fushi/src/mining/galgame_process_group.dart';

/// BUG-4002：游戏进程存活的唯一判据 [GalGameExitWatch] 与共用归属判据
/// [GalgameProcessGroup] 的纯逻辑守卫（不碰 Win32，Linux CI 照跑）。
void main() {
  const int selfPid = 1;
  const String gameExe = r'D:\Games\Title\Game.exe';

  GalGameExitWatch watchOf(
    _Probe probe, {
    int pid = 100,
    String? exe = gameExe,
    int confirmSamples = 3,
  }) => GalGameExitWatch(
    pid: pid,
    group: GalgameProcessGroup.forExecutable(
      exe,
      probe: probe,
      selfPid: selfPid,
    ),
    confirmSamples: confirmSamples,
  );

  test('从没见过活着就永不判死（判活不可用退回手动停止）', () {
    final _Probe probe = _Probe();
    final GalGameExitWatch watch = watchOf(probe);
    for (int i = 0; i < 10; i++) {
      expect(watch.sample(), GalGameExitStatus.unconfirmed);
    }
  });

  test('连续 N 次失活才判退出；单次抖动不算', () {
    final _Probe probe = _Probe()..processes[100] = gameExe;
    final GalGameExitWatch watch = watchOf(probe);
    expect(watch.sample(), GalGameExitStatus.alive);
    probe.dead.add(100);
    expect(watch.sample(), GalGameExitStatus.unconfirmed);
    probe.dead.remove(100);
    expect(watch.sample(), GalGameExitStatus.alive);
    probe.dead.add(100);
    expect(watch.sample(), GalGameExitStatus.unconfirmed);
    expect(watch.sample(), GalGameExitStatus.unconfirmed);
    expect(watch.sample(), GalGameExitStatus.exited);
  });

  test('Launcher → 本体：原进程死后游戏目录下的活进程接手', () {
    final _Probe probe = _Probe()..processes[100] = gameExe;
    final GalGameExitWatch watch = watchOf(probe, confirmSamples: 1);
    expect(watch.sample(), GalGameExitStatus.alive);
    probe
      ..dead.add(100)
      ..processes[200] = r'D:\Games\Title\bin\Engine.exe'
      ..processes[300] = r'D:\Games\Title2\Other.exe';
    expect(watch.sample(), GalGameExitStatus.handedOff);
    expect(watch.pid, 200);
  });

  test('游戏装在 junction 后面：exe 是链接路径、进程报真实路径时仍认出接手进程', () {
    final _Probe probe = _Probe(
      canonicalMap: <String, String>{r'D:\Games\Title': r'E:\Real\Title'},
    )..processes[100] = gameExe;
    final GalGameExitWatch watch = watchOf(probe, confirmSamples: 1);
    expect(watch.sample(), GalGameExitStatus.alive);
    probe
      ..dead.add(100)
      ..processes[200] = r'E:\Real\Title\Game.exe';
    expect(
      watch.sample(),
      GalGameExitStatus.handedOff,
      reason: '与计时器同一套 canonicalize 回退，两边结论不能相反',
    );
    expect(watch.pid, 200);
  });

  test('PID 被回收给无关进程不算接手；Fushi 自身不算', () {
    final _Probe probe = _Probe()..processes[100] = gameExe;
    final GalGameExitWatch watch = watchOf(probe, confirmSamples: 1);
    expect(watch.sample(), GalGameExitStatus.alive);
    probe
      ..dead.add(100)
      ..processes[selfPid] = r'D:\Games\Title\fushi.exe'
      ..processes[200] = r'C:\Windows\explorer.exe';
    expect(watch.sample(), GalGameExitStatus.exited);
  });

  test('开局不知道 PID：认领游戏目录下的活进程', () {
    final _Probe probe = _Probe();
    final GalGameExitWatch watch = watchOf(probe, pid: 0);
    expect(watch.sample(), GalGameExitStatus.unconfirmed);
    probe.processes[200] = gameExe;
    expect(watch.sample(), GalGameExitStatus.adopted);
    expect(watch.pid, 200);
    expect(watch.sample(), GalGameExitStatus.alive);
  });

  test('盘符根下的 exe 不把整盘进程当本游戏', () {
    expect(galgameExecutableDirectory(r'D:\Game.exe'), isNull);
    expect(galgameExecutableDirectory(null), isNull);
    expect(
      galgameExecutableDirectory(r'D:\Games\Title\Game.exe'),
      r'D:\Games\Title',
    );
    final _Probe probe = _Probe()
      ..processes[100] = r'D:\Game.exe'
      ..processes[200] = r'D:\Other\x.exe';
    final GalGameExitWatch watch = watchOf(
      probe,
      exe: r'D:\Game.exe',
      confirmSamples: 1,
    );
    expect(watch.sample(), GalGameExitStatus.alive);
    probe.dead.add(100);
    expect(watch.sample(), GalGameExitStatus.exited);
  });
}

class _Probe implements GalgameProcessProbe {
  _Probe({this.canonicalMap = const <String, String>{}});

  final Map<int, String> processes = <int, String>{};
  final Set<int> dead = <int>{};

  /// `{链接目录: 真实目录}`，前缀替换。
  final Map<String, String> canonicalMap;

  @override
  int? foregroundProcessId() => null;

  @override
  bool isProcessAlive(int pid) =>
      processes.containsKey(pid) && !dead.contains(pid);

  @override
  String? processImagePath(int pid) => processes[pid];

  @override
  List<GalgameProcessInfo> listProcesses() => processes.entries
      .where((MapEntry<int, String> e) => !dead.contains(e.key))
      .map(
        (MapEntry<int, String> e) =>
            GalgameProcessInfo(pid: e.key, imagePath: e.value),
      )
      .toList(growable: false);

  @override
  String? canonicalize(String path) {
    for (final MapEntry<String, String> entry in canonicalMap.entries) {
      if (path == entry.key) return entry.value;
      if (path.startsWith('${entry.key}\\')) {
        return entry.value + path.substring(entry.key.length);
      }
    }
    return path;
  }
}
