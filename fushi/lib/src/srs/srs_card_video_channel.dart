/// 卡面上可见的视频片段（视频制卡的 `<video class="fushi-inline-video">` 片段，自带句子
/// 音频）与卡面音频序列（`SrsCardAudioSequencer`）之间的登记处。
///
/// 原生卡面把片段画成 `SrsCardVideoClip`，它在挂载时按媒体文件名登记一个
/// [SrsCardVideoHandle]；序列播到同名媒体时先问这里：有登记 = 在卡面那段画面上从头
/// 播（声音与画面同步、用户看得见），没登记 = 返回 null，调用方退回只播音频。
///
/// 片段只在它所在那一面**构建出来之后**才登记：复习页翻面是 `setState` 后同步起序列，
/// 片段要等下一帧构建才挂上。序列走 [SrsCardVideoChannel.playToEndOrElse]：没登记、但名字
/// 是视频且卡面还有一轮构建没跑完时，等这轮构建跑完再决定（挂上了 = 在画面里播；仍没有 =
/// 退回只播音频）；等待期间 [SrsCardVideoChannel.stopAll]（换卡 / 翻回 / 序列被取消）以
/// false 结束它，不再开播任何东西。
///
/// 纯逻辑，不碰播放器；播放器与 widget 生命周期都在 handle 实现里。
library;

import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/srs/srs_fushi_card_fields.dart' show srsIsVideoName;

/// 一段已挂到卡面上的视频片段（由 `SrsCardVideoClip` 实现；测试可换假实现）。
abstract class SrsCardVideoHandle {
  /// 从 0 开始、以当前复习音量播放，并等它播完。
  ///
  /// true = 自然播到结尾；false = 被打断（[stop]、widget 卸载 / 换片段、又一次
  /// [playFromStart]、用户在片段上点了暂停 / 播放 / 重播）或文件打不开。
  ///
  /// 与 `SrsCardAudioOutput.playToEnd` 同一契约：实现必须在**返回 Future 之前**
  /// 同步登记这次播放，之后的 [stop] 必须能取消它（包括播放器还没打开好的情况）。
  Future<bool> playFromStart();

  /// 停下（暂停）正在播的片段，并让未完成的 [playFromStart] 以 false 结束。
  Future<void> stop();
}

/// 卡面此刻是否还有一轮构建没跑完（已排了帧 / 正在帧里）：片段只在构建时挂上，没有待跑的
/// 构建就不会再有片段登记。
bool _schedulerBuildPending() {
  final SchedulerBinding binding = SchedulerBinding.instance;
  if (binding.hasScheduledFrame) return true;
  return switch (binding.schedulerPhase) {
    SchedulerPhase.transientCallbacks ||
    SchedulerPhase.midFrameMicrotasks ||
    SchedulerPhase.persistentCallbacks => true,
    SchedulerPhase.idle || SchedulerPhase.postFrameCallbacks => false,
  };
}

/// 待跑的那一轮构建（及其布局 / 绘制）完成。
Future<void> _schedulerBuildSettled() => SchedulerBinding.instance.endOfFrame;

/// 一次等片段登记的播放（见 [SrsCardVideoChannel.playToEndOrElse]）。
class _PendingClipPlay {
  _PendingClipPlay(this.name, this.orElse);

  final String name;
  final Future<bool> Function() orElse;
  final Completer<bool> done = Completer<bool>();
}

/// 按媒体文件名找卡面上的视频片段。
class SrsCardVideoChannel {
  /// [buildPending] / [buildSettled]：卡面是否还有一轮构建没跑完、等它跑完（缺省 = Flutter
  /// 调度器的「已排帧」与 `endOfFrame`；测试可注入）。
  SrsCardVideoChannel({
    bool Function()? buildPending,
    Future<void> Function()? buildSettled,
  }) : _buildPending = buildPending ?? _schedulerBuildPending,
       _buildSettled = buildSettled ?? _schedulerBuildSettled;

  final bool Function() _buildPending;
  final Future<void> Function() _buildSettled;

  /// 正在等卡面构建跑完的播放；[stopAll] 以 false 结束它们。
  final List<_PendingClipPlay> _pending = <_PendingClipPlay>[];

  /// 同名可能同时挂着多个（正反面过渡时新旧两张卡短暂并存）；最后挂上的那个算数。
  final Map<String, List<SrsCardVideoHandle>> _handles =
      <String, List<SrsCardVideoHandle>>{};

  /// 登记 [name] 的片段 [handle]（重复登记同一个 handle 只算一次，并移到最新）。
  void attach(String name, SrsCardVideoHandle handle) {
    final List<SrsCardVideoHandle> list = _handles.putIfAbsent(
      name,
      () => <SrsCardVideoHandle>[],
    );
    list
      ..remove(handle)
      ..add(handle);
  }

  /// 撤销登记（widget 卸载 / 换了片段时调用）；没登记过就什么也不做。
  void detach(String name, SrsCardVideoHandle handle) {
    final List<SrsCardVideoHandle>? list = _handles[name];
    if (list == null) return;
    list.remove(handle);
    if (list.isEmpty) _handles.remove(name);
  }

  /// [name] 此刻是否有片段挂在卡面上。
  bool isAttached(String name) => _handles[name]?.isNotEmpty ?? false;

  /// 在卡面上把 [name] 的片段从头播到尾。
  ///
  /// null = 卡面上没有这段片段（调用方退回只播音频）；否则同
  /// [SrsCardVideoHandle.playFromStart]。同一时刻只让一段片段出声：别的片段先停。
  /// 本方法同步登记播放，返回之后的 [stopAll] 一定能打断它。
  Future<bool>? playToEnd(String name) {
    final List<SrsCardVideoHandle>? list = _handles[name];
    if (list == null || list.isEmpty) return null;
    final SrsCardVideoHandle target = list.last;
    for (final SrsCardVideoHandle other in _allHandles()) {
      if (!identical(other, target)) unawaited(other.stop());
    }
    return target.playFromStart();
  }

  /// 播放 [name]：卡面上有这段片段就在画面里从头播（同 [playToEnd]），确定没有就交给
  /// [orElse]（只播音频）。
  ///
  /// 「确定没有」：此刻没登记，并且 [name] 不是视频文件、或卡面没有待跑的构建。否则（视频、
  /// 构建还没跑完——典型是翻面 `setState` 后同步起的序列）先等这一轮构建跑完再看：片段在
  /// 构建里挂上就交给它，仍没挂上（这一面根本没画这段片段，例如整面 WebView 卡、外观关了
  /// 图片）才走 [orElse]。等的只是已经排上的那一帧，不是猜时长；等待期间 [stopAll] 以 false
  /// 结束这次播放，之后什么也不开播。
  ///
  /// 与 [SrsCardVideoHandle.playFromStart] 同一契约：本方法同步登记，返回之后的 [stopAll]
  /// 一定能打断它（[orElse] 自己负责同步登记它那条路）。
  Future<bool> playToEndOrElse(String name, Future<bool> Function() orElse) {
    final Future<bool>? clip = playToEnd(name);
    if (clip != null) return clip;
    if (!srsIsVideoName(name) || !_buildPending()) return orElse();
    final _PendingClipPlay pending = _PendingClipPlay(name, orElse);
    _pending.add(pending);
    unawaited(
      _buildSettled().then<void>(
        (_) => _resolvePending(pending),
        onError: (Object _) => _resolvePending(pending),
      ),
    );
    return pending.done.future;
  }

  void _resolvePending(_PendingClipPlay pending) {
    // 已被 stopAll 结束。
    if (!_pending.remove(pending)) return;
    pending.done.complete(playToEnd(pending.name) ?? pending.orElse());
  }

  /// 停掉所有挂着的片段（换卡 / 翻面 / 离开复习页 / 序列被取消），并以 false 结束还在等
  /// 卡面构建的播放（[playToEndOrElse]）。
  Future<void> stopAll() async {
    final List<_PendingClipPlay> pending = List<_PendingClipPlay>.of(_pending);
    _pending.clear();
    for (final _PendingClipPlay p in pending) {
      p.done.complete(false);
    }
    await Future.wait<void>(<Future<void>>[
      for (final SrsCardVideoHandle h in _allHandles()) h.stop(),
    ]);
  }

  List<SrsCardVideoHandle> _allHandles() => <SrsCardVideoHandle>[
    for (final List<SrsCardVideoHandle> list in _handles.values) ...list,
  ];
}

/// 复习页范围内共用的一个登记处（卡面片段登记、音频序列查询的是同一个实例）。
final Provider<SrsCardVideoChannel> srsCardVideoChannelProvider =
    Provider<SrsCardVideoChannel>((Ref ref) => SrsCardVideoChannel());
