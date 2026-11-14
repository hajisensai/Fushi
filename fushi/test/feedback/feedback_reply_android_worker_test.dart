// 反馈 yjn-3h8B-7（BUG-4271 记下的遗留结构问题）：Android 的反馈回复后台检查改为纯原生
// `FeedbackReplyWorker.kt`，不再经 workmanager 插件起一个自动注册全部插件的后台 Flutter 引擎
// （audio_service 附着时会另起一个跑 main() 的主引擎常驻）。
//
// 本文件钉住三件事：
// 1. Dart 门面 [AndroidFeedbackReplyScheduler] 经 `feedback_reply_work` 通道排 / 撤，参数齐全；
//    生产装配里 Android 不再走 workmanager。
// 2. Kotlin 侧判据常量与 Dart 一致（载荷前缀、通知 id 派生、批大小、周期、通知渠道、端点）。
// 3. Kotlin 发的通知按 flutter_local_notifications 的点击契约构造——契约常量对照解析到的插件
//    源码核对，插件升级改了契约这里先红。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/feedback/feedback_reply_background.dart';
import 'package:fushi/src/feedback/feedback_reply_state.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart'
    show kLeaderboardDefaultBaseUrl;
import 'package:fushi/src/updates/local_update_notifier.dart'
    show kUpdateNotificationChannelId;
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';

import '../helpers/source_guard.dart' show maskComments;

const String _kotlinDir =
    'android/app/src/main/kotlin/app/fushi/reader/feedback';

String _read(String path) => File(path).readAsStringSync();

/// 经 `.dart_tool/package_config.json` 解析 [package] 包里的一个文件（pub cache 目录名带
/// 版本号，只有 package_config 知道真值）。
File _packageFile(String package, String relative) {
  Directory current = Directory.current.absolute;
  File? config;
  while (true) {
    final File candidate = File(
      '${current.path}/.dart_tool/package_config.json',
    );
    if (candidate.existsSync()) {
      config = candidate;
      break;
    }
    final Directory parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  if (config == null) {
    throw StateError('找不到 .dart_tool/package_config.json —— 先跑 pub get');
  }
  final Map<String, Object?> json =
      jsonDecode(config.readAsStringSync()) as Map<String, Object?>;
  for (final Object? entry in json['packages']! as List<Object?>) {
    final Map<String, Object?> pkg = entry! as Map<String, Object?>;
    if (pkg['name'] != package) continue;
    final Uri root = config.parent.uri.resolve('${pkg["rootUri"]}/');
    return File.fromUri(root.resolve(relative));
  }
  throw StateError('package_config.json 里没有 $package');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AndroidFeedbackReplyScheduler', () {
    late List<MethodCall> calls;
    late Directory root;

    setUp(() {
      calls = <MethodCall>[];
      root = Directory.systemTemp.createTempSync('fushi_fb_android_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FushiChannels.feedbackReplyWork, (
            MethodCall call,
          ) async {
            calls.add(call);
            return null;
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FushiChannels.feedbackReplyWork, null);
      root.deleteSync(recursive: true);
    });

    test('schedule：任务名 / 周期 / 数据根 / 默认服务器一并交给原生 Worker', () async {
      final AndroidFeedbackReplyScheduler s = AndroidFeedbackReplyScheduler(
        supportRoot: () async => root,
      );
      expect(s.supported, isTrue);
      await s.schedule();
      expect(calls, hasLength(1));
      expect(calls.single.method, 'schedule');
      expect(calls.single.arguments, <String, Object>{
        'uniqueName': kFeedbackReplyTaskName,
        'intervalMinutes': kFeedbackReplyPollInterval.inMinutes,
        'supportRoot': root.path,
        'defaultServer': kLeaderboardDefaultBaseUrl,
      });
    });

    test('cancel：按同一个唯一任务名撤', () async {
      await AndroidFeedbackReplyScheduler(
        supportRoot: () async => root,
      ).cancel();
      expect(calls.single.method, 'cancel');
      expect(calls.single.arguments, <String, Object>{
        'uniqueName': kFeedbackReplyTaskName,
      });
    });

    test('原生侧报错原样上抛（由 FeedbackReplyAlerts.syncSchedule 记日志），不吞', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            FushiChannels.feedbackReplyWork,
            (MethodCall call) async =>
                throw PlatformException(code: 'query_failed'),
          );
      await expectLater(
        AndroidFeedbackReplyScheduler(supportRoot: () async => root).schedule(),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  test('生产装配：Android 走原生 Worker，workmanager 只留给 iOS', () {
    final String src = _read('lib/src/feedback/feedback_reply_background.dart');
    expect(
      src,
      contains(
        'if (Platform.isAndroid) return AndroidFeedbackReplyScheduler();',
      ),
    );
    expect(
      src,
      contains(
        'if (Platform.isIOS) return WorkmanagerFeedbackReplyScheduler();',
      ),
    );
    // 别处也不许再排 workmanager 任务（否则 Android 又会起插件的后台引擎）。
    final List<String> offenders = <String>[
      for (final FileSystemEntity f in Directory(
        'lib',
      ).listSync(recursive: true))
        if (f is File &&
            f.path.endsWith('.dart') &&
            !f.path
                .replaceAll(r'\', '/')
                .endsWith('lib/src/feedback/feedback_reply_background.dart') &&
            f.readAsStringSync().contains('package:workmanager/'))
          f.path,
    ];
    expect(offenders, isEmpty);
  });

  test('原生侧注册了排程通道，名字与 Dart 一致', () {
    expect(
      FushiChannels.feedbackReplyWork.name,
      'app.fushi.reader/feedback_reply_work',
    );
    expect(
      _read(
        'android/app/src/main/java/app/fushi/reader/constants/ChannelNames.java',
      ),
      contains('FEEDBACK_REPLY_WORK = PREFIX + "/feedback_reply_work"'),
    );
    expect(
      _read('android/app/src/main/java/app/fushi/reader/MainActivity.java'),
      contains('FeedbackReplyWorkChannel.registerWith('),
    );
    // 原生 Worker 本身不碰 Flutter 引擎（这正是本次修复的全部意义）。判代码不判注释：
    // 类注释里正是在解释「旧实现用 FlutterEngine(applicationContext) 起后台引擎」。
    final String worker = maskComments(
      _read('$_kotlinDir/FeedbackReplyWorker.kt'),
    );
    expect(worker, isNot(contains('FlutterEngine')));
    expect(worker, isNot(contains('io.flutter')));
    expect(
      maskComments(_read('$_kotlinDir/FeedbackReplyCheck.kt')),
      isNot(contains('io.flutter')),
    );
  });

  test('Kotlin 判据常量与 Dart 一致', () {
    final String check = _read('$_kotlinDir/FeedbackReplyCheck.kt');
    final String worker = _read('$_kotlinDir/FeedbackReplyWorker.kt');
    final String store = _read('$_kotlinDir/FeedbackReplyStateFile.kt');
    expect(
      check,
      contains(
        'POLL_INTERVAL_MS: Long = '
        '${kFeedbackReplyPollInterval.inMinutes}L * 60L * 1000L',
      ),
    );
    expect(
      check,
      contains('STATUS_BATCH: Int = ${FeedbackLimits.statusBatch}'),
    );
    expect(
      check,
      contains(
        'PAYLOAD_PREFIX: String = "${encodeFeedbackNotificationPayload('')}"',
      ),
    );
    expect(check, contains('STATUS_PATH: String = "/v1/feedback/status"'));
    expect(worker, contains('CHANNEL_ID = "$kUpdateNotificationChannelId"'));
    expect(
      store,
      contains('File(File(supportRoot, "feedback"), "poll_state.json")'),
    );
    expect(store, contains('File(file.path + ".lock")'));
    // 两边共用一把锁文件：过期判据必须相同。
    expect(FeedbackReplyStateStore.staleLockAge, const Duration(seconds: 10));
    expect(store, contains('STALE_LOCK_MS: Long = 10_000L'));
    // 通知 id 派生：Kotlin FeedbackReplyCheckTest 钉着同两个数。
    expect(feedbackNotificationId('yjn-3h8B-7'), 1730234009);
    expect(feedbackNotificationId('aaaaaaaaaa'), 1348136096);
  });

  test('点通知契约与解析到的 flutter_local_notifications 一致', () {
    final String plugin = _packageFile(
      'flutter_local_notifications',
      'android/src/main/java/com/dexterous/flutterlocalnotifications/'
          'FlutterLocalNotificationsPlugin.java',
    ).readAsStringSync();
    final String worker = _read('$_kotlinDir/FeedbackReplyWorker.kt');
    String pluginConst(String name) {
      final RegExpMatch? m = RegExp(
        'static final String $name = "([^"]+)";',
      ).firstMatch(plugin);
      expect(m, isNotNull, reason: '插件里找不到常量 $name');
      return m!.group(1)!;
    }

    expect(
      worker,
      contains(
        'FLN_SELECT_NOTIFICATION = "${pluginConst('SELECT_NOTIFICATION')}"',
      ),
    );
    expect(
      worker,
      contains('FLN_NOTIFICATION_ID = "${pluginConst('NOTIFICATION_ID')}"'),
    );
    expect(worker, contains('FLN_PAYLOAD = "${pluginConst('PAYLOAD')}"'));
    // 插件自己的通知也是「启动 Activity + 上面三项」，点击由它在 onNewIntent / launch details
    // 里认出；它若改成别的 Intent 形态，这里同步复核。
    expect(plugin, contains('getLaunchIntentForPackage(packageName)'));
    expect(plugin, contains('intent.setAction(SELECT_NOTIFICATION);'));
  });
}
