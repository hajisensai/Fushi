import 'package:meta/meta.dart';

/// 视频页对**进程级显示态**的所有权登记表（BUG-2105）。
///
/// 视频页在 `initState` 里认领三件全局显示态（都是进程唯一、没有「谁设的谁看得见」
/// 的作用域）：
///   * 移动端横屏锁（`SystemChrome.setPreferredOrientations`）；
///   * 移动端系统栏可见性回调（`SystemChrome.setSystemUIChangeCallback`，全局单槽）；
///   * macOS 交通灯隐藏（`setMacOSTrafficLightsHidden`）。
///
/// 原先这三件在 `dispose` 里**无条件**还原。换集（`_switchEpisode` 的窗口模式分支）
/// 用 `pushReplacement`，而 Flutter 语义下**旧路由的 `dispose` 晚于新路由的
/// `initState`**（旧路由要等新页入场动画结束才被移除并销毁）——于是顺序变成
/// 「新页认领 → 旧页还原」，新页刚设好的横屏锁被放宽成含竖屏、刚注册的系统栏回调
/// 被置空。移动端开着「自动旋转锁定」时，方向集一旦含 `portraitUp` 就退回用户锁定
/// 的竖屏，观感就是「换集后掉出全屏播放」。
///
/// 根治形状与仓内 `FushiWindowsTitleBar._contentFullscreenOwners` 一致：**按所有者
/// 记账，只有最后一个持有者离开才还原**。换集期间集合短暂同时含新旧两页，旧页释放
/// 时集合非空 → 不还原；正常退页时集合空 → 还原。
///
/// 纯 Dart、无平台调用：判据可在 headless 环境单测（`test/media/video/
/// video_display_claim_test.dart`），页面只消费 [claim] / [release] 的布尔结论，
/// 不再自己手写「该不该还原」。
class VideoDisplayClaim {
  const VideoDisplayClaim._();

  /// 当前持有进程级显示态的视频页（`State` 实例身份，不持有生命周期）。
  static final Set<Object> _owners = <Object>{};

  /// [owner] 认领显示态。返回 `true` 表示这是**首个**持有者（此前无人持有）。
  ///
  /// 重复认领同一个 owner 幂等（返回 `false`）。认领动作本身（锁横屏 / 注册回调 /
  /// 隐交通灯）由调用方无条件执行——新页必须真的把全局单槽设成自己的，返回值只用来
  /// 区分「首次进入」这类可选副作用。
  static bool claim(Object owner) {
    final bool wasEmpty = _owners.isEmpty;
    _owners.add(owner);
    return wasEmpty;
  }

  /// [owner] 释放显示态。返回 `true` **仅当**它是最后一个持有者（还原全局显示态的
  /// 唯一判据）。
  ///
  /// 从未认领过的 owner 释放返回 `false`（不还原）——它没设过，也就无权还原。
  static bool release(Object owner) {
    if (!_owners.remove(owner)) return false;
    return _owners.isEmpty;
  }

  /// 是否仍有视频页持有进程级显示态。
  static bool get held => _owners.isNotEmpty;

  /// 当前持有者数量（测试断言用）。
  @visibleForTesting
  static int get ownerCount => _owners.length;

  @visibleForTesting
  static void resetForTest() => _owners.clear();
}
