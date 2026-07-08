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

  test('iOS keeps debug frame override off but enables ProMotion builds', () {
    final String plist = File('ios/Runner/Info.plist').readAsStringSync();
    final String project =
        File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    const String key = '<key>CADisableMinimumFrameDurationOnPhone</key>';
    final int keyIndex = plist.indexOf(key);

    expect(
      keyIndex,
      isNonNegative,
      reason: 'Keep the source plist key explicit; otherwise flutter build may '
          'auto-upgrade the file back to true and put Debug at iOS 27 risk.',
    );
    final String valueAfterKey = plist.substring(keyIndex + key.length);
    final int nextKeyIndex = valueAfterKey.indexOf('<key>');
    final String valueBlock = nextKeyIndex == -1
        ? valueAfterKey
        : valueAfterKey.substring(0, nextKeyIndex);
    expect(
      valueBlock,
      contains('<false/>'),
      reason:
          'The source plist fallback stays false so Debug remains safe even '
          'before target build-setting overrides are applied.',
    );

    final String thinBinaryScript = _shellScript(project, 'Thin Binary');
    expect(thinBinaryScript, contains('CADisableMinimumFrameDurationOnPhone'));
    expect(thinBinaryScript, contains(r'\"$CONFIGURATION\" = \"Debug\"'));
    expect(
      thinBinaryScript,
      contains('Set :CADisableMinimumFrameDurationOnPhone false'),
      reason: 'BUG-642: Debug keeps the override disabled because iOS 27 beta '
          'crashes in FlutterEngine VSyncClient when the key is true.',
    );
    expect(
      thinBinaryScript,
      contains('Set :CADisableMinimumFrameDurationOnPhone true'),
      reason: 'BUG-647: Profile/Release final app plists must opt into '
          'iPhone ProMotion/high-refresh frame pacing.',
    );
    expect(
      thinBinaryScript.indexOf('CADisableMinimumFrameDurationOnPhone'),
      lessThan(thinBinaryScript.indexOf('embed_and_thin')),
      reason: 'The final app Info.plist must be patched before Flutter thin/'
          'embed and before code signing.',
    );
  });
}

String _shellScript(String project, String phaseName) {
  final String escapedName = RegExp.escape(phaseName);
  final RegExp re = RegExp(
    '$escapedName'
    r' \*/ = \{\s*isa = PBXShellScriptBuildPhase;[\s\S]*?'
    r'shellScript = "([\s\S]*?)";',
  );
  final RegExpMatch? match = re.firstMatch(project);
  expect(match, isNotNull,
      reason: 'Missing Runner shell script phase $phaseName');
  return match!.group(1)!;
}
