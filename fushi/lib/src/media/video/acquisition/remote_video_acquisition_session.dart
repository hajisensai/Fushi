/// 「AI 下视频」的远端会话：状态机跑在已配对的电脑上（用电脑自己的 AI 指派与下载
/// 管线），手机只长轮询快照、发动作。对话页不区分它与本机会话。
library;

import 'dart:async';

import 'package:fushi/src/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_view.dart';
import 'package:fushi/src/sync/interconnect_assistant_client.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/sync/assistant/host_assistant.dart';

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
  /// host 的 reason 短码），由入口翻成引导文案。
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

  /// 当前是否处于「连不上」状态（只提示一次，恢复后清掉）。
  bool _unreachable = false;

  /// host 上的会话已经没了（过期 / host 重启）：不再轮询，动作一律报失败。
  bool _lost = false;
  bool _disposed = false;

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
    if (_lost) return;
    // 页面退出即关 host 上的会话；失败只记诊断（host 闲置回收兜底）。
    unawaited(_closeHostSession());
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
    if (_disposed) return;
    if (_lost) {
      _markUnavailable();
      return;
    }
    try {
      _apply(await _client.act(_target, _id, action));
    } on Object catch (error) {
      _onError(error, 'act');
    }
  }

  Future<void> _pollLoop() async {
    while (!_disposed && !_lost) {
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
        if (_disposed || _lost) return;
        await Future<void>.delayed(_retryDelay);
      }
    }
  }

  void _apply(HostAssistantEnvelope envelope) {
    if (_disposed) return;
    final bool recovered = _unreachable;
    _unreachable = false;
    if (envelope.revision <= _revision && !recovered) return;
    _revision = envelope.revision;
    _hostView = VideoAcquisitionView.fromJson(envelope.view);
    _emit();
  }

  void _onError(Object error, String where) {
    if (_disposed) return;
    ErrorLogService.instance.logDiagnostic(
      'RemoteVideoAcquisition.$where',
      '${_target.label}: $error',
    );
    if (error is HostAssistantException && error.sessionGone) _lost = true;
    _markUnavailable();
  }

  void _markUnavailable() {
    if (_unreachable) return;
    _unreachable = true;
    _notices.add((
      _hostView.transcript.length,
      const VideoAcquisitionAssistantMessage(
        VideoAcquisitionSay(
          VideoAcquisitionSayKind.failed,
          args: <String, Object?>{
            'message': kVideoAcquisitionFailureRemoteUnavailable,
          },
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
    final bool offline = _unreachable || _lost;
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
