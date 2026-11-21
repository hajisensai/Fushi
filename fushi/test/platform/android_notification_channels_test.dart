// 拍板台 left3621：Android 通知渠道名跟界面语言，不再在原生里写死英文。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/platform/android/android_notification_channels.dart';
import 'package:fushi/src/updates/local_update_notifier.dart';

const String _javaRoot = 'android/app/src/main/java/app/fushi/reader';
const String _kotlinRoot = 'android/app/src/main/kotlin/app/fushi/reader';

String _read(String path) => File(path).readAsStringSync();

/// 原生全部 `.java` / `.kt` 源文件（相对 `fushi/`）。
List<File> _nativeSources() =>
    <Directory>[Directory(_javaRoot), Directory(_kotlinRoot)]
        .expand((Directory d) => d.listSync(recursive: true))
        .whereType<File>()
        .where((File f) => f.path.endsWith('.java') || f.path.endsWith('.kt'))
        .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('渠道名表', () {
    test('覆盖 NotificationIds.java 里的每个渠道 id', () {
      final String ids = _read('$_javaRoot/constants/NotificationIds.java');
      final Iterable<String> javaIds = RegExp(
        r'String CHANNEL_\w+\s*=\s*"([^"]+)"',
      ).allMatches(ids).map((RegExpMatch m) => m.group(1)!);
      expect(javaIds, isNotEmpty);
      final Map<String, String> names = androidNotificationChannelNames(
        AppLocale.en,
      );
      for (final String id in javaIds) {
        expect(names.keys, contains(id), reason: '原生渠道 $id 没进本地化名字表');
      }
      expect(names.keys, contains(kUpdateNotificationChannelId));
      expect(names.keys, contains(kAudioServiceNotificationChannelId));
    });

    test('跟着语言走：中文表与英文表每一项都不同且非空', () {
      final Map<String, String> en = androidNotificationChannelNames(
        AppLocale.en,
      );
      final Map<String, String> zh = androidNotificationChannelNames(
        AppLocale.zhCn,
      );
      expect(zh.keys, en.keys);
      for (final String id in en.keys) {
        expect(en[id], isNotEmpty);
        expect(zh[id], isNotEmpty);
        expect(zh[id], isNot(en[id]), reason: '$id 的中文名还是英文');
      }
      expect(zh[kCrossAppAudioNotificationChannelId], '缓存其他应用的声音');
    });
  });

  group('syncAndroidNotificationChannelNames', () {
    const MethodChannel channel = MethodChannel('test/notification_channels');
    final List<MethodCall> calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            return 0;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('Android：整表经 sync 推给原生', () async {
      const AppLocale zh = AppLocale.zhCn;
      await syncAndroidNotificationChannelNames(
        locale: zh,
        channel: channel,
        isAndroid: true,
      );
      expect(calls, hasLength(1));
      expect(calls.single.method, 'sync');
      expect(
        Map<String, String>.from(calls.single.arguments as Map),
        androidNotificationChannelNames(zh),
      );
    });

    test('非 Android 不碰通道', () async {
      await syncAndroidNotificationChannelNames(
        locale: AppLocale.en,
        channel: channel,
        isAndroid: false,
      );
      expect(calls, isEmpty);
    });

    test('原生没注册（弹窗进程）不抛', () async {
      await syncAndroidNotificationChannelNames(
        locale: AppLocale.en,
        channel: const MethodChannel('test/unregistered_notification_channels'),
        isAndroid: true,
      );
    });

    test('Java 通道名与 Dart 一致，且主引擎注册了 handler', () {
      expect(
        _read('$_javaRoot/constants/ChannelNames.java'),
        contains('NOTIFICATION_CHANNELS = PREFIX + "/notification_channels"'),
      );
      expect(
        _read('lib/src/utils/misc/channel_constants.dart'),
        contains(r"'$_prefix/notification_channels'"),
      );
      expect(
        _read('$_javaRoot/MainActivity.java'),
        contains('NotificationChannelNames.registerWith(flutterEngine'),
      );
    });
  });

  group('接线守卫', () {
    test('原生每处 new NotificationChannel 的名字都经 NotificationChannelNames', () {
      int checked = 0;
      for (final File f in _nativeSources()) {
        if (f.path.endsWith('NotificationChannelNames.java')) continue;
        final List<String> lines = f.readAsLinesSync();
        for (int i = 0; i < lines.length; i++) {
          if (!RegExp(
            r'(?<![\w.])(?:new\s+)?NotificationChannel\(',
          ).hasMatch(lines[i])) {
            continue;
          }
          // 构造调用最多跨 4 行；取到语句结束。
          final String stmt = lines
              .sublist(i, (i + 5).clamp(0, lines.length))
              .join('\n');
          final String call = stmt.substring(
            0,
            stmt.contains(';') ? stmt.indexOf(';') : stmt.length,
          );
          checked++;
          final bool viaHelper =
              call.contains('NotificationChannelNames.nameFor') ||
              RegExp(r'NotificationChannel\(\s*\w+,\s*name,').hasMatch(call);
          expect(
            viaHelper,
            isTrue,
            reason: '${f.path}:${i + 1} 渠道名没经 NotificationChannelNames：\n$call',
          );
        }
      }
      expect(checked, greaterThanOrEqualTo(5));
      expect(
        _read('$_kotlinRoot/feedback/FeedbackReplyWorker.kt'),
        contains(
          'NotificationChannelNames.nameFor(ctx, CHANNEL_ID, CHANNEL_NAME)',
        ),
      );
    });

    test('插件建的两个渠道也用本地化名字', () {
      final String appModel = _read('lib/src/models/app_model.dart');
      expect(
        appModel,
        contains('androidChannelName: t.notification_channel_updates'),
        reason: 'flutter_local_notifications 每次发通知都会用传入名字重建渠道',
      );
      expect(
        appModel,
        contains('unawaited(syncAndroidNotificationChannelNames())'),
      );
      final String audio = _read('lib/src/models/audio_controller.dart');
      expect(
        audio,
        contains(
          'androidNotificationChannelName: t.notification_channel_media_playback',
        ),
      );
      expect(
        audio,
        contains(
          'androidNotificationChannelId: kAudioServiceNotificationChannelId',
        ),
      );
      expect(
        _read('lib/src/updates/local_update_notifier.dart'),
        contains('kUpdateNotificationChannelId,\n      androidChannelName,'),
      );
    });

    test('LocalUpdateNotifier 的渠道名默认取 appName，可单独覆盖', () {
      expect(LocalUpdateNotifier(appName: 'Fushi').androidChannelName, 'Fushi');
      expect(
        LocalUpdateNotifier(
          appName: 'Fushi',
          androidChannelName: '更新与回复提醒',
        ).androidChannelName,
        '更新与回复提醒',
      );
    });
  });
}
