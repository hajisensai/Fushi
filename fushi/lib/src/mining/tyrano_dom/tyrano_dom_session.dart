// TyranoScript（Electron / NW.js）游戏的 DOM 数据源：经 Chrome DevTools Protocol 从游戏
// 页面实时取当前台词与每个字形在客户区的物理像素矩形。
//
// 流程：轮询 `/json/list` 直到出现 page 目标（有总超时）→ 连 WebSocket →
// `Runtime.addBinding` 注册回推函数 → `Page.addScriptToEvaluateOnNewDocument` 让读档 /
// 重载后的新文档自动带上观察脚本 → `Runtime.evaluate` 给当前文档补注一次。之后快照全由
// 页面里的观察脚本主动推回（`Runtime.bindingCalled`），Dart 侧不轮询 evaluate。
// WebSocket 断开（游戏退出 / 页面目标销毁）时帧流结束，[TyranoDomSession.done] 给出原因。

import 'dart:async';
import 'dart:convert';

import 'package:fushi/src/mining/tyrano_dom/tyrano_dom_cdp.dart';
import 'package:fushi/src/mining/tyrano_dom/tyrano_dom_frame.dart';
import 'package:fushi/src/mining/tyrano_dom/tyrano_dom_observer_script.dart';
import 'package:fushi/src/mining/tyrano_dom/tyrano_dom_voice.dart';

/// 会话结束原因。
enum TyranoDomEndReason {
  /// 调用了 [TyranoDomSession.close]。
  closed,

  /// WebSocket 被对端断开（游戏退出、页面目标销毁、调试连接被抢走）。
  disconnected,
}

/// 等不到游戏页面或连不上调试端口。
class TyranoDomConnectException implements Exception {
  /// 创建异常。
  const TyranoDomConnectException(this.message);

  /// 原因。
  final String message;

  @override
  String toString() => 'TyranoDomConnectException: $message';
}

/// DOM 数据源会话的消费面（会话控制器只依赖它，测试可替换）。
abstract interface class TyranoDomFrameSource {
  /// 快照流（单订阅）；会话结束时关闭。
  Stream<TyranoDomFrame> get frames;

  /// 最近一帧。
  TyranoDomFrame? get latest;

  /// 语音事件流（单订阅）；会话结束时关闭。事件的 [TyranoDomVoiceEvent.pageUrl] 由
  /// 会话按 CDP 目标填写。与 [frames] 走同一个绑定，页面里的先后顺序保持不变。
  Stream<TyranoDomVoiceEvent> get voices;

  /// 会话结束时完成。
  Future<TyranoDomEndReason> get done;

  /// 断开并卸载观察脚本。
  Future<void> close();
}

/// 一个游戏页面的 DOM 数据源会话。
class TyranoDomSession implements TyranoDomFrameSource {
  TyranoDomSession._(this._connection, this._pageUrl) {
    _eventSubscription = _connection.events.listen(_onEvent);
    unawaited(
      _connection.closed.then(
        (void _) => _finish(TyranoDomEndReason.disconnected),
      ),
    );
  }

  /// 连接 `host:port` 上的游戏页面。
  ///
  /// 游戏刚启动时调试端口 / 页面目标还没出现：每 [pollInterval] 拉一次 `/json/list`，直到
  /// 出现 page 目标；超过 [timeout] 抛 [TyranoDomConnectException]。
  static Future<TyranoDomSession> connect({
    required int port,
    String host = '127.0.0.1',
    Duration timeout = const Duration(seconds: 60),
    Duration pollInterval = const Duration(milliseconds: 250),
  }) async {
    final Stopwatch clock = Stopwatch()..start();
    CdpTarget? target;
    while (true) {
      final List<CdpTarget>? targets = await fetchCdpTargets(host, port);
      if (targets != null) target = selectGamePageTarget(targets);
      if (target != null) break;
      if (clock.elapsed + pollInterval > timeout) {
        throw TyranoDomConnectException(
          targets == null
              ? 'debug port $host:$port not reachable within $timeout'
              : 'no page target on $host:$port within $timeout',
        );
      }
      await Future<void>.delayed(pollInterval);
    }
    final CdpConnection connection;
    try {
      connection = await CdpConnection.connect(target.webSocketDebuggerUrl!);
    } on Object catch (error) {
      throw TyranoDomConnectException('websocket connect failed: $error');
    }
    final TyranoDomSession session = TyranoDomSession._(connection, target.url);
    try {
      await session._install();
    } on Object catch (error) {
      await session.close();
      throw TyranoDomConnectException('observer install failed: $error');
    }
    return session;
  }

  final CdpConnection _connection;
  late final StreamSubscription<CdpIncoming> _eventSubscription;
  final StreamController<TyranoDomFrame> _frames =
      StreamController<TyranoDomFrame>();
  final StreamController<TyranoDomVoiceEvent> _voices =
      StreamController<TyranoDomVoiceEvent>();
  String _pageUrl;
  final TyranoDomFrameAssembler _assembler = TyranoDomFrameAssembler();
  final Completer<TyranoDomEndReason> _done = Completer<TyranoDomEndReason>();
  String? _newDocumentScriptId;
  TyranoDomFrame? _latest;

  /// 快照流（单订阅，订阅前的帧会缓冲）；会话结束时关闭。
  @override
  Stream<TyranoDomFrame> get frames => _frames.stream;

  /// 最近一帧。
  @override
  TyranoDomFrame? get latest => _latest;

  @override
  Stream<TyranoDomVoiceEvent> get voices => _voices.stream;

  /// 游戏页面当前 URL（连接时取自 CDP 目标，主框架导航时更新）。
  String get pageUrl => _pageUrl;

  /// 会话结束时完成。
  @override
  Future<TyranoDomEndReason> get done => _done.future;

  /// 会话是否已结束。
  bool get isEnded => _done.isCompleted;

  Future<void> _install() async {
    await _connection.send('Runtime.addBinding', <String, Object?>{
      'name': kTyranoDomBindingName,
    });
    await _connection.send('Page.enable');
    final Map<String, Object?> added = await _connection.send(
      'Page.addScriptToEvaluateOnNewDocument',
      <String, Object?>{'source': kTyranoDomObserverScript},
    );
    final Object? identifier = added['identifier'];
    if (identifier is String) _newDocumentScriptId = identifier;
    final Map<String, Object?> evaluated = await _connection.send(
      'Runtime.evaluate',
      <String, Object?>{'expression': kTyranoDomObserverScript},
    );
    final Object? exception = evaluated['exceptionDetails'];
    if (exception != null) {
      throw CdpCommandException('Runtime.evaluate', '$exception');
    }
  }

  void _onEvent(CdpIncoming event) {
    if (event.method == 'Page.frameNavigated') {
      final Object? frame = event.params?['frame'];
      if (frame is Map<String, Object?> &&
          frame['parentId'] == null &&
          frame['url'] is String) {
        _pageUrl = frame['url']! as String;
      }
      return;
    }
    if (event.method != 'Runtime.bindingCalled') return;
    final Map<String, Object?>? params = event.params;
    if (params == null || params['name'] != kTyranoDomBindingName) return;
    final Object? payloadText = params['payload'];
    if (payloadText is! String) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(payloadText);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, Object?>) return;
    // 带 `k` 的是语音消息（k == "voice"），其余是快照。
    if (decoded.containsKey('k')) {
      if (decoded['v'] != kTyranoDomPayloadVersion) return;
      final TyranoDomVoiceEvent? voice = parseTyranoDomVoicePayload(decoded);
      if (voice != null && !_voices.isClosed) {
        _voices.add(voice.withPageUrl(_pageUrl));
      }
      return;
    }
    final TyranoDomPayload? payload = parseTyranoDomPayloadMap(decoded);
    if (payload == null || _frames.isClosed) return;
    final TyranoDomFrame frame = _assembler.assemble(payload);
    _latest = frame;
    _frames.add(frame);
  }

  void _finish(TyranoDomEndReason reason) {
    if (_done.isCompleted) return;
    _done.complete(reason);
    unawaited(_eventSubscription.cancel());
    unawaited(_frames.close());
    unawaited(_voices.close());
  }

  /// 卸载观察脚本并断开。游戏已退出时直接结束。
  @override
  Future<void> close() async {
    if (_done.isCompleted) return;
    if (!_connection.isClosed) {
      final List<Future<Object?>> cleanup = <Future<Object?>>[
        _connection.send('Runtime.evaluate', <String, Object?>{
          'expression': kTyranoDomDisposeExpression,
        }),
        _connection.send('Runtime.removeBinding', <String, Object?>{
          'name': kTyranoDomBindingName,
        }),
        if (_newDocumentScriptId != null)
          _connection.send(
            'Page.removeScriptToEvaluateOnNewDocument',
            <String, Object?>{'identifier': _newDocumentScriptId},
          ),
      ];
      try {
        await Future.wait(cleanup).timeout(const Duration(seconds: 2));
      } on Object {
        // 清理失败不影响关闭：页面里的观察脚本没有绑定可调就不再推送。
      }
    }
    _finish(TyranoDomEndReason.closed);
    await _connection.close();
  }
}
