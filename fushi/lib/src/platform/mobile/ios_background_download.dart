/// 词典包下载的 iOS 后台传输（BUG-3887）。
///
/// iOS 上 app 切到后台几十秒即被挂起，进程内的 dio socket 随之停摆，几 GB 的推荐词典
/// 永远下不完（`beginBackgroundTask` 也只多给半分钟）。这里把传输交给系统后台
/// `URLSession`（原生 `ios/Runner/FushiBackgroundDownload.swift`）：下载在系统守护
/// 进程里跑，app 挂起期间照常推进，下完系统把 app 唤醒到后台交付文件。
///
/// 契约（方法名 / 参数名是跨语言契约，改一边必须改另一边）：
/// * Dart → 原生 `start {id, url, dest, proxyMode, proxyHost?, proxyPort?, meta?}`、
///   `cancel {id}`；
/// * 原生 → Dart `progress {id, received, total}`（total 未知为 -1）、
///   `complete {id, error?}`，error = `{kind, status?, message?}`，kind 取
///   [_kindCancel] / [_kindConnection] / [_kindStall] / [_kindBadResponse] / 其它；
/// * 跨进程接管：带 `meta`（[DictionaryDownloadHandoff] 的 JSON）发起的任务进原生
///   持久化注册表。`recover` → `[{id, meta}]` 列出注册表；`attach {id}` →
///   `{state: running|delivered|failed|missing, received?, total?, error?}` 答复它此刻的
///   结局；`forget {id}` 释放记录、`discard {id}` 取消任务 + 删已交付文件 + 释放记录。
///
/// 进程被系统回收：传输照常在守护进程里跑，新进程启动时原生侧把注册表里的任务接回
/// （进程不在时交付的文件照样挪到目标路径），只取消注册表里没有的真孤儿；Dart 侧由
/// `DictionaryDownloadController.resumeAdoptedDownloads` 经 [IosBackgroundDownloadTransport.recover]
/// 接手，续上候选回退，再走原导入流程。
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
import 'dart:convert';
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

  void succeed() {
    if (!completer.isCompleted) completer.complete();
  }

  void fail(Object error) {
    if (!completer.isCompleted) completer.completeError(error);
  }
}

/// 系统后台 `URLSession` 传输，实现 [DictionaryDownloadTransport] 与
/// [DictionaryDownloadRecovery] 契约。
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

  /// [DictionaryDownloadTransport] 的实现。[handoff] 非 null 时随任务交给原生
  /// 注册表（`meta`），进程被回收后新进程经 [recover] 接回。
  Future<void> download({
    required String url,
    required String destPath,
    required void Function(int received, int total) onReceiveProgress,
    CancelToken? cancelToken,
    DictionaryDownloadHandoff? handoff,
  }) async {
    final IosBackgroundDownloadProxy? proxy = _proxy();
    if (proxy == null || _channelMissing) {
      return _fallback(
        url: url,
        destPath: destPath,
        onReceiveProgress: onReceiveProgress,
        cancelToken: cancelToken,
        handoff: handoff,
      );
    }
    final CancelToken? token = cancelToken;
    if (token != null && token.isCancelled) {
      throw token.cancelError!;
    }

    final String id = 'dict-${_now().microsecondsSinceEpoch}-${_sequence++}';
    try {
      await _drive(
        id: id,
        url: url,
        onReceiveProgress: onReceiveProgress,
        cancelToken: cancelToken,
        persistent: handoff != null,
        begin: (_PendingDownload pending) =>
            _channel.invokeMethod<void>('start', <String, Object?>{
              'id': id,
              'url': url,
              'dest': destPath,
              ...proxy.toArguments(),
              if (handoff != null) 'meta': jsonEncode(handoff.toJson()),
            }),
      );
    } on MissingPluginException {
      // 没注册原生侧的引擎入口（弹窗词典等）：本进程从此一律走进程内传输。
      _channelMissing = true;
      return _fallback(
        url: url,
        destPath: destPath,
        onReceiveProgress: onReceiveProgress,
        cancelToken: cancelToken,
        handoff: handoff,
      );
    }
  }

  /// [DictionaryDownloadRecovery] 的实现：列出上一个进程登记、原生注册表里还在的
  /// 下载。记录坏了（解析不出接管描述）的没人接得住，当场 `discard`。
  Future<List<AdoptedDictionaryDownload>> recover() async {
    if (_channelMissing) return const <AdoptedDictionaryDownload>[];
    final List<Object?>? raw;
    try {
      raw = await _channel.invokeListMethod<Object?>('recover');
    } on MissingPluginException {
      _channelMissing = true;
      return const <AdoptedDictionaryDownload>[];
    } on PlatformException catch (e) {
      debugPrint('[BackgroundDownload] recover failed: $e');
      return const <AdoptedDictionaryDownload>[];
    }
    final List<AdoptedDictionaryDownload> adopted =
        <AdoptedDictionaryDownload>[];
    for (final Object? entry in raw ?? const <Object?>[]) {
      if (entry is! Map<Object?, Object?>) continue;
      final Object? id = entry['id'];
      if (id is! String) continue;
      DictionaryDownloadHandoff? handoff;
      final Object? meta = entry['meta'];
      if (meta is String) {
        try {
          handoff = DictionaryDownloadHandoff.tryParse(jsonDecode(meta));
        } on FormatException {
          handoff = null;
        }
      }
      if (handoff == null) {
        await _invokeQuietly('discard', id);
        continue;
      }
      adopted.add(_AdoptedIosDownload(this, id, handoff));
    }
    return adopted;
  }

  /// 接手一条上一个进程的记录：先挂上等待（之后到的原生事件都能路由过来），再问
  /// 原生此刻的结局——任务在进程不在时已经交付 / 失败的，结局就在答复里。
  Future<void> _attach(
    String id,
    DictionaryDownloadHandoff handoff, {
    required void Function(int received, int total) onReceiveProgress,
    CancelToken? cancelToken,
  }) {
    final String url = handoff.candidate;
    return _drive(
      id: id,
      url: url,
      onReceiveProgress: onReceiveProgress,
      cancelToken: cancelToken,
      persistent: true,
      begin: (_PendingDownload pending) async {
        final Map<Object?, Object?>? state = await _channel
            .invokeMapMethod<Object?, Object?>('attach', <String, Object?>{
              'id': id,
            });
        switch (state?['state']) {
          case 'running':
            final int received = (state!['received'] as num?)?.toInt() ?? 0;
            final int total = (state['total'] as num?)?.toInt() ?? -1;
            if (received > 0) {
              pending.receivedBytes = true;
              pending.lastActivity = _now();
              pending.onReceiveProgress(received, total);
            }
          case 'delivered':
            pending.succeed();
          case 'failed':
            final Object? error = state!['error'];
            pending.fail(
              _dioErrorFor(
                url,
                error is Map<Object?, Object?>
                    ? error
                    : const <Object?, Object?>{},
              ),
            );
          default:
            pending.fail(
              DioError(
                requestOptions: RequestOptions(path: url),
                message: 'background download $id is gone',
              ),
            );
        }
      },
    );
  }

  /// 一次原生任务的等待骨架：挂等待 → [begin]（发起 / 接手）→ 等原生 complete。
  /// 取消令牌与前台看门狗都在这里接；[persistent] 的任务结束后释放原生注册表记录
  /// （**先释放再返回**：返回后调用方就要导入并删文件，记录残留会让下一个进程拿一个
  /// 已经删掉的文件再导一次）。
  Future<void> _drive({
    required String id,
    required String url,
    required void Function(int received, int total) onReceiveProgress,
    required CancelToken? cancelToken,
    required bool persistent,
    required Future<void> Function(_PendingDownload pending) begin,
  }) async {
    final _PendingDownload pending = _PendingDownload(
      url,
      onReceiveProgress,
      _now(),
    );
    _pending[id] = pending;

    final CancelToken? token = cancelToken;
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
        await begin(pending);
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
      if (persistent) await _invokeQuietly('forget', id);
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

  Future<void> _cancelNative(String id) => _invokeQuietly('cancel', id);

  /// 只带 id 的原生调用（cancel / forget / discard）：失败只记日志——它们都在收尾
  /// 路径上，不能盖住真正的下载结局。
  Future<void> _invokeQuietly(String method, String id) async {
    try {
      await _channel.invokeMethod<void>(method, <String, Object?>{'id': id});
    } on PlatformException catch (e) {
      debugPrint('[BackgroundDownload] $method $id failed: $e');
    } on MissingPluginException catch (e) {
      debugPrint('[BackgroundDownload] $method $id: channel missing ($e)');
    }
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    final Map<Object?, Object?> args =
        (call.arguments as Map<Object?, Object?>?) ??
        const <Object?, Object?>{};
    final _PendingDownload? pending = _pending[args['id']];
    // 不认识的 id：还没被 Dart 接手的上一进程任务（结局记在原生注册表里，接手时
    // `attach` 会答复），或已被看门狗 / 取消了结的任务。
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
          pending.succeed();
        }
    }
    return null;
  }
}

/// 原生注册表里一条上一进程的记录，由 [IosBackgroundDownloadTransport.recover] 交出。
class _AdoptedIosDownload implements AdoptedDictionaryDownload {
  _AdoptedIosDownload(this._transport, this._id, this.handoff);

  final IosBackgroundDownloadTransport _transport;
  final String _id;
  bool _claimed = false;

  @override
  final DictionaryDownloadHandoff handoff;

  @override
  Future<void> wait({
    required void Function(int received, int total) onReceiveProgress,
    CancelToken? cancelToken,
  }) {
    if (_claimed) throw StateError('adopted download $_id already claimed');
    _claimed = true;
    return _transport._attach(
      _id,
      handoff,
      onReceiveProgress: onReceiveProgress,
      cancelToken: cancelToken,
    );
  }

  @override
  Future<void> discard() {
    _claimed = true;
    return _transport._invokeQuietly('discard', _id);
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
/// 同一个传输实例同时接上 [dictionaryDownloadRecovery]：通道 handler 只有一个，
/// 接手上一进程任务的事件也得路由到同一份 pending 表。
void installIosBackgroundDictionaryTransport() {
  if (!Platform.isIOS) return;
  if (dictionaryDownloadTransport != null) return;
  final IosBackgroundDownloadTransport transport =
      IosBackgroundDownloadTransport();
  dictionaryDownloadTransport = transport.download;
  dictionaryDownloadRecovery = transport.recover;
}
