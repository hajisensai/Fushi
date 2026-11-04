/// BUG-4072 通道契约守卫：「本次引擎有没有界面」通道三处字面量（Dart 包常量、Android
/// 插件、iOS AppDelegate）必须一致，且 Android 半边必须注册到**每个**引擎。
///
/// 这些写错都不会报错：通道名 / 键名对不上时 Dart 收到 MissingPluginException 或形状
/// 不对，按「不知道」回落成 `launching`，无界面会话又被判成「启动即闪退」——测试全绿、
/// 只在用户手机上复发。尤其 Android 半边若挪进 `MainActivity.configureFlutterEngine`，
/// audio_service 无界面拉起的引擎上就没有它（那正是要识别的引擎），所以逐条钉住。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_launch_presence/fushi_launch_presence.dart';

import '../helpers/source_guard.dart';

void main() {
  const String pluginJava =
      '../packages/fushi_launch_presence/android/src/main/java/app/fushi/'
      'launchpresence/LaunchPresencePlugin.java';

  test('Android 插件：通道名 / 方法名 / 返回键与 Dart 常量一致', () {
    final String java = maskComments(File(pluginJava).readAsStringSync());
    expect(java, contains('CHANNEL = "$kLaunchPresenceChannelName"'));
    expect(java, contains('METHOD_QUERY = "$kLaunchPresenceQueryMethod"'));
    expect(java, contains('out.put("$kLaunchPresenceHasUiKey"'));
    expect(java, contains('out.put("$kLaunchPresenceDetailKey"'));
  });

  test('Android 插件按 ActivityAware 附着判界面，并在 onAttachedToEngine 注册通道', () {
    final String java = maskComments(File(pluginJava).readAsStringSync());
    expect(java, contains('package app.fushi.launchpresence;'));
    expect(
      java,
      matches(
        RegExp(
          r'class LaunchPresencePlugin implements FlutterPlugin, ActivityAware',
        ),
      ),
    );
    final int attach = java.indexOf('public void onAttachedToEngine');
    final int detach = java.indexOf('public void onDetachedFromEngine');
    expect(attach, isNonNegative);
    expect(
      java.substring(attach, detach),
      contains('new MethodChannel(binding.getBinaryMessenger(), CHANNEL)'),
    );
    expect(java, contains('out.put("hasUi", attachedActivity != null)'));
  });

  test('插件经 GeneratedPluginRegistrant 进每个引擎：pubspec 声明 + 主应用依赖', () {
    final String pubspec = File(
      '../packages/fushi_launch_presence/pubspec.yaml',
    ).readAsStringSync();
    expect(pubspec, contains('package: app.fushi.launchpresence'));
    expect(pubspec, contains('pluginClass: LaunchPresencePlugin'));
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains(
        'fushi_launch_presence:\n    path: ../packages/fushi_launch_presence',
      ),
    );
    expect(
      File('../pubspec.yaml').readAsStringSync(),
      contains('  - packages/fushi_launch_presence\n'),
    );
  });

  test('Android 不能把这条通道挂到 MainActivity（无界面引擎不经过它）', () {
    final String main = maskComments(
      File(
        'android/app/src/main/java/app/fushi/reader/MainActivity.java',
      ).readAsStringSync(),
    );
    expect(main, isNot(contains('launch_presence')));
    expect(main, isNot(contains('LaunchPresencePlugin')));
  });

  test('iOS AppDelegate：同名通道、同方法 / 键，且在 installChannels 里注册', () {
    final String swift = maskComments(
      File('ios/Runner/AppDelegate.swift').readAsStringSync(),
    );
    expect(swift, contains('channelName = "$kLaunchPresenceChannelName"'));
    expect(swift, contains('call.method == "$kLaunchPresenceQueryMethod"'));
    expect(swift, contains('"$kLaunchPresenceHasUiKey": hasUi'));
    expect(swift, contains('"$kLaunchPresenceDetailKey":'));
    final int install = swift.indexOf(
      'private func installChannels(binaryMessenger: FlutterBinaryMessenger)',
    );
    expect(install, isNonNegative);
    final int nextFunc = swift.indexOf('\n  private ', install + 10);
    expect(
      swift.substring(install, nextFunc),
      contains(
        'FushiLaunchPresence.register(binaryMessenger: binaryMessenger)',
      ),
    );
  });

  test('会话标记在 marker.start 之前问原生（标记初值依赖回答）', () {
    final String dart = maskComments(
      File('lib/src/diagnostics/previous_exit_log.dart').readAsStringSync(),
    );
    final int ask = dart.indexOf('await queryLaunchPresence(');
    final int start = dart.indexOf('marker.start(nowMs: now, launch: launch)');
    expect(ask, isNonNegative);
    expect(start, greaterThan(ask));
  });
}
