// iOS 远程推送的原生半边与 CI 签名接线（源码扫描守卫，从 feedback_push_test.dart 拆出）。
//
// 只读源码 / workflow，不加载原生库：CI 的 guards job 按「引用了 .github/ 或 ../tool/」挑文件、
// 不编 fushi_compute，行为测试（要 LeaderboardIdentity 签名 → 原生 ECDSA）留在
// feedback_push_test.dart 由单测 job 跑。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/feedback/feedback_push.dart';

void main() {
  group('原生 / 签名接线', () {
    test('channel 名与方法 Dart / Swift 逐字一致；自己的推送先认领、别的交还 super', () {
      final String swift = File(
        'ios/Runner/AppDelegate.swift',
      ).readAsStringSync();
      expect(swift, contains('"$kRemotePushChannel"'));
      for (final String m in <String>[
        '"register"',
        '"takeLaunchFeedbackId"',
        '"onTap"',
        '"onForegroundPush"',
      ]) {
        expect(swift, contains(m));
      }
      expect(swift, contains('FushiRemotePush.shared.install('));
      expect(
        swift,
        contains('UNUserNotificationCenter.current().delegate = self'),
      );
      expect(
        swift,
        contains('didRegisterForRemoteNotificationsWithDeviceToken'),
      );
      expect(
        swift,
        contains('didFailToRegisterForRemoteNotificationsWithError'),
      );
      // 两个委托回调都要把非反馈推送交还 super（flutter_local_notifications 靠它）。
      expect('super.userNotificationCenter('.allMatches(swift).length, 2);
      // 载荷键与服务端 pushPayload 一致。
      expect(swift, contains('userInfo["fushi"]'));
      expect(swift, contains('fushi["feedback"]'));
      final String server = File(
        '../services/leaderboard/src/feedback_push.js',
      ).readAsStringSync();
      expect(server, contains('fushi: { feedback: feedbackId }'));
    });

    test('aps-environment entitlement 只在描述文件带 Push 时才接入构建', () {
      final String ent = File(
        'ios/Runner/Runner.entitlements',
      ).readAsStringSync();
      expect(ent, contains('<key>aps-environment</key>'));
      expect(ent, contains(r'$(FUSHI_APS_ENVIRONMENT)'));
      expect(
        File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync(),
        isNot(contains('CODE_SIGN_ENTITLEMENTS')),
        reason: '无条件接入会让没开 Push 的描述文件签名失败（TestFlight 整条断）',
      );
      final RegExp assignment = RegExp(
        r'^\s*CODE_SIGN_ENTITLEMENTS\s*=',
        multiLine: true,
      );
      for (final String cfg in <String>['Debug', 'Release']) {
        expect(
          assignment.hasMatch(
            File('ios/Flutter/$cfg.xcconfig').readAsStringSync(),
          ),
          isFalse,
          reason: '$cfg.xcconfig 不得无条件接入 entitlements',
        );
      }
      final String wf = File(
        '../.github/workflows/release-desktop.yml',
      ).readAsStringSync();
      final int probe = wf.indexOf(':Entitlements:aps-environment');
      final int wire = wf.indexOf(
        'CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements',
      );
      expect(probe, isNonNegative);
      expect(wire, greaterThan(probe));
      expect(
        wf.substring(probe, wire),
        contains(r'if [ -n "$APS_ENV" ]; then'),
      );
    });
  });
}
