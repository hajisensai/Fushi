/// app 当互联 host 时的「AI 助手会话」：手机经 `/api/assistant` 把一句话交给本机，
/// 本机用**自己的** AI 指派、资源搜索与下载管线把事办完（第一个功能：AI 下视频）。
///
/// 这里只做两件事：能力 / 前置判断（缺什么回稳定短码，手机据此给出具体引导），以
/// 及把 [VideoAcquisitionService] 包成引擎的 [HostAssistantSession]（快照 = 与语言
/// 无关的 [VideoAcquisitionView]，动作 = 对话页的那几个按钮）。全部依赖按闭包现取：
/// 下载管线是 fire-and-forget 起的，host 可能先绑上端口。
library;

import 'dart:async';

import 'package:fushi/src/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_service.dart';
import 'package:fushi_engine/sync/assistant/host_assistant.dart';

/// 能力位 `reason` 短码。
const String kAppAssistantReasonNoProvider = 'no_provider';
const String kAppAssistantReasonNotReady = 'not_ready';
const String kAppAssistantReasonDisabled = 'disabled';

/// 开一场本机执行的 AI 下视频会话：service + 会话结束时要释放的资源（发现服务等）。
typedef AppVideoAcquisitionOpener
    = Future<({VideoAcquisitionService service, void Function() release})>
        Function(String locale);

class AppAssistantHost implements HostAssistantProvider {
  AppAssistantHost({
    required Future<String?> Function() videoAcquireBlocker,
    required AppVideoAcquisitionOpener openVideoAcquisition,
  })  : _videoAcquireBlocker = videoAcquireBlocker,
        _openVideoAcquisition = openVideoAcquisition;

  /// null = 现在就能开；否则是缺什么（[kAppAssistantReasonNoProvider] 等）。
  final Future<String?> Function() _videoAcquireBlocker;
  final AppVideoAcquisitionOpener _openVideoAcquisition;

  @override
  Future<Map<String, Object?>> capability() async {
    final String? reason = await _videoAcquireBlocker();
    return <String, Object?>{
      'supported': reason == null,
      'features': <String>[
        if (reason == null) kHostAssistantFeatureVideoAcquire,
      ],
      if (reason != null) 'reason': reason,
    };
  }

  @override
  Future<HostAssistantSession> open(
    String feature, {
    required String locale,
  }) async {
    if (feature != kHostAssistantFeatureVideoAcquire) {
      throw ArgumentError.value(
          feature, 'feature', 'unknown assistant feature');
    }
    final String? reason = await _videoAcquireBlocker();
    if (reason != null) throw HostAssistantUnavailable(reason);
    final ({VideoAcquisitionService service, void Function() release}) parts =
        await _openVideoAcquisition(locale);
    return VideoAcquisitionHostSession(parts.service, onClose: parts.release);
  }
}

/// 把一个本机 [VideoAcquisitionService] 暴露成互联会话。
class VideoAcquisitionHostSession implements HostAssistantSession {
  VideoAcquisitionHostSession(this._service, {void Function()? onClose})
      : _onClose = onClose {
    _subscription = _service.states.listen((_) {
      _revision++;
      if (!_changes.isClosed) _changes.add(null);
    });
  }

  final VideoAcquisitionService _service;
  final void Function()? _onClose;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  late final StreamSubscription<VideoAcquisitionState> _subscription;
  int _revision = 0;
  bool _closed = false;

  @override
  int get revision => _revision;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Map<String, Object?> snapshot() => _service.view.toJson();

  /// 动作形状：
  ///
  /// ```
  /// {type: text, text}
  /// {type: choose, slot, optionId, remember?}
  /// {type: confirm | cancel | restart}
  /// {type: toggleFranchise, index}
  /// ```
  ///
  /// 只校验形状；「此刻能不能点」交给 reducer（不合时宜的事件原样忽略，与本机页面
  /// 同一口径）。动作引发的效果链在后台跑，不等它结束。
  @override
  Future<void> act(Map<String, Object?> action) async {
    if (_closed) throw StateError('session closed');
    final Future<void> Function() run = switch (action['type']) {
      'text' => switch (action['text']) {
          final String text when text.trim().isNotEmpty => () =>
              _service.submitText(text),
          _ => throw ArgumentError('text action needs non-empty text'),
        },
      'choose' => _chooseAction(action),
      'confirm' => _service.confirm,
      'cancel' => _service.cancel,
      'restart' => _service.restart,
      'toggleFranchise' => switch (action['index']) {
          final int index when index >= 0 => () =>
              _service.toggleFranchiseEntry(index),
          _ =>
            throw ArgumentError('toggleFranchise needs a non-negative index'),
        },
      _ => throw ArgumentError('unknown action type: ${action['type']}'),
    };
    // dispatch 在第一个 await 之前就把事件归约进状态了：这里返回时快照已是新的。
    unawaited(run());
  }

  Future<void> Function() _chooseAction(Map<String, Object?> action) {
    final Object? rawSlot = action['slot'];
    final VideoAcquisitionSlot? slot = VideoAcquisitionSlot.values
        .where((VideoAcquisitionSlot s) => s.name == rawSlot)
        .firstOrNull;
    final Object? optionId = action['optionId'];
    final Object? remember = action['remember'];
    if (slot == null || optionId is! String || optionId.isEmpty) {
      throw ArgumentError('choose needs a known slot and an optionId');
    }
    if (remember != null && remember is! bool) {
      throw ArgumentError('remember must be a bool');
    }
    return () => _service.choose(slot, optionId, remember: remember as bool?);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    _service.dispose();
    _onClose?.call();
    await _changes.close();
  }
}
