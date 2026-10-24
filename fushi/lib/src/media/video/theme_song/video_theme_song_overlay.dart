/// 视频页的「跳过片头 / 片尾」按钮 + OP 期间角落的「♪ 曲名 · 在音乐库打开」（作品图谱
/// L2，docs/specs/2026-10-24-cross-media-links.md §2）。
///
/// 数据来自声纹识别的按集缓存（[loadThemeSongSpansForEpisode]）。这里只有两样东西：
/// - [VideoThemeSongTracker]：纯状态机（不依赖 widget），按播放位置算「当前在哪段主题曲
///   里」，以及进入 OP / ED 时要不要自动跳过；
/// - [VideoThemeSongOverlay]：渲染。整层 [ExcludeFocus]——它是覆盖在画面上的 chrome，
///   不是焦点所有者（docs/agent/focus-ownership.md：焦点永远归正文，chrome 不进焦点
///   遍历），按钮只接指针。
library;

import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/links/theme_song/theme_song_plan.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:material_ui/material_ui.dart';

/// 跳过时落点比段尾早这么多：识别出的段尾在 TV size 剪辑处有约 ±0.6 s 的估计误差，
/// 宁可多看半秒片尾，也不要跳过正片的第一句台词。
const int kThemeSongSkipLandingLeadMs = 500;

/// 段首之后这段时间内才算「刚进入」，自动跳过只在这个窗口里触发：用户自己拖回 OP
/// 中间看，就不该被再次弹走。
const int kThemeSongAutoSkipWindowMs = 3000;

/// 一段主题曲在当前位置的展示状态。
@immutable
class VideoThemeSongActive {
  const VideoThemeSongActive({required this.span, required this.skippable});

  final ThemeSongSpan span;

  /// 是否给「跳过」按钮：OP / ED 才给（插入曲在正片中间，跳过会跳掉剧情）。
  final bool skippable;

  @override
  bool operator ==(Object other) =>
      other is VideoThemeSongActive &&
      other.span.trackUid == span.trackUid &&
      other.span.startMs == span.startMs &&
      other.skippable == skippable;

  @override
  int get hashCode => Object.hash(span.trackUid, span.startMs, skippable);
}

/// 按播放位置推导当前主题曲段。播放器每次位置更新调 [onPosition]。
class VideoThemeSongTracker {
  VideoThemeSongTracker({required this.autoSkip, required this.onAutoSkip});

  /// 读「自动跳过」开关（每次判定时现读：设置页改了立即生效）。
  final bool Function() autoSkip;

  /// 自动跳过时调（参数 = 落点毫秒）。
  final void Function(int targetMs) onAutoSkip;

  final ValueNotifier<VideoThemeSongActive?> active =
      ValueNotifier<VideoThemeSongActive?>(null);

  List<ThemeSongSpan> _spans = const <ThemeSongSpan>[];

  /// 本集已经自动跳过 / 用户手动关掉过的段（按段首定位），不再重复处理。
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
    active.value = null;
  }

  static bool _skippable(ThemeSongSpan s) =>
      s.role == ThemeSongRole.op || s.role == ThemeSongRole.ed;

  /// 段尾落点（见 [kThemeSongSkipLandingLeadMs]）。
  static int skipTargetOf(ThemeSongSpan span) =>
      (span.endMs - kThemeSongSkipLandingLeadMs).clamp(
        span.startMs,
        span.endMs,
      );

  void onPosition(int? positionMs) {
    if (positionMs == null) return;
    ThemeSongSpan? current;
    for (final ThemeSongSpan s in _spans) {
      if (s.contains(positionMs)) {
        current = s;
        break;
      }
    }
    if (current == null) {
      active.value = null;
      return;
    }
    final bool skippable = _skippable(current);
    if (skippable &&
        autoSkip() &&
        !_handled.contains(current.startMs) &&
        positionMs - current.startMs <= kThemeSongAutoSkipWindowMs) {
      _handled.add(current.startMs);
      active.value = null;
      onAutoSkip(skipTargetOf(current));
      return;
    }
    active.value = VideoThemeSongActive(span: current, skippable: skippable);
  }

  /// 用户点了「跳过」：返回落点并把这段记为已处理。
  int skip(ThemeSongSpan span) {
    _handled.add(span.startMs);
    active.value = null;
    return skipTargetOf(span);
  }

  void dispose() {
    detach();
    active.dispose();
  }
}

/// 跳过按钮的文案（片头 / 片尾）。
String themeSongSkipLabel(ThemeSongRole role) => role == ThemeSongRole.ed
    ? t.video_theme_song_skip_ending
    : t.video_theme_song_skip_intro;

/// 渲染层。挂在视频页 controls Stack 里（[Positioned.fill]）。
class VideoThemeSongOverlay extends StatelessWidget {
  const VideoThemeSongOverlay({
    super.key,
    required this.tracker,
    required this.showNowPlaying,
    required this.onSkip,
    required this.onOpenTrack,
    required this.surfaceColor,
    required this.textColor,
    required this.skipBottomInset,
    required this.nowPlayingTopInset,
    this.uiScale = 1.0,
  });

  final VideoThemeSongTracker tracker;

  /// 角落「♪ 曲名」开关（设置项）。
  final bool showNowPlaying;
  final ValueChanged<ThemeSongSpan> onSkip;
  final ValueChanged<ThemeSongSpan> onOpenTrack;

  /// OSD 配色（与视频页其它角标同源，页面传进来）。
  final Color surfaceColor;
  final Color textColor;

  /// 跳过按钮离底边的距离（页面按进度条真实几何算，避开 seek bar）。
  final double skipBottomInset;

  /// 曲名角标离顶边的距离（避开顶栏）。
  final double nowPlayingTopInset;
  final double uiScale;

  @override
  Widget build(BuildContext context) {
    final Duration fade = fushiMotionDuration(context, FushiMotion.short);
    final bool apple = isGlassDesign(context);
    final ShapeBorder shape = apple
        ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
        : const StadiumBorder();
    return ExcludeFocus(
      child: ValueListenableBuilder<VideoThemeSongActive?>(
        valueListenable: tracker.active,
        builder: (BuildContext context, VideoThemeSongActive? state, _) {
          final ThemeSongSpan? span = state?.span;
          return Stack(
            children: <Widget>[
              Positioned(
                right: 16 * uiScale,
                bottom: skipBottomInset,
                child: AnimatedSwitcher(
                  duration: fade,
                  switchInCurve: FushiMotion.enter,
                  switchOutCurve: FushiMotion.exit,
                  child: span != null && state!.skippable
                      ? _Pill(
                          key: ValueKey<String>(
                            'video-theme-song-skip-${span.startMs}',
                          ),
                          shape: shape,
                          color: surfaceColor,
                          onTap: () => onSkip(span),
                          semanticsLabel: themeSongSkipLabel(span.role),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(
                                themeSongSkipLabel(span.role),
                                style: TextStyle(
                                  color: textColor,
                                  fontSize: 15 * uiScale,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              SizedBox(width: 6 * uiScale),
                              FushiIcon(
                                FushiIcons.skipNext,
                                size: 20 * uiScale,
                                color: textColor,
                              ),
                            ],
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
              Positioned(
                left: 16 * uiScale,
                top: nowPlayingTopInset,
                child: AnimatedSwitcher(
                  duration: fade,
                  switchInCurve: FushiMotion.enter,
                  switchOutCurve: FushiMotion.exit,
                  child: span != null && showNowPlaying
                      ? _Pill(
                          key: ValueKey<String>(
                            'video-theme-song-now-playing-${span.trackUid}',
                          ),
                          shape: shape,
                          color: surfaceColor,
                          onTap: () => onOpenTrack(span),
                          semanticsLabel: t.video_theme_song_now_playing(
                            title: span.title,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              FushiIcon(
                                FushiIcons.music,
                                size: 16 * uiScale,
                                color: textColor,
                              ),
                              SizedBox(width: 6 * uiScale),
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: 280 * uiScale,
                                ),
                                child: Text(
                                  t.video_theme_song_now_playing(
                                    title: span.title,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: textColor,
                                    fontSize: 13 * uiScale,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    super.key,
    required this.shape,
    required this.color,
    required this.onTap,
    required this.semanticsLabel,
    required this.child,
  });

  final ShapeBorder shape;
  final Color color;
  final VoidCallback onTap;
  final String semanticsLabel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticsLabel,
      excludeSemantics: true,
      child: FushiHoverLift(
        builder: (BuildContext context, bool hovering) => FushiPressScale(
          child: Material(
            color: color,
            shape: shape,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              customBorder: shape,
              canRequestFocus: false,
              onTap: onTap,
              child: ConstrainedBox(
                // 命中区 ≥ 48dp（工具栏规则）。
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Center(widthFactor: 1, child: child),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
