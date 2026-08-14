import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 「在 Anki 中打开」后 Anki 只闪任务栏、不跳到前台的修复守卫。
///
/// 现象分两半（用户实测）：Anki 的「浏览」窗口没开时能跳出来；已在后台开着时只闪。
/// 原因是后者走 Anki 内部「raise 一个已存在窗口」的路径，被 Windows 前台锁定降级
/// 成闪任务栏。解锁权只属于当时的前台进程（Hibiki），所以 [AnkiConnectRepository]
/// 必须在 guiBrowse **前**把前台权限让渡给 Anki 进程、**后**再兜底强拉一次。
///
/// 这里钉的是编排（顺序 / loopback 门 / fail-soft），真实 Win32 调用由
/// [AnkiDesktopForegroundBackend] 替身隔离——测试环境没有 Anki 窗口可激活。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AnkiDesktopForeground.raiseRetryInterval = Duration.zero;
  });

  tearDown(() {
    AnkiDesktopForeground.debugBackend = null;
    AnkiDesktopForeground.raiseRetryInterval =
        const Duration(milliseconds: 120);
  });

  /// 把 HTTP 侧的 action 与前台调用记进**同一条**时间线，才能钉住先后顺序。
  MockClient clientRecording(List<String> events) {
    return MockClient((http.Request req) async {
      final Map<String, dynamic> body =
          jsonDecode(req.body) as Map<String, dynamic>;
      events.add('http:${body['action']}');
      return http.Response(jsonEncode({'result': null, 'error': null}), 200);
    });
  }

  test('本机 Anki：先让渡前台权限，再发 guiBrowse，最后兜底强拉', () async {
    final List<String> events = <String>[];
    final _FakeForegroundBackend backend = _FakeForegroundBackend(
      events: events,
      ankiPid: 4321,
      // 让渡没生效（Anki 没能自己上来），兜底这一路必须走到。
      foregroundPidSequence: <int?>[null, 4321],
    );
    AnkiDesktopForeground.debugBackend = backend;
    final AnkiConnectRepository repo = AnkiConnectRepository(
      service: AnkiConnectService(client: clientRecording(events)),
    );

    final bool ok = await repo.openNoteInAnki(305);

    expect(ok, isTrue);
    expect(events, <String>[
      'find',
      'allow:4321',
      'http:guiBrowse',
      'foreground?',
      'raise:4321',
      'foreground?',
    ]);
  });

  test('让渡已生效（前台已归 Anki）时不再强拉窗口', () async {
    final List<String> events = <String>[];
    AnkiDesktopForeground.debugBackend = _FakeForegroundBackend(
      events: events,
      ankiPid: 4321,
      foregroundPidSequence: <int?>[4321],
    );
    final AnkiConnectRepository repo = AnkiConnectRepository(
      service: AnkiConnectService(client: clientRecording(events)),
    );

    await repo.openNoteInAnki(305);

    expect(
        events, <String>['find', 'allow:4321', 'http:guiBrowse', 'foreground?'],
        reason: 'Anki 自己已经上来了，再 SetForegroundWindow 只会抢焦点');
  });

  test('远端 AnkiConnect（非 loopback）完全不碰本机窗口', () async {
    final List<String> events = <String>[];
    AnkiDesktopForeground.debugBackend = _FakeForegroundBackend(
      events: events,
      ankiPid: 4321,
      foregroundPidSequence: <int?>[null],
    );
    final AnkiConnectRepository repo = AnkiConnectRepository(
      service: AnkiConnectService(
        client: clientRecording(events),
        host: '192.168.1.34',
      ),
    );

    final bool ok = await repo.openNoteInAnki(305);

    expect(ok, isTrue);
    expect(events, <String>['http:guiBrowse'],
        reason: '另一台机器上的 Anki，激活本机窗口毫无意义');
  });

  test('本机找不到 Anki 窗口时降级为纯 guiBrowse（不抛、不空转重试）', () async {
    final List<String> events = <String>[];
    AnkiDesktopForeground.debugBackend = _FakeForegroundBackend(
      events: events,
      ankiPid: null,
      foregroundPidSequence: <int?>[null],
    );
    final AnkiConnectRepository repo = AnkiConnectRepository(
      service: AnkiConnectService(client: clientRecording(events)),
    );

    final bool ok = await repo.openNoteInAnki(305);

    expect(ok, isTrue);
    expect(events, <String>['find', 'http:guiBrowse']);
  });

  test('窗口一次没拉上来时重试，且总次数有上限', () async {
    final List<String> events = <String>[];
    AnkiDesktopForeground.debugBackend = _FakeForegroundBackend(
      events: events,
      ankiPid: 4321,
      foregroundPidSequence: <int?>[null],
      raiseSucceeds: false,
    );
    final AnkiConnectRepository repo = AnkiConnectRepository(
      service: AnkiConnectService(client: clientRecording(events)),
    );

    await repo.openNoteInAnki(305);

    expect(events.where((String e) => e == 'raise:4321').length, 3,
        reason: '重试上限，避免前台被别的程序占住时无限循环');
  });

  test('前台激活抛错不得影响「在 Anki 中打开」的结果', () async {
    AnkiDesktopForeground.debugBackend = _ThrowingForegroundBackend();
    final AnkiConnectRepository repo = AnkiConnectRepository(
      service: AnkiConnectService(client: clientRecording(<String>[])),
    );

    expect(await repo.openNoteInAnki(305), isTrue);
  });
}

/// 记录调用时间线的 Win32 替身。
class _FakeForegroundBackend implements AnkiDesktopForegroundBackend {
  _FakeForegroundBackend({
    required this.events,
    required this.ankiPid,
    required List<int?> foregroundPidSequence,
    this.raiseSucceeds = true,
  }) : _foregroundPidSequence = foregroundPidSequence;

  final List<String> events;
  final int? ankiPid;
  final bool raiseSucceeds;

  /// 依次返回的「当前前台进程」；用完后保持最后一个值。
  final List<int?> _foregroundPidSequence;
  int _foregroundReads = 0;

  @override
  int? findAnkiProcessId() {
    events.add('find');
    return ankiPid;
  }

  @override
  bool allowSetForegroundWindow(int pid) {
    events.add('allow:$pid');
    return true;
  }

  @override
  bool isForegroundOwnedByProcess(int pid) {
    events.add('foreground?');
    final int index = _foregroundReads < _foregroundPidSequence.length
        ? _foregroundReads
        : _foregroundPidSequence.length - 1;
    _foregroundReads++;
    return _foregroundPidSequence[index] == pid;
  }

  @override
  bool raiseTopWindowOfProcess(int pid) {
    events.add('raise:$pid');
    return raiseSucceeds;
  }
}

class _ThrowingForegroundBackend implements AnkiDesktopForegroundBackend {
  @override
  int? findAnkiProcessId() => throw StateError('user32 unavailable');

  @override
  bool allowSetForegroundWindow(int pid) =>
      throw StateError('user32 unavailable');

  @override
  bool isForegroundOwnedByProcess(int pid) =>
      throw StateError('user32 unavailable');

  @override
  bool raiseTopWindowOfProcess(int pid) =>
      throw StateError('user32 unavailable');
}
