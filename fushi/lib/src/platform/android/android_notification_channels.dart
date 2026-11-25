// Android 通知渠道在系统设置里显示的名字跟界面语言走（拍板台 left3621）。
//
// 渠道名以前在各前台服务里写死英文（「App audio capture」「Floating Ball」…），非英文用户
// 在系统通知设置里看到的是英文分类。文案的唯一来源仍是 i18n json：主引擎启动时把
// 「渠道 id → 当前界面语言的名字」整表推给原生 `NotificationChannelNames.java`，原生落盘
// 供各服务建渠道时取名，并把已经建过的渠道就地改名。手机端换界面语言会重启 app，下一次
// 启动自然推新表。
//
// 两个由插件建的渠道另外在 Dart 侧直接传名字：
// - `fushi_updates`：flutter_local_notifications 每次发通知都会用传入的名字重建渠道，所以
//   `LocalUpdateNotifier` 也必须传同一个本地化名字（见 app_model 的 `systemNotifier`），
//   否则每发一条更新提醒就被改回去；
// - audio_service 的播放渠道：插件只在渠道不存在时用 `AudioServiceConfig` 里的名字建，
//   之后的改名由这里的启动同步负责。

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi/i18n/strings.g.dart' show AppLocale, t;
import 'package:fushi/src/updates/local_update_notifier.dart'
    show kUpdateNotificationChannelId;
import 'package:fushi/src/utils/misc/channel_constants.dart';

/// 原生 `NotificationIds.java` 里的渠道 id（**发布后不可改**，改了等于新建渠道、用户的
/// 静音设置全部失联）。守卫测试逐个核对这里和 Java 常量一致。
const String kFloatingBallNotificationChannelId = 'fushi_floating_ball';
const String kScreenOcrNotificationChannelId = 'fushi_screen_ocr';
const String kCrossAppAudioNotificationChannelId = 'fushi_cross_app_audio';
const String kDownloadKeepAliveNotificationChannelId =
    'fushi_download_keep_alive';
const String kFloatingDictNotificationChannelId = 'hibiki_floating_dict';
const String kFloatingLyricNotificationChannelId = 'hibiki_floating_lyric';

/// audio_service 前台播放服务的渠道 id（`AudioServiceConfig.androidNotificationChannelId`）。
const String kAudioServiceNotificationChannelId =
    'app.fushi.reader.channel.audio';

/// 本 app 全部 Android 通知渠道 → [locale]（默认当前界面语言）下的显示名。
Map<String, String> androidNotificationChannelNames([AppLocale? locale]) {
  final tr = locale?.translations ?? t;
  return <String, String>{
    kFloatingBallNotificationChannelId: tr.notification_channel_floating_ball,
    kScreenOcrNotificationChannelId: tr.notification_channel_screen_ocr,
    kCrossAppAudioNotificationChannelId:
        tr.notification_channel_app_audio_capture,
    kDownloadKeepAliveNotificationChannelId: tr.notification_channel_downloads,
    kFloatingDictNotificationChannelId:
        tr.notification_channel_floating_dictionary,
    kFloatingLyricNotificationChannelId:
        tr.notification_channel_floating_lyrics,
    kAudioServiceNotificationChannelId: tr.notification_channel_media_playback,
    kUpdateNotificationChannelId: tr.notification_channel_updates,
  };
}

/// 把当前界面语言的渠道名整表推给原生。非 Android 直接返回；原生没注册（旧壳 / 测试）
/// 或调用失败只记日志——渠道名退回英文兜底不影响任何功能，不值得打断启动。
Future<void> syncAndroidNotificationChannelNames({
  AppLocale? locale,
  MethodChannel? channel,
  bool? isAndroid,
}) async {
  if (!(isAndroid ?? (!kIsWeb && Platform.isAndroid))) return;
  final Map<String, String> names = androidNotificationChannelNames(locale);
  try {
    await (channel ?? FushiChannels.notificationChannels).invokeMethod<int>(
      'sync',
      names,
    );
  } on MissingPluginException {
    // 非主引擎（弹窗 / 悬浮词典进程）没注册这条通道，主引擎启动时会推。
  } on PlatformException catch (e) {
    debugPrint('[Fushi] notification channel names sync failed: $e');
  }
}
