// 复习同步互联快速通道（srs_interconnect_watch.dart）：第一次长轮询只拿基线，令牌变了才同步；断线后补一轮；
// 老 host（不支持）不同步、也不刷请求；本机变动去抖成一次推送。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_interconnect_watch.dart';

void main() {
  test('基线不算变化；令牌变了同步一次', () async {
    final List<int?> asked = <int?>[];
    final List<int> replies = <int>[5, 5, 6];
    int changes = 0;
    final Completer<void> done = Completer<void>();
    late SrsInterconnectWatcher w;
    w = SrsInterconnectWatcher(
      ready: () async => true,
      wait: (int? after) async {
        asked.add(after);
        if (replies.isEmpty) {
          w.stop();
          if (!done.isCompleted) done.complete();
          return after;
        }
        return replies.removeAt(0);
      },
      onChange: () async => changes++,
    );
    w.start();
    await done.future;
    expect(asked, <int?>[null, 5, 5, 6]);
    expect(changes, 1);
  });

  test('断线：退避后令牌作废并补同步一轮', () async {
    int calls = 0;
    int changes = 0;
    final Completer<void> done = Completer<void>();
    late SrsInterconnectWatcher w;
    w = SrsInterconnectWatcher(
      ready: () async => true,
      maxBackoff: const Duration(milliseconds: 5),
      wait: (int? after) async {
        calls++;
        if (calls == 1) return 1;
        if (calls == 2) throw const SocketExceptionStub();
        w.stop();
        if (!done.isCompleted) done.complete();
        return 1;
      },
      onChange: () async => changes++,
    );
    w.start();
    await done.future;
    expect(changes, 1, reason: '有过基线的连接断了：重连前先补一轮');
  });

  test('老 host 不支持：不同步，按长间隔重查', () async {
    int calls = 0;
    int changes = 0;
    final SrsInterconnectWatcher w = SrsInterconnectWatcher(
      ready: () async => true,
      unsupportedRecheck: const Duration(hours: 1),
      wait: (int? after) async {
        calls++;
        return null;
      },
      onChange: () async => changes++,
    );
    w.start();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    w.stop();
    expect(calls, 1);
    expect(changes, 0);
  });

  test('没准备好（后台 / 互联没开）：不发请求', () async {
    int calls = 0;
    final SrsInterconnectWatcher w = SrsInterconnectWatcher(
      ready: () async => false,
      idleRecheck: const Duration(hours: 1),
      wait: (int? after) async {
        calls++;
        return 1;
      },
      onChange: () async {},
    );
    w.start();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    w.stop();
    expect(calls, 0);
  });

  test('本机连续变动去抖成一次推送', () async {
    int pushes = 0;
    final SrsLocalPush push = SrsLocalPush(
      push: () async => pushes++,
      debounce: const Duration(milliseconds: 20),
    );
    for (int i = 0; i < 5; i++) {
      push.trigger();
    }
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(pushes, 1);
    push.dispose();
  });
}

class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
