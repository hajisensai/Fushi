import 'dart:io';

import 'package:flutter/services.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart';

import 'package:fushi/src/utils/misc/channel_constants.dart';

/// 经 `app.fushi.reader/system_proxy` 读一次 Android 系统代理，换成
/// `findProxyFromEnvironment` 用的 environment 片段（无代理 → 空 map）。
///
/// 没注册通道的 engine（MissingPluginException）与读取失败都按「无系统代理」处理——
/// 与本层存在之前的直连行为一致；错误由 [resolveSystemProxyEnvironment] 记 debug 日志。
Future<Map<String, String>> readAndroidSystemProxyEnvironment({
  MethodChannel channel = FushiChannels.systemProxy,
}) async {
  final Map<Object?, Object?>? raw = await channel
      .invokeMethod<Map<Object?, Object?>>('getHttpProxy');
  if (raw == null) return const <String, String>{};
  final Object? port = raw['port'];
  return androidSystemProxyEnvironment(
    host: raw['host'] as String?,
    port: port is int ? port : int.tryParse('$port'),
    exclusionList: raw['exclusionList'] as String?,
  );
}

/// Android 上把系统代理读取器装进出站代理层（其余平台不装：桌面有原生读取，iOS 暂无通道）。
void installAndroidSystemProxyReader() {
  if (!Platform.isAndroid) return;
  installPlatformSystemProxyReader(readAndroidSystemProxyEnvironment);
}
