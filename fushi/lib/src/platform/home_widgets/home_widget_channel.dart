import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:fushi/src/utils/misc/channel_constants.dart';

/// Live Activity（iOS）/ 菜单栏播放条（macOS）与小组件按钮回调的原生通道门面
/// （`fushi/apple/HomeWidgets/FushiHomeWidgets.swift`）。主屏小组件的快照不走这里，走与
/// Android 共用的 `WidgetSnapshotPublisher`（`FushiChannels.widgets`）。
///
/// 只有 iOS / macOS 有原生实现；其它平台 [supported] 为 false，调用方不该进来。
/// 原生缺方法（旧原生 + 新 Dart 的混搭不会出现在正式包里，但测试宿主会）一律按「不可用」处理。
class HomeWidgetChannel {
  HomeWidgetChannel({MethodChannel? channel})
    : _channel = channel ?? FushiChannels.homeWidgets;

  final MethodChannel _channel;

  static bool get supported => !kIsWeb && (Platform.isIOS || Platform.isMacOS);

  Future<bool> activitiesEnabled() async =>
      await _call<bool>('activitiesEnabled') ?? false;

  /// 起播放活动。`attributes.cover` 是本机封面的绝对路径，原生侧缩略后拷进 App Group。
  /// 成功返回活动 id；系统拒绝（用户关了实时活动、超出并发上限）为 null。
  Future<String?> startPlayback({
    required Map<String, Object?> attributes,
    required Map<String, Object?> state,
  }) => _call<String>('startPlayback', <String, Object?>{
    'attributes': attributes,
    'state': state,
  });

  Future<void> updatePlayback(String id, Map<String, Object?> state) =>
      _call<void>('updatePlayback', <String, Object?>{
        'id': id,
        'state': state,
      });

  Future<String?> startTask({
    required Map<String, Object?> attributes,
    required Map<String, Object?> state,
  }) => _call<String>('startTask', <String, Object?>{
    'attributes': attributes,
    'state': state,
  });

  Future<void> updateTask(String id, Map<String, Object?> state) =>
      _call<void>('updateTask', <String, Object?>{'id': id, 'state': state});

  /// 结束活动。[dismissAfter] 秒；null = 立即消失。[finalState] 非 null 时原生侧用它作为
  /// 最终内容**一步**结束（转录完成），不再单独发一次 update——两次调用在原生侧的执行顺序
  /// 没有保证。
  Future<void> endActivity(
    String id, {
    double? dismissAfter,
    Map<String, Object?>? finalState,
  }) => _call<void>('endActivity', <String, Object?>{
    'id': id,
    'dismissAfter': dismissAfter,
    'finalState': finalState,
  });

  /// 收掉上次进程留下的全部活动。原生侧在**收到调用时**取当时的活动快照，只结束这一批；
  /// 返回的 Future 在它们全部结束后完成，调用方等它完成再起新活动。
  Future<void> endAllActivities() => _call<void>('endAllActivities');

  /// 小组件 / Live Activity / 菜单栏按钮回调。返回 true = 接住了。
  void setActionHandler(
    Future<bool> Function(String action, String? argument)? handler,
  ) {
    _channel.setMethodCallHandler(
      handler == null
          ? null
          : (MethodCall call) async {
              if (call.method != 'action') return false;
              final Map<Object?, Object?> args =
                  (call.arguments as Map<Object?, Object?>?) ??
                  const <Object?, Object?>{};
              final Object? action = args['action'];
              if (action is! String) return false;
              final Object? argument = args['argument'];
              return handler(action, argument is String ? argument : null);
            },
    );
  }

  Future<T?> _call<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('[home-widgets] $method failed: ${e.code} ${e.message}');
      return null;
    }
  }
}
