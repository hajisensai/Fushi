import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/texthooker_ws_client_host.dart';

void main() {
  tearDown(() => TexthookerWsClientHost.instance.stop());

  test('start/stop toggles isRunning', () async {
    expect(TexthookerWsClientHost.instance.isRunning, false);
    // 用本机大概率未监听的端口，connect 是 lazy，start 后即 isRunning=true（后台重连）
    TexthookerWsClientHost.instance.start(<String>['ws://127.0.0.1:59999']);
    expect(TexthookerWsClientHost.instance.isRunning, true);
    await TexthookerWsClientHost.instance.stop();
    expect(TexthookerWsClientHost.instance.isRunning, false);
  });

  test('start is idempotent while running', () async {
    TexthookerWsClientHost.instance.start(<String>['ws://127.0.0.1:59999']);
    expect(TexthookerWsClientHost.instance.isRunning, true);
    // 二次 start 不应抛异常，仍 running。
    TexthookerWsClientHost.instance.start(<String>['ws://127.0.0.1:59998']);
    expect(TexthookerWsClientHost.instance.isRunning, true);
    await TexthookerWsClientHost.instance.stop();
    expect(TexthookerWsClientHost.instance.isRunning, false);
  });

  test('restart keeps running with new urls', () async {
    TexthookerWsClientHost.instance.start(<String>['ws://127.0.0.1:59998']);
    expect(TexthookerWsClientHost.instance.isRunning, true);
    await TexthookerWsClientHost.instance
        .restart(<String>['ws://127.0.0.1:59997']);
    expect(TexthookerWsClientHost.instance.isRunning, true);
    await TexthookerWsClientHost.instance.stop();
    expect(TexthookerWsClientHost.instance.isRunning, false);
  });
}
