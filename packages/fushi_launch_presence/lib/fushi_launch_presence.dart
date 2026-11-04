/// 本次 Flutter 引擎是不是带界面启动的（BUG-4072）。
///
/// 跑 `main()` 的引擎不一定有界面：Android 上系统媒体续播 / 媒体键 / 车机绑
/// `AudioService` 时，audio_service 在没有 Activity 的情况下新建引擎跑完整
/// `main()`；iOS 上后台拉起（BGTask / 后台刷新 / 推送）同理。这类会话收不到前台
/// 生命周期，会话标记若按「还在启动 = 前台」记，进程后来被后台回收就会误判成
/// 「启动即闪退」。原生侧如实回答，Dart 侧把会话记成 `headless`。
///
/// 原生实现：
/// * Android：`android/src/main/java/app/fushi/launchpresence/LaunchPresencePlugin.java`
///   （FlutterPlugin + ActivityAware，经 GeneratedPluginRegistrant 注册到**每个**引擎）。
/// * iOS：`fushi/ios/Runner/AppDelegate.swift` 的 `FushiLaunchPresence`。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 通道名。原生两端与契约守卫都按这个字面量对账。
const String kLaunchPresenceChannelName = 'app.fushi.reader/launch_presence';

/// 唯一的方法：返回 `{hasUi: bool, detail: String}`。
const String kLaunchPresenceQueryMethod = 'query';

/// 返回值里的键。
const String kLaunchPresenceHasUiKey = 'hasUi';
const String kLaunchPresenceDetailKey = 'detail';

/// 生产通道。
const MethodChannel launchPresenceChannel = MethodChannel(
  kLaunchPresenceChannelName,
);

/// 原生回答的启动形态。
@immutable
class LaunchPresence {
  const LaunchPresence({required this.hasUi, required this.detail});

  /// 引擎当下挂着界面（Android：有 Activity 附着；iOS：app 不在后台或有前台场景）。
  final bool hasUi;

  /// 原生给的取证细节（Activity 名 / 进程重要性 / applicationState），只进诊断文本。
  final String detail;

  /// 解析原生返回值；形状不对返回 null（当作不知道）。
  static LaunchPresence? fromMap(Map<Object?, Object?>? map) {
    if (map == null) return null;
    final Object? hasUi = map[kLaunchPresenceHasUiKey];
    if (hasUi is! bool) return null;
    final Object? detail = map[kLaunchPresenceDetailKey];
    return LaunchPresence(hasUi: hasUi, detail: detail is String ? detail : '');
  }
}

/// 问原生本次启动有没有界面。
///
/// 返回 null = 不知道：平台没有实现（桌面）、或这个引擎上没注册通道。调用方按
/// 旧逻辑处理，不据此推断任何东西。
Future<LaunchPresence?> queryLaunchPresence({
  MethodChannel channel = launchPresenceChannel,
}) async {
  try {
    return LaunchPresence.fromMap(
      await channel.invokeMapMethod<Object?, Object?>(
        kLaunchPresenceQueryMethod,
      ),
    );
  } on MissingPluginException {
    return null;
  }
}
