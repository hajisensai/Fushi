/// 视频页对声纹识别出的 OP / ED 的「自动跳过」（作品图谱 L2，
/// docs/specs/2026-10-24-cross-media-links.md §2；默认关，设置里开）。
///
/// 画面上**不出任何提示**：「跳过片头 / 片尾」按钮与 OP 期间的「♪ 曲名 · 在音乐库打开」
/// 角标都按用户决定删掉了（BUG-3218 删过章节版跳过按钮；BUG-3850 删声纹版两个提示）。
/// 守卫 `test/pages/video_skip_chapter_removed_guard_test.dart`。
///
/// 数据来自声纹识别的按集缓存（[loadThemeSongSpansForEpisode]）。[VideoThemeSongTracker]
/// 是纯状态机（不依赖 widget），按播放位置判定进入 OP / ED 时要不要自动跳过。
library;

import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/links/theme_song/theme_song_plan.dart';

/// 跳过时落点比段尾早这么多：识别出的段尾在 TV size 剪辑处有约 ±0.6 s 的估计误差，
/// 宁可多看半秒片尾，也不要跳过正片的第一句台词。
const int kThemeSongSkipLandingLeadMs = 500;

/// 段首之后这段时间内才算「刚进入」，自动跳过只在这个窗口里触发：用户自己拖回 OP
/// 中间看，就不该被再次弹走。
const int kThemeSongAutoSkipWindowMs = 3000;

/// 按播放位置判定自动跳过。播放器每次位置更新调 [onPosition]。
class VideoThemeSongTracker {
  VideoThemeSongTracker({required this.autoSkip, required this.onAutoSkip});

  /// 读「自动跳过」开关（每次判定时现读：设置页改了立即生效）。
  final bool Function() autoSkip;

  /// 自动跳过时调（参数 = 落点毫秒）。
  final void Function(int targetMs) onAutoSkip;

  List<ThemeSongSpan> _spans = const <ThemeSongSpan>[];

  /// 本集已经自动跳过的段（按段首定位），不再重复处理。
  final Set<int> _handled = <int>{};

  List<ThemeSongSpan> get spans => _spans;

  ValueListenable<int?>? _position;

  /// 跟一个播放位置源（`VideoPlayerController.positionMsListenable`）。换 controller
  /// 时再调一次即可，旧源自动解绑。
  void attach(ValueListenable<int?> position) {
    if (identical(_position, position)) return;
    detach();
    _position = position..addListener(_onTick);
  }

  void detach() {
    _position?.removeListener(_onTick);
    _position = null;
  }

  void _onTick() => onPosition(_position?.value);

  /// 换集 / 识别结果到了：替换整组段。
  void setSpans(List<ThemeSongSpan> spans) {
    _spans = List<ThemeSongSpan>.unmodifiable(spans);
    _handled.clear();
  }

  /// 只有 OP / ED 可跳（插入曲在正片中间，跳过会跳掉剧情）。
  static bool _skippable(ThemeSongSpan s) =>
      s.role == ThemeSongRole.op || s.role == ThemeSongRole.ed;

  /// 段尾落点（见 [kThemeSongSkipLandingLeadMs]）。
  static int skipTargetOf(ThemeSongSpan span) =>
      (span.endMs - kThemeSongSkipLandingLeadMs).clamp(
        span.startMs,
        span.endMs,
      );

  void onPosition(int? positionMs) {
    if (positionMs == null || !autoSkip()) return;
    for (final ThemeSongSpan s in _spans) {
      if (!s.contains(positionMs)) continue;
      if (_skippable(s) &&
          !_handled.contains(s.startMs) &&
          positionMs - s.startMs <= kThemeSongAutoSkipWindowMs) {
        _handled.add(s.startMs);
        onAutoSkip(skipTargetOf(s));
      }
      return;
    }
  }

  void dispose() => detach();
}
