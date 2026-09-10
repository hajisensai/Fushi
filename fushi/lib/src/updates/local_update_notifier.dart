/// 系统通知的真实实现（flutter_local_notifications 20.x，五端）。
///
/// 与 `UpdateFeedService` 隔着 [UpdateNotifier] 抽象：投递逻辑必须能在纯 Dart
/// 单测里跑完，而这一层一旦被 import 进去，每条测试都要先架 method channel。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:fushi/src/updates/update_notifier.dart';

/// Android 通知渠道。渠道 id 一旦发布就**不能改**——改了等于建一个新渠道，用户
/// 在系统设置里对旧渠道做的静音/重要性调整全部失效。
const String kUpdateNotificationChannelId = 'fushi_updates';

/// Windows toast 需要一个稳定 GUID 标识本应用。同样**不可变更**：换 GUID =
/// 换一个应用身份，已发出的通知与用户的通知设置一起失联。
const String kWindowsNotificationGuid = '4f6a1c2e-8b3d-4a91-9c27-2d5b8e0f7a13';

class LocalUpdateNotifier implements UpdateNotifier {
  LocalUpdateNotifier({
    required this.appName,
    FlutterLocalNotificationsPlugin? plugin,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  /// 通知里显示的应用名 + Windows 的 AUMID 名。
  final String appName;

  final FlutterLocalNotificationsPlugin _plugin;

  bool _ready = false;
  bool _initialised = false;

  /// 这个平台上到底有没有系统通知实现。
  ///
  /// web 与「既非移动也非桌面」的入口直接判否——不是每个 entry point 都跑在有
  /// 通知中心的地方（弹窗词典是独立进程，集成测试跑在离屏窗口里）。
  static bool get isSupportedPlatform {
    if (kIsWeb) return false;
    return Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isLinux ||
        Platform.isWindows;
  }

  @override
  Future<bool> ensureReady() async {
    if (_initialised) return _ready;
    _initialised = true;
    if (!isSupportedPlatform) return false;
    try {
      _ready = await _initialise();
    } on Object catch (error) {
      // 初始化失败（缺渠道权限、Windows 未注册 AUMID、Linux 无 D-Bus 通知服务）
      // 只降级成「不发通知」。更新事件照常投递、红点照常出——把提醒功能整个连坐
      // 掉才是真正的 bug。
      debugPrint('LocalUpdateNotifier: initialise failed, falling back to '
          'in-app only. $error');
      _ready = false;
    }
    return _ready;
  }

  Future<bool> _initialise() async {
    final bool? initialised = await _plugin.initialize(
      settings: InitializationSettings(
        android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: const DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        macOS: const DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        linux: LinuxInitializationSettings(defaultActionName: appName),
        windows: WindowsInitializationSettings(
          appName: appName,
          appUserModelId: 'com.hibiki.fushi',
          guid: kWindowsNotificationGuid,
        ),
      ),
    );
    if (initialised == false) return false;
    return _requestPermission();
  }

  /// 权限申请。三个平台三种口径，返回「现在能不能发」。
  ///
  /// Linux / Windows 没有运行时权限概念，初始化成功即可发。
  Future<bool> _requestPermission() async {
    if (Platform.isAndroid) {
      final AndroidFlutterLocalNotificationsPlugin? android =
          _plugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return false;
      // API 33+ 才有 POST_NOTIFICATIONS；更低版本这里返回 null，视作已授权
      // （清单里的权限在安装时就给了）。
      final bool? granted = await android.requestNotificationsPermission();
      return granted ?? true;
    }
    if (Platform.isIOS) {
      final bool? granted = await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: false);
      return granted ?? false;
    }
    if (Platform.isMacOS) {
      final bool? granted = await _plugin
          .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: false);
      return granted ?? false;
    }
    return true;
  }

  @override
  Future<void> notify(UpdateNotification notification) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: notification.id,
        title: notification.title,
        body: notification.body.isEmpty ? null : notification.body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            kUpdateNotificationChannelId,
            appName,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            // 更新提醒不是即时通讯，不该震动/响铃打断用户。
            playSound: false,
            enableVibration: false,
          ),
          iOS: const DarwinNotificationDetails(presentSound: false),
          macOS: const DarwinNotificationDetails(presentSound: false),
          linux: const LinuxNotificationDetails(),
          windows: const WindowsNotificationDetails(),
        ),
        payload: notification.payload,
      );
    } on Object catch (error) {
      debugPrint('LocalUpdateNotifier: show failed. $error');
    }
  }

  @override
  Future<void> cancel(int id) async {
    if (!_ready) return;
    try {
      await _plugin.cancel(id: id);
    } on Object catch (error) {
      debugPrint('LocalUpdateNotifier: cancel failed. $error');
    }
  }
}
