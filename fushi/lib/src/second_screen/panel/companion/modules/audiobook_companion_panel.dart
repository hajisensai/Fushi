import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_scroll.dart';
import 'package:fushi/src/second_screen/companion/companion_snapshot.dart';
import 'package:fushi/src/second_screen/companion/modules/audiobook_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_lookup_controller.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/second_screen/panel/companion/modules/companion_module_widgets.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// Now tab panel while an audiobook plays in the reader's audiobook view:
/// book info, whole-book position, the chapter's transcript (tap = play from
/// that line, long-press = look it up here), transport and speed. Schema:
/// [AudiobookCompanionKeys].
class AudiobookCompanionPanel extends ConsumerStatefulWidget {
  const AudiobookCompanionPanel({required this.session, super.key});

  final CompanionPanelSession session;

  @override
  ConsumerState<AudiobookCompanionPanel> createState() =>
      _AudiobookCompanionPanelState();
}

class _AudiobookCompanionPanelState
    extends ConsumerState<AudiobookCompanionPanel> {
  final GlobalKey _currentLine = GlobalKey(debugLabel: 'audiobook-current');
  int _scrolledTo = -1;

  void _send(
    String action, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) => widget.session.command(action, args);

  /// Keeps the current line in view when it changes (not on every
  /// snapshot, so a user scrolling the transcript is not pulled back each
  /// second).
  void _followCurrent(int current) {
    if (current == _scrolledTo) return;
    _scrolledTo = current;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      final BuildContext? line = _currentLine.currentContext;
      if (line == null || !line.mounted) return;
      FushiFocusScroll.ensureVisible(
        line,
        alignment: 0.3,
        duration: fushiMotionDuration(context, FushiMotion.medium),
      );
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (BuildContext context, Widget? _) {
      final Map<String, Object?>? snap = widget.session.snapshot;
      if (snap == null) {
        return const Center(child: FushiCircularProgressIndicator());
      }
      return _body(context, snap);
    },
  );

  Widget _body(BuildContext context, Map<String, Object?> snap) {
    final int positionMs = snap.integer(AudiobookCompanionKeys.positionMs);
    final int durationMs = snap.integer(AudiobookCompanionKeys.durationMs);
    final bool playing = snap.flag(AudiobookCompanionKeys.playing);
    final double speed = snap.doubleOrNull(AudiobookCompanionKeys.speed) ?? 1.0;
    final int chapter = snap.integer(AudiobookCompanionKeys.chapterIndex);
    final int current = snap.integer(AudiobookCompanionKeys.current, -1);
    final List<Map<String, Object?>> lines = snap.maps(
      AudiobookCompanionKeys.lines,
    );
    final double? fraction = durationMs > 0 ? positionMs / durationMs : null;
    final String? author = snap.strOrNull(AudiobookCompanionKeys.author);
    final String chapterTitle = snap.str(AudiobookCompanionKeys.chapterTitle);
    _followCurrent(current);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        CompanionPanelHeader(
          label: t.second_screen_audiobook_header,
          trailing: durationMs > 0
              ? '${companionFormatClock(positionMs)} / '
                    '${companionFormatClock(durationMs)}'
              : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FushiEntranceScope(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                FushiStaggeredEntrance(
                  index: 0,
                  child: CompanionTitleBlock(
                    title: snap.str(AudiobookCompanionKeys.title),
                    subtitle: <String>[
                      ?author,
                      if (chapterTitle.isNotEmpty) chapterTitle,
                    ].join(' · '),
                    coverPath: snap.strOrNull(AudiobookCompanionKeys.cover),
                    fallbackIcon: FushiIcons.audiobook,
                  ),
                ),
                const SizedBox(height: 10),
                FushiStaggeredEntrance(
                  index: 1,
                  child: CompanionProgressRow(
                    label: t.second_screen_audiobook_chapter_listened(
                      n: chapter + 1,
                      percent: ((fraction ?? 0) * 100).round(),
                    ),
                    fraction: fraction,
                    valueText: '',
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: CompanionSectionLabel(t.second_screen_audiobook_transcript),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: lines.isEmpty
              ? const SizedBox.shrink()
              : SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final Map<String, Object?> line in lines)
                        _line(line, current),
                    ],
                  ),
                ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            8,
            16,
            8 + MediaQuery.paddingOf(context).bottom,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: CompanionActionRow(
                  children: <Widget>[
                    CompanionActionButton(
                      key: const ValueKey<String>('audiobook-prev-chapter'),
                      icon: FushiIcons.skipPrevious,
                      tooltip: t.second_screen_audiobook_previous_chapter,
                      onPressed: () =>
                          _send(AudiobookCompanionActions.previousChapter),
                    ),
                    CompanionActionButton(
                      key: const ValueKey<String>('audiobook-back'),
                      icon: FushiIcons.replay10,
                      tooltip: t.second_screen_video_back_10,
                      onPressed: () => _send(
                        AudiobookCompanionActions.seekRelative,
                        const <String, Object?>{
                          AudiobookCompanionActions.seconds: -10,
                        },
                      ),
                    ),
                    CompanionActionButton(
                      key: const ValueKey<String>('audiobook-play'),
                      icon: playing ? FushiIcons.pause : FushiIcons.play,
                      tooltip: playing ? t.pause : t.play,
                      primary: true,
                      onPressed: () =>
                          _send(AudiobookCompanionActions.playPause),
                    ),
                    CompanionActionButton(
                      key: const ValueKey<String>('audiobook-forward'),
                      icon: FushiIcons.forward10,
                      tooltip: t.second_screen_video_forward_10,
                      onPressed: () => _send(
                        AudiobookCompanionActions.seekRelative,
                        const <String, Object?>{
                          AudiobookCompanionActions.seconds: 10,
                        },
                      ),
                    ),
                    CompanionActionButton(
                      key: const ValueKey<String>('audiobook-next-chapter'),
                      icon: FushiIcons.skipNext,
                      tooltip: t.second_screen_audiobook_next_chapter,
                      onPressed: () =>
                          _send(AudiobookCompanionActions.nextChapter),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _SpeedButton(
                speed: speed,
                onPressed: () => _send(
                  AudiobookCompanionActions.setSpeed,
                  <String, Object?>{
                    AudiobookCompanionActions.speed: nextAudiobookSpeed(speed),
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _line(Map<String, Object?> line, int current) {
    final int index = line.integer(AudiobookCompanionKeys.lineIndex, -1);
    final String text = line.str(AudiobookCompanionKeys.lineText);
    final bool isCurrent = index == current;
    return Padding(
      key: isCurrent ? _currentLine : null,
      padding: const EdgeInsets.only(bottom: 6),
      child: CompanionLineTile(
        key: ValueKey<String>('audiobook-line-$index'),
        text: text,
        maxLines: 4,
        selected: isCurrent,
        semanticsHint: t.second_screen_audiobook_transcript,
        onTap: () => _send(
          AudiobookCompanionActions.seekLine,
          <String, Object?>{AudiobookCompanionActions.index: index},
        ),
        onLongPressChar: (int index) => ref
            .read(companionLookupControllerProvider)
            .lookUp(text: text, charIndex: index, sentence: text),
      ),
    );
  }
}

/// The next speed of the panel's speed button (cycles through
/// [AudiobookCompanionActions.speeds]; an off-list speed goes to the next
/// larger one).
double nextAudiobookSpeed(double speed) {
  const List<double> speeds = AudiobookCompanionActions.speeds;
  for (final double s in speeds) {
    if (s > speed + 0.001) return s;
  }
  return speeds.first;
}

class _SpeedButton extends StatelessWidget {
  const _SpeedButton({required this.speed, required this.onPressed});

  final double speed;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final String label = '${speed.toStringAsFixed(speed == 1 ? 1 : 2)}×';
    final String tooltip = '${t.second_screen_audiobook_speed} · $label';
    return FushiPressScale(
      child: FushiTooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          label: tooltip,
          excludeSemantics: true,
          child: SizedBox(
            height: CompanionActionButton.height,
            child: FushiFilledButton.tonal(
              key: const ValueKey<String>('audiobook-speed'),
              onPressed: onPressed,
              style: FilledButton.styleFrom(
                minimumSize: const Size(56, CompanionActionButton.height),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                shape: const RoundedRectangleBorder(
                  borderRadius: FushiM3eShape.smallRadius,
                ),
              ),
              child: Text(label),
            ),
          ),
        ),
      ),
    );
  }
}
