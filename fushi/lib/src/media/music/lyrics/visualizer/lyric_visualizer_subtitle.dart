/// 共享底部字幕（folia `VisualizerSubtitleOverlay`）：当前行的副字幕（按全局偏好：译文 / 罗马音 /
/// 两行都要 / 不要）+ 下一句预览。样式声明
/// `sharedSubtitle: false` 时宿主不画它。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 字幕字号（译文 / 下一句）只有这一处来源，切样式时不跳字号：歌词字号倍数 × 副字幕字号倍数
/// （`LyricVisualizerSubtitleSettings.fontScale`）。
({double translation, double upcoming}) lyricVisualizerSubtitleSizes(
  double fontScale, {
  double subtitleScale = 1,
}) {
  final double s =
      fontScale.clamp(0.6, 2.0) *
      subtitleScale.clamp(
        LyricVisualizerSubtitleSettings.minFontScale,
        LyricVisualizerSubtitleSettings.maxFontScale,
      );
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
    final LyricVisualizerSubtitleSettings settings = c.subtitle;
    // folia hideTranslationSubtitle：整个字幕浮层都不画（含下一句预览）。
    if (settings.hideTranslation) return const SizedBox.shrink();
    final ({double translation, double upcoming}) sizes =
        lyricVisualizerSubtitleSizes(
          c.fontScale,
          subtitleScale: settings.fontScale,
        );
    final TextStyle rowStyle = settings.applyFont(
      TextStyle(
        fontSize: sizes.translation,
        color: c.palette.text.withValues(alpha: 0.85),
        fontWeight: FontWeight.w500,
      ),
      c.theme,
    );
    final TextStyle upcomingStyle = settings.applyFont(
      TextStyle(fontSize: sizes.upcoming, color: c.palette.dimText),
      c.theme,
    );
    return LyricVisualizerFrameBuilder(
      context: c,
      builder: (BuildContext bc, LyricVisualizerTick tick) {
        final int i = c.runtime.lastStartedLineAt(tick.timeMs);
        final LyricVisualizerLine? line = i >= 0 ? c.runtime.lines[i] : null;
        final LyricVisualizerLine? next = c.runtime.upcomingLineAt(tick.timeMs);
        final List<LyricVisualizerSubtitleRow> rows =
            showTranslation && line != null
            ? settings.rowsFor(
                lineText: line.text,
                translation: line.translation,
                romanization: line.romanization,
              )
            : const <LyricVisualizerSubtitleRow>[];
        final String? upcoming = showUpcoming ? next?.text : null;
        return AnimatedSwitcher(
          duration: fushiMotionDuration(bc, FushiMotion.short),
          child: Column(
            key: ValueKey<int>(i),
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (int r = 0; r < rows.length; r++)
                Padding(
                  padding: EdgeInsets.only(
                    top: r == 0
                        ? 0
                        : sizes.translation *
                              kLyricVisualizerSecondarySubtitleSize *
                              kLyricVisualizerSecondarySubtitleGapEm,
                  ),
                  child: Text(
                    rows[r].text,
                    key: ValueKey<String>(
                      'lyric_visualizer_subtitle_${rows[r].kind.name}',
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    // 双行时第二行（译文）退一级：字号 0.88、透明度 0.82、主题没给字重时 w400。
                    style: r == 0
                        ? rowStyle
                        : rowStyle.copyWith(
                            fontSize:
                                sizes.translation *
                                kLyricVisualizerSecondarySubtitleSize,
                            color: c.palette.text.withValues(
                              alpha:
                                  0.85 *
                                  kLyricVisualizerSecondarySubtitleOpacity,
                            ),
                            fontWeight:
                                c.theme?.fontWeight ??
                                kLyricVisualizerSecondarySubtitleWeight,
                          ),
                  ),
                ),
              if (lyricVisualizerIsReadableSubtitle(upcoming))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    upcoming!,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: upcomingStyle,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
