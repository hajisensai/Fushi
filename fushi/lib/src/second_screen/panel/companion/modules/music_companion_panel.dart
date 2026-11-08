import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_snapshot.dart';
import 'package:fushi/src/second_screen/companion/modules/music_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_lookup_controller.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/second_screen/panel/companion/modules/companion_module_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/settings_shared.dart'
    show gamepadSeekableSlider;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// The companion's Now panel while the music now-playing / lyrics page is on
/// top (`CompanionContextKind.music`): track, seek bar, a window of the lyrics
/// around the current line (tap a word to look it up here, play from a line),
/// the whole-song offset step and lyrics source choice the page already has,
/// and the transport. No lyric editing.
class MusicCompanionPanel extends StatelessWidget {
  const MusicCompanionPanel({required this.session, super.key});

  final CompanionPanelSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (BuildContext context, Widget? _) {
      final Map<String, Object?>? snapshot = session.snapshot;
      if (snapshot == null ||
          snapshot.strOrNull(MusicCompanionKeys.title) == null) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            CompanionPanelHeader(label: t.second_screen_context_music),
            Expanded(
              child: Center(
                child: FushiPlaceholderMessage(
                  icon: FushiIcons.music,
                  message: t.second_screen_music_nothing,
                ),
              ),
            ),
          ],
        );
      }
      return _MusicBody(session: session, snapshot: snapshot);
    },
  );
}

class _MusicBody extends StatelessWidget {
  const _MusicBody({required this.session, required this.snapshot});

  final CompanionPanelSession session;
  final Map<String, Object?> snapshot;

  void _send(String action, [Map<String, Object?> args = const {}]) =>
      unawaited(session.command(action, args));

  @override
  Widget build(BuildContext context) {
    final Map<String, Object?> s = snapshot;
    final bool playing = s.flag(MusicCompanionKeys.playing);
    final int position = s.integer(MusicCompanionKeys.positionMs);
    final int? duration = s.intOrNull(MusicCompanionKeys.durationMs);
    final bool canSeek = s.flag(MusicCompanionKeys.canSeek);
    final bool hasLyrics = s.flag(MusicCompanionKeys.hasLyrics);
    final bool synced = s.flag(MusicCompanionKeys.synced);
    final bool loading = s.flag(MusicCompanionKeys.lyricsLoading);
    final String subtitle = <String>[
      ?s.strOrNull(MusicCompanionKeys.artist),
      ?s.strOrNull(MusicCompanionKeys.album),
    ].join(' · ');
    final String clock = duration == null
        ? companionFormatClock(position)
        : '${companionFormatClock(position)} / ${companionFormatClock(duration)}';
    final List<Map<String, Object?>> lyrics = s.maps(MusicCompanionKeys.lyrics);

    final Widget lyricsArea = hasLyrics && lyrics.isNotEmpty
        ? _LyricsList(
            lines: lyrics,
            current: s.integer(MusicCompanionKeys.lyricIndex, -1),
            synced: synced,
            onSeekLine: (int index) => _send(
              MusicCompanionActions.seekLine,
              <String, Object?>{MusicCompanionKeys.index: index},
            ),
          )
        : loading
        ? const Center(child: FushiCircularProgressIndicator())
        : const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        CompanionPanelHeader(
          label: t.second_screen_context_music,
          trailing: clock,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: CompanionTitleBlock(
            title: s.str(MusicCompanionKeys.title),
            subtitle: subtitle.isEmpty ? null : subtitle,
            coverPath: s.strOrNull(MusicCompanionKeys.cover),
            fallbackIcon: FushiIcons.music,
          ),
        ),
        if (canSeek && duration != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Semantics(
              label: t.second_screen_music_seek,
              child: gamepadSeekableSlider(
                value: position.clamp(0, duration).toDouble(),
                max: duration.toDouble(),
                step: 5000,
                onChanged: (double _) {},
                onChangeEnd: (double v) => _send(
                  MusicCompanionActions.seek,
                  <String, Object?>{MusicCompanionKeys.ms: v.round()},
                ),
              ),
            ),
          )
        else
          const SizedBox(height: 12),
        _LyricsToolsRow(
          snapshot: s,
          onNudge: (int direction) => _send(
            MusicCompanionActions.nudgeOffset,
            <String, Object?>{MusicCompanionKeys.direction: direction},
          ),
          onChooseSource: () => _send(MusicCompanionActions.chooseSource),
          onResetSource: () => _send(MusicCompanionActions.resetSource),
        ),
        Expanded(child: lyricsArea),
        Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            8,
            16,
            12 + MediaQuery.paddingOf(context).bottom,
          ),
          child: CompanionActionRow(
            children: <Widget>[
              CompanionActionButton(
                icon: FushiIcons.skipPrevious,
                tooltip: t.shortcut_action_music_previous_track,
                onPressed: s.flag(MusicCompanionKeys.canPrevious)
                    ? () => _send(MusicCompanionActions.previous)
                    : null,
              ),
              CompanionActionButton(
                icon: playing ? FushiIcons.pause : FushiIcons.play,
                tooltip: playing ? t.pause : t.play,
                primary: true,
                onPressed: () => _send(MusicCompanionActions.playPause),
              ),
              CompanionActionButton(
                icon: FushiIcons.skipNext,
                tooltip: t.shortcut_action_music_next_track,
                onPressed: () => _send(MusicCompanionActions.next),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "Lyrics" caption + the page's existing lyric tools: whole-song offset
/// step (timed lyrics only), choose source, use automatic source.
class _LyricsToolsRow extends StatelessWidget {
  const _LyricsToolsRow({
    required this.snapshot,
    required this.onNudge,
    required this.onChooseSource,
    required this.onResetSource,
  });

  final Map<String, Object?> snapshot;
  final ValueChanged<int> onNudge;
  final VoidCallback onChooseSource;
  final VoidCallback onResetSource;

  static const double _buttonWidth = 52;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool hasLyrics = snapshot.flag(MusicCompanionKeys.hasLyrics);
    final bool synced = hasLyrics && snapshot.flag(MusicCompanionKeys.synced);
    Widget tool(Widget child) => Padding(
      padding: const EdgeInsetsDirectional.only(start: 6),
      child: SizedBox(width: _buttonWidth, child: child),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: hasLyrics
                ? Text(
                    t.second_screen_music_lyrics_label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          if (synced) ...<Widget>[
            tool(
              CompanionActionButton(
                icon: FushiIcons.remove,
                tooltip: t.music_lyrics_offset_later,
                onPressed: () => onNudge(-1),
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 6),
              child: Text(
                t.music_lyrics_offset_value(
                  ms: snapshot.integer(MusicCompanionKeys.offsetMs),
                ),
                style: theme.textTheme.labelSmall,
              ),
            ),
            tool(
              CompanionActionButton(
                icon: FushiIcons.add,
                tooltip: t.music_lyrics_offset_earlier,
                onPressed: () => onNudge(1),
              ),
            ),
          ],
          tool(
            CompanionActionButton(
              icon: FushiIcons.lyrics,
              tooltip: t.music_lyrics_choose_source,
              onPressed: onChooseSource,
            ),
          ),
          if (snapshot.flag(MusicCompanionKeys.userSource))
            tool(
              CompanionActionButton(
                icon: FushiIcons.undo,
                tooltip: t.music_lyrics_reset_source,
                onPressed: onResetSource,
              ),
            ),
        ],
      ),
    );
  }
}

/// The lyric window; the current line is highlighted and kept in view.
class _LyricsList extends StatefulWidget {
  const _LyricsList({
    required this.lines,
    required this.current,
    required this.synced,
    required this.onSeekLine,
  });

  final List<Map<String, Object?>> lines;
  final int current;
  final bool synced;
  final ValueChanged<int> onSeekLine;

  @override
  State<_LyricsList> createState() => _LyricsListState();
}

class _LyricsListState extends State<_LyricsList> {
  final GlobalKey _currentKey = GlobalKey(debugLabel: 'music-companion-line');

  @override
  void initState() {
    super.initState();
    _revealCurrent(animate: false);
  }

  @override
  void didUpdateWidget(covariant _LyricsList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.current != widget.current) _revealCurrent(animate: true);
  }

  void _revealCurrent({required bool animate}) {
    if (widget.current < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final BuildContext? line = _currentKey.currentContext;
      if (!mounted || line == null) return;
      unawaited(
        Scrollable.ensureVisible(
          line,
          alignment: 0.3,
          duration: animate
              ? fushiMotionDuration(context, FushiMotion.medium)
              : Duration.zero,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => FushiEntranceScope(
    child: ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: widget.lines.length,
      itemBuilder: fushiStaggeredItemBuilder((BuildContext context, int i) {
        final Map<String, Object?> line = widget.lines[i];
        final int index = line.integer(MusicCompanionKeys.index, -1);
        final bool selected = index == widget.current;
        return Padding(
          key: selected ? _currentKey : null,
          padding: const EdgeInsets.only(bottom: 6),
          child: _LyricLineRow(
            text: line.str(MusicCompanionKeys.text),
            translation: line.strOrNull(MusicCompanionKeys.translation),
            selected: selected,
            onSeek: widget.synced && index >= 0
                ? () => widget.onSeekLine(index)
                : null,
          ),
        );
      }),
    ),
  );
}

/// One lyric line: tap a word → looked up in the companion's Lookup tab
/// (the tapped character's index; activated by a controller it looks up
/// from the start of the line). Timed lyrics also get "Play from this line".
class _LyricLineRow extends ConsumerStatefulWidget {
  const _LyricLineRow({
    required this.text,
    required this.translation,
    required this.selected,
    required this.onSeek,
  });

  final String text;
  final String? translation;
  final bool selected;
  final VoidCallback? onSeek;

  @override
  ConsumerState<_LyricLineRow> createState() => _LyricLineRowState();
}

class _LyricLineRowState extends ConsumerState<_LyricLineRow> {
  final GlobalKey _textKey = GlobalKey(debugLabel: 'music-companion-text');
  int? _tappedIndex;

  int? _indexAt(Offset global) =>
      companionTextIndexAt(_textKey, widget.text, global);

  void _lookUp() {
    final String text = widget.text;
    final int index = _tappedIndex ?? 0;
    _tappedIndex = null;
    ref
        .read(companionLookupControllerProvider)
        .lookUp(text: text, charIndex: index, sentence: text);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final FushiSurfaceColors surfaces = FushiDesignTokens.of(context).surfaces;
    final String? translation = widget.translation;
    final VoidCallback? onSeek = widget.onSeek;
    final Widget line = Semantics(
      button: true,
      selected: widget.selected,
      hint: t.second_screen_music_lyrics_label,
      child: FushiPressScale(
        child: Material(
          color: widget.selected ? surfaces.selected : surfaces.group,
          shape: const RoundedRectangleBorder(
            borderRadius: FushiM3eShape.smallRadius,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTapDown: (TapDownDetails d) =>
                _tappedIndex = _indexAt(d.globalPosition),
            onTapCancel: () => _tappedIndex = null,
            onTap: _lookUp,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      widget.text,
                      key: _textKey,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: widget.selected
                            ? colors.onSecondaryContainer
                            : colors.onSurface,
                      ),
                    ),
                    if (translation != null)
                      Text(
                        translation,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
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
    if (onSeek == null) return line;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(child: line),
        const SizedBox(width: 6),
        SizedBox(
          width: 48,
          child: CompanionActionButton(
            icon: FushiIcons.play,
            tooltip: t.second_screen_music_play_line,
            onPressed: onSeek,
          ),
        ),
      ],
    );
  }
}
