/// 全屏播放页传输行下方的「功能行」（设计稿 ①：队列 / 音效 / 睡眠定时 / 倍速）：一个能放
/// 多个按钮的横排容器，每个按钮等宽、图标在上、小字说明在下。目前只有「队列」一项
/// （[musicQueueActionButton]），音效等由各自的改动往 [MusicPlayerActionRow.children] 里加。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

/// 单个按钮的最宽宽度：按钮少时整行不撑满（设计稿四格时约 88 宽）。
const double kMusicPlayerActionMaxWidth = 112;

class MusicPlayerActionRow extends StatelessWidget {
  const MusicPlayerActionRow({super.key, required this.children});

  /// [MusicPlayerActionButton]，从左到右。
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final ColorScheme cs = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: kMusicPlayerActionMaxWidth * children.length + 12,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.surfaceContainer.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (int i = 0; i < children.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: 8),
                Flexible(child: children[i]),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 功能行里的一个按钮：图标 + 小字（文字同时作 Semantics / tooltip）。
class MusicPlayerActionButton extends StatelessWidget {
  const MusicPlayerActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
  });

  final IconData icon;

  /// 按钮下方的小字（如「队列 · 24」）。
  final String label;

  /// 完整说明（tooltip 与读屏）。
  final String tooltip;
  final VoidCallback? onPressed;

  /// 开着的状态（如侧栏展开）：填色底。
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color fg = selected ? cs.onSecondaryContainer : cs.onSurface;
    return FushiPressScale(
      enabled: onPressed != null,
      child: Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          selected: selected,
          label: tooltip,
          excludeSemantics: true,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: onPressed,
              child: AnimatedContainer(
                duration: fushiMotionDuration(context, FushiMotion.short),
                constraints: const BoxConstraints(minWidth: 72, minHeight: 56),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: selected ? cs.secondaryContainer : Colors.transparent,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    FushiIcon(icon, color: fg, size: 22),
                    const SizedBox(height: 2),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.fushiType.labelSmall.copyWith(
                        color: selected ? fg : cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
