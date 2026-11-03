// Apple Music 原生桥真 app 探针（iOS / macOS 14+，MusicKit 方案 P2）。
//
// 不需要 Apple ID，只证明：
// 1. `createAppleMusicBridge()` 在这台设备上选中原生桥；
// 2. Swift 侧 `FushiAppleMusic` 已在 AppDelegate 注册，`accountState` 走通方法通道并回读授权状态；
// 3. 事件通道能订阅（`onListen` 不抛）。
// 授权框、整曲播放要人手点 / 订阅账号，见 spec §10.3。
//
// 跑（Mac）：fushi/ 下 `flutter test integration_test/apple_music_native_bridge_itest.dart -d macos`
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/media/music/apple_music/apple_music_bridge.dart';
import 'package:fushi/src/media/music/apple_music/apple_music_native_bridge.dart';
import 'package:fushi/src/models/app_model.dart';

import 'helpers/library_fixture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Apple Music native bridge: channel registered, state readable', (
    WidgetTester tester,
  ) async {
    if (!Platform.isIOS && !Platform.isMacOS) return;
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));
    final AppModel app = await readyAppModel(tester);

    final AppleMusicBridge? bridge = app.appleMusicAccount.bridge;
    debugPrint('[apple-music-native-itest] bridge=${bridge.runtimeType}');
    expect(bridge, isA<AppleMusicNativeBridge>());

    final StreamSubscription<AppleMusicPlayerEvent> sub = bridge!.events.listen(
      (AppleMusicPlayerEvent e) =>
          debugPrint('[apple-music-native-itest] event $e'),
    );
    final AppleMusicAccountState state = (await tester.runAsync(
      () => bridge.accountState(),
    ))!;
    debugPrint(
      '[apple-music-native-itest] status=${state.status} '
      'canPlay=${state.canPlayCatalogContent} sf=${state.storefront}',
    );
    // 通道没注册会抛 MissingPluginException；能读回就说明 Swift 侧接通。
    expect(state.status, isA<AppleMusicAuthStatus>());
    await sub.cancel();
  });
}
