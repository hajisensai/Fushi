/// 互联下载保活的唯一 Dart 门面。
///
/// 互联下载（手机从已配对电脑拉视频）跑在主 isolate 里，没有原生组件托底；
/// 用户切走后 Android 随时可能杀进程，下载随之中断。Android 上本门面驱动原生
/// `DownloadKeepAliveService.java`（dataSync 前台服务 + 常驻进度通知）把进程
/// 保活到下载结束；其余平台是 no-op。
///
/// 方法名与参数名（`update` / `stop`，`title` / `text` / `progress`）是跨语言
/// 契约，改一边必须改另一边。
///
/// **调用纪律**：第一次 [DownloadKeepAlive.update] 必须发生在 app 前台（用户点
/// 下载那一刻）——Android 12+ 不允许后台拉起前台服务，原生侧会拒绝并只记日志。
/// 服务起来之后的进度更新在后台也安全（原生侧直接改通知，不再拉起服务）。
/// 所有下载结束（完成 / 失败 / 取消）后必须 [DownloadKeepAlive.stop]。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

/// 通知进度条的「不确定」取值（原生侧画转圈而不是进度条）。
const int kDownloadKeepAliveIndeterminate = -1;

/// 进度更新的默认最小间隔：下载进度回调可能每个分块一次，全部过通道没有意义。
const Duration kDownloadKeepAliveMinInterval = Duration(milliseconds: 500);

/// 下载保活门面。
abstract interface class DownloadKeepAlive {
  /// 开始（尚未保活时）或更新保活通知。[percent] 为 null / 越界时显示不确定进度。
  Future<void> update({
    required String title,
    required String text,
    int? percent,
  });

  /// 结束保活并移除通知。未在保活时是 no-op。
  Future<void> stop();
}

/// 按平台选实现：只有 Android 有原生侧，其余平台一律 no-op。
DownloadKeepAlive createDownloadKeepAlive() {
  if (Platform.isAndroid) {
    return AndroidDownloadKeepAlive();
  }
  return const NoopDownloadKeepAlive();
}

/// 非 Android 平台的实现：什么也不做，也不发任何通道调用。
class NoopDownloadKeepAlive implements DownloadKeepAlive {
  const NoopDownloadKeepAlive();

  @override
  Future<void> update({
    required String title,
    required String text,
    int? percent,
  }) async {}

  @override
  Future<void> stop() async {}
}

/// 一次要显示的通知状态。[percent] 已归一化：`0..100` 或
/// [kDownloadKeepAliveIndeterminate]。
@immutable
class DownloadKeepAliveState {
  const DownloadKeepAliveState({
    required this.title,
    required this.text,
    required this.percent,
  });

  /// 归一化构造：null / 越界 / 负数一律当作不确定进度。
  factory DownloadKeepAliveState.normalized({
    required String title,
    required String text,
    int? percent,
  }) {
    final int value = percent == null || percent < 0 || percent > 100
        ? kDownloadKeepAliveIndeterminate
        : percent;
    return DownloadKeepAliveState(title: title, text: text, percent: value);
  }

  final String title;
  final String text;
  final int percent;

  @override
  bool operator ==(Object other) =>
      other is DownloadKeepAliveState &&
      other.title == title &&
      other.text == text &&
      other.percent == percent;

  @override
  int get hashCode => Object.hash(title, text, percent);

  @override
  String toString() =>
      'DownloadKeepAliveState($title, $text, percent: $percent)';
}

/// [DownloadKeepAliveThrottle.onUpdate] 的裁决。
enum DownloadKeepAliveAction {
  /// 立刻发。
  send,

  /// 先不发，[DownloadKeepAliveDecision.delay] 之后再发最新状态。
  defer,

  /// 与已发出的状态相同，不必发。
  skip,
}

/// 一次裁决：动作 + （仅 defer 时有意义的）延迟。
@immutable
class DownloadKeepAliveDecision {
  const DownloadKeepAliveDecision(this.action, [this.delay = Duration.zero]);

  final DownloadKeepAliveAction action;
  final Duration delay;

  @override
  bool operator ==(Object other) =>
      other is DownloadKeepAliveDecision &&
      other.action == action &&
      other.delay == delay;

  @override
  int get hashCode => Object.hash(action, delay);

  @override
  String toString() => 'DownloadKeepAliveDecision($action, $delay)';
}

/// 去重 + 节流的纯逻辑（无通道、无定时器，时钟可注入）。
///
/// 规则：
/// * 与上一次发出的状态相同 → skip；
/// * 未在保活（启动）→ 立即 send，不受节流约束；
/// * 距上一次发送不足 [minInterval] → defer 到间隔满；否则 send；
/// * stop 只在保活中时才需要发，发完回到未保活。
class DownloadKeepAliveThrottle {
  DownloadKeepAliveThrottle({
    DateTime Function()? now,
    this.minInterval = kDownloadKeepAliveMinInterval,
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Duration minInterval;

  DownloadKeepAliveState? _lastSent;
  DateTime? _lastSentAt;

  /// 是否在保活中（已发出过 update 且之后没有 stop）。
  bool get isActive => _lastSent != null;

  /// 最近一次发出的状态。
  DownloadKeepAliveState? get lastSent => _lastSent;

  /// 对一条新状态做裁决。不改内部状态；真正发出后调用 [markSent]。
  DownloadKeepAliveDecision onUpdate(DownloadKeepAliveState state) {
    final DownloadKeepAliveState? last = _lastSent;
    if (last == null) {
      return const DownloadKeepAliveDecision(DownloadKeepAliveAction.send);
    }
    if (last == state) {
      return const DownloadKeepAliveDecision(DownloadKeepAliveAction.skip);
    }
    final Duration elapsed = _now().difference(_lastSentAt ?? _now());
    if (elapsed >= minInterval) {
      return const DownloadKeepAliveDecision(DownloadKeepAliveAction.send);
    }
    return DownloadKeepAliveDecision(
      DownloadKeepAliveAction.defer,
      minInterval - elapsed,
    );
  }

  /// 记录一次已发出的 update。
  void markSent(DownloadKeepAliveState state) {
    _lastSent = state;
    _lastSentAt = _now();
  }

  /// 处理 stop：返回是否需要发 stop（保活中才需要），并回到未保活。
  bool onStop() {
    final bool wasActive = _lastSent != null;
    _lastSent = null;
    _lastSentAt = null;
    return wasActive;
  }
}

/// Android 实现：经 [FushiChannels.downloadKeepAlive] 驱动原生前台服务。
///
/// 通道异常（没注册 / 原生抛错）一律吞掉只记日志：保活失败不能连带下载失败。
class AndroidDownloadKeepAlive implements DownloadKeepAlive {
  AndroidDownloadKeepAlive({
    MethodChannel? channel,
    DateTime Function()? now,
    Duration minInterval = kDownloadKeepAliveMinInterval,
  })  : _channel = channel ?? FushiChannels.downloadKeepAlive,
        _throttle = DownloadKeepAliveThrottle(
          now: now,
          minInterval: minInterval,
        );

  static const String _methodUpdate = 'update';
  static const String _methodStop = 'stop';
  static const String _argTitle = 'title';
  static const String _argText = 'text';
  static const String _argProgress = 'progress';

  final MethodChannel _channel;
  final DownloadKeepAliveThrottle _throttle;

  /// 被节流挡下、等待补发的最新状态。
  DownloadKeepAliveState? _pending;
  Timer? _pendingTimer;

  @override
  Future<void> update({
    required String title,
    required String text,
    int? percent,
  }) async {
    final DownloadKeepAliveState state = DownloadKeepAliveState.normalized(
      title: title,
      text: text,
      percent: percent,
    );
    final DownloadKeepAliveDecision decision = _throttle.onUpdate(state);
    switch (decision.action) {
      case DownloadKeepAliveAction.skip:
        // 最新期望状态已经在通知上了：之前挡下的旧状态不必再补发。
        _cancelPending();
      case DownloadKeepAliveAction.defer:
        _pending = state;
        _pendingTimer ??= Timer(decision.delay, _flushPending);
      case DownloadKeepAliveAction.send:
        _cancelPending();
        await _send(state);
    }
  }

  @override
  Future<void> stop() async {
    _cancelPending();
    if (!_throttle.onStop()) return;
    await _invoke(_methodStop, null);
  }

  void _flushPending() {
    _pendingTimer = null;
    final DownloadKeepAliveState? state = _pending;
    _pending = null;
    if (state == null || !_throttle.isActive) return;
    final DownloadKeepAliveDecision decision = _throttle.onUpdate(state);
    switch (decision.action) {
      case DownloadKeepAliveAction.skip:
        return;
      case DownloadKeepAliveAction.defer:
        _pending = state;
        _pendingTimer = Timer(decision.delay, _flushPending);
      case DownloadKeepAliveAction.send:
        unawaited(_send(state));
    }
  }

  void _cancelPending() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pending = null;
  }

  Future<void> _send(DownloadKeepAliveState state) {
    // 先记账再发：await 期间并发进来的 update 要能看到这次已发出的状态。
    _throttle.markSent(state);
    return _invoke(_methodUpdate, <String, Object?>{
      _argTitle: state.title,
      _argText: state.text,
      _argProgress: state.percent,
    });
  }

  Future<void> _invoke(String method, Object? arguments) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException catch (e) {
      // 非 MainActivity 引擎入口（弹窗词典等）没注册这条通道。
      debugPrint('[DownloadKeepAlive] $method: channel missing ($e)');
    } on PlatformException catch (e) {
      debugPrint('[DownloadKeepAlive] $method failed: $e');
    }
  }
}
