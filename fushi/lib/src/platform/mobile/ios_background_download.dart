/// 词典包下载的 iOS 后台传输（BUG-3887）。
///
/// iOS 上 app 切到后台几十秒即被挂起，进程内的 dio socket 随之停摆，几 GB 的推荐词典
/// 永远下不完（`beginBackgroundTask` 也只多给半分钟）。这里把传输交给系统后台
/// `URLSession`（原生 `ios/Runner/FushiBackgroundDownload.swift`）：下载在系统守护
/// 进程里跑，app 挂起期间照常推进，下完系统把 app 唤醒到后台交付文件。
///
/// 契约（方法名 / 参数名是跨语言契约，改一边必须改另一边）：
/// * Dart → 原生 `start {id, url, dest, proxyMode, proxyHost?, proxyPort?}`、
///   `cancel {id}`；
/// * 原生 → Dart `progress {id, received, total}`（total 未知为 -1）、
///   `complete {id, error?}`，error = `{kind, status?, message?}`，kind 取
///   [_kindCancel] / [_kindConnection] / [_kindStall] / [_kindBadResponse] / 其它。
///
/// 失败一律翻译成 [DioError]：`DictionaryDownloader.download` 的候选回退、失败归因与
/// 「取消不算失败」全按 [DioError] 判，换传输不换契约。
///
/// 超时：后台会话会无限等网络（`waitsForConnectivity` 对它恒开），镜像回退因此永远
/// 轮不到。前台时由本文件的看门狗补上与 dio 同额的预算——首字节前
/// [kDictionaryConnectTimeout]、之后两次进度间 [kDictionaryStallTimeout]；app 不在
/// 前台时看门狗暂停（挂起期间原生进度送不到 Dart，按墙钟算会把正常下载误判成卡死）。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart';

/// 原生侧通道。只有 iOS 注册。
const MethodChannel kIosBackgroundDownloadChannel = MethodChannel(
  'app.fushi.reader/background_download',
);

const String _kindCancel = 'cancel';
const String _kindConnection = 'connection';
const String _kindStall = 'stall';
const String _kindBadResponse = 'badResponse';

/// 看门狗检查周期。
const Duration kIosBackgroundDownloadWatchdogTick = Duration(seconds: 1);

/// 交给原生会话的代理配置。原生会话装不上 `findProxy` 闭包，只能吃静态配置。
@immutable
class IosBackgroundDownloadProxy {
  const IosBackgroundDownloadProxy._(this.mode, [this.host, this.port]);

  /// 跟随系统代理（iOS 设置里的 Wi-Fi 代理 / VPN）。
  static const IosBackgroundDownloadProxy system = IosBackgroundDownloadProxy._(
    'system',
  );

  /// 不走任何代理。
  static const IosBackgroundDownloadProxy direct = IosBackgroundDownloadProxy._(
    'direct',
  );

  /// 手填的 HTTP 代理。
  factory IosBackgroundDownloadProxy.manual(String host, int port) =>
      IosBackgroundDownloadProxy._('manual', host, port);

  final String mode;
  final String? host;
  final int? port;

  Map<String, Object?> toArguments() => <String, Object?>{
    'proxyMode': mode,
    if (host != null) 'proxyHost': host,
    if (port != null) 'proxyPort': port,
  };

  @override
  bool operator ==(Object other) =>
      other is IosBackgroundDownloadProxy &&
      other.mode == mode &&
      other.host == host &&
      other.port == port;

  @override
  int get hashCode => Object.hash(mode, host, port);
}

/// **纯函数**：全应用代理裁决 → 原生会话配置。返回 null 表示原生会话表达不了
/// 这份配置，调用方必须退回进程内传输（否则会静默绕开用户的代理选择）。
///
/// * 自动 → 系统代理（iOS 上 app 能读到的「系统代理」就是这一份，与 dio 侧一致）；
/// * 直连 → 直连；
/// * 手动 → 手填地址；地址非法时与 dio 侧一样安全直连；
/// * 手动 + 认证 → null：后台会话的代理 407 质询只能在 app 活着时应答，挂起期间
///   应答不了，强行交给它等于后台必失败。
IosBackgroundDownloadProxy? iosBackgroundDownloadProxyFor({
  required String mode,
  required String proxy,
  required String username,
}) {
  switch (mode) {
    case kProxyModeDirect:
      return IosBackgroundDownloadProxy.direct;
    case kProxyModeManual:
      if (username.isNotEmpty) return null;
      final String? hostPort = normalizeUserProxyHostPort(proxy);
      if (hostPort == null) return IosBackgroundDownloadProxy.direct;
      final int colon = hostPort.lastIndexOf(':');
      return IosBackgroundDownloadProxy.manual(
        hostPort.substring(0, colon),
        int.parse(hostPort.substring(colon + 1)),
      );
    default:
      return IosBackgroundDownloadProxy.system;
  }
}

/// 此刻的应用代理裁决对应的原生会话配置（见 [iosBackgroundDownloadProxyFor]）。
IosBackgroundDownloadProxy? currentIosBackgroundDownloadProxy() {
  final ({String mode, String proxy}) decision = resolveAppProxyDecision();
  return iosBackgroundDownloadProxyFor(
    mode: decision.mode,
    proxy: decision.proxy,
    username: appUserProxyUsernameReader(),
  );
}

/// 当前 app 是否在前台（看门狗只在前台计时）。
bool _appInForeground() {
  final AppLifecycleState? state = WidgetsBinding.instance.lifecycleState;
  return state == null || state == AppLifecycleState.resumed;
}

class _PendingDownload {
  _PendingDownload(this.url, this.onReceiveProgress, this.lastActivity);

  final String url;
  final void Function(int received, int total) onReceiveProgress;
  final Completer<void> completer = Completer<void>();
  bool receivedBytes = false;
  DateTime lastActivity;

  void fail(Object error) {
    if (!completer.isCompleted) completer.completeError(error);
  }
}

/// 系统后台 `URLSession` 传输，实现 [DictionaryDownloadTransport] 契约。
class IosBackgroundDownloadTransport {
  IosBackgroundDownloadTransport({
    MethodChannel channel = kIosBackgroundDownloadChannel,
    bool Function()? isForeground,
    DateTime Function()? now,
    IosBackgroundDownloadProxy? Function()? proxy,
    DictionaryDownloadTransport fallback = dioDictionaryDownloadTransport,
    Duration connectTimeout = kDictionaryConnectTimeout,
    Duration stallTimeout = kDictionaryStallTimeout,
    Duration watchdogTick = kIosBackgroundDownloadWatchdogTick,
  }) : _channel = channel,
       _isForeground = isForeground ?? _appInForeground,
       _now = now ?? DateTime.now,
       _proxy = proxy ?? currentIosBackgroundDownloadProxy,
       _fallback = fallback,
       _connectTimeout = connectTimeout,
       _stallTimeout = stallTimeout,
       _watchdogTick = watchdogTick {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  final MethodChannel _channel;
  final bool Function() _isForeground;
  final DateTime Function() _now;
  final IosBackgroundDownloadProxy? Function() _proxy;

  /// 原生会话用不了时的退路（代理带认证 / 本引擎没注册通道）。
  final DictionaryDownloadTransport _fallback;
  bool _channelMissing = false;
  final Duration _connectTimeout;
  final Duration _stallTimeout;
  final Duration _watchdogTick;

  final Map<String, _PendingDownload> _pending = <String, _PendingDownload>{};
  int _sequence = 0;

  /// 当前在途的下载 id（测试 / 诊断用）。
  Iterable<String> get pendingIds => _pending.keys;

  /// [DictionaryDownloadTransport] 的实现。
  Future<void> download({
    required String url,
    required String destPath,
    required void Function(int received, int total) onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    final IosBackgroundDownloadProxy? proxy = _proxy();
    if (proxy == null || _channelMissing) {
      return _fallback(
        url: url,
        destPath: destPath,
        onReceiveProgress: onReceiveProgress,
        cancelToken: cancelToken,
      );
    }
    final CancelToken? token = cancelToken;
    if (token != null && token.isCancelled) {
      throw token.cancelError!;
    }

    final String id = 'dict-${_now().microsecondsSinceEpoch}-${_sequence++}';
    final _PendingDownload pending = _PendingDownload(
      url,
      onReceiveProgress,
      _now(),
    );
    _pending[id] = pending;

    unawaited(
      token?.whenCancel.then((DioError error) {
        if (pending.completer.isCompleted) return;
        pending.fail(error);
        unawaited(_cancelNative(id));
      }),
    );
    final Timer watchdog = Timer.periodic(
      _watchdogTick,
      (_) => _checkWatchdog(id, pending),
    );

    try {
      try {
        await _channel.invokeMethod<void>('start', <String, Object?>{
          'id': id,
          'url': url,
          'dest': destPath,
          ...proxy.toArguments(),
        });
      } on MissingPluginException {
        // 没注册原生侧的引擎入口（弹窗词典等）：本进程从此一律走进程内传输。
        _channelMissing = true;
        _pending.remove(id);
        watchdog.cancel();
        return await _fallback(
          url: url,
          destPath: destPath,
          onReceiveProgress: onReceiveProgress,
          cancelToken: cancelToken,
        );
      } on PlatformException catch (e) {
        pending.fail(
          DioError(
            requestOptions: RequestOptions(path: url),
            error: e,
            message: e.message,
          ),
        );
      }
      await pending.completer.future;
    } finally {
      watchdog.cancel();
      _pending.remove(id);
    }
  }

  void _checkWatchdog(String id, _PendingDownload pending) {
    if (pending.completer.isCompleted) return;
    final DateTime now = _now();
    if (!_isForeground()) {
      // 不在前台：挂起期间进度送不过来，不能把这段算进「没动静」。
      pending.lastActivity = now;
      return;
    }
    final Duration budget = pending.receivedBytes
        ? _stallTimeout
        : _connectTimeout;
    if (now.difference(pending.lastActivity) < budget) return;
    pending.fail(
      DioError(
        requestOptions: RequestOptions(path: pending.url),
        type: pending.receivedBytes
            ? DioErrorType.receiveTimeout
            : DioErrorType.connectionTimeout,
        message: 'no data for ${budget.inSeconds}s',
      ),
    );
    unawaited(_cancelNative(id));
  }

  Future<void> _cancelNative(String id) async {
    try {
      await _channel.invokeMethod<void>('cancel', <String, Object?>{'id': id});
    } on PlatformException catch (e) {
      debugPrint('[BackgroundDownload] cancel $id failed: $e');
    } on MissingPluginException catch (e) {
      debugPrint('[BackgroundDownload] cancel $id: channel missing ($e)');
    }
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    final Map<Object?, Object?> args =
        (call.arguments as Map<Object?, Object?>?) ??
        const <Object?, Object?>{};
    final _PendingDownload? pending = _pending[args['id']];
    // 不认识的 id：上一个进程留下的任务，或已被看门狗 / 取消了结的任务。
    if (pending == null || pending.completer.isCompleted) return null;
    switch (call.method) {
      case 'progress':
        final int received = (args['received'] as num?)?.toInt() ?? 0;
        final int total = (args['total'] as num?)?.toInt() ?? -1;
        pending.lastActivity = _now();
        if (received > 0) pending.receivedBytes = true;
        pending.onReceiveProgress(received, total);
      case 'complete':
        final Object? error = args['error'];
        if (error is Map<Object?, Object?>) {
          pending.fail(_dioErrorFor(pending.url, error));
        } else {
          pending.completer.complete();
        }
    }
    return null;
  }
}

/// 原生失败 → [DioError]（类型与 dio 传输同一失败的类型逐一对齐）。
DioError _dioErrorFor(String url, Map<Object?, Object?> error) {
  final RequestOptions request = RequestOptions(path: url);
  final String? message = error['message'] as String?;
  switch (error['kind']) {
    case _kindCancel:
      return DioError(
        requestOptions: request,
        type: DioErrorType.cancel,
        message: message,
      );
    case _kindConnection:
      return DioError(
        requestOptions: request,
        type: DioErrorType.connectionError,
        message: message,
      );
    case _kindStall:
      return DioError(
        requestOptions: request,
        type: DioErrorType.receiveTimeout,
        message: message,
      );
    case _kindBadResponse:
      final int? status = (error['status'] as num?)?.toInt();
      return DioError(
        requestOptions: request,
        type: DioErrorType.badResponse,
        response: Response<void>(requestOptions: request, statusCode: status),
        message: message ?? 'HTTP $status',
      );
    default:
      return DioError(requestOptions: request, message: message);
  }
}

/// 在 iOS 上把词典包下载接到系统后台会话（启动时调一次，幂等；其余平台 no-op）。
/// 用户配了带认证的手动代理、或本引擎入口没注册原生通道时退回进程内 dio。
void installIosBackgroundDictionaryTransport() {
  if (!Platform.isIOS) return;
  if (dictionaryDownloadTransport != null) return;
  dictionaryDownloadTransport = IosBackgroundDownloadTransport().download;
}
