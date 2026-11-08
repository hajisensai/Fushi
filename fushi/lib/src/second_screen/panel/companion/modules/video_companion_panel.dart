import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_snapshot.dart';
import 'package:fushi/src/second_screen/companion/modules/video_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_lookup_controller.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/second_screen/panel/companion/modules/companion_module_widgets.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptivePageRoute;
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart'
    show FushiSlider;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:material_ui/material_ui.dart';

/// Step of the "back / forward 10 seconds" buttons.
const int kVideoCompanionSeekStepMs = 10000;

/// One subtitle line of the snapshot window.
class _Cue {
  const _Cue({required this.start, required this.text});

  final int start;
  final String text;
}

/// A track of the snapshot ([id] = audio id or subtitle source).
class _Track {
  const _Track({required this.id, required this.label, required this.selected});

  final String id;
  final String label;
  final bool selected;
}

/// A cast / staff line: [role] = character (cast) or job (staff).
class _Credit {
  const _Credit({required this.name, this.role});

  final String name;
  final String? role;
}

/// Label of a cached staff credit kind (null for kinds without one).
String? _staffKindLabel(String? kind) => switch (kind) {
  'director' => t.second_screen_info_director,
  'writer' => t.second_screen_info_writer,
  _ => null,
};

/// The snapshot read once per rebuild (missing values = unknown / hidden).
class _VideoView {
  _VideoView(Map<String, Object?> s)
    : title = s.str(VideoCompanionKeys.title),
      series = s.strOrNull(VideoCompanionKeys.series),
      cover = s.strOrNull(VideoCompanionKeys.cover),
      episodeIndex = s.integer(VideoCompanionKeys.episodeIndex, -1),
      playing = s.flag(VideoCompanionKeys.playing),
      positionMs = s.integer(VideoCompanionKeys.positionMs),
      durationMs = s.integer(VideoCompanionKeys.durationMs),
      cueStart = s.integer(VideoCompanionKeys.cueStart, -1),
      cues = <_Cue>[
        for (final Map<String, Object?> c in s.maps(VideoCompanionKeys.cues))
          if (c.intOrNull(VideoCompanionKeys.start) != null)
            _Cue(
              start: c.integer(VideoCompanionKeys.start),
              text: c.str(VideoCompanionKeys.text),
            ),
      ],
      audioTracks = <_Track>[
        for (final Map<String, Object?> a in s.maps(
          VideoCompanionKeys.audioTracks,
        ))
          if (a.strOrNull(VideoCompanionKeys.id) != null)
            _Track(
              id: a.str(VideoCompanionKeys.id),
              label: a.str(VideoCompanionKeys.label),
              selected: a.flag(VideoCompanionKeys.selected),
            ),
      ],
      subtitleTracks = <_Track>[
        for (final Map<String, Object?> a in s.maps(
          VideoCompanionKeys.subtitleTracks,
        ))
          if (a.strOrNull(VideoCompanionKeys.source) != null)
            _Track(
              id: a.str(VideoCompanionKeys.source),
              label: a.str(VideoCompanionKeys.label),
              selected: a.flag(VideoCompanionKeys.selected),
            ),
      ],
      subtitlesOff = s.flag(VideoCompanionKeys.subtitlesOff),
      info = s.mapOrNull(VideoCompanionKeys.info) ?? const <String, Object?>{};

  final String title;
  final String? series;
  final String? cover;
  final int episodeIndex;
  final bool playing;
  final int positionMs;
  final int durationMs;
  final int cueStart;
  final List<_Cue> cues;
  final List<_Track> audioTracks;
  final List<_Track> subtitleTracks;
  final bool subtitlesOff;
  final Map<String, Object?> info;

  String? get workTitle => info.strOrNull(VideoCompanionKeys.workTitle);
  double? get rating => info.doubleOrNull(VideoCompanionKeys.rating);
  int? get votes => info.intOrNull(VideoCompanionKeys.votes);
  String? get overview => info.strOrNull(VideoCompanionKeys.overview);
  String? get episodeTitle => info.strOrNull(VideoCompanionKeys.episodeTitle);
  String? get episodeOverview =>
      info.strOrNull(VideoCompanionKeys.episodeOverview);

  /// Episode number: the scraped one, else the playlist position.
  int? get episodeNumber =>
      info.intOrNull(VideoCompanionKeys.episodeNumber) ??
      (episodeIndex >= 0 ? episodeIndex + 1 : null);

  /// The big title: the show (scraped work / playlist name), else the video.
  String get mainTitle => workTitle ?? series ?? title;

  /// "E3 · Episode title" (the file title when no episode title is cached and
  /// it is not already the main title).
  String? get subtitle {
    final int? n = episodeNumber;
    final String? name =
        episodeTitle ?? (title.isNotEmpty && title != mainTitle ? title : null);
    final List<String> parts = <String>[
      if (n != null) t.second_screen_video_episode_short(n: n),
      ?name,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// "★ 8.4 · 1234 votes" / "★ 8.4"; null without a rating.
  String? get ratingText {
    final double? r = rating;
    return r == null ? null : companionRatingLabel(r, votes: votes);
  }

  int? get year => info.intOrNull(VideoCompanionKeys.year);
  List<String> get studios => info.strings(VideoCompanionKeys.studios);
  List<String> get genres => info.strings(VideoCompanionKeys.genres);
  List<_Credit> get cast => <_Credit>[
    for (final Map<String, Object?> c in info.maps(VideoCompanionKeys.cast))
      if (c.strOrNull(VideoCompanionKeys.personName) case final String name)
        _Credit(name: name, role: c.strOrNull(VideoCompanionKeys.personRole)),
  ];
  List<_Credit> get staff => <_Credit>[
    for (final Map<String, Object?> c in info.maps(VideoCompanionKeys.staff))
      if (c.strOrNull(VideoCompanionKeys.personName) case final String name)
        _Credit(
          name: name,
          role:
              c.strOrNull(VideoCompanionKeys.staffJob) ??
              _staffKindLabel(c.strOrNull(VideoCompanionKeys.staffKind)),
        ),
  ];

  /// Year / studio facts of the info card (only the known ones).
  List<CompanionInfoFact> get facts => <CompanionInfoFact>[
    if (year case final int y)
      CompanionInfoFact(label: t.second_screen_info_year, value: '$y'),
    if (studios.isNotEmpty)
      CompanionInfoFact(
        label: t.second_screen_info_studio,
        value: studios.join(', '),
      ),
  ];

  /// Something for the info page beyond the title row.
  bool get hasInfo =>
      overview != null ||
      episodeOverview != null ||
      year != null ||
      studios.isNotEmpty ||
      genres.isNotEmpty ||
      info.maps(VideoCompanionKeys.cast).isNotEmpty ||
      info.maps(VideoCompanionKeys.staff).isNotEmpty;

  String get audioLabel {
    for (final _Track a in audioTracks) {
      if (a.selected) return a.label;
    }
    return audioTracks.isEmpty ? '' : audioTracks.first.label;
  }

  String get subtitleLabel {
    if (subtitlesOff) return t.second_screen_video_off;
    for (final _Track s in subtitleTracks) {
      if (s.selected) return s.label;
    }
    return t.second_screen_video_off;
  }
}

/// The video module's Now panel on the companion: what plays (cached show /
/// episode info), position + transport, the subtitle lines around the
/// current one (tap = jump, long-press = look the line up here), "Mine this
/// line" and the audio / subtitle track pickers.
class VideoCompanionPanel extends StatelessWidget {
  const VideoCompanionPanel({required this.session, super.key});

  final CompanionPanelSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (BuildContext context, Widget? _) {
      final Map<String, Object?>? snapshot = session.snapshot;
      if (snapshot == null || snapshot.isEmpty) {
        return Center(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.video,
            message: t.second_screen_video_waiting,
          ),
        );
      }
      return _VideoBody(session: session, view: _VideoView(snapshot));
    },
  );
}

class _VideoBody extends ConsumerWidget {
  const _VideoBody({required this.session, required this.view});

  final CompanionPanelSession session;
  final _VideoView view;

  void _send(String action, [Map<String, Object?>? args]) =>
      unawaited(session.command(action, args ?? const <String, Object?>{}));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int? episode = view.episodeNumber;
    final String header = episode == null
        ? t.second_screen_video_now_playing
        : '${t.second_screen_video_now_playing} · '
              '${t.second_screen_video_episode(n: episode)}';
    final List<Widget> sections = <Widget>[
      _TitleRow(
        view: view,
        onInfo: view.hasInfo ? () => _openInfo(context) : null,
      ),
      _PositionSection(
        positionMs: view.positionMs,
        durationMs: view.durationMs,
        onSeek: (int ms) => _send(
          VideoCompanionActions.seekTo,
          <String, Object?>{VideoCompanionKeys.ms: ms},
        ),
      ),
      CompanionActionRow(
        children: <Widget>[
          CompanionActionButton(
            icon: FushiIcons.replay10,
            tooltip: t.second_screen_video_back_10,
            onPressed: () =>
                _send(VideoCompanionActions.seekBy, <String, Object?>{
                  VideoCompanionKeys.ms: -kVideoCompanionSeekStepMs,
                }),
          ),
          CompanionActionButton(
            icon: FushiIcons.skipPrevious,
            tooltip: t.second_screen_video_previous_line,
            onPressed: () => _send(VideoCompanionActions.previousCue),
          ),
          CompanionActionButton(
            icon: view.playing ? FushiIcons.pause : FushiIcons.play,
            tooltip: view.playing ? t.pause : t.play,
            primary: true,
            onPressed: () => _send(VideoCompanionActions.playPause),
          ),
          CompanionActionButton(
            icon: FushiIcons.skipNext,
            tooltip: t.second_screen_video_next_line,
            onPressed: () => _send(VideoCompanionActions.nextCue),
          ),
          CompanionActionButton(
            icon: FushiIcons.forward10,
            tooltip: t.second_screen_video_forward_10,
            onPressed: () =>
                _send(VideoCompanionActions.seekBy, <String, Object?>{
                  VideoCompanionKeys.ms: kVideoCompanionSeekStepMs,
                }),
          ),
        ],
      ),
      CompanionSectionLabel(t.second_screen_video_subtitles_hint),
      _CueList(
        cues: view.cues,
        currentStart: view.cueStart,
        onJump: (_Cue cue) =>
            _send(VideoCompanionActions.jumpToCue, <String, Object?>{
              VideoCompanionKeys.start: cue.start,
              VideoCompanionKeys.text: cue.text,
            }),
        onLookUp: (_Cue cue) => ref
            .read(companionLookupControllerProvider)
            .lookUp(text: cue.text, sentence: cue.text),
      ),
      Row(
        children: <Widget>[
          Expanded(
            child: _LabeledButton(
              icon: FushiIcons.ankiCard,
              label: t.second_screen_video_mine_line,
              primary: true,
              onPressed: view.cues.isEmpty
                  ? null
                  : () => _send(VideoCompanionActions.mineLine),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _LabeledButton(
              icon: FushiIcons.audio,
              label: t.second_screen_video_audio_label(
                label: view.audioLabel.isEmpty ? '—' : view.audioLabel,
              ),
              onPressed: view.audioTracks.isEmpty
                  ? null
                  : () => _openTracks(context, audio: true),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _LabeledButton(
              icon: view.subtitlesOff
                  ? FushiIcons.subtitlesOff
                  : FushiIcons.subtitles,
              label: t.second_screen_video_subtitles_label(
                label: view.subtitleLabel,
              ),
              onPressed: () => _openTracks(context, audio: false),
            ),
          ),
        ],
      ),
    ];
    return FushiEntranceScope(
      child: ListView(
        padding: EdgeInsets.only(
          bottom: 16 + MediaQuery.paddingOf(context).bottom,
        ),
        children: <Widget>[
          CompanionPanelHeader(label: header, trailing: view.ratingText),
          for (int i = 0; i < sections.length; i++)
            Padding(
              padding: EdgeInsets.fromLTRB(16, i == 0 ? 0 : 12, 16, 0),
              child: FushiStaggeredEntrance(index: i, child: sections[i]),
            ),
        ],
      ),
    );
  }

  void _openInfo(BuildContext context) => unawaited(
    Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => _VideoInfoPage(session: session),
      ),
    ),
  );

  void _openTracks(BuildContext context, {required bool audio}) => unawaited(
    Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) =>
            _VideoTrackPage(session: session, audio: audio),
      ),
    ),
  );
}

class _TitleRow extends StatelessWidget {
  const _TitleRow({required this.view, required this.onInfo});

  final _VideoView view;
  final VoidCallback? onInfo;

  @override
  Widget build(BuildContext context) {
    final VoidCallback? info = onInfo;
    return Row(
      children: <Widget>[
        Expanded(
          child: CompanionTitleBlock(
            title: view.mainTitle,
            subtitle: view.subtitle,
            coverPath: view.cover,
            fallbackIcon: FushiIcons.video,
          ),
        ),
        if (info != null) ...<Widget>[
          const SizedBox(width: 8),
          SizedBox(
            width: 56,
            child: CompanionActionButton(
              icon: FushiIcons.info,
              tooltip: t.second_screen_video_info,
              onPressed: info,
            ),
          ),
        ],
      ],
    );
  }
}

/// Position slider (seeks on release) with the elapsed / total times.
class _PositionSection extends StatefulWidget {
  const _PositionSection({
    required this.positionMs,
    required this.durationMs,
    required this.onSeek,
  });

  final int positionMs;
  final int durationMs;
  final ValueChanged<int> onSeek;

  @override
  State<_PositionSection> createState() => _PositionSectionState();
}

class _PositionSectionState extends State<_PositionSection> {
  /// The value while the user drags (snapshots keep coming meanwhile).
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int duration = widget.durationMs;
    final bool known = duration > 0;
    final double max = known ? duration.toDouble() : 1;
    final double value = (_dragMs ?? widget.positionMs.toDouble()).clamp(
      0,
      max,
    );
    final TextStyle? style = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Semantics(
          label: t.second_screen_video_position,
          child: FushiSlider(
            value: value,
            max: max,
            onChanged: known ? (double v) => setState(() => _dragMs = v) : null,
            onChangeEnd: known
                ? (double v) {
                    setState(() => _dragMs = null);
                    widget.onSeek(v.round());
                  }
                : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(companionFormatClock(value.round()), style: style),
              ),
              Text(
                known ? companionFormatClock(duration) : '--:--',
                style: style,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The subtitle window (fixed height, follows the current line).
class _CueList extends StatefulWidget {
  const _CueList({
    required this.cues,
    required this.currentStart,
    required this.onJump,
    required this.onLookUp,
  });

  final List<_Cue> cues;
  final int currentStart;
  final ValueChanged<_Cue> onJump;
  final ValueChanged<_Cue> onLookUp;

  static const double height = 184;

  @override
  State<_CueList> createState() => _CueListState();
}

class _CueListState extends State<_CueList> {
  final GlobalKey _currentKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _followCurrent();
  }

  @override
  void didUpdateWidget(_CueList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentStart != widget.currentStart) _followCurrent();
  }

  void _followCurrent() {
    if (widget.currentStart < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      final BuildContext? target = _currentKey.currentContext;
      if (!mounted || target == null) return;
      unawaited(
        Scrollable.ensureVisible(
          target,
          alignment: 0.3,
          duration: fushiMotionDuration(context, FushiMotion.medium),
          curve: FushiMotion.standard,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.cues.isEmpty) {
      final ThemeData theme = Theme.of(context);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          t.second_screen_video_no_subtitles,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return SizedBox(
      height: _CueList.height,
      child: ClipRRect(
        borderRadius: FushiM3eShape.smallRadius,
        child: SingleChildScrollView(
          child: Column(
            children: <Widget>[
              for (final _Cue cue in widget.cues)
                Padding(
                  key: cue.start == widget.currentStart ? _currentKey : null,
                  padding: const EdgeInsets.only(bottom: 4),
                  child: CompanionLineTile(
                    text: cue.text,
                    leading: companionFormatClock(cue.start),
                    selected: cue.start == widget.currentStart,
                    semanticsHint: t.second_screen_video_line_hint,
                    onTap: () => widget.onJump(cue),
                    onLongPress: () => widget.onLookUp(cue),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tonal / filled button with icon + text (a picker or the mine action),
/// 52 dp tall, tooltip + Semantics with the full label.
class _LabeledButton extends StatelessWidget {
  const _LabeledButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final ButtonStyle style = FilledButton.styleFrom(
      minimumSize: const Size(48, CompanionActionButton.height),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      shape: const RoundedRectangleBorder(
        borderRadius: FushiM3eShape.smallRadius,
      ),
    );
    final Widget content = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        FushiIcon(icon, size: 20),
        const SizedBox(width: 6),
        Flexible(
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
    return FushiPressScale(
      child: FushiTooltip(
        message: label,
        child: Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          child: SizedBox(
            height: CompanionActionButton.height,
            child: primary
                ? FushiFilledButton(
                    onPressed: onPressed,
                    style: style,
                    child: content,
                  )
                : FushiFilledButton.tonal(
                    onPressed: onPressed,
                    style: style,
                    child: content,
                  ),
          ),
        ),
      ),
    );
  }
}

/// Header of a page pushed on the Now tab's navigator: back + title.
class _PushedHeader extends StatelessWidget {
  const _PushedHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(4, 8, 16, 4),
      child: Row(
        children: <Widget>[
          FushiIconButton(
            icon: FushiIcons.back,
            tooltip: t.back,
            padTouchTarget: true,
            onTap: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// Show / episode overview from the cached metadata (pushed page).
class _VideoInfoPage extends StatelessWidget {
  const _VideoInfoPage({required this.session});

  final CompanionPanelSession session;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: ListenableBuilder(
        listenable: session,
        builder: (BuildContext context, Widget? _) {
          final _VideoView view = _VideoView(
            session.snapshot ?? const <String, Object?>{},
          );
          final ThemeData theme = Theme.of(context);
          final String? rating = view.ratingText;
          final String? sub = view.subtitle;
          final String? overview = view.overview;
          final String? episodeOverview = view.episodeOverview;
          final CompanionInfoCard card = CompanionInfoCard(
            chips: view.genres,
            facts: view.facts,
          );
          final List<_Credit> cast = view.cast;
          final List<_Credit> staff = view.staff;
          final List<Widget> sections = <Widget>[
            if (rating != null)
              Text(
                rating,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            if (!card.isEmpty) card,
            if (overview != null) ...<Widget>[
              CompanionSectionLabel(t.second_screen_video_info_series),
              Text(overview, style: theme.textTheme.bodyMedium),
            ],
            if (episodeOverview != null) ...<Widget>[
              CompanionSectionLabel(
                sub == null
                    ? t.second_screen_video_info_episode
                    : '${t.second_screen_video_info_episode} · $sub',
              ),
              Text(episodeOverview, style: theme.textTheme.bodyMedium),
            ],
            if (cast.isNotEmpty) ...<Widget>[
              CompanionSectionLabel(t.second_screen_info_cast),
              _CreditList(credits: cast),
            ],
            if (staff.isNotEmpty) ...<Widget>[
              CompanionSectionLabel(t.second_screen_info_staff),
              _CreditList(credits: staff),
            ],
          ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _PushedHeader(title: view.mainTitle),
              Expanded(
                child: FushiEntranceScope(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    children: <Widget>[
                      for (int i = 0; i < sections.length; i++)
                        Padding(
                          padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
                          child: FushiStaggeredEntrance(
                            index: i,
                            child: sections[i],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

/// Cast / staff lines: name, role on the right (when cached).
class _CreditList extends StatelessWidget {
  const _CreditList({required this.credits});

  final List<_Credit> credits;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? meta = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final _Credit c in credits)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    c.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                if (c.role case final String role) ...<Widget>[
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      role,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: meta,
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// Audio or subtitle track picker (pushed page). Picking sends the command
/// and goes back.
class _VideoTrackPage extends StatelessWidget {
  const _VideoTrackPage({required this.session, required this.audio});

  final CompanionPanelSession session;
  final bool audio;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: ListenableBuilder(
        listenable: session,
        builder: (BuildContext context, Widget? _) {
          final _VideoView view = _VideoView(
            session.snapshot ?? const <String, Object?>{},
          );
          void pick(String action, [Map<String, Object?>? args]) {
            unawaited(
              session.command(action, args ?? const <String, Object?>{}),
            );
            unawaited(Navigator.of(context).maybePop());
          }

          final List<Widget> rows = audio
              ? <Widget>[
                  for (final _Track a in view.audioTracks)
                    CompanionLineTile(
                      text: a.label,
                      selected: a.selected,
                      maxLines: 1,
                      onTap: () => pick(
                        VideoCompanionActions.selectAudio,
                        <String, Object?>{VideoCompanionKeys.id: a.id},
                      ),
                    ),
                ]
              : <Widget>[
                  CompanionLineTile(
                    text: t.second_screen_video_subtitles_off,
                    selected: view.subtitlesOff,
                    maxLines: 1,
                    onTap: () => pick(VideoCompanionActions.subtitleOff),
                  ),
                  for (final _Track s in view.subtitleTracks)
                    CompanionLineTile(
                      text: s.label,
                      selected: s.selected && !view.subtitlesOff,
                      maxLines: 1,
                      onTap: () => pick(
                        VideoCompanionActions.selectSubtitle,
                        <String, Object?>{VideoCompanionKeys.source: s.id},
                      ),
                    ),
                ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _PushedHeader(
                title: audio
                    ? t.second_screen_video_audio_tracks
                    : t.second_screen_video_subtitle_tracks,
              ),
              Expanded(
                child: FushiEntranceScope(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    itemCount: rows.length,
                    itemBuilder: fushiStaggeredItemBuilder(
                      (BuildContext context, int index) => Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: rows[index],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
