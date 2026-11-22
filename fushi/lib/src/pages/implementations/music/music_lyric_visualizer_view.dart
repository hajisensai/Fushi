/// 歌词页的「全屏歌词动画」宿主（folia `VisualizerRenderer` + `VisualizerShell`）：在歌词页
/// 背景之上画选中的样式、共享字幕和悬停工具条；点一下 / Esc 退出回原布局（纯观赏，不查词，
/// 用户 2026-11-22 拍板）。另含样式选择面板与通用参数面板。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_registry.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_subtitle.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show FushiPlaybackClock;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 随机模式下本首的样式：按曲目种子稳定地挑一个（同一首重进不换）。
LyricVisualizerMode lyricVisualizerRandomModeFor(String trackUid) {
  const List<LyricVisualizerMode> pool = LyricVisualizerMode.values;
  return pool[lyricVisualizerSeedOf(trackUid) % pool.length];
}

/// 全屏宿主。
class MusicLyricVisualizerView extends StatefulWidget {
  const MusicLyricVisualizerView({
    super.key,
    required this.mode,
    required this.timeline,
    required this.clock,
    required this.offsetMs,
    required this.playing,
    required this.trackUid,
    required this.tunings,
    required this.fontScale,
    required this.onExit,
    required this.onPickStyle,
    this.coverPath,
    this.title,
    this.artist,
    this.album,
    this.onSeek,
  });

  final LyricVisualizerMode mode;
  final LyricTimeline? timeline;
  final FushiPlaybackClock clock;
  final int offsetMs;
  final bool playing;
  final String trackUid;

  /// 全部样式的落库参数（`{样式 prefValue: {key: 值}}`）。
  final Map<String, Map<String, Object?>> tunings;
  final double fontScale;
  final VoidCallback onExit;

  /// 悬停条上的「样式」按钮。
  final VoidCallback onPickStyle;
  final String? coverPath;
  final String? title;
  final String? artist;
  final String? album;
  final ValueChanged<int>? onSeek;

  @override
  State<MusicLyricVisualizerView> createState() =>
      _MusicLyricVisualizerViewState();
}

class _MusicLyricVisualizerViewState extends State<MusicLyricVisualizerView> {
  LyricVisualizerRuntime? _runtime;
  LyricTimeline? _runtimeOf;
  bool _hover = false;
  Timer? _hoverHide;
  final FocusNode _focus = FocusNode(debugLabel: 'music_visualizer');

  LyricVisualizerRuntime _runtimeFor(LyricTimeline t) {
    if (!identical(_runtimeOf, t) || _runtime == null) {
      _runtimeOf = t;
      _runtime = LyricVisualizerRuntime(t);
    }
    return _runtime!;
  }

  void _pokeHover() {
    _hoverHide?.cancel();
    if (!_hover) setState(() => _hover = true);
    _hoverHide = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _hover = false);
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _hoverHide?.cancel();
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onExit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final LyricVisualizerEntry entry = lyricVisualizerEntryOf(widget.mode);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final LyricVisualizerPalette palette = LyricVisualizerPalette.fromScheme(
      scheme,
    );
    final LyricTimeline? timeline = widget.timeline;
    final bool hasLyrics =
        timeline != null && timeline.isSynced && timeline.lines.isNotEmpty;
    Widget body;
    if (!hasLyrics) {
      body = _NoSyncedLyrics(
        title: widget.title,
        artist: widget.artist,
        palette: palette,
      );
    } else {
      final LyricVisualizerContext c = LyricVisualizerContext(
        timeline: timeline,
        runtime: _runtimeFor(timeline),
        clock: widget.clock,
        offsetMs: widget.offsetMs,
        playing: widget.playing,
        palette: palette,
        tuning: LyricVisualizerTuning(
          entry.tunings,
          widget.tunings[widget.mode.prefValue] ?? const <String, Object?>{},
        ),
        seed: lyricVisualizerSeedOf(widget.trackUid),
        motion: fushiMotionEnabled(context),
        fontScale: widget.fontScale,
        coverPath: widget.coverPath,
        title: widget.title,
        artist: widget.artist,
        album: widget.album,
        onSeek: widget.onSeek,
      );
      body = Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (!entry.sharedBackdrop) ColoredBox(color: palette.background),
          // 样式本体在 RepaintBoundary 里：逐帧重绘不连带页面其余部分。
          RepaintBoundary(child: entry.builder(c)),
          if (entry.sharedSubtitle)
            Positioned(
              left: 32,
              right: 32,
              bottom: 40,
              child: IgnorePointer(child: LyricVisualizerSubtitle(context: c)),
            ),
        ],
      );
    }
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: MouseRegion(
        onHover: (_) => _pokeHover(),
        child: GestureDetector(
          key: const ValueKey<String>('music_visualizer_tap_exit'),
          behavior: HitTestBehavior.opaque,
          onTap: widget.onExit,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              AnimatedSwitcher(
                duration: fushiMotionDuration(context, FushiMotion.medium),
                child: KeyedSubtree(
                  key: ValueKey<String>(
                    'music_visualizer_${widget.mode.prefValue}',
                  ),
                  child: body,
                ),
              ),
              Positioned(
                top: 12,
                right: 12,
                child: AnimatedOpacity(
                  opacity: _hover ? 1 : 0,
                  duration: fushiMotionDuration(context, FushiMotion.short),
                  child: IgnorePointer(
                    ignoring: !_hover,
                    child: _HoverBar(
                      label: entry.label(),
                      onPickStyle: widget.onPickStyle,
                      onExit: widget.onExit,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HoverBar extends StatelessWidget {
  const _HoverBar({
    required this.label,
    required this.onPickStyle,
    required this.onExit,
  });

  final String label;
  final VoidCallback onPickStyle;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.72),
      shape: const StadiumBorder(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiPressScale(
              child: FushiTextButton.icon(
                key: const ValueKey<String>('music_visualizer_pick_style'),
                onPressed: onPickStyle,
                icon: const Icon(FushiIcons.animation),
                label: Text(label),
              ),
            ),
            FushiIconButtonControl(
              key: const ValueKey<String>('music_visualizer_exit'),
              tooltip: t.music_visualizer_exit,
              onPressed: onExit,
              icon: const Icon(FushiIcons.fullscreenExit),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoSyncedLyrics extends StatelessWidget {
  const _NoSyncedLyrics({
    required this.title,
    required this.artist,
    required this.palette,
  });

  final String? title;
  final String? artist;
  final LyricVisualizerPalette palette;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (title != null)
            Text(
              title!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 40,
                fontWeight: FontWeight.w700,
                color: palette.text,
              ),
            ),
          if (artist != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                artist!,
                style: TextStyle(fontSize: 20, color: palette.dimText),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 24),
            child: Text(
              t.music_visualizer_needs_synced,
              style: TextStyle(fontSize: 14, color: palette.dimText),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 选择面板
// ---------------------------------------------------------------------------

/// 选择面板的结果。
@immutable
class LyricVisualizerPick {
  const LyricVisualizerPick({required this.mode, required this.random});

  final LyricVisualizerMode mode;
  final bool random;
}

/// 打开样式选择面板。选了样式返回它（并立即进入全屏）；关掉返回 null。
/// [onTuningsChanged] 在面板里改参数时落库。
Future<LyricVisualizerPick?> showLyricVisualizerPicker({
  required BuildContext context,
  required LyricVisualizerMode current,
  required bool random,
  required Map<String, Map<String, Object?>> tunings,
  required Future<void> Function(String mode, Map<String, Object?> values)
  onTuningsChanged,
}) {
  return adaptiveModalSheet<LyricVisualizerPick>(
    context: context,
    builder: (BuildContext context) => _LyricVisualizerPicker(
      current: current,
      random: random,
      tunings: tunings,
      onTuningsChanged: onTuningsChanged,
    ),
  );
}

class _LyricVisualizerPicker extends StatefulWidget {
  const _LyricVisualizerPicker({
    required this.current,
    required this.random,
    required this.tunings,
    required this.onTuningsChanged,
  });

  final LyricVisualizerMode current;
  final bool random;
  final Map<String, Map<String, Object?>> tunings;
  final Future<void> Function(String mode, Map<String, Object?> values)
  onTuningsChanged;

  @override
  State<_LyricVisualizerPicker> createState() => _LyricVisualizerPickerState();
}

class _LyricVisualizerPickerState extends State<_LyricVisualizerPicker> {
  late bool _random = widget.random;
  late final Map<String, Map<String, Object?>> _tunings =
      <String, Map<String, Object?>>{...widget.tunings};

  Future<void> _openTuning(LyricVisualizerEntry entry) async {
    final Map<String, Object?>? next = await showLyricVisualizerTuningSheet(
      context: context,
      entry: entry,
      stored: _tunings[entry.mode.prefValue] ?? const <String, Object?>{},
    );
    if (next == null || !mounted) return;
    setState(() {
      if (next.isEmpty) {
        _tunings.remove(entry.mode.prefValue);
      } else {
        _tunings[entry.mode.prefValue] = next;
      }
    });
    await widget.onTuningsChanged(entry.mode.prefValue, next);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<LyricVisualizerEntry> entries = <LyricVisualizerEntry>[
      for (final LyricVisualizerMode m in LyricVisualizerMode.values)
        lyricVisualizerEntryOf(m),
    ];
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
            child: Text(
              t.music_visualizer_title,
              style: theme.textTheme.titleLarge,
            ),
          ),
          FushiSwitchListTile(
            key: const ValueKey<String>('music_visualizer_random'),
            value: _random,
            onChanged: (bool v) => setState(() => _random = v),
            title: Text(t.music_visualizer_random),
            subtitle: Text(t.music_visualizer_random_hint),
          ),
          Flexible(
            child: FushiEntranceScope(
              child: GridView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 220,
                  mainAxisExtent: 112,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: entries.length,
                itemBuilder: fushiStaggeredItemBuilder((
                  BuildContext context,
                  int i,
                ) {
                  final LyricVisualizerEntry e = entries[i];
                  return _StyleTile(
                    entry: e,
                    selected: !_random && e.mode == widget.current,
                    onTap: () => Navigator.of(
                      context,
                    ).pop(LyricVisualizerPick(mode: e.mode, random: _random)),
                    onTune: e.tunings.isEmpty
                        ? null
                        : () => unawaited(_openTuning(e)),
                  );
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StyleTile extends StatelessWidget {
  const _StyleTile({
    required this.entry,
    required this.selected,
    required this.onTap,
    this.onTune,
  });

  final LyricVisualizerEntry entry;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onTune;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    return FushiHoverLift(
      builder: (BuildContext context, bool hovering) => FushiPressScale(
        child: Material(
          key: ValueKey<String>('music_visualizer_style_${entry.mode.name}'),
          color: selected
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(entry.icon, size: 22),
                      const Spacer(),
                      if (onTune != null)
                        FushiIconButtonControl(
                          key: ValueKey<String>(
                            'music_visualizer_tune_${entry.mode.name}',
                          ),
                          visualDensity: VisualDensity.compact,
                          tooltip: t.music_visualizer_tuning,
                          onPressed: onTune,
                          icon: const Icon(FushiIcons.settings, size: 18),
                        ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    entry.label(),
                    style: text.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (entry.description != null)
                    Text(
                      entry.description!(),
                      style: text.bodySmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 参数面板（通用：按样式声明的 spec 画）
// ---------------------------------------------------------------------------

/// 打开某样式的参数面板。返回改动后要落库的值（空表 = 恢复默认），关掉不改返回 null。
Future<Map<String, Object?>?> showLyricVisualizerTuningSheet({
  required BuildContext context,
  required LyricVisualizerEntry entry,
  required Map<String, Object?> stored,
}) {
  return adaptiveModalSheet<Map<String, Object?>>(
    context: context,
    builder: (BuildContext context) =>
        LyricVisualizerTuningPanel(entry: entry, stored: stored),
  );
}

/// 参数面板本体（可单测）。
class LyricVisualizerTuningPanel extends StatefulWidget {
  const LyricVisualizerTuningPanel({
    super.key,
    required this.entry,
    required this.stored,
  });

  final LyricVisualizerEntry entry;
  final Map<String, Object?> stored;

  @override
  State<LyricVisualizerTuningPanel> createState() =>
      _LyricVisualizerTuningPanelState();
}

class _LyricVisualizerTuningPanelState
    extends State<LyricVisualizerTuningPanel> {
  late Map<String, Object> _values = LyricVisualizerTuning(
    widget.entry.tunings,
    widget.stored,
  ).toMap();

  /// 只存与默认不同的项。
  Map<String, Object?> _diff() => <String, Object?>{
    for (final LyricVisualizerTuningSpec s in widget.entry.tunings)
      if (_values[s.key] != s.defaultValue) s.key: _values[s.key],
  };

  Widget _row(LyricVisualizerTuningSpec spec) {
    final Object value = _values[spec.key] ?? spec.defaultValue;
    return switch (spec) {
      LyricVisualizerSliderSpec() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(child: Text(spec.label())),
                Text(
                  spec.format?.call(value as double) ??
                      (value as double).toStringAsFixed(2),
                ),
              ],
            ),
            FushiSlider(
              key: ValueKey<String>('music_visualizer_tuning_${spec.key}'),
              value: value as double,
              min: spec.min,
              max: spec.max,
              divisions: spec.divisions,
              onChanged: (double v) => setState(() => _values[spec.key] = v),
            ),
          ],
        ),
      ),
      LyricVisualizerToggleSpec() => FushiSwitchListTile(
        key: ValueKey<String>('music_visualizer_tuning_${spec.key}'),
        value: value as bool,
        onChanged: (bool v) => setState(() => _values[spec.key] = v),
        title: Text(spec.label()),
      ),
      LyricVisualizerChoiceSpec() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(spec.label()),
            const SizedBox(height: 6),
            adaptiveSegmentedButton<String>(
              context: context,
              segments: <ButtonSegment<String>>[
                for (final (String v, String Function() label) in spec.options)
                  ButtonSegment<String>(value: v, label: Text(label())),
              ],
              selected: <String>{value as String},
              onSelectionChanged: (Set<String> s) {
                if (s.isNotEmpty) setState(() => _values[spec.key] = s.first);
              },
            ),
          ],
        ),
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
            child: Text(
              widget.entry.label(),
              style: theme.textTheme.titleLarge,
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: <Widget>[
                for (final LyricVisualizerTuningSpec s in widget.entry.tunings)
                  _row(s),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: <Widget>[
                FushiTextButton(
                  key: const ValueKey<String>('music_visualizer_tuning_reset'),
                  onPressed: () => setState(
                    () => _values = LyricVisualizerTuning.defaults(
                      widget.entry.tunings,
                    ).toMap(),
                  ),
                  child: Text(t.music_visualizer_tuning_reset),
                ),
                const Spacer(),
                FushiFilledButton(
                  key: const ValueKey<String>('music_visualizer_tuning_done'),
                  onPressed: () => Navigator.of(context).pop(_diff()),
                  child: Text(MaterialLocalizations.of(context).okButtonLabel),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
