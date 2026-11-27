/// 歌词页的「全屏歌词动画」宿主（folia `VisualizerRenderer` + `VisualizerShell`）：在歌词页
/// 背景之上画选中的样式、共享字幕和悬停工具条；点一下 / Esc 退出回原布局（纯观赏，不查词，
/// 用户 2026-11-22 拍板）。另含样式选择面板与通用参数面板。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/ai_theme/lyric_visualizer_ai_theme_controller.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/ai_theme/lyric_visualizer_ai_theme_sheet.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_assets.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_registry.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_subtitle.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiTextField;
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show FushiPlaybackClock;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart'
    show FushiChoiceChip;
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiExpansionTile;
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/state_resource_scope.dart';

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
    this.intensity = LyricVisualizerIntensity.normal,
    this.backgroundId,
    this.mvBackdrop = false,
    this.subtitle = LyricVisualizerSubtitleSettings.defaults,
    this.theme,
    this.audio,
    this.aiTheme,
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

  /// 全局动画强度偏好（`music_visualizer_intensity`）；[theme] 指定了强度时以主题为准。
  final LyricVisualizerIntensity intensity;

  /// 用户选的共享背景（`music_visualizer_background`）；null = 默认（歌词页背景）。
  final String? backgroundId;

  /// 歌词页正在放 MV 背景（`MusicMvBackdropController.showing`）：用共享背景的样式不画
  /// 背景，让下面的 MV 透上来（[lyricVisualizerBackgroundYieldsToMv]）。
  final bool mvBackdrop;

  /// 全局字幕偏好（`music_visualizer_subtitle_*`），原样进样式 context。
  final LyricVisualizerSubtitleSettings subtitle;

  /// 本首的歌词动画主题（AI 主题）；null = 封面取色。
  final LyricVisualizerTheme? theme;

  /// 本首的音频分析；null = 样式回落歌词包络。
  final LyricVisualizerAudio? audio;

  /// 每首的 AI 主题（[theme] 为 null 时用它的）；null = 不提供 AI 主题入口。
  final LyricVisualizerAiThemeController? aiTheme;

  @override
  State<MusicLyricVisualizerView> createState() =>
      _MusicLyricVisualizerViewState();
}

class _MusicLyricVisualizerViewState extends State<MusicLyricVisualizerView>
    with StateResourceScope<MusicLyricVisualizerView> {
  late final _PlaybackClockAdapter _clock = _PlaybackClockAdapter(
    () => widget.clock,
  );
  LyricVisualizerRuntime? _runtime;
  LyricTimeline? _runtimeOf;

  /// 上一帧交给样式的输入：值没变就沿用同一个对象，样式的 didUpdateWidget 不白跑。
  LyricVisualizerContext? _lastContext;
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

  /// 挂 / 换 AI 主题控制器的监听；没有时用空撤销顶掉旧槽位。
  void _listenAiTheme() {
    final LyricVisualizerAiThemeController? theme = widget.aiTheme;
    if (theme != null) {
      listenTo(theme, _onAiTheme, slot: #aiTheme);
    } else {
      onTeardown(() {}, slot: #aiTheme);
    }
  }

  void _onAiTheme() {
    if (mounted) setState(() {});
  }

  void _attachAiTheme() => unawaited(
    widget.aiTheme?.attach(
      LyricVisualizerAiThemeTrack(
        uid: widget.trackUid,
        title: widget.title,
        artist: widget.artist,
        timeline: widget.timeline,
      ),
    ),
  );

  @override
  void didUpdateWidget(covariant MusicLyricVisualizerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.aiTheme, widget.aiTheme)) {
      _listenAiTheme();
    }
    if (!identical(oldWidget.aiTheme, widget.aiTheme) ||
        oldWidget.trackUid != widget.trackUid ||
        !identical(oldWidget.timeline, widget.timeline)) {
      _attachAiTheme();
    }
  }

  @override
  void initState() {
    super.initState();
    _listenAiTheme();
    _attachAiTheme();
    schedulePostFrame((_) {
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
    // 宿主让场景铺满整窗（含桌面顶栏拖动条 / 系统安全区）；浮在场景上的
    // 控件与字幕按安全区内缩，免得压到窗口按钮 / 刘海。
    final EdgeInsets safe = MediaQuery.paddingOf(context);
    final LyricVisualizerTheme? visualTheme =
        widget.theme ??
        widget.aiTheme?.themeFor(widget.trackUid, scheme.brightness);
    final LyricVisualizerPalette palette = LyricVisualizerPalette.fromScheme(
      scheme,
    ).applyOverride(visualTheme?.palette);
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
      final LyricVisualizerTuning tuning = LyricVisualizerTuning(
        entry.tunings,
        widget.tunings[widget.mode.prefValue] ?? const <String, Object?>{},
      );
      final LyricVisualizerContext fresh = LyricVisualizerContext(
        timeline: timeline,
        runtime: _runtimeFor(timeline),
        clock: _clock,
        offsetMs: widget.offsetMs,
        playing: widget.playing,
        palette: palette,
        tuning: tuning,
        seed: lyricVisualizerSeedOf(widget.trackUid),
        motion: fushiMotionEnabled(context),
        fontScale: widget.fontScale,
        coverPath: widget.coverPath,
        title: widget.title,
        artist: widget.artist,
        album: widget.album,
        onSeek: widget.onSeek,
        intensity: visualTheme?.intensity ?? widget.intensity,
        theme: visualTheme,
        audio: widget.audio,
        subtitle: widget.subtitle,
      );
      final LyricVisualizerContext c = fresh == _lastContext
          ? _lastContext!
          : fresh;
      _lastContext = c;
      // 背景层（folia 背景独立组合）：样式按参数请求，宿主画在样式下面。
      final LyricVisualizerBackgroundRequest backgroundRequest = entry
          .backgroundFor(tuning);
      // 歌词页在放 MV 背景时共享背景让位，MV 从下面透上来。
      final LyricVisualizerBackgroundEntry? background =
          lyricVisualizerBackgroundYieldsToMv(
            backgroundRequest,
            mvShowing: widget.mvBackdrop,
          )
          ? null
          : resolveLyricVisualizerBackground(
              backgroundRequest,
              widget.backgroundId,
            );
      body = Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (background != null && !background.drawsNothing)
            RepaintBoundary(
              key: ValueKey<String>(
                'music_visualizer_background_${background.id}',
              ),
              child: IgnorePointer(
                child: background.builder(
                  c,
                  lyricVisualizerBackgroundTuning(
                    background,
                    widget.tunings[lyricVisualizerBackgroundTuningKey(
                          background.id,
                        )] ??
                        const <String, Object?>{},
                    backgroundRequest,
                  ),
                ),
              ),
            ),
          // 样式本体在 RepaintBoundary 里：逐帧重绘不连带页面其余部分。
          RepaintBoundary(child: entry.builder(c)),
          if (entry.sharedSubtitle)
            Positioned(
              left: 32 + safe.left,
              right: 32 + safe.right,
              bottom: 40 + safe.bottom,
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
        // 单击画面只唤出悬停控制条（触屏没有悬停，这是它唤出控制条的途径），不退出：
        // 在 MV 背景上随手一点就退回原布局太容易误触（反馈 0i-FWiMxFO）。退出只走
        // Esc（_onKey）、返回键（歌词页的 PopScope）和控制条上的退出按钮。
        child: GestureDetector(
          key: const ValueKey<String>('music_visualizer_tap_reveal'),
          behavior: HitTestBehavior.opaque,
          onTap: _pokeHover,
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
                top: 12 + safe.top,
                right: 12 + safe.right,
                child: AnimatedOpacity(
                  opacity: _hover ? 1 : 0,
                  duration: fushiMotionDuration(context, FushiMotion.short),
                  child: IgnorePointer(
                    ignoring: !_hover,
                    child: _HoverBar(
                      label: entry.label(),
                      onPickStyle: widget.onPickStyle,
                      onAiTheme: widget.aiTheme?.available ?? false
                          ? () => unawaited(
                              showLyricVisualizerAiThemeSheet(
                                context: context,
                                controller: widget.aiTheme!,
                              ),
                            )
                          : null,
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

/// app 的播放时钟 → 框架的最小时钟接口（读当前 widget 的时钟，换时钟不用重建 context）。
class _PlaybackClockAdapter implements LyricVisualizerClock {
  _PlaybackClockAdapter(this._source);

  final FushiPlaybackClock Function() _source;

  @override
  Duration get position => _source().position;

  @override
  Duration get duration => _source().duration;
}

class _HoverBar extends StatelessWidget {
  const _HoverBar({
    required this.label,
    required this.onPickStyle,
    required this.onExit,
    this.onAiTheme,
  });

  final String label;
  final VoidCallback onPickStyle;

  /// 「AI 主题」；null = 不显示（AI 模块关着 / 宿主没给控制器）。
  final VoidCallback? onAiTheme;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    return Material(
      // 浮在画面上的控件条：浮层面板色阶，再压一层透明度透出底下的动画。
      color: FushiDesignTokens.of(
        context,
      ).surfaces.overlay.withValues(alpha: 0.72),
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
            if (onAiTheme != null)
              FushiIconButtonControl(
                key: const ValueKey<String>('music_visualizer_ai_theme'),
                tooltip: t.music_visualizer_ai_theme,
                onPressed: onAiTheme,
                icon: const Icon(FushiIcons.aiAssistant),
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
/// [backgroundId] 是用户选的共享背景：它有参数时面板里多一个「背景设置」入口，改动经
/// [onTuningsChanged] 落在 `lyricVisualizerBackgroundTuningKey(id)` 下。
Future<LyricVisualizerPick?> showLyricVisualizerPicker({
  required BuildContext context,
  required LyricVisualizerMode current,
  required bool random,
  required Map<String, Map<String, Object?>> tunings,
  required Future<void> Function(String mode, Map<String, Object?> values)
  onTuningsChanged,
  String? backgroundId,
}) {
  return adaptiveModalSheet<LyricVisualizerPick>(
    context: context,
    builder: (BuildContext context) => _LyricVisualizerPicker(
      current: current,
      random: random,
      tunings: tunings,
      onTuningsChanged: onTuningsChanged,
      backgroundId: backgroundId,
    ),
  );
}

class _LyricVisualizerPicker extends StatefulWidget {
  const _LyricVisualizerPicker({
    required this.current,
    required this.random,
    required this.tunings,
    required this.onTuningsChanged,
    this.backgroundId,
  });

  final LyricVisualizerMode current;
  final bool random;
  final Map<String, Map<String, Object?>> tunings;
  final Future<void> Function(String mode, Map<String, Object?> values)
  onTuningsChanged;
  final String? backgroundId;

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

  Future<void> _openBackgroundTuning(
    LyricVisualizerBackgroundEntry background,
  ) async {
    final String key = lyricVisualizerBackgroundTuningKey(background.id);
    final Map<String, Object?>? next =
        await showLyricVisualizerBackgroundTuningSheet(
          context: context,
          background: background,
          stored: _tunings[key] ?? const <String, Object?>{},
        );
    if (next == null || !mounted) return;
    setState(() {
      if (next.isEmpty) {
        _tunings.remove(key);
      } else {
        _tunings[key] = next;
      }
    });
    await widget.onTuningsChanged(key, next);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 「背景设置」对的是当前样式实际画的背景：样式请求了专属背景（如莫奈）时调那个，
    // 否则调用户选的共享背景；样式要透明底时没有背景可调。
    final LyricVisualizerEntry currentEntry = lyricVisualizerEntryOf(
      widget.current,
    );
    final LyricVisualizerBackgroundEntry? background =
        resolveLyricVisualizerBackground(
          currentEntry.backgroundFor(
            LyricVisualizerTuning(
              currentEntry.tunings,
              _tunings[widget.current.prefValue] ?? const <String, Object?>{},
            ),
          ),
          widget.backgroundId,
        );
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
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
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
          if (background != null && background.tunings.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: FushiPressScale(
                  child: FushiTextButton.icon(
                    key: const ValueKey<String>(
                      'music_visualizer_background_tuning',
                    ),
                    onPressed: () =>
                        unawaited(_openBackgroundTuning(background)),
                    icon: Icon(background.icon),
                    label: Text(
                      '${t.music_visualizer_background_tuning} · '
                      '${background.label()}',
                    ),
                  ),
                ),
              ),
            ),
          Flexible(
            child: FushiEntranceScope(
              // 卡片高度要按网格实际列宽排版说明才量得准，所以在 LayoutBuilder 里拿宽度。
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) =>
                    GridView.builder(
                      shrinkWrap: true,
                      padding: _kStyleGridPadding,
                      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: _kStyleGridMaxTileWidth,
                        mainAxisExtent: lyricVisualizerStyleTileExtent(
                          context,
                          entries: entries,
                          gridWidth: constraints.maxWidth,
                        ),
                        crossAxisSpacing: _kStyleGridSpacing,
                        mainAxisSpacing: _kStyleGridSpacing,
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
                          onTap: () => Navigator.of(context).pop(
                            LyricVisualizerPick(mode: e.mode, random: _random),
                          ),
                          onTune: e.tunings.isEmpty
                              ? null
                              : () => unawaited(_openTuning(e)),
                        );
                      }),
                    ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 样式卡高度：按网格实际列宽把每张卡的标题和说明完整排版一次（含系统字号放大），
/// 取最高那张定整个网格的 `mainAxisExtent`，所有卡的说明都完整显示、不截断不加省略号。
///
/// 早先写死 112（说明被上下裁，BUG-5355），后来按「标题一行 + 说明两行」量（说明
/// 多于两行时被截成省略号，BUG-5369）；说明长短各异，只有按真实宽度排版才量得准。
double lyricVisualizerStyleTileExtent(
  BuildContext context, {
  required List<LyricVisualizerEntry> entries,
  required double gridWidth,
}) {
  final TextTheme text = Theme.of(context).textTheme;
  final TextStyle base = DefaultTextStyle.of(context).style;
  final TextScaler scaler = MediaQuery.textScalerOf(context);
  final TextDirection direction = Directionality.of(context);
  final Locale? locale = Localizations.maybeLocaleOf(context);
  final double textWidth = math.max(
    0,
    lyricVisualizerStyleTileWidth(gridWidth) - _kStyleTilePadding * 2,
  );
  double measure(String value, TextStyle? style) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: value, style: base.merge(style)),
      textDirection: direction,
      textScaler: scaler,
      locale: locale,
    )..layout(maxWidth: textWidth);
    final double h = painter.height;
    painter.dispose();
    return h;
  }

  double tallest = 0;
  for (final LyricVisualizerEntry e in entries) {
    final String? description = e.description?.call();
    final double h =
        measure(e.label(), text.titleMedium) +
        (description == null ? 0 : measure(description, text.bodySmall));
    tallest = math.max(tallest, h);
  }
  return (_kStyleTilePadding * 2 +
          _kStyleTileIconRowHeight +
          _kStyleTileTitleGap +
          tallest)
      .ceilToDouble();
}

/// 样式网格（`SliverGridDelegateWithMaxCrossAxisExtent`）在 [gridWidth] 下每列的实际宽度，
/// 与网格自己的分列算法一致。
double lyricVisualizerStyleTileWidth(double gridWidth) {
  final double usable = math.max(0, gridWidth - _kStyleGridPadding.horizontal);
  final int columns = math.max(
    1,
    (usable / (_kStyleGridMaxTileWidth + _kStyleGridSpacing)).ceil(),
  );
  return math.max(0, usable - _kStyleGridSpacing * (columns - 1)) / columns;
}

const EdgeInsets _kStyleGridPadding = EdgeInsets.fromLTRB(16, 8, 16, 16);
const double _kStyleGridMaxTileWidth = 220;
const double _kStyleGridSpacing = 12;
const double _kStyleTilePadding = 14;
const double _kStyleTileIconRowHeight = 48;
const double _kStyleTileTitleGap = 6;

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
              : FushiDesignTokens.of(context).surfaces.overlay,
          borderRadius: FushiM3eShape.cardRadius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(_kStyleTilePadding),
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
                          tooltip: t.music_visualizer_tuning,
                          onPressed: onTune,
                          icon: const Icon(FushiIcons.settings, size: 18),
                        ),
                    ],
                  ),
                  // 卡片高度按实际列宽排版量出（lyricVisualizerStyleTileExtent）：
                  // 标题与说明都不限行数，完整显示，贴底对齐。
                  const SizedBox(height: _kStyleTileTitleGap),
                  Expanded(
                    child: Align(
                      alignment: AlignmentDirectional.bottomStart,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(entry.label(), style: text.titleMedium),
                          if (entry.description != null)
                            Text(entry.description!(), style: text.bodySmall),
                        ],
                      ),
                    ),
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
// 参数面板（通用：按样式 / 背景声明的 spec 画）
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

/// 打开某个背景的参数面板（返回值同 [showLyricVisualizerTuningSheet]；落库键是
/// `lyricVisualizerBackgroundTuningKey(background.id)`）。
Future<Map<String, Object?>?> showLyricVisualizerBackgroundTuningSheet({
  required BuildContext context,
  required LyricVisualizerBackgroundEntry background,
  required Map<String, Object?> stored,
}) {
  return adaptiveModalSheet<Map<String, Object?>>(
    context: context,
    builder: (BuildContext context) => LyricVisualizerTuningPanel.specs(
      title: background.label,
      specs: background.tunings,
      stored: stored,
    ),
  );
}

/// 参数面板本体（可单测）：滑杆 / 开关 / 单选 / 颜色 / 文本 / 素材包，条件显隐、分组折叠、预设。
class LyricVisualizerTuningPanel extends StatefulWidget {
  LyricVisualizerTuningPanel({
    super.key,
    required LyricVisualizerEntry entry,
    required this.stored,
    this.assetStore = LyricVisualizerAssetStore.open,
    this.pickAssetFiles = pickLyricVisualizerAssetFiles,
  }) : title = entry.label,
       specs = entry.tunings,
       presets = entry.tuningPresets;

  const LyricVisualizerTuningPanel.specs({
    super.key,
    required this.title,
    required this.specs,
    required this.stored,
    this.presets = const <LyricVisualizerTuningPreset>[],
    this.assetStore = LyricVisualizerAssetStore.open,
    this.pickAssetFiles = pickLyricVisualizerAssetFiles,
  });

  final String Function() title;
  final List<LyricVisualizerTuningSpec> specs;
  final List<LyricVisualizerTuningPreset> presets;
  final Map<String, Object?> stored;

  /// 素材库（测试注入临时目录）。
  final Future<LyricVisualizerAssetStore> Function() assetStore;

  /// 选图（测试注入）。
  final Future<List<String>> Function() pickAssetFiles;

  @override
  State<LyricVisualizerTuningPanel> createState() =>
      _LyricVisualizerTuningPanelState();
}

class _LyricVisualizerTuningPanelState
    extends State<LyricVisualizerTuningPanel> {
  // 可写副本：`toMap()` 是只读视图，直接往里写会抛（旧面板任何一项一改就抛）。
  late Map<String, Object> _values = Map<String, Object>.of(
    LyricVisualizerTuning(widget.specs, widget.stored).toMap(),
  );

  /// 只存与默认不同的项。
  Map<String, Object?> _diff() => <String, Object?>{
    for (final LyricVisualizerTuningSpec s in widget.specs)
      if (_values[s.key] != s.defaultValue) s.key: _values[s.key],
  };

  LyricVisualizerTuning get _current =>
      LyricVisualizerTuning(widget.specs, _values);

  void _set(String key, Object value) => setState(() => _values[key] = value);

  bool _visible(LyricVisualizerTuningSpec s, LyricVisualizerTuning current) =>
      s.visibleWhen?.call(current) ?? true;

  Widget _labelled(String label, Widget child, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text(label)),
            ?trailing,
          ],
        ),
        const SizedBox(height: 6),
        child,
      ],
    ),
  );

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
              onChanged: (double v) => _set(spec.key, v),
            ),
          ],
        ),
      ),
      LyricVisualizerToggleSpec() => FushiSwitchListTile(
        key: ValueKey<String>('music_visualizer_tuning_${spec.key}'),
        value: value as bool,
        onChanged: (bool v) => _set(spec.key, v),
        title: Text(spec.label()),
      ),
      LyricVisualizerChoiceSpec() => _labelled(
        spec.label(),
        adaptiveSegmentedButton<String>(
          context: context,
          segments: <ButtonSegment<String>>[
            for (final (String v, String Function() label) in spec.options)
              ButtonSegment<String>(value: v, label: Text(label())),
          ],
          selected: <String>{value as String},
          onSelectionChanged: (Set<String> s) {
            if (s.isNotEmpty) _set(spec.key, s.first);
          },
        ),
      ),
      LyricVisualizerColorSpec() => _ColorTuningRow(
        key: ValueKey<String>('music_visualizer_tuning_${spec.key}'),
        spec: spec,
        value: Color(value as int),
        onChanged: (Color c) => _set(spec.key, spec.normalize(c.toARGB32())),
      ),
      LyricVisualizerTextSpec() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: FushiTextField(
          key: ValueKey<String>('music_visualizer_tuning_${spec.key}'),
          initialValue: value as String,
          labelText: spec.label(),
          hintText: spec.hint?.call(),
          maxLength: spec.maxLength,
          onChanged: (String v) => _set(spec.key, spec.normalize(v)),
        ),
      ),
      LyricVisualizerAssetPackSpec() => _AssetPackTuningRow(
        key: ValueKey<String>('music_visualizer_tuning_${spec.key}'),
        spec: spec,
        pack: value as String,
        store: widget.assetStore,
        pickAssetFiles: widget.pickAssetFiles,
        onPackChanged: (String pack) => _set(spec.key, pack),
      ),
    };
  }

  /// 按分组链画：同一分组的相邻项收进一个折叠区块，分组可嵌套。
  List<Widget> _items(
    List<LyricVisualizerTuningSpec> specs,
    int depth,
    LyricVisualizerTuning current,
  ) {
    final List<Widget> out = <Widget>[];
    int i = 0;
    while (i < specs.length) {
      final LyricVisualizerTuningSpec s = specs[i];
      final List<LyricVisualizerTuningSection> path =
          s.section?.path ?? const <LyricVisualizerTuningSection>[];
      if (path.length <= depth) {
        if (_visible(s, current)) out.add(_row(s));
        i++;
        continue;
      }
      final LyricVisualizerTuningSection section = path[depth];
      final List<LyricVisualizerTuningSpec> group =
          <LyricVisualizerTuningSpec>[];
      while (i < specs.length) {
        final List<LyricVisualizerTuningSection> p =
            specs[i].section?.path ?? const <LyricVisualizerTuningSection>[];
        if (p.length <= depth || p[depth] != section) break;
        group.add(specs[i]);
        i++;
      }
      final List<Widget> children = _items(group, depth + 1, current);
      if (children.isEmpty) continue;
      out.add(
        FushiExpansionTile(
          key: ValueKey<String>('music_visualizer_section_${section.key}'),
          title: Text(section.label()),
          initiallyExpanded: section.initiallyExpanded,
          tilePadding: EdgeInsets.only(left: 24.0 + depth * 12, right: 16),
          children: children,
        ),
      );
    }
    return out;
  }

  Widget _presets() {
    final Map<String, Object> defaults = LyricVisualizerTuning.defaults(
      widget.specs,
    ).toMap();
    bool same(Map<String, Object> m) =>
        m.length == _values.length &&
        m.entries.every(
          (MapEntry<String, Object> e) => _values[e.key] == e.value,
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Text(t.music_visualizer_tuning_presets),
          FushiChoiceChip(
            key: const ValueKey<String>('music_visualizer_preset_default'),
            label: Text(t.music_visualizer_tuning_preset_default),
            selected: same(defaults),
            onSelected: (_) =>
                setState(() => _values = Map<String, Object>.of(defaults)),
          ),
          for (final LyricVisualizerTuningPreset p in widget.presets)
            FushiChoiceChip(
              key: ValueKey<String>('music_visualizer_preset_${p.id}'),
              label: Text(p.label()),
              selected: same(p.apply(widget.specs, current: _values)),
              onSelected: (_) => setState(
                () => _values = Map<String, Object>.of(
                  p.apply(widget.specs, current: _values),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final LyricVisualizerTuning current = _current;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
            child: Text(widget.title(), style: theme.textTheme.titleLarge),
          ),
          if (widget.presets.isNotEmpty) _presets(),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: _items(widget.specs, 0, current),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: <Widget>[
                FushiTextButton(
                  key: const ValueKey<String>('music_visualizer_tuning_reset'),
                  onPressed: () => setState(
                    () => _values = Map<String, Object>.of(
                      LyricVisualizerTuning.defaults(widget.specs).toMap(),
                    ),
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

/// 颜色：配色色板（当前主题的主色 / 辅色 / 强调色 / 底色 / 字色 + 样式自带的预置色）+ 十六进制输入。
class _ColorTuningRow extends StatefulWidget {
  const _ColorTuningRow({
    super.key,
    required this.spec,
    required this.value,
    required this.onChanged,
  });

  final LyricVisualizerColorSpec spec;
  final Color value;
  final ValueChanged<Color> onChanged;

  @override
  State<_ColorTuningRow> createState() => _ColorTuningRowState();
}

class _ColorTuningRowState extends State<_ColorTuningRow> {
  late final TextEditingController _hex = TextEditingController(
    text: lyricVisualizerHexOf(widget.value),
  );
  bool _invalid = false;

  @override
  void didUpdateWidget(covariant _ColorTuningRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value &&
        lyricVisualizerParseHexColor(_hex.text) != widget.value) {
      _hex.text = lyricVisualizerHexOf(widget.value);
      _invalid = false;
    }
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _onHex(String text) {
    final Color? c = lyricVisualizerParseHexColor(text);
    setState(() => _invalid = c == null);
    if (c != null) widget.onChanged(c);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<Color> swatches = <Color>[
      scheme.primary,
      scheme.secondary,
      scheme.tertiary,
      scheme.surface,
      scheme.onSurface,
      ...widget.spec.swatches,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text(widget.spec.label())),
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: widget.value,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.outline),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: <Widget>[
              for (int i = 0; i < swatches.length; i++)
                FushiPressScale(
                  child: Semantics(
                    button: true,
                    selected: swatches[i].toARGB32() == widget.value.toARGB32(),
                    label: lyricVisualizerHexOf(swatches[i]),
                    child: InkWell(
                      key: ValueKey<String>(
                        'music_visualizer_swatch_${widget.spec.key}_$i',
                      ),
                      customBorder: const CircleBorder(),
                      onTap: () {
                        _hex.text = lyricVisualizerHexOf(swatches[i]);
                        _onHex(_hex.text);
                      },
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: Center(
                          child: Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: swatches[i],
                              shape: BoxShape.circle,
                              border: Border.all(
                                width:
                                    swatches[i].toARGB32() ==
                                        widget.value.toARGB32()
                                    ? 3
                                    : 1,
                                color: scheme.outline,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          FushiTextField(
            key: ValueKey<String>('music_visualizer_hex_${widget.spec.key}'),
            controller: _hex,
            labelText: t.music_visualizer_tuning_color_hex,
            errorText: _invalid
                ? t.music_visualizer_tuning_color_invalid
                : null,
            onChanged: _onHex,
          ),
        ],
      ),
    );
  }
}

/// 素材包：选用哪个包（已有的包 + 当前值），往当前包里加图 / 删图。
class _AssetPackTuningRow extends StatefulWidget {
  const _AssetPackTuningRow({
    super.key,
    required this.spec,
    required this.pack,
    required this.store,
    required this.pickAssetFiles,
    required this.onPackChanged,
  });

  final LyricVisualizerAssetPackSpec spec;
  final String pack;
  final Future<LyricVisualizerAssetStore> Function() store;
  final Future<List<String>> Function() pickAssetFiles;
  final ValueChanged<String> onPackChanged;

  @override
  State<_AssetPackTuningRow> createState() => _AssetPackTuningRowState();
}

class _AssetPackTuningRowState extends State<_AssetPackTuningRow> {
  List<String> _packs = const <String>[];
  List<File> _files = const <File>[];
  Map<String, LyricVisualizerAssetPlacement> _placements =
      const <String, LyricVisualizerAssetPlacement>{};

  /// 正在设摆放的那张（只在 spec 允许逐张摆放时有）。
  String? _editing;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  @override
  void didUpdateWidget(covariant _AssetPackTuningRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pack != widget.pack) unawaited(_reload());
  }

  Future<void> _reload() async {
    final LyricVisualizerAssetStore store = await widget.store();
    final List<String> packs = await store.listPacks(widget.spec.style);
    final List<File> files = await store.list(widget.spec.style, widget.pack);
    final LyricVisualizerAssetPlacement? fallback = widget.spec.placement;
    final Map<String, LyricVisualizerAssetPlacement> placements =
        fallback == null
        ? const <String, LyricVisualizerAssetPlacement>{}
        : await store.loadPlacements(
            widget.spec.style,
            widget.pack,
            fallback: fallback,
          );
    if (!mounted) return;
    setState(() {
      _packs = packs;
      _files = files;
      _placements = placements;
      if (!files.any((File f) => _nameOf(f) == _editing)) _editing = null;
    });
  }

  static String _nameOf(File f) => f.uri.pathSegments.last;

  LyricVisualizerAssetPlacement _placementOf(String name) =>
      _placements[name] ??
      widget.spec.placement ??
      LyricVisualizerAssetPlacement.defaults;

  /// 改一张图的摆放：先改界面，[persist] 时落盘（滑杆拖动中只改界面，松手再写）。
  Future<void> _setPlacement(
    File f,
    LyricVisualizerAssetPlacement placement, {
    bool persist = true,
  }) async {
    setState(
      () => _placements = <String, LyricVisualizerAssetPlacement>{
        ..._placements,
        _nameOf(f): placement,
      },
    );
    if (!persist) return;
    final LyricVisualizerAssetStore store = await widget.store();
    await store.savePlacement(widget.spec.style, widget.pack, f, placement);
  }

  Widget _placementSlider({
    required File file,
    required String label,
    required String keySuffix,
    required double value,
    required double min,
    required double max,
    required LyricVisualizerAssetPlacement Function(double v) apply,
  }) {
    final int percent = (value * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text(label)),
            Text('$percent%'),
          ],
        ),
        FushiSlider(
          key: ValueKey<String>(
            'music_visualizer_asset_${keySuffix}_${widget.spec.key}',
          ),
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: (double v) =>
              unawaited(_setPlacement(file, apply(v), persist: false)),
          onChangeEnd: (double v) => unawaited(_setPlacement(file, apply(v))),
        ),
      ],
    );
  }

  Widget _placementEditor(BuildContext context, File f) {
    final LyricVisualizerAssetPlacement pl = _placementOf(_nameOf(f));
    return Column(
      key: ValueKey<String>(
        'music_visualizer_asset_placement_${widget.spec.key}',
      ),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 8),
        Text(t.music_visualizer_assets_placement_horizontal),
        const SizedBox(height: 4),
        adaptiveSegmentedButton<LyricVisualizerAssetAlign>(
          context: context,
          segments: <ButtonSegment<LyricVisualizerAssetAlign>>[
            for (final LyricVisualizerAssetAlign a
                in LyricVisualizerAssetAlign.values)
              ButtonSegment<LyricVisualizerAssetAlign>(
                value: a,
                label: Text(switch (a) {
                  LyricVisualizerAssetAlign.free =>
                    t.music_visualizer_assets_placement_free,
                  LyricVisualizerAssetAlign.left =>
                    t.music_visualizer_assets_placement_left,
                  LyricVisualizerAssetAlign.center =>
                    t.music_visualizer_assets_placement_center,
                  LyricVisualizerAssetAlign.right =>
                    t.music_visualizer_assets_placement_right,
                }),
              ),
          ],
          selected: <LyricVisualizerAssetAlign>{pl.align},
          onSelectionChanged: (Set<LyricVisualizerAssetAlign> v) {
            if (v.isNotEmpty) {
              unawaited(_setPlacement(f, pl.copyWith(align: v.first)));
            }
          },
        ),
        const SizedBox(height: 8),
        Text(t.music_visualizer_assets_placement_vertical),
        const SizedBox(height: 4),
        adaptiveSegmentedButton<LyricVisualizerAssetVerticalAlign>(
          context: context,
          segments: <ButtonSegment<LyricVisualizerAssetVerticalAlign>>[
            for (final LyricVisualizerAssetVerticalAlign a
                in LyricVisualizerAssetVerticalAlign.values)
              ButtonSegment<LyricVisualizerAssetVerticalAlign>(
                value: a,
                label: Text(switch (a) {
                  LyricVisualizerAssetVerticalAlign.free =>
                    t.music_visualizer_assets_placement_free,
                  LyricVisualizerAssetVerticalAlign.top =>
                    t.music_visualizer_assets_placement_top,
                  LyricVisualizerAssetVerticalAlign.center =>
                    t.music_visualizer_assets_placement_center,
                  LyricVisualizerAssetVerticalAlign.bottom =>
                    t.music_visualizer_assets_placement_bottom,
                }),
              ),
          ],
          selected: <LyricVisualizerAssetVerticalAlign>{pl.verticalAlign},
          onSelectionChanged: (Set<LyricVisualizerAssetVerticalAlign> v) {
            if (v.isNotEmpty) {
              unawaited(_setPlacement(f, pl.copyWith(verticalAlign: v.first)));
            }
          },
        ),
        const SizedBox(height: 8),
        _placementSlider(
          file: f,
          label: t.music_visualizer_assets_placement_scale,
          keySuffix: 'scale',
          value: pl.scale,
          min: LyricVisualizerAssetPlacement.minScale,
          max: LyricVisualizerAssetPlacement.maxScale,
          apply: (double v) => pl.copyWith(scale: v),
        ),
        _placementSlider(
          file: f,
          label: t.music_visualizer_assets_placement_opacity,
          keySuffix: 'opacity',
          value: pl.opacity,
          min: 0,
          max: 1,
          apply: (double v) => pl.copyWith(opacity: v),
        ),
        // 逐张摆放时删图放进编辑器：角标删除钮的命中区会盖住大半张缩略图，点图选中容易误删。
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FushiPressScale(
            child: FushiTextButton.icon(
              key: ValueKey<String>(
                'music_visualizer_asset_delete_${_nameOf(f)}',
              ),
              onPressed: _busy ? null : () => unawaited(_delete(f)),
              icon: const Icon(FushiIcons.delete),
              label: Text(t.music_visualizer_assets_delete),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _add() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final List<String> picked = await widget.pickAssetFiles();
      if (picked.isEmpty) return;
      final LyricVisualizerAssetStore store = await widget.store();
      await store.importFiles(
        widget.spec.style,
        widget.pack,
        picked,
        maxFiles: widget.spec.maxFiles,
      );
      await _reload();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(File f) async {
    final LyricVisualizerAssetStore store = await widget.store();
    await store.delete(widget.spec.style, widget.pack, f);
    await _reload();
  }

  Widget _thumbnail(BuildContext context, File f) {
    final Widget image = ClipRRect(
      borderRadius: FushiM3eShape.smallRadius,
      child: Image.file(
        f,
        width: 64,
        height: 64,
        fit: BoxFit.cover,
        cacheWidth: 128,
        errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
            const SizedBox(width: 64, height: 64),
      ),
    );
    if (widget.spec.placement == null) return image;
    final String name = _nameOf(f);
    final bool selected = name == _editing;
    return FushiPressScale(
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: ValueKey<String>('music_visualizer_asset_select_$name'),
          borderRadius: FushiM3eShape.smallRadius,
          onTap: () => setState(() => _editing = selected ? null : name),
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: FushiM3eShape.smallRadius,
              border: selected
                  ? Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    )
                  : null,
            ),
            child: image,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<String> packs = <String>{widget.pack, ..._packs}.toList()
      ..sort();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text(widget.spec.label())),
              Text(t.music_visualizer_assets_count(n: _files.length)),
            ],
          ),
          if (packs.length > 1)
            Wrap(
              spacing: 8,
              children: <Widget>[
                for (final String p in packs)
                  FushiChoiceChip(
                    key: ValueKey<String>(
                      'music_visualizer_pack_${widget.spec.key}_$p',
                    ),
                    label: Text(p),
                    selected: p == widget.pack,
                    onSelected: (_) => widget.onPackChanged(p),
                  ),
              ],
            ),
          const SizedBox(height: 8),
          if (_files.isEmpty)
            Text(
              t.music_visualizer_assets_empty,
              style: Theme.of(context).textTheme.bodySmall,
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final File f in _files)
                  Stack(
                    children: <Widget>[
                      _thumbnail(context, f),
                      if (widget.spec.placement == null)
                        Positioned(
                          right: -8,
                          top: -8,
                          child: FushiIconButtonControl(
                            key: ValueKey<String>(
                              'music_visualizer_asset_delete_${f.uri.pathSegments.last}',
                            ),
                            tooltip: t.music_visualizer_assets_delete,
                            onPressed: () => unawaited(_delete(f)),
                            icon: const Icon(FushiIcons.delete, size: 16),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          if (widget.spec.placement != null && _files.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              t.music_visualizer_assets_placement_hint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          for (final File f in _files)
            if (_nameOf(f) == _editing) _placementEditor(context, f),
          const SizedBox(height: 8),
          FushiPressScale(
            child: FushiTextButton.icon(
              key: ValueKey<String>(
                'music_visualizer_asset_add_${widget.spec.key}',
              ),
              onPressed: _busy ? null : () => unawaited(_add()),
              icon: const Icon(FushiIcons.addImage),
              label: Text(t.music_visualizer_assets_add),
            ),
          ),
        ],
      ),
    );
  }
}
