/// 音乐迷你播放条（设计 §11.2）：与有声书「正在听书」条同一形态（底栏上方的浮动胶囊），
/// 二者互斥——媒体会话归谁就显示谁（[MediaSessionOwner]）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_session.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/audio_controller.dart';
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/pages/implementations/music/music_signal_path_panel.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_page.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 纯函数：两条迷你条谁显示。音乐有活动会话、且（音乐持有媒体会话或有声书没有会话）
/// 时显示音乐条；有声书条在音乐持有会话时让位。
bool musicBarVisible({
  required bool musicActive,
  required bool audiobookActive,
  required MediaSessionOwner owner,
}) => musicActive && (owner == MediaSessionOwner.music || !audiobookActive);

class MusicNowPlayingBar extends ConsumerWidget {
  const MusicNowPlayingBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppModel appModel = ref.watch(appProvider);
    final MusicSession session = appModel.musicSession;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        session,
        appModel.audioCtrl.sessionOwner,
        appModel.audiobookSession,
      ]),
      builder: (BuildContext context, _) {
        final MusicPlayItem? item = session.engine.current;
        if (item == null ||
            !musicBarVisible(
              musicActive: session.isActive,
              audiobookActive: appModel.audiobookSession.isActive,
              owner: appModel.audioCtrl.sessionOwner.value,
            )) {
          return const SizedBox.shrink();
        }
        final bool playing = session.engine.isPlaying;
        final Duration? duration = session.engine.duration;
        final double progress = duration == null || duration.inMilliseconds <= 0
            ? 0
            : (session.engine.position.inMilliseconds / duration.inMilliseconds)
                  .clamp(0.0, 1.0);
        final Widget content = Row(
          children: <Widget>[
            MusicCover(
              coverPath: item.coverPath,
              size: 44,
              borderRadius: FushiDesignTokens.of(context).radii.chipRadius,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.fushiType.titleSmallEmphasized,
                  ),
                  Text(
                    item.artist ?? t.music_now_playing,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.fushiType.bodySmall,
                  ),
                  const SizedBox(height: 4),
                  FushiLinearProgressIndicator(value: progress, minHeight: 2),
                ],
              ),
            ),
            FushiIconButtonControl(
              icon: const FushiIcon(FushiIcons.skipPrevious),
              tooltip: t.shortcut_action_music_previous_track,
              onPressed: () => unawaited(session.engine.skipPrevious()),
            ),
            FushiIconButtonControl.filled(
              key: const ValueKey<String>('music_bar_play_pause'),
              icon: FushiIcon(
                playing
                    ? FushiIcons.filled(FushiIcons.pause)
                    : FushiIcons.filled(FushiIcons.play),
              ),
              tooltip: t.shortcut_action_music_toggle_play_pause,
              onPressed: () => unawaited(session.engine.togglePlayPause()),
            ),
            FushiIconButtonControl(
              icon: const FushiIcon(FushiIcons.skipNext),
              tooltip: t.shortcut_action_music_next_track,
              onPressed: () => unawaited(session.engine.skipNext()),
            ),
            FushiIconButtonControl(
              key: const ValueKey<String>('music_bar_signal_path'),
              icon: const FushiIcon(FushiIcons.highQuality),
              tooltip: t.music_signal_path_title,
              onPressed: () =>
                  unawaited(showMusicSignalPathPanel(context, appModel)),
            ),
            FushiIconButtonControl(
              icon: const FushiIcon(FushiIcons.stop),
              tooltip: t.music_stop,
              onPressed: () => unawaited(session.stop()),
            ),
          ],
        );
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            kFushiFloatingToolbarEdgeMargin,
            4,
            kFushiFloatingToolbarEdgeMargin,
            8,
          ),
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: FushiPressScale(
                // 点条身打开播放页（封面 ↔ 歌词），按钮各自吃掉自己的点击。
                child: GestureDetector(
                  key: const ValueKey<String>('music_bar_open_player'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => unawaited(
                    Navigator.of(context).push<void>(
                      adaptivePageRoute<void>(
                        context: context,
                        builder: (_) => const MusicLyricsPage(),
                      ),
                    ),
                  ),
                  child: DecoratedBox(
                    decoration: isGlassDesign(context)
                        ? fushiAppleSolidFloatingDecoration(
                            context,
                            shape: const StadiumBorder(),
                          )
                        : fushiFloatingPillDecoration(
                            context,
                            color: fushiFloatingToolbarPalette(
                              context,
                            ).container,
                          ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
                      child: content,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
