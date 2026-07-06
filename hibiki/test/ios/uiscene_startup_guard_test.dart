import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS adopts UIScene lifecycle for Flutter implicit engine startup', () {
    final String plist = File('ios/Runner/Info.plist').readAsStringSync();
    final String appDelegate =
        File('ios/Runner/AppDelegate.swift').readAsStringSync();

    expect(plist, contains('<key>UIApplicationSceneManifest</key>'));
    expect(plist, contains('<key>UIApplicationSupportsMultipleScenes</key>'));
    expect(plist, contains('<false/>'));
    expect(plist, contains('<key>UISceneDelegateClassName</key>'));
    expect(plist,
        contains('<string>\$(PRODUCT_MODULE_NAME).SceneDelegate</string>'));
    expect(plist, contains('<key>UISceneStoryboardFile</key>'));
    expect(plist, contains('<string>Main</string>'));

    expect(appDelegate, contains('FlutterImplicitEngineDelegate'));
    expect(appDelegate, contains('didInitializeImplicitFlutterEngine'));
    expect(
        appDelegate,
        contains(
            'GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)'));
    expect(
        appDelegate, contains('engineBridge.applicationRegistrar.messenger()'));
    expect(
      appDelegate,
      isNot(contains('window?.rootViewController as? FlutterViewController')),
      reason: 'Flutter UIScene migration forbids grabbing the root controller '
          'during didFinishLaunching; channels must be registered from the '
          'implicit engine bridge.',
    );
  });

  test('iOS SceneDelegate preserves Hibiki URL callbacks under UIScene', () {
    final File sceneDelegate = File('ios/Runner/SceneDelegate.swift');
    expect(sceneDelegate.existsSync(), isTrue);
    final String src = sceneDelegate.readAsStringSync();

    expect(src, contains('class SceneDelegate: FlutterSceneDelegate'));
    expect(src, contains('willConnectTo session'));
    expect(src, contains('openURLContexts'));
    expect(src, contains('deliverUrl'));
    expect(src, contains('connectionOptions.urlContexts'));
  });

  test('iOS implements splash color MethodChannel used during startup', () {
    final String appDelegate =
        File('ios/Runner/AppDelegate.swift').readAsStringSync();

    expect(appDelegate, contains('app.hibiki.reader/splash'));
    expect(appDelegate, contains('getSplashColor'));
    expect(appDelegate, contains('LaunchScreen'));
  });

  test('iOS does not opt into minimum frame duration override on phone', () {
    final String plist = File('ios/Runner/Info.plist').readAsStringSync();
    const String key = '<key>CADisableMinimumFrameDurationOnPhone</key>';
    final int keyIndex = plist.indexOf(key);

    expect(
      keyIndex,
      isNonNegative,
      reason: 'BUG-567: keep the iOS frame pacing override explicit so Xcode '
          'or Flutter template churn cannot silently re-enable it.',
    );

    final String valueAfterKey = plist.substring(keyIndex + key.length);
    final int nextKeyIndex = valueAfterKey.indexOf('<key>');
    final String valueBlock = nextKeyIndex == -1
        ? valueAfterKey
        : valueAfterKey.substring(0, nextKeyIndex);

    expect(
      valueBlock,
      contains('<false/>'),
      reason: 'BUG-567: iOS 27 beta on iPhone 17 crashes in FlutterEngine '
          'VSyncClient/createTouchRateCorrectionVSyncClientIfNeeded when '
          'CADisableMinimumFrameDurationOnPhone is true.',
    );
  });
}
