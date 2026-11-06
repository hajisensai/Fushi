/// 「电台」式的续播队列：首批放完前再取下一批拼到队尾（在线插件的私人电台 / 以某首起电台）。
///
/// 与 Apple Music 电台不同：那边由 MusicKit 自管队列（引擎的 external queue）；这里队列仍在
/// Fushi 手里，只是不定长——[MusicQueueFeedRunner] 盯着引擎，当前曲目离队尾不到
/// [kMusicQueueFeedPrefetch] 首时调 [MusicQueueFeed.next]，结果经
/// [MusicPlayerEngine.appendToQueue] 追加。用户换了别的队列（引擎来源不再是这个电台）即停止续取。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';

/// 离队尾还剩几首（含当前这首之后）时去取下一批。
const int kMusicQueueFeedPrefetch = 2;

/// 一个可以不断「取下一批」的曲目来源。
abstract interface class MusicQueueFeed {
  /// 接下来的一批；空列表 = 没有更多（停止续取）。
  Future<List<MusicPlayItem>> next();
}

/// 把一个 [MusicQueueFeed] 接到引擎上：开播首批、快到队尾时续取。
class MusicQueueFeedRunner {
  MusicQueueFeedRunner(this.engine) {
    engine.addListener(_onEngineChanged);
  }

  final MusicPlayerEngine engine;

  MusicQueueFeed? _feed;
  MusicPlaySource? _source;
  bool _loading = false;

  /// 正在续取的电台来源（测试 / 界面判断用）；没有时为 null。
  MusicPlaySource? get activeSource => _feed == null ? null : _source;

  /// 取首批并开播。首批为空回 false（调用方提示「没有可播的」）。
  Future<bool> play(
    MusicQueueFeed feed, {
    required MusicPlaySource source,
  }) async {
    _feed = null;
    final List<MusicPlayItem> first = await feed.next();
    if (first.isEmpty) return false;
    _feed = feed;
    _source = source;
    _loading = false;
    await engine.playQueue(first, source: source);
    return true;
  }

  void _onEngineChanged() {
    final MusicQueueFeed? feed = _feed;
    if (feed == null || _loading) return;
    // 来源对象换了 = 用户开了别的队列（或停止）：这个电台到此为止。
    if (!identical(engine.source, _source)) {
      _feed = null;
      return;
    }
    final int remaining = engine.queue.length - 1 - engine.index;
    if (remaining >= kMusicQueueFeedPrefetch) return;
    _loading = true;
    unawaited(_extend(feed));
  }

  Future<void> _extend(MusicQueueFeed feed) async {
    try {
      final List<MusicPlayItem> more = await feed.next();
      if (!identical(_feed, feed) || !identical(engine.source, _source)) return;
      if (more.isEmpty) {
        _feed = null;
        return;
      }
      await engine.appendToQueue(more);
    } on Object catch (e, st) {
      // 取不到下一批（断网 / 登录失效）：停在已有队列的末尾，不反复重试。
      debugPrint('MusicQueueFeed: next batch failed: $e\n$st');
      if (identical(_feed, feed)) _feed = null;
    } finally {
      if (identical(_feed, feed) || _feed == null) _loading = false;
    }
  }

  void dispose() {
    engine.removeListener(_onEngineChanged);
    _feed = null;
  }
}
