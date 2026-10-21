/// 卡面上可见的视频片段（视频制卡的 `<video class="fushi-inline-video">` 片段，自带句子
/// 音频）与卡面音频序列（`SrsCardAudioSequencer`）之间的登记处。
///
/// 原生卡面把片段画成 `SrsCardVideoClip`，它在挂载时按媒体文件名登记一个
/// [SrsCardVideoHandle]；序列播到同名媒体时先问这里：有登记 = 在卡面那段画面上从头
/// 播（声音与画面同步、用户看得见），没登记 = 返回 null，调用方退回只播音频。
///
/// 纯逻辑，不碰播放器；播放器与 widget 生命周期都在 handle 实现里。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// 按媒体文件名找卡面上的视频片段。
class SrsCardVideoChannel {
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

  /// 停掉所有挂着的片段（换卡 / 翻面 / 离开复习页 / 序列被取消）。
  Future<void> stopAll() async {
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
