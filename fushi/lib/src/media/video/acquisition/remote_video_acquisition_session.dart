/// 「AI 下视频」的远端会话：状态机跑在已配对的电脑上（用电脑自己的 AI 指派与下载
/// 管线），手机只长轮询快照、发动作。对话页不区分它与本机会话。
library;

import 'dart:async';

import 'package:fushi_engine/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_view.dart';
import 'package:fushi/src/sync/interconnect_assistant_client.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/sync/assistant/host_assistant.dart';

/// 远端会话停下来的失败提示码（再试也不会好，停止轮询）：凭据被拒 / 证书不符 /
/// 已不在配对表。与 [kVideoAcquisitionFailureRemoteUnavailable]（会自己恢复）区分。
const String kRemoteVideoAcquisitionAuthRejected = 'remote_auth_rejected';
const String kRemoteVideoAcquisitionCertificateMismatch =
    'remote_certificate_mismatch';
const String kRemoteVideoAcquisitionNotPaired = 'remote_not_paired';

class RemoteVideoAcquisitionSession implements VideoAcquisitionSession {
  RemoteVideoAcquisitionSession._({
    required InterconnectAssistantClient client,
    required HostAssistantTarget target,
    required HostAssistantEnvelope first,
    required Duration retryDelay,
    required Duration longPollWait,
  }) : _client = client,
       _target = target,
       _id = first.id,
       _revision = first.revision,
       _hostView = VideoAcquisitionView.fromJson(first.view),
       _retryDelay = retryDelay,
       _longPollWait = longPollWait {
    unawaited(_pollLoop());
  }

  /// 在 [target] 上开一场会话。失败原样抛 [HostAssistantException]（409 的 detail 是
  /// host 的 reason 短码），由入口翻成引导文案；此时 [client] 仍归调用方。
  ///
  /// 开成功后会话接管 [client]：[dispose] 关完 host 上的会话再释放它。
  static Future<RemoteVideoAcquisitionSession> open({
    required InterconnectAssistantClient client,
    required HostAssistantTarget target,
    required String locale,
    Duration retryDelay = const Duration(seconds: 3),
    Duration longPollWait = InterconnectAssistantClient.longPollWait,
  }) async {
    final HostAssistantEnvelope first = await client.open(
      target,
      feature: kHostAssistantFeatureVideoAcquire,
      locale: locale,
    );
    return RemoteVideoAcquisitionSession._(
      client: client,
      target: target,
      first: first,
      retryDelay: retryDelay,
      longPollWait: longPollWait,
    );
  }

  final InterconnectAssistantClient _client;
  final HostAssistantTarget _target;
  final String _id;
  final Duration _retryDelay;
  final Duration _longPollWait;
  final StreamController<VideoAcquisitionView> _views =
      StreamController<VideoAcquisitionView>.broadcast();

  int _revision;
  VideoAcquisitionView _hostView;

  /// 本地插入的失败提示：(插在 host 记录的第几条之后, 提示)。位置固定，host 记录
  /// 长大后提示留在原处——页面按失败条数判断「新失败」，条数不能倒退。
  final List<(int, VideoAcquisitionMessage)> _notices =
      <(int, VideoAcquisitionMessage)>[];

  _RemoteState _state = _RemoteState.live;
  bool _disposed = false;

  /// 停下来了（[_RemoteState.gone] / [_RemoteState.halted]）：不再轮询、不再发请求。
  bool get _stopped =>
      _state == _RemoteState.gone || _state == _RemoteState.halted;

  String get deviceLabel => _target.label;

  @override
  VideoAcquisitionView get view => _compose();

  @override
  Stream<VideoAcquisitionView> get views => _views.stream;

  @override
  Future<void> submitText(String text) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return Future<void>.value();
    return _act(<String, Object?>{'type': 'text', 'text': trimmed});
  }

  @override
  Future<void> choose(
    VideoAcquisitionSlot slot,
    String optionId, {
    bool? remember,
  }) => _act(<String, Object?>{
    'type': 'choose',
    'slot': slot.name,
    'optionId': optionId,
    if (remember != null) 'remember': remember,
  });

  @override
  Future<void> confirm() => _act(const <String, Object?>{'type': 'confirm'});

  @override
  Future<void> cancel() => _act(const <String, Object?>{'type': 'cancel'});

  @override
  Future<void> restart() => _act(const <String, Object?>{'type': 'restart'});

  @override
  Future<void> toggleFranchiseEntry(int index) =>
      _act(<String, Object?>{'type': 'toggleFranchise', 'index': index});

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _views.close();
    if (_stopped) {
      // 会话已没了 / 凭据证书不认：关会话的请求也不会成功，直接释放 client。
      _client.dispose();
      return;
    }
    // 页面退出即关 host 上的会话；失败只记诊断（host 闲置回收兜底）。关完再释放
    // client（在途的长轮询随之以 cancelled 收尾）。
    unawaited(_closeHostSession().whenComplete(_client.dispose));
  }

  Future<void> _closeHostSession() async {
    try {
      await _client.close(_target, _id);
    } on Object catch (error) {
      ErrorLogService.instance.logDiagnostic(
        'RemoteVideoAcquisition.close',
        '${_target.label}: $error',
      );
    }
  }

  Future<void> _act(Map<String, Object?> action) async {
    // 停下来之后不再发请求：失败提示在进入该状态时已经插过一次。
    if (_disposed || _stopped) return;
    try {
      _apply(await _client.act(_target, _id, action));
    } on Object catch (error) {
      _onError(error, 'act');
    }
  }

  Future<void> _pollLoop() async {
    // 每次读都经通道重新选路：同一台 host 换了可达地址照样续得上。
    while (!_disposed && !_stopped) {
      try {
        final HostAssistantEnvelope envelope = await _client.read(
          _target,
          _id,
          after: _revision,
          wait: _longPollWait,
        );
        _apply(envelope);
      } on Object catch (error) {
        _onError(error, 'poll');
        if (_disposed || _stopped) return;
        // 连不上是长轮询会话的常态（换网、休眠），按固定节奏再读。
        await Future<void>.delayed(_retryDelay);
      }
    }
  }

  void _apply(HostAssistantEnvelope envelope) {
    if (_disposed || _stopped) return;
    final bool recovered = _state == _RemoteState.unreachable;
    _state = _RemoteState.live;
    if (envelope.revision <= _revision && !recovered) return;
    _revision = envelope.revision;
    _hostView = VideoAcquisitionView.fromJson(envelope.view);
    _emit();
  }

  void _onError(Object error, String where) {
    if (_disposed) return;
    // 本机 client 已关（dispose 路径）：不是 host 的问题，静默。
    if (error is HostAssistantException && error.cancelled) return;
    ErrorLogService.instance.logDiagnostic(
      'RemoteVideoAcquisition.$where',
      '${_target.label}: $error',
    );
    if (_stopped) return;
    if (error is HostAssistantException && error.permanent) {
      _enter(_RemoteState.halted, _haltedMessage(error.code));
    } else if (error is HostAssistantException && error.sessionGone) {
      _enter(_RemoteState.gone, kVideoAcquisitionFailureRemoteUnavailable);
    } else {
      _enter(
        _RemoteState.unreachable,
        kVideoAcquisitionFailureRemoteUnavailable,
      );
    }
  }

  /// 永久失败的提示码。
  static String _haltedMessage(String code) => switch (code) {
    'certificate_mismatch' => kRemoteVideoAcquisitionCertificateMismatch,
    'no_host' => kRemoteVideoAcquisitionNotPaired,
    _ => kRemoteVideoAcquisitionAuthRejected,
  };

  /// 转入非 live 状态。提示只在「从 live 断开」与「转为永久失败」时插一条：持续
  /// 连不上、连不上之后发现会话没了都不重复提示。
  void _enter(_RemoteState next, String message) {
    final _RemoteState previous = _state;
    _state = next;
    final bool notify = next == _RemoteState.halted
        ? previous != _RemoteState.halted
        : previous == _RemoteState.live;
    if (!notify) return;
    _notices.add((
      _hostView.transcript.length,
      VideoAcquisitionAssistantMessage(
        VideoAcquisitionSay(
          VideoAcquisitionSayKind.failed,
          args: <String, Object?>{'message': message},
        ),
      ),
    ));
    _emit();
  }

  void _emit() {
    if (_disposed) return;
    _views.add(_compose());
  }

  VideoAcquisitionView _compose() {
    final VideoAcquisitionView host = _hostView;
    final bool offline = _state != _RemoteState.live;
    if (_notices.isEmpty && !offline) return host;
    final List<VideoAcquisitionMessage> transcript = <VideoAcquisitionMessage>[
      ...host.transcript,
    ];
    // 从后往前插，前面的位置不受影响。
    for (final (int at, VideoAcquisitionMessage notice) in _notices.reversed) {
      transcript.insert(at.clamp(0, transcript.length), notice);
    }
    return host.copyWith(
      transcript: transcript,
      // 连不上时 host 的 busy 不可信（可能永远等不到结束），放开输入让用户能重试。
      busy: offline ? false : host.busy,
      failureHint: offline ? VideoAcquisitionFailureHint.none : null,
    );
  }
}

/// 远端会话的连接状态。
enum _RemoteState {
  /// 收到过快照、连接正常。
  live,

  /// 暂时连不上：继续按固定节奏轮询，通道每次都重新选路。
  unreachable,

  /// host 上的会话没了（过期 / host 重启）：停止。
  gone,

  /// 凭据被拒 / 证书不符 / 已不在配对表：再试也不会好，停止。
  halted,
}
