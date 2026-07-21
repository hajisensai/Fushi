import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/texthooker_ws_client_manager.dart';

void main() {
  tearDown(() => TexthookerWsClientManager.instance.stop());

  test('start/stop toggles isRunning', () async {
    expect(TexthookerWsClientManager.instance.isRunning, false);
    // 用本机大概率未监听的端口，connect 是 lazy，start 后即 isRunning=true（后台重连）
    TexthookerWsClientManager.instance.start(<String>['ws://127.0.0.1:59999']);
    expect(TexthookerWsClientManager.instance.isRunning, true);
    await TexthookerWsClientManager.instance.stop();
    expect(TexthookerWsClientManager.instance.isRunning, false);
  });

  test('start is idempotent while running', () async {
    TexthookerWsClientManager.instance.start(<String>['ws://127.0.0.1:59999']);
    expect(TexthookerWsClientManager.instance.isRunning, true);
    // 二次 start 不应抛异常，仍 running。
    TexthookerWsClientManager.instance.start(<String>['ws://127.0.0.1:59998']);
    expect(TexthookerWsClientManager.instance.isRunning, true);
    await TexthookerWsClientManager.instance.stop();
    expect(TexthookerWsClientManager.instance.isRunning, false);
  });

  test('restart keeps running with new urls', () async {
    TexthookerWsClientManager.instance.start(<String>['ws://127.0.0.1:59998']);
    expect(TexthookerWsClientManager.instance.isRunning, true);
    await TexthookerWsClientManager.instance
        .restart(<String>['ws://127.0.0.1:59997']);
    expect(TexthookerWsClientManager.instance.isRunning, true);
    await TexthookerWsClientManager.instance.stop();
    expect(TexthookerWsClientManager.instance.isRunning, false);
  });
}
