import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:material_ui/material_ui.dart';

/// Title and play / pause of what plays on the main screen, for the
/// companion's browse screens. Collapses to nothing when nothing plays.
class CompanionNowPlayingBar extends ConsumerWidget {
  const CompanionNowPlayingBar({super.key});

  static const double height = 56;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CompanionPanelSession session = ref.watch(
      companionPanelSessionProvider,
    );
    final CompanionNowPlaying? now = session.nowPlaying;
    return FushiAnimatedSize(
      duration: fushiMotionDuration(context, FushiMotion.medium),
      curve: FushiMotion.standard,
      alignment: Alignment.topCenter,
      child: now == null
          ? const SizedBox(width: double.infinity)
          : _Bar(nowPlaying: now, onToggle: session.togglePlayback),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.nowPlaying, required this.onToggle});

  final CompanionNowPlaying nowPlaying;
  final Future<void> Function() onToggle;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final String toggleLabel = nowPlaying.playing
        ? t.second_screen_now_playing_pause
        : t.second_screen_now_playing_play;
    return Material(
      color: colors.surfaceContainer,
      child: SizedBox(
        height: CompanionNowPlayingBar.height,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(start: 16, end: 4),
          child: Row(
            children: <Widget>[
              FushiIcon(
                switch (nowPlaying.kind) {
                  CompanionNowPlayingKind.music => FushiIcons.music,
                  CompanionNowPlayingKind.audiobook => FushiIcons.audiobook,
                  CompanionNowPlayingKind.video => FushiIcons.video,
                },
                size: 22,
                color: colors.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      t.second_screen_now_playing_on_top(
                        title: nowPlaying.title,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    if (nowPlaying.subtitle.isNotEmpty)
                      Text(
                        nowPlaying.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              FushiIconButton(
                icon: nowPlaying.playing ? FushiIcons.pause : FushiIcons.play,
                tooltip: toggleLabel,
                onTap: onToggle,
                padTouchTarget: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
