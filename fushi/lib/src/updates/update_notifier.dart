/// 系统通知的**平台无关**面。
///
/// 单独抽一层是因为：投递逻辑（哪些是新事件、要不要提醒）必须能在纯 Dart 单测里
/// 跑完，而 `flutter_local_notifications` 一旦被 import 进服务本体，任何测试都要
/// 先架 method channel mock。这里只留两个动词，真实实现在
/// `local_update_notifier.dart`，测试用 [RecordingUpdateNotifier]。
library;

/// 通知上的一个动作按钮。[id] 回流到 [UpdateNotificationResponse.actionId]。
class UpdateNotificationAction {
  const UpdateNotificationAction({required this.id, required this.label});

  final String id;
  final String label;
}

/// 一条待发的系统通知。
class UpdateNotification {
  const UpdateNotification({
    required this.id,
    required this.title,
    required this.body,
    this.payload,
    this.imagePath,
    this.timestamp,
    this.actions = const <UpdateNotificationAction>[],
  });

  /// 平台通知 id。同 id 再发 = 替换而不是叠加（见 `updateNotificationId`：
  /// 无组 = 域固定值，有组 = 域 + 组名派生）。
  final int id;

  final String title;
  final String body;

  /// 点击通知时回传的载荷（`UpdateNotificationPayload` 编码，见
  /// `update_feed_service.dart`），用于把用户送到那条更新的落点。
  final String? payload;

  /// 配图的本机绝对路径；null = 纯文字。各平台各自映射（Windows hero 大图 /
  /// Android BigPicture / Apple attachment / Linux icon）。
  final String? imagePath;

  /// 通知显示的时刻；null = 平台默认（发出的那一刻）。
  final DateTime? timestamp;

  /// 动作按钮，按顺序显示。空 = 只有点击本体。
  final List<UpdateNotificationAction> actions;
}

/// 用户对一条通知的响应：点本体（[actionId] 为 null）或点某个按钮。
class UpdateNotificationResponse {
  const UpdateNotificationResponse({required this.payload, this.actionId});

  final String? payload;
  final String? actionId;
}

abstract class UpdateNotifier {
  /// 初始化并申请权限。返回 false = 这台设备上发不出系统通知（用户拒权、平台
  /// 不支持、初始化失败）。调用方据此**降级**——照常投递、照常出红点，只是不弹
  /// 通知；绝不因为通知发不出去就丢掉事件。
  Future<bool> ensureReady();

  /// 发一条通知。[ensureReady] 未成功时应静默无操作。
  Future<void> notify(UpdateNotification notification);

  /// 撤掉某个 id 的通知（用户已在应用内看过该域的更新时调用）。
  Future<void> cancel(int id);
}

/// 不发任何通知的实现。桌面/移动之外的入口（弹窗词典进程、集成测试）与关闭了
/// 系统通知的用户都用它。
class NoopUpdateNotifier implements UpdateNotifier {
  const NoopUpdateNotifier();

  @override
  Future<bool> ensureReady() async => false;

  @override
  Future<void> notify(UpdateNotification notification) async {}

  @override
  Future<void> cancel(int id) async {}
}

/// 只记录不发送，供单测断言「发了几条、内容是什么」。
class RecordingUpdateNotifier implements UpdateNotifier {
  RecordingUpdateNotifier({this.ready = true});

  final bool ready;

  final List<UpdateNotification> sent = <UpdateNotification>[];
  final List<int> cancelled = <int>[];
  int ensureReadyCalls = 0;

  @override
  Future<bool> ensureReady() async {
    ensureReadyCalls++;
    return ready;
  }

  @override
  Future<void> notify(UpdateNotification notification) async {
    if (!ready) return;
    sent.add(notification);
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
  }
}
