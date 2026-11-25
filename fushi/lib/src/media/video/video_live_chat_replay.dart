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
  }) : _position = position,
       _reprobe = null {
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

  /// 「有没有聊天回放」探测失败（BUG-5411）：不知道有没有，所以按钮照样出、聊天栏显示
  /// 失败与「重试」，重试 = 重新探测（[reprobe]，由视频页换上探测结果对应的新实例）。
  /// 与「探测成功但没有聊天回放」（不出按钮）区分开。
  VideoLiveChatReplay.probeFailed({
    required this.videoId,
    required ValueListenable<int?> position,
    required Future<void> Function() reprobe,
  }) : _position = position,
       _reprobe = reprobe,
       _session = null;

  /// 这份聊天回放属于哪个视频（换集 / 换源时据此判断要不要重建）。
  final String videoId;

  final ValueListenable<int?> _position;

  /// 探测成功时的分页会话；探测失败的实例为 null。
  late final YoutubeChatReplaySession? _session;
  final Future<void> Function()? _reprobe;
  YoutubeChatReplayHttpFetcher? _fetcher;
  int _viewers = 0;
  bool _disposed = false;
  bool _reprobing = false;

  /// 是不是「探测失败」的占位（见 [VideoLiveChatReplay.probeFailed]）。
  bool get probeFailed => _session == null;

  /// 播放头附近的消息窗口（升序，只读视图）。
  List<YoutubeChatMessage> get messages =>
      _session?.messages ?? const <YoutubeChatMessage>[];

  YoutubeChatReplayStatus get status {
    final YoutubeChatReplaySession? session = _session;
    if (session != null) return session.status;
    return _reprobing
        ? YoutubeChatReplayStatus.loading
        : YoutubeChatReplayStatus.failed;
  }

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
    if (_viewers == 1 && _session != null) {
      _position.addListener(_onPosition);
      _onPosition();
    }
  }

  /// 聊天栏卸载时调：最后一个观看者走了就不再向 YouTube 取页。
  void detachViewer() {
    if (_disposed || _viewers == 0) return;
    _viewers--;
    if (_viewers == 0 && _session != null) {
      _position.removeListener(_onPosition);
    }
  }

  void _onPosition() {
    final int? pos = _position.value;
    if (pos == null) return;
    unawaited(_session?.syncTo(pos));
  }

  /// 失败后「重试」：取页失败重取这一页；探测失败重新探测。
  void retry() {
    final YoutubeChatReplaySession? session = _session;
    if (session != null) {
      unawaited(session.retry());
      return;
    }
    final Future<void> Function()? reprobe = _reprobe;
    if (_disposed || _reprobing || reprobe == null) return;
    _reprobing = true;
    notifyListeners();
    unawaited(
      reprobe().whenComplete(() {
        if (_disposed) return;
        _reprobing = false;
        notifyListeners();
      }),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    if (_viewers > 0 && _session != null) {
      _position.removeListener(_onPosition);
    }
    _session?.dispose();
    _fetcher?.close();
    _fetcher = null;
    super.dispose();
  }
}

/// 换上新的聊天回放后要不要直接打开聊天栏：换源 / 换集前栏开着就接着开（不因为换视频把
/// 用户开着的栏收掉），否则看设置「自动打开聊天回放」（`video.live_chat.auto_open`）。
///
/// [probeFailed]（换上的是「探测失败」占位，BUG-5411）时不按自动打开开栏：不知道这个视频
/// 有没有聊天回放，绝大多数普通视频本来就没有，接口一出问题就每个视频都弹出一个失败栏
/// 挤占画面；按钮照出，用户想看再点开重试。换视频前栏开着的照旧接着开。
bool videoLiveChatOpensOnLoad({
  required bool wasOpen,
  required bool autoOpen,
  required bool probeFailed,
}) => wasOpen || (autoOpen && !probeFailed);
