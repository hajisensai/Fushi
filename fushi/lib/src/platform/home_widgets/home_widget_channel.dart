import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:fushi/src/utils/misc/channel_constants.dart';

/// 小组件 / Live Activity 的原生通道门面（`fushi/apple/HomeWidgets/FushiHomeWidgets.swift`）。
///
/// 只有 iOS / macOS 有原生实现；其它平台 [supported] 为 false，调用方不该进来。
/// 原生缺方法（旧原生 + 新 Dart 的混搭不会出现在正式包里，但测试宿主会）一律按「不可用」处理。
class HomeWidgetChannel {
  HomeWidgetChannel({MethodChannel? channel})
    : _channel = channel ?? FushiChannels.homeWidgets;

  final MethodChannel _channel;

  static bool get supported => Platform.isIOS || Platform.isMacOS;

  /// App Group 里的 `home_widgets/` 目录；没签 App Group 为 null（不写快照）。
  Future<String?> containerPath() => _call<String>('containerPath');

  Future<void> reloadWidgets() => _call<bool>('reloadWidgets');

  Future<bool> activitiesEnabled() async =>
      await _call<bool>('activitiesEnabled') ?? false;

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

  /// [dismissAfter] 秒；null = 立即消失。
  Future<void> endActivity(String id, {double? dismissAfter}) => _call<void>(
    'endActivity',
    <String, Object?>{'id': id, 'dismissAfter': dismissAfter},
  );

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
