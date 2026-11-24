import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kDebugMode;

import 'package:fushi/src/utils/window_caption_channel.dart';

/// Dart 失联检测的 Dart 侧：每秒经 `app.fushi/window` 向 Windows runner 报一次平安。
///
/// runner 的看门狗（`windows/runner/hang_watchdog.cpp`）只量得到「主线程不泵消息」。
/// 还有一种事故它看不见：平台线程空闲、窗口消息照常处理，但 Dart 事件循环不再运转
/// （界面停在底色黑屏、本地端口不回话、从外部缩放窗口也无反应）。心跳走 Dart
/// [Timer]，Dart 侧一停它就停；runner 在主线程仍泵消息而心跳连续静默 ≥10 s 时抓
/// hang dump 并写 `hang_watchdog.log`。
const Duration kDartHeartbeatInterval = Duration(seconds: 1);

Timer? _heartbeatTimer;

/// 在 `main()` 里调一次（仅 Windows 的 profile / release 生效，重复调用无效果）。
/// debug 构建不发心跳：Dart 断点 / VM service 暂停会让 isolate 停住任意久，而 runner
/// 的 `IsDebuggerPresent()` 只认原生调试器、认不出 Dart 调试器，发了就会把每次断点
/// 都抓成 hang dump。[send]、[interval]、[isWindows]、[isDebug] 供测试注入。
void installDartHeartbeat({
  Future<void> Function()? send,
  Duration interval = kDartHeartbeatInterval,
  bool? isWindows,
  bool? isDebug,
}) {
  if (!(isWindows ?? Platform.isWindows)) return;
  if (isDebug ?? kDebugMode) return;
  if (_heartbeatTimer != null) return;
  final Future<void> Function() beat =
      send ?? WindowCaptionChannel.dartHeartbeat;
  _heartbeatTimer = Timer.periodic(interval, (Timer _) {
    unawaited(beat());
  });
}

/// 测试用：停掉并清掉心跳定时器。
void resetDartHeartbeatForTest() {
  _heartbeatTimer?.cancel();
  _heartbeatTimer = null;
}
