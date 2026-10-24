import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/music_lyrics_coverage_index.dart';
import 'package:fushi/utils.dart';

/// 曲目行尾的难度标记（曲库按难度排序时显示）：已知覆盖率 / 无歌词 / 无词典词。
/// 还没算出来时不占位。数值变化交叉淡入（时长走 [fushiMotionDuration]，减弱动态效果 /
/// 墨水屏归零）。
class MusicDifficultyBadge extends StatelessWidget {
  const MusicDifficultyBadge({super.key, required this.difficulty});

  final MusicTrackDifficulty difficulty;

  String? get _label {
    final int? percent = difficulty.percent;
    if (percent != null) return t.music_difficulty_known(percent: percent);
    return switch (difficulty.status) {
      MusicCoverageStatus.noLyrics => t.music_difficulty_no_lyrics,
      MusicCoverageStatus.noTerms => t.music_difficulty_no_terms,
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final String? label = _label;
    return AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.short),
      child: label == null
          ? const SizedBox.shrink(key: ValueKey<String>('none'))
          : _chip(context, label),
    );
  }

  Widget _chip(BuildContext context, String label) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double? ratio = difficulty.ratio;
    final Color background;
    final Color foreground;
    if (isGlassDesign(context)) {
      // Apple：内容层实色小标签（tertiaryFill 底 + secondaryLabel 字），不着彩色。
      final FushiAppleColors apple = appleColorsOf(context);
      background = apple.tertiaryFill;
      foreground = ratio == null ? apple.tertiaryLabel : apple.secondaryLabel;
    } else {
      // MD3：按覆盖率分三档容器色（越熟越偏主色），没有覆盖率的用中性色。
      final ColorScheme colors = Theme.of(context).colorScheme;
      if (ratio == null) {
        background = colors.surfaceContainerHighest;
        foreground = colors.onSurfaceVariant;
      } else if (ratio >= 0.9) {
        background = colors.primaryContainer;
        foreground = colors.onPrimaryContainer;
      } else if (ratio >= 0.7) {
        background = colors.secondaryContainer;
        foreground = colors.onSecondaryContainer;
      } else {
        background = colors.tertiaryContainer;
        foreground = colors.onTertiaryContainer;
      }
    }
    final Widget chip = Container(
      key: ValueKey<String>(label),
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.gap,
        vertical: tokens.spacing.gap / 4,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: tokens.radii.chipRadius,
      ),
      child: Text(
        label,
        maxLines: 1,
        style: context.fushiType.labelSmall.copyWith(color: foreground),
      ),
    );
    final int? known = difficulty.knownTokens;
    final int? percent = difficulty.percent;
    if (known == null || percent == null) return chip;
    return Tooltip(
      key: ValueKey<String>(label),
      message: t.music_lyrics_coverage(
        known: known,
        total: difficulty.totalTokens,
        percent: percent,
      ),
      child: chip,
    );
  }
}
