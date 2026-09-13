import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/updates/local_update_notifier.dart';
import 'package:fushi/src/updates/update_feed_service.dart';
import 'package:fushi/src/updates/update_notifier.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';

/// 系统通知后端的两条纯函数契约：
/// ① Windows 按钮把「按钮 id + 本体载荷」编进 arguments 再拆回来（插件在 Windows
///   上把 payload 与 actionId 都填成被点元素的 arguments，本体载荷会丢）；
/// ② 本地化文案：单条带发布时刻与两个按钮，多条汇总不带时刻。
/// 外加一条 method channel 级守卫（BUG-2498）：初始化绝不向系统申请权限。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BUG-2498：ensureReady 不申请权限，申请只在 requestPermission', () {
    // 插件五端共用这一条 channel（platform_flutter_local_notifications.dart）。
    const MethodChannel channel =
        MethodChannel('dexterous.com/flutter/local_notifications');
    late List<String> calls;
    late bool enabled;

    setUp(() {
      calls = <String>[];
      enabled = false;
      // 插件按 defaultTargetPlatform 分派实现；本仓 notifier 也按它分派，于是
      // 在 Windows 测试宿主上能真走到 Android 分支——否则这条守卫就是空壳。
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      // 测试里没有插件注册表，手动把 Android 实现挂成平台实例。
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'initialize':
            return true;
          case 'getNotificationAppLaunchDetails':
            return null;
          case 'areNotificationsEnabled':
            return enabled;
          case 'requestNotificationsPermission':
            enabled = true;
            return true;
          default:
            return null;
        }
      });
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('初始化只做 initialize + 冷启动回放，不碰 requestNotificationsPermission',
        () async {
      final LocalUpdateNotifier notifier = LocalUpdateNotifier(
        appName: 'Fushi',
        onResponse: (_) {},
        windowsIconPath: 'unused',
      );
      expect(await notifier.ensureReady(), isTrue);
      expect(calls, <String>['initialize'],
          reason: '初始化不回放冷启动点击——回放是启动期单独一步');
      await notifier.replayLaunchResponse();
      expect(calls, <String>['initialize', 'getNotificationAppLaunchDetails']);
      expect(calls, isNot(contains('requestNotificationsPermission')),
          reason: '启动期弹系统权限框 = 退出新手引导即在 MIUI 上被连坐杀掉');

      expect(await notifier.hasPermission(), isFalse);
      expect(calls.last, 'areNotificationsEnabled', reason: '查询只查询');
      expect(calls, isNot(contains('requestNotificationsPermission')));
    });

    test('requestPermission 才真的申请，且申请前不重复初始化', () async {
      final LocalUpdateNotifier notifier = LocalUpdateNotifier(
        appName: 'Fushi',
        windowsIconPath: 'unused',
      );
      expect(await notifier.ensureReady(), isTrue);
      expect(await notifier.requestPermission(), isTrue);
      expect(calls.where((String m) => m == 'requestNotificationsPermission'),
          hasLength(1));
      expect(calls.where((String m) => m == 'initialize'), hasLength(1),
          reason: '申请复用已有初始化');
      expect(await notifier.hasPermission(), isTrue);
    });
  });

  group('decodeNotificationResponse', () {
    const String payload =
        '{"kind":"video_episode","entryId":"video_episode:1"}';

    test('Windows 按钮：arguments 自带载荷，拆成 (payload, actionId)', () {
      final String arguments = encodeWindowsActionArguments('open', payload);
      final UpdateNotificationResponse response = decodeNotificationResponse(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          payload: arguments,
          actionId: arguments,
        ),
      );
      expect(response.actionId, 'open');
      expect(response.payload, payload);
    });

    test('点本体：payload 原样、actionId 为 null（哪怕插件填了东西）', () {
      final UpdateNotificationResponse response = decodeNotificationResponse(
        const NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotification,
          payload: payload,
          actionId: payload,
        ),
      );
      expect(response.actionId, isNull);
      expect(response.payload, payload);
    });

    test('Android/Linux 按钮：payload 与 actionId 本来分开，直接透传', () {
      final UpdateNotificationResponse response = decodeNotificationResponse(
        const NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          payload: payload,
          actionId: 'view_all',
        ),
      );
      expect(response.actionId, 'view_all');
      expect(response.payload, payload);
    });
  });

  group('localizedUpdateNotificationText', () {
    test('单条：副标题 · MM-dd HH:mm，两个按钮', () {
      final DateTime published = DateTime(2026, 9, 10, 18, 30);
      final UpdateNotificationText text =
          AppModel.localizedUpdateNotificationText(
        UpdateFeedKind.videoEpisode,
        <UpdateFeedDraft>[
          UpdateFeedDraft(
            kind: UpdateFeedKind.videoEpisode,
            targetKey: '1',
            title: 'グロウアップショウ',
            subtitle: 'S01E02 · 1080p',
            publishedAt: published.millisecondsSinceEpoch,
          ),
        ],
      );
      expect(text.title, 'グロウアップショウ');
      expect(text.body, 'S01E02 · 1080p · 09-10 18:30');
      expect(text.openLabel, isNotEmpty);
      expect(text.viewAllLabel, isNotEmpty);
    });

    test('单条无副标题无时刻：正文只剩空串，不留孤零零的分隔符', () {
      final UpdateNotificationText text =
          AppModel.localizedUpdateNotificationText(
        UpdateFeedKind.appRelease,
        const <UpdateFeedDraft>[
          UpdateFeedDraft(
            kind: UpdateFeedKind.appRelease,
            targetKey: '2.4.0',
            title: '2.4.0',
          ),
        ],
      );
      expect(text.body, '');
    });

    test('多条：汇总句不带时刻（时刻属于谁说不清）', () {
      final UpdateNotificationText text =
          AppModel.localizedUpdateNotificationText(
        UpdateFeedKind.videoEpisode,
        <UpdateFeedDraft>[
          for (int i = 1; i <= 3; i++)
            UpdateFeedDraft(
              kind: UpdateFeedKind.videoEpisode,
              targetKey: '$i',
              title: 'Show',
              subtitle: 'S01E0$i',
              publishedAt: 1700000000000,
            ),
        ],
      );
      expect(text.body, contains('S01E01'));
      expect(text.body, isNot(contains(':')));
      expect(text.body, contains('2'));
    });
  });
}
