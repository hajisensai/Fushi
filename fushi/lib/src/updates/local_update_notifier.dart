/// 系统通知的真实实现（flutter_local_notifications 20.x，五端）。
///
/// 与 `UpdateFeedService` 隔着 [UpdateNotifier] 抽象：投递逻辑必须能在纯 Dart
/// 单测里跑完，而这一层一旦被 import 进去，每条测试都要先架 method channel。
library;

import 'dart:io' show Directory, File, Platform;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/updates/update_notifier.dart';

/// Android 通知渠道。渠道 id 一旦发布就**不能改**——改了等于建一个新渠道，用户
/// 在系统设置里对旧渠道做的静音/重要性调整全部失效。
const String kUpdateNotificationChannelId = 'fushi_updates';

/// Windows toast 需要一个稳定 GUID 标识本应用。同样**不可变更**：换 GUID =
/// 换一个应用身份，已发出的通知与用户的通知设置一起失联。
const String kWindowsNotificationGuid = '4f6a1c2e-8b3d-4a91-9c27-2d5b8e0f7a13';

/// Windows toast 头部图标：随包 Flutter 资产（构建期已在 `data/flutter_assets`
/// 下，五端同一张）。不传给插件就没有 `IconUri`，头部只剩文字。
const String kWindowsNotificationIconAsset = 'assets/meta/icon.png';

/// Windows 按钮参数的封装前缀。插件在 Windows 上把「被点的东西的 arguments」同时
/// 塞进 `payload` 与 `actionId`——点本体拿到的是 `launch`（= 载荷），点按钮拿到的
/// 是按钮 `arguments`，本体载荷就丢了。所以按钮参数自带载荷：
/// `action:<id>|<payload>`，收到后在 [decodeNotificationResponse] 拆开。
const String kWindowsActionPrefix = 'action:';

/// Windows 按钮的 arguments 编码（与 [decodeNotificationResponse] 互逆）。
String encodeWindowsActionArguments(String actionId, String? payload) =>
    '$kWindowsActionPrefix$actionId|${payload ?? ''}';

/// 把插件回传的响应归一成 `(payload, actionId)`：Windows 按钮参数按
/// [kWindowsActionPrefix] 拆；其它平台的 payload / actionId 本来就分开。
UpdateNotificationResponse decodeNotificationResponse(
  NotificationResponse response,
) {
  final String? raw = response.payload;
  if (raw != null && raw.startsWith(kWindowsActionPrefix)) {
    final int split = raw.indexOf('|');
    if (split > kWindowsActionPrefix.length) {
      return UpdateNotificationResponse(
        payload: raw.substring(split + 1),
        actionId: raw.substring(kWindowsActionPrefix.length, split),
      );
    }
  }
  final bool isAction = response.notificationResponseType ==
      NotificationResponseType.selectedNotificationAction;
  return UpdateNotificationResponse(
    payload: raw,
    actionId: isAction ? response.actionId : null,
  );
}

class LocalUpdateNotifier implements UpdateNotifier {
  LocalUpdateNotifier({
    required this.appName,
    this.groupTitle,
    this.onResponse,
    FlutterLocalNotificationsPlugin? plugin,
    String? windowsIconPath,
  })  : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
        _windowsIconPath = windowsIconPath;

  /// 通知里显示的应用名 + Windows 的 AUMID 名。
  final String appName;

  /// Windows 通知中心里这组通知的页眉（如「订阅更新」）；null = 不分组。
  final String? groupTitle;

  /// 用户点了通知（本体或按钮）。null = 只发不收。
  final void Function(UpdateNotificationResponse response)? onResponse;

  final FlutterLocalNotificationsPlugin _plugin;
  final String? _windowsIconPath;

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

  /// 随包资产在磁盘上的绝对路径：`<exe 目录>/data/flutter_assets/<asset>`。
  /// 按 exe 定位而不是 cwd——从文件关联 / 开始菜单启动时 cwd 不是安装目录。
  static String bundledAssetPath(String asset) => p.join(
        p.dirname(Platform.resolvedExecutable),
        'data',
        'flutter_assets',
        asset,
      );

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
      debugPrint(
        'LocalUpdateNotifier: initialise failed, falling back to '
        'in-app only. $error',
      );
      _ready = false;
    }
    if (_ready) await _replayLaunchResponse();
    return _ready;
  }

  /// 冷启动是被通知拉起来的（Android 进程被杀后点通知）：初始化时回调还没挂
  /// 上，那次点击只留在 launch details 里，这里补投一次。只在启动期的
  /// [ensureReady]（`UpdateFeedService.warmUpNotifier`）里走到——时机确定，不会
  /// 在几小时后第一次发通知时突然回放一次旧点击。
  Future<void> _replayLaunchResponse() async {
    if (onResponse == null) return;
    try {
      final NotificationAppLaunchDetails? details =
          await _plugin.getNotificationAppLaunchDetails();
      final NotificationResponse? response = details?.notificationResponse;
      if (details?.didNotificationLaunchApp == true && response != null) {
        _dispatch(response);
      }
    } on Object catch (error) {
      debugPrint('LocalUpdateNotifier: launch details unavailable. $error');
    }
  }

  Future<bool> _initialise() async {
    final String iconPath =
        _windowsIconPath ?? bundledAssetPath(kWindowsNotificationIconAsset);
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
          // 图标文件不在（开发期从别的 cwd 起、包被裁过）就不传：插件会把不存在
          // 的路径原样写进注册表，头部反而显示一个坏图。
          iconPath: File(iconPath).existsSync() ? iconPath : null,
        ),
      ),
      onDidReceiveNotificationResponse: _dispatch,
    );
    if (initialised == false) return false;
    return _requestPermission();
  }

  void _dispatch(NotificationResponse response) {
    onResponse?.call(decodeNotificationResponse(response));
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
      final DarwinNotificationDetails darwin = await _darwinDetails(
        notification,
      );
      await _plugin.show(
        id: notification.id,
        title: notification.title,
        body: notification.body.isEmpty ? null : notification.body,
        notificationDetails: NotificationDetails(
          android: _androidDetails(notification),
          iOS: darwin,
          macOS: darwin,
          linux: _linuxDetails(notification),
          windows: _windowsDetails(notification),
        ),
        payload: notification.payload,
      );
    } on Object catch (error) {
      debugPrint('LocalUpdateNotifier: show failed. $error');
    }
  }

  /// 配图文件真的在才挂：抽帧产物可能已被封面 GC 收走，挂个不存在的路径在
  /// Android 上是整条通知不显示。
  static String? _existingImage(UpdateNotification notification) {
    final String? path = notification.imagePath;
    if (path == null || path.isEmpty) return null;
    return File(path).existsSync() ? path : null;
  }

  AndroidNotificationDetails _androidDetails(UpdateNotification notification) {
    final String? image = _existingImage(notification);
    return AndroidNotificationDetails(
      kUpdateNotificationChannelId,
      appName,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      // 更新提醒不是即时通讯，不该震动/响铃打断用户。
      playSound: false,
      enableVibration: false,
      when: notification.timestamp?.millisecondsSinceEpoch,
      largeIcon: image == null ? null : FilePathAndroidBitmap(image),
      styleInformation: image == null
          ? null
          : BigPictureStyleInformation(
              FilePathAndroidBitmap(image),
              // 展开后大图接管，缩略角标隐藏，别一张图出现两次。
              hideExpandedLargeIcon: true,
              contentTitle: notification.title,
              summaryText: notification.body,
            ),
      actions: <AndroidNotificationAction>[
        for (final UpdateNotificationAction action in notification.actions)
          AndroidNotificationAction(
            action.id,
            action.label,
            showsUserInterface: true,
            cancelNotification: true,
          ),
      ],
    );
  }

  /// Apple 端：附件即配图；按钮要在初始化时按 category 预先登记文案，而文案
  /// 随语言变、随域变，这里刻意不做——点本体即打开落点，与桌面一致。
  ///
  /// **附件必须是一份拷贝**：`UNNotificationAttachment` 会把文件**移动**进系统
  /// 附件存储（只有 bundle 内的资源才是复制）。传来的 [UpdateNotification
  /// .imagePath] 是这集刚落成的书架封面 / 作品海报，直接挂等于把封面搬走。
  Future<DarwinNotificationDetails> _darwinDetails(
    UpdateNotification notification,
  ) async {
    String? attachment;
    if (Platform.isIOS || Platform.isMacOS) {
      attachment = await _copyForAttachment(_existingImage(notification));
    }
    return DarwinNotificationDetails(
      presentSound: false,
      attachments: attachment == null
          ? null
          : <DarwinNotificationAttachment>[
              DarwinNotificationAttachment(attachment),
            ],
    );
  }

  static Future<String?> _copyForAttachment(String? image) async {
    if (image == null) return null;
    try {
      final Directory dir = Directory(
        p.join(Directory.systemTemp.path, 'fushi_notification_attachments'),
      );
      await dir.create(recursive: true);
      final String target = p.join(
        dir.path,
        '${DateTime.now().microsecondsSinceEpoch}${p.extension(image)}',
      );
      await File(image).copy(target);
      return target;
    } on Object catch (error) {
      debugPrint('LocalUpdateNotifier: attachment copy failed. $error');
      return null;
    }
  }

  LinuxNotificationDetails _linuxDetails(UpdateNotification notification) {
    final String? image = _existingImage(notification);
    return LinuxNotificationDetails(
      icon: image == null ? null : FilePathLinuxIcon(image),
      suppressSound: true,
      actions: <LinuxNotificationAction>[
        for (final UpdateNotificationAction action in notification.actions)
          LinuxNotificationAction(key: action.id, label: action.label),
      ],
    );
  }

  WindowsNotificationDetails _windowsDetails(UpdateNotification notification) {
    final String? image = _existingImage(notification);
    final String? groupTitle = this.groupTitle;
    return WindowsNotificationDetails(
      audio: WindowsNotificationAudio.silent(),
      timestamp: notification.timestamp,
      header: groupTitle == null
          ? null
          : WindowsHeader(
              id: kUpdateNotificationChannelId,
              title: groupTitle,
              arguments: notification.payload ?? '',
            ),
      images: <WindowsImage>[
        if (image != null)
          WindowsImage(
            Uri.file(image, windows: true),
            altText: notification.title,
            placement: WindowsImagePlacement.hero,
          ),
      ],
      actions: <WindowsAction>[
        for (final UpdateNotificationAction action in notification.actions)
          WindowsAction(
            content: action.label,
            arguments: encodeWindowsActionArguments(
              action.id,
              notification.payload,
            ),
          ),
      ],
    );
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
