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
  /// 初始化通知后端：挂点击回调、回放冷启动点击。返回 false = 这台设备上发不出
  /// 系统通知（平台不支持、初始化失败）。调用方据此**降级**——照常投递、照常出
  /// 红点，只是不弹通知；绝不因为通知发不出去就丢掉事件。
  ///
  /// **绝不向系统申请运行时权限**。它跑在启动期（HomePage 就绪那一帧），而运行
  /// 时权限对话框是系统 UI——用户没做任何动作就弹系统框，本身就是错的时机；在
  /// MIUI 上那个对话框（com.lbe.security.miui）还会崩掉并把发起请求的我们一起
  /// 杀掉（BUG-2498）。申请权限走 [requestPermission]，只由用户的显式动作触发。
  Future<bool> ensureReady();

  /// 回放「被通知冷启动」的那次点击（[ensureReady] 时回调还没挂上）。只在启动
  /// 期调一次；不并进 [ensureReady]——它还有用户打开开关这个晚得多的入口。
  Future<void> replayLaunchResponse();

  /// 系统当前是否允许本应用发通知。只查询、不弹任何界面。
  Future<bool> hasPermission();

  /// 向系统申请通知权限——会弹系统对话框，只能由用户的显式动作（打开「系统
  /// 通知」开关）触发。返回申请后的最终状态。
  Future<bool> requestPermission();

  /// 发一条通知。[ensureReady] 未成功或 [hasPermission] 为假时应静默无操作。
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
  Future<void> replayLaunchResponse() async {}

  @override
  Future<bool> hasPermission() async => false;

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<void> notify(UpdateNotification notification) async {}

  @override
  Future<void> cancel(int id) async {}
}

/// 只记录不发送，供单测断言「发了几条、内容是什么」。
class RecordingUpdateNotifier implements UpdateNotifier {
  RecordingUpdateNotifier({this.ready = true, this.permission = true});

  final bool ready;

  /// 系统权限的模拟状态：[hasPermission] 回它；[requestPermission] 把它当作
  /// 「用户在系统框里的选择」写进 [granted]。
  final bool permission;

  /// 申请过之后的权限状态；没申请过时等于 [permission]。
  bool? granted;

  final List<UpdateNotification> sent = <UpdateNotification>[];
  final List<int> cancelled = <int>[];
  int ensureReadyCalls = 0;
  int replayLaunchCalls = 0;
  int requestPermissionCalls = 0;

  @override
  Future<bool> ensureReady() async {
    ensureReadyCalls++;
    return ready;
  }

  @override
  Future<void> replayLaunchResponse() async {
    replayLaunchCalls++;
  }

  @override
  Future<bool> hasPermission() async => granted ?? permission;

  @override
  Future<bool> requestPermission() async {
    requestPermissionCalls++;
    return granted = permission;
  }

  @override
  Future<void> notify(UpdateNotification notification) async {
    if (!ready || !(granted ?? permission)) return;
    sent.add(notification);
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
  }
}
