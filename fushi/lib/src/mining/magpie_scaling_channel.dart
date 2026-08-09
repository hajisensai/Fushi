import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Magpie 缩放状态监听（仅 Windows）的极薄 channel 封装。
///
/// native 侧（`fushi/windows/runner/flutter_window.cpp` 的 `RegisterMagpieChannel`）
/// 用 `RegisterWindowMessage(L"MagpieScalingChanged")` 注册 Magpie 的系统广播消息，
/// 收到后经 `app.fushi.reader/magpie` channel 单向推 `onScalingChanged` 给 Dart。
/// 只有 native -> Dart 一个方向，Dart 侧不发起任何调用。
///
/// 非 Windows / 未构建 native 时 native 永不推送，[setHandler] 装上的回调只是不会被
/// 调用（不崩、不抛）。
abstract final class MagpieScalingChannel {
  static const MethodChannel _channel =
      MethodChannel('app.fushi.reader/magpie');

  /// 当前已装载的回调；null = 未监听。
  static void Function(MagpieScalingEvent event)? _handler;

  /// 装载缩放状态回调。重复调用直接替换旧回调（同一时刻只有一个消费者）。
  static void setHandler(void Function(MagpieScalingEvent event) callback) {
    _handler = callback;
    _channel.setMethodCallHandler(_dispatch);
  }

  /// 卸载回调并摘掉 native 侧的 handler（native 仍会推，但这里不再解析）。
  static void clearHandler() {
    _handler = null;
    _channel.setMethodCallHandler(null);
  }

  /// 把 native 的 `onScalingChanged` 调用解析成 [MagpieScalingEvent] 派发出去。
  /// 未知方法名静默忽略（native 加新方法时旧 Dart 不崩）。
  static Future<Object?> _dispatch(MethodCall call) async {
    if (call.method != 'onScalingChanged') {
      return null;
    }
    final void Function(MagpieScalingEvent event)? handler = _handler;
    if (handler == null) {
      return null;
    }
    final Object? args = call.arguments;
    if (args is! Map) {
      return null;
    }
    handler(MagpieScalingEvent.fromMap(args));
    return null;
  }

  /// 仅供测试：直接喂一条 native 消息，验证解析与派发。
  @visibleForTesting
  static Future<void> debugDispatch(MethodCall call) => _dispatch(call);
}

/// 一次 Magpie 缩放状态变化。
///
/// [state] 是 native 原样透传的 `wParam`：
///   * `1` —— 缩放开始，或源窗口重新回到前台；
///   * `0` —— 配合 [handle]：`handle == 0` 表示缩放真正结束（缩放窗口销毁），
///     `handle != 0` 表示只是源窗口转到后台、缩放仍在跑；
///   * `2` —— 窗口模式下缩放窗口位置/大小变化；
///   * `3` —— 用户开始拖动缩放窗口。
///
/// [scaling] 是 native 按上述语义算好的「当前是否处于缩放中」，调用方直接用它，
/// 不要自己再从 [state] 推导。
@immutable
class MagpieScalingEvent {
  const MagpieScalingEvent({
    required this.state,
    required this.handle,
    required this.scaling,
  });

  /// native 原样透传的 `wParam`（见类文档）。
  final int state;

  /// native 原样透传的 `lParam`：缩放窗口 HWND（`state == 0 && handle == 0` 时
  /// 表示缩放已结束）。
  final int handle;

  /// 当前是否处于 Magpie 缩放中（native 已消化 `state`/`handle` 的组合语义）。
  final bool scaling;

  /// 从 native map 解析；字段缺失或类型不符时取保守缺省（`0` / `false`）。
  static MagpieScalingEvent fromMap(Map<Object?, Object?> map) {
    final Object? rawState = map['state'];
    final Object? rawHandle = map['handle'];
    final Object? rawScaling = map['scaling'];
    return MagpieScalingEvent(
      state: rawState is int ? rawState : 0,
      handle: rawHandle is int ? rawHandle : 0,
      scaling: rawScaling is bool ? rawScaling : false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MagpieScalingEvent &&
      other.state == state &&
      other.handle == handle &&
      other.scaling == scaling;

  @override
  int get hashCode => Object.hash(state, handle, scaling);

  @override
  String toString() =>
      'MagpieScalingEvent(state: $state, handle: $handle, scaling: $scaling)';
}
