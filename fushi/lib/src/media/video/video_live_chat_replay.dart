import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi_engine/media/video/youtube_live_chat_replay.dart';

/// 视频页持有的「当前 YouTube 视频的聊天回放」（拍板台 zTedU_pOQF，方案 b）。
///
/// 只是引擎会话 [YoutubeChatReplaySession] 的 [ChangeNotifier] 外壳：状态与分页逻辑都在
/// 会话里，这里不另存一份。播放位置只在有聊天栏挂着（[attachViewer]）时才喂给会话——
/// 没人看聊天时不向 YouTube 发分页请求。
class VideoLiveChatReplay extends ChangeNotifier {
  VideoLiveChatReplay({
    required this.videoId,
    required String entryContinuation,
    required ValueListenable<int?> position,
    YoutubeChatReplayPageFetch? fetch,
  }) : _position = position {
    final YoutubeChatReplayHttpFetcher? fetcher = fetch == null
        ? YoutubeChatReplayHttpFetcher()
        : null;
    _fetcher = fetcher;
    _session = YoutubeChatReplaySession(
      entryContinuation: entryContinuation,
      fetch: fetch ?? fetcher!.fetch,
      onChanged: notifyListeners,
    );
  }

  /// 这份聊天回放属于哪个视频（换集 / 换源时据此判断要不要重建）。
  final String videoId;

  final ValueListenable<int?> _position;
  late final YoutubeChatReplaySession _session;
  YoutubeChatReplayHttpFetcher? _fetcher;
  int _viewers = 0;
  bool _disposed = false;

  /// 播放头附近的消息窗口（升序，只读视图）。
  List<YoutubeChatMessage> get messages => _session.messages;

  YoutubeChatReplayStatus get status => _session.status;

  /// 当前播放位置（毫秒）；播放器还没报过位置时为 0。
  int get positionMs => _position.value ?? 0;

  /// 位置推送源（聊天栏据此算「已发出」的条数与高亮）。
  ValueListenable<int?> get position => _position;

  /// 是否有聊天栏在看（[attachViewer] 计数 > 0）。
  bool get active => _viewers > 0;

  /// 聊天栏挂载时调：第一个观看者出现就开始按播放位置分页，并立刻同步一次。横屏侧栏
  /// 收起动画期间与竖屏页签可能短暂同时挂着，所以按计数而不是开关。
  void attachViewer() {
    if (_disposed) return;
    _viewers++;
    if (_viewers == 1) {
      _position.addListener(_onPosition);
      _onPosition();
    }
  }

  /// 聊天栏卸载时调：最后一个观看者走了就不再向 YouTube 取页。
  void detachViewer() {
    if (_disposed || _viewers == 0) return;
    _viewers--;
    if (_viewers == 0) _position.removeListener(_onPosition);
  }

  void _onPosition() {
    final int? pos = _position.value;
    if (pos == null) return;
    unawaited(_session.syncTo(pos));
  }

  /// 失败后「重试」。
  void retry() => unawaited(_session.retry());

  @override
  void dispose() {
    _disposed = true;
    if (_viewers > 0) _position.removeListener(_onPosition);
    _session.dispose();
    _fetcher?.close();
    _fetcher = null;
    super.dispose();
  }
}
