/// 复习写入转交（`srs_write_relay.dart`）在 Android 上的两条 MethodChannel（BUG-5542）。
///
/// - [srsWriteRelayForward]（辅助进程，`app.fushi.reader/srs_write_relay`）：原生 `SrsWriteRelayClient` 绑定主进程的
///   `SrsWriteRelayService`，把请求交过去、等回包。主进程不在时绑定会把它拉起来。
/// - [SrsWriteRelayHostChannel]（主进程的执行引擎，`app.fushi.reader/srs_write_relay_host`）：原生 `SrsWriteRelay`
///   在这里调 `execute`（执行一条请求）/ `release`（交出主库：做完手上的请求、关库）；Dart 调 `ready`（处理器已装好，
///   可以派活）与 `claimPrimary`（主界面的引擎开主库之前：原生先让无界面的执行引擎交出主库，同一进程里不同时有两个
///   Primary）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// 辅助进程一侧：把一条请求交给主进程，等回包。
const MethodChannel _clientChannel = MethodChannel(
  'app.fushi.reader/srs_write_relay',
);

/// 主进程执行引擎一侧。
const MethodChannel _hostChannel = MethodChannel(
  'app.fushi.reader/srs_write_relay_host',
);

/// [SrsWriteRelayTransport] 的 Android 实现。原生侧有超时，主进程起不来 / 中途死掉时以 [PlatformException] 结束。
Future<Map<String, Object?>> srsWriteRelayForward(
  Map<String, Object?> request,
) async {
  final String? reply = await _clientChannel.invokeMethod<String>(
    'forward',
    jsonEncode(request),
  );
  if (reply == null) {
    throw StateError('srs write relay: empty reply from the main process');
  }
  return (jsonDecode(reply) as Map<Object?, Object?>).cast<String, Object?>();
}

/// 主进程执行引擎的通道（主界面的引擎、或服务拉起的无界面执行引擎各装一次）。
abstract final class SrsWriteRelayHostChannel {
  /// 装上处理器并告诉原生「可以派活了」。[execute] 执行一条请求（回包永不抛）；[release] 交出主库（无界面执行引擎
  /// 才有：做完手上的请求、关库；主界面的引擎不交）。
  static Future<void> install({
    required Future<Map<String, Object?>> Function(Map<String, Object?>)
    execute,
    Future<void> Function()? release,
  }) async {
    _hostChannel.setMethodCallHandler((MethodCall call) async {
      switch (call.method) {
        case 'execute':
          final Map<String, Object?> request =
              (jsonDecode(call.arguments as String) as Map<Object?, Object?>)
                  .cast<String, Object?>();
          return jsonEncode(await execute(request));
        case 'release':
          await release?.call();
          return true;
        default:
          throw MissingPluginException(call.method);
      }
    });
    await _hostChannel.invokeMethod<void>('ready');
  }

  /// 主界面的引擎开主库之前调：原生让无界面执行引擎（若有）做完手上的请求、关库、销毁之后才返回。
  /// 本引擎没装原生一端（没有 MainActivity 的宿主，例如集成测试的裸引擎）时就没有别的执行引擎，直接返回。
  static Future<void> claimPrimary() async {
    try {
      await _hostChannel.invokeMethod<void>('claimPrimary');
    } on MissingPluginException {
      // 没有原生一端：本进程里也就不会有替辅助进程执行写入的引擎。
    }
  }
}
