/// 共享底部字幕（folia `VisualizerSubtitleOverlay`）：当前行译文 + 下一句预览。样式声明
/// `sharedSubtitle: false` 时宿主不画它。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 字幕字号（译文 / 下一句）只有这一处来源，切样式时不跳字号。
({double translation, double upcoming}) lyricVisualizerSubtitleSizes(
  double fontScale,
) {
  final double s = fontScale.clamp(0.6, 2.0);
  return (translation: 20 * s, upcoming: 15 * s);
}

class LyricVisualizerSubtitle extends StatelessWidget {
  const LyricVisualizerSubtitle({
    super.key,
    required this.context,
    this.showTranslation = true,
    this.showUpcoming = true,
  });

  final LyricVisualizerContext context;
  final bool showTranslation;
  final bool showUpcoming;

  @override
  Widget build(BuildContext buildContext) {
    final LyricVisualizerContext c = context;
    final ({double translation, double upcoming}) sizes =
        lyricVisualizerSubtitleSizes(c.fontScale);
    return LyricVisualizerFrameBuilder(
      context: c,
      builder: (BuildContext bc, LyricVisualizerTick tick) {
        final int i = c.runtime.lastStartedLineAt(tick.timeMs);
        final LyricVisualizerLine? line = i >= 0 ? c.runtime.lines[i] : null;
        final LyricVisualizerLine? next = c.runtime.upcomingLineAt(tick.timeMs);
        final String? translation = showTranslation ? line?.translation : null;
        final String? upcoming = showUpcoming ? next?.text : null;
        return AnimatedSwitcher(
          duration: fushiMotionDuration(bc, FushiMotion.short),
          child: Column(
            key: ValueKey<int>(i),
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (translation != null && translation.trim().isNotEmpty)
                Text(
                  translation,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: sizes.translation,
                    color: c.palette.text.withValues(alpha: 0.85),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              if (upcoming != null && upcoming.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    upcoming,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: sizes.upcoming,
                      color: c.palette.dimText,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
