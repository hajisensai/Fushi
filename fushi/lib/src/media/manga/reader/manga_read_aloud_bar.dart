/// 漫画朗读时的浮动播放条：状态行 + 纯图标悬浮工具栏（上一句 / 暂停·继续 /
/// 下一句 / 倍速 / 声音 / 停止），倍速展开一行拖动条。
///
/// 两种音源共用同一副外框（[_MangaBarFrame]）：现场合成用 [MangaReadAloudBar]；
/// 成品音频用 [MangaAudioPlaybackBar]——多一行进度拖动与「跟随翻页」开关，少「声音」
/// 按钮（声音在生成时就定了）。
///
/// 工具栏复用共享的 [FushiFloatingToolbar]（MD3 / Apple 两套、48dp 纯图标、
/// tooltip 与 Semantics 齐全、按压缩放）；状态行与倍速行画在 [MangaChromeSurface]
/// 上，展开 / 收起走 [FushiAnimatedSize] + [FushiMotion]。
library;

import 'dart:async';

import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart'
    show MangaRenderedLine;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/audiobook_speed_slider.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_playback_driver.dart';
import 'package:fushi/src/media/manga/reader/manga_read_aloud_controller.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_chrome.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 拿不到文字的原因 → 现有文案。
String mangaReadAloudTextProblemText(MangaPageTextUnavailableReason reason) =>
    switch (reason) {
      MangaPageTextUnavailableReason.noEngine => t.manga_reader_ocr_unavailable,
      MangaPageTextUnavailableReason.chapterOcrDisabled =>
        t.manga_chapter_not_downloaded,
      MangaPageTextUnavailableReason.lensDeclined ||
      MangaPageTextUnavailableReason.cancelled ||
      MangaPageTextUnavailableReason.failed =>
        t.manga_read_aloud_ocr_unavailable,
    };

/// 播放条状态行：正在读的句子原文，或等待 / 暂停 / 失败 / 读完的说明。
String mangaReadAloudStatusText(MangaReadAloudController c) {
  final String? sentence = c.currentUtterance?.displayText;
  return switch (c.state) {
    MangaReadAloudState.idle => '',
    MangaReadAloudState.preparingText => t.manga_read_aloud_waiting_ocr,
    MangaReadAloudState.synthesizing => sentence ?? t.audiobook_tts_preparing,
    MangaReadAloudState.playing => sentence ?? '',
    MangaReadAloudState.paused =>
      sentence == null ? t.pause : '${t.pause} · $sentence',
    MangaReadAloudState.finished =>
      c.finish == MangaReadAloudFinish.noText
          ? t.manga_read_aloud_no_text
          : t.manga_read_aloud_chapter_end,
    MangaReadAloudState.failed => switch (c.problem) {
      MangaReadAloudTextProblem(:final MangaPageTextUnavailableReason reason) =>
        mangaReadAloudTextProblemText(reason),
      MangaReadAloudSynthesisProblem(:final failure) => ttsFailureText(failure),
      null => t.audiobook_tts_start_failed,
    },
  };
}

class MangaReadAloudBar extends StatefulWidget {
  const MangaReadAloudBar({
    super.key,
    required this.controller,
    required this.onVoice,
  });

  final MangaReadAloudController controller;

  /// 声音快速切换（选中即热切换，「朗读声音」项进设置页）。
  final VoidCallback onVoice;

  @override
  State<MangaReadAloudBar> createState() => _MangaReadAloudBarState();
}

class _MangaReadAloudBarState extends State<MangaReadAloudBar> {
  bool _speedOpen = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, Widget? _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final MangaReadAloudController c = widget.controller;
    final MangaReadAloudState state = c.state;
    final bool running =
        state == MangaReadAloudState.playing ||
        state == MangaReadAloudState.synthesizing ||
        state == MangaReadAloudState.preparingText;
    final bool failed = state == MangaReadAloudState.failed;
    final String status = mangaReadAloudStatusText(c);

    final List<FushiToolbarItem> items = <FushiToolbarItem>[
      FushiToolbarItem(
        key: const ValueKey<String>('manga_read_aloud_previous'),
        icon: FushiIcons.skipPrevious,
        label: t.manga_read_aloud_previous,
        onPressed: c.isActive ? c.previous : null,
      ),
      if (running)
        FushiToolbarItem(
          key: const ValueKey<String>('manga_read_aloud_pause'),
          icon: FushiIcons.pause,
          label: t.pause,
          onPressed: c.pause,
        )
      else if (failed)
        FushiToolbarItem(
          key: const ValueKey<String>('manga_read_aloud_retry'),
          icon: FushiIcons.refresh,
          label: t.retry,
          onPressed: c.resume,
        )
      else
        FushiToolbarItem(
          key: const ValueKey<String>('manga_read_aloud_resume'),
          icon: FushiIcons.play,
          label: t.manga_read_aloud_resume,
          onPressed: state == MangaReadAloudState.paused ? c.resume : null,
        ),
      FushiToolbarItem(
        key: const ValueKey<String>('manga_read_aloud_next'),
        icon: FushiIcons.skipNext,
        label: t.manga_read_aloud_next,
        onPressed: c.isActive ? c.next : null,
      ),
      FushiToolbarItem(
        key: const ValueKey<String>('manga_read_aloud_speed'),
        icon: FushiIcons.speed,
        label: t.playback_speed,
        tooltip: '${t.playback_speed} ${AudiobookSpeedSlider.format(c.speed)}',
        selected: _speedOpen,
        onPressed: () => setState(() => _speedOpen = !_speedOpen),
      ),
      FushiToolbarItem(
        key: const ValueKey<String>('manga_read_aloud_voice'),
        icon: FushiIcons.voice,
        label: t.audiobook_tts_voices_section,
        onPressed: widget.onVoice,
      ),
      FushiToolbarItem(
        key: const ValueKey<String>('manga_read_aloud_stop'),
        icon: FushiIcons.stop,
        label: t.manga_read_aloud_stop,
        onPressed: c.stop,
      ),
    ];

    return _MangaBarFrame(
      status: status,
      warning: failed,
      items: items,
      extras: <Widget>[
        if (_speedOpen)
          _SpeedRow(speed: c.speed, onChanged: (double v) => c.setSpeed(v)),
      ],
    );
  }
}

/// 倍速一行（两种音源共用）。
class _SpeedRow extends StatelessWidget {
  const _SpeedRow({required this.speed, required this.onChanged});

  final double speed;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final MangaChromePalette colors = MangaChromePalette.of(context);
    final ThemeData theme = Theme.of(context);
    return Row(
      children: <Widget>[
        FushiIcon(
          FushiIcons.speed,
          size: 20,
          color: colors.secondaryForeground,
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 52,
          child: Text(
            AudiobookSpeedSlider.format(speed),
            style: theme.textTheme.labelLarge?.copyWith(
              color: colors.foreground,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
        Expanded(
          child: AudiobookSpeedSlider(
            key: const ValueKey<String>('manga_read_aloud_speed_slider'),
            speed: speed,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

/// 播放条外框：状态面板（状态行 + 额外行，展开 / 收起带动效）+ 纯图标悬浮工具栏。
class _MangaBarFrame extends StatelessWidget {
  const _MangaBarFrame({
    required this.status,
    required this.warning,
    required this.items,
    this.extras = const <Widget>[],
  });

  final String status;
  final bool warning;
  final List<FushiToolbarItem> items;
  final List<Widget> extras;

  @override
  Widget build(BuildContext context) {
    final MangaChromePalette colors = MangaChromePalette.of(context);
    final ThemeData theme = Theme.of(context);
    final Duration motion = fushiMotionDuration(context, FushiMotion.short);
    final TextStyle? statusStyle = theme.textTheme.bodyMedium?.copyWith(
      color: warning ? colors.warning : colors.foreground,
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: kMangaChromeBottomMaxWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiAnimatedSize(
            duration: motion,
            curve: FushiMotion.standard,
            alignment: Alignment.bottomCenter,
            child: status.isEmpty && extras.isEmpty
                ? const SizedBox(width: double.infinity)
                : FushiHoverLift(
                    builder: (BuildContext context, bool _) =>
                        MangaChromeSurface(
                          radius: 20,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                if (status.isNotEmpty)
                                  Semantics(
                                    liveRegion: true,
                                    child: Text(
                                      status,
                                      key: const ValueKey<String>(
                                        'manga_read_aloud_status',
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: statusStyle,
                                    ),
                                  ),
                                ...extras,
                              ],
                            ),
                          ),
                        ),
                  ),
          ),
          const SizedBox(height: 8),
          KeyedSubtree(
            key: const ValueKey<String>('manga_read_aloud_bar'),
            child: FushiFloatingToolbar(
              groups: <List<FushiToolbarItem>>[items],
            ),
          ),
        ],
      ),
    );
  }
}

/// 成品音频的状态行：正在读的句子原文（没配上音的句子标出来），静音段显示页码。
String mangaAudioStatusText(MangaAudioPlaybackDriver d) {
  final MangaRenderedLine? line = d.currentLine;
  if (line == null) return t.manga_audio_status_page(page: d.currentPage + 1);
  final String text = line.text.isEmpty
      ? t.manga_audio_status_page(page: line.page + 1)
      : line.text;
  return line.placeholder ? '${t.manga_audio_unvoiced} · $text' : text;
}

/// 成品音频播放条：进度拖动 + 跟随翻页 + 上一句 / 播放·暂停 / 下一句 / 倍速 / 停止。
class MangaAudioPlaybackBar extends StatefulWidget {
  const MangaAudioPlaybackBar({
    super.key,
    required this.driver,
    required this.onStop,
  });

  final MangaAudioPlaybackDriver driver;

  /// 停止成品音频会话（会话级，不只是暂停）。
  final VoidCallback onStop;

  @override
  State<MangaAudioPlaybackBar> createState() => _MangaAudioPlaybackBarState();
}

class _MangaAudioPlaybackBarState extends State<MangaAudioPlaybackBar> {
  bool _speedOpen = false;

  /// 拖动中的进度（松手才 seek）。
  double? _dragFraction;

  /// 播放中位置流不是每个 tick 都通知（控制器只在换句 / 换状态时通知）：进度条自己
  /// 按固定节拍刷新。
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted && widget.driver.isPlaying && _dragFraction == null) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.driver,
    builder: (BuildContext context, Widget? _) => _build(context),
  );

  static String _clock(int ms) {
    final int s = (ms / 1000).floor();
    final String sec = (s % 60).toString().padLeft(2, '0');
    final int m = s ~/ 60;
    if (m < 60) return '$m:$sec';
    return '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}:$sec';
  }

  Widget _build(BuildContext context) {
    final MangaAudioPlaybackDriver d = widget.driver;
    final MangaChromePalette colors = MangaChromePalette.of(context);
    final ThemeData theme = Theme.of(context);
    final int total = d.totalMs;
    final double live = total <= 0
        ? 0
        : (d.positionMs / total).clamp(0.0, 1.0).toDouble();
    final double fraction = _dragFraction ?? live;
    final TextStyle? clockStyle = theme.textTheme.labelMedium?.copyWith(
      color: colors.secondaryForeground,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    final List<FushiToolbarItem> items = <FushiToolbarItem>[
      FushiToolbarItem(
        key: const ValueKey<String>('manga_audio_previous'),
        icon: FushiIcons.skipPrevious,
        label: t.manga_read_aloud_previous,
        onPressed: () => unawaited(d.previous()),
      ),
      if (d.isPlaying)
        FushiToolbarItem(
          key: const ValueKey<String>('manga_audio_pause'),
          icon: FushiIcons.pause,
          label: t.pause,
          onPressed: () => unawaited(d.pause()),
        )
      else
        FushiToolbarItem(
          key: const ValueKey<String>('manga_audio_play'),
          icon: FushiIcons.play,
          label: t.manga_read_aloud_resume,
          onPressed: () => unawaited(d.play()),
        ),
      FushiToolbarItem(
        key: const ValueKey<String>('manga_audio_next'),
        icon: FushiIcons.skipNext,
        label: t.manga_read_aloud_next,
        onPressed: () => unawaited(d.next()),
      ),
      FushiToolbarItem(
        key: const ValueKey<String>('manga_audio_follow_page'),
        icon: FushiIcons.sync,
        label: t.manga_audio_follow_page,
        selected: d.followPage,
        onPressed: () => d.setFollowPage(!d.followPage),
      ),
      FushiToolbarItem(
        key: const ValueKey<String>('manga_audio_speed'),
        icon: FushiIcons.speed,
        label: t.playback_speed,
        tooltip: '${t.playback_speed} ${AudiobookSpeedSlider.format(d.speed)}',
        selected: _speedOpen,
        onPressed: () => setState(() => _speedOpen = !_speedOpen),
      ),
      FushiToolbarItem(
        key: const ValueKey<String>('manga_audio_stop'),
        icon: FushiIcons.stop,
        label: t.manga_read_aloud_stop,
        onPressed: widget.onStop,
      ),
    ];
    return _MangaBarFrame(
      status: mangaAudioStatusText(d),
      warning: d.currentLine?.placeholder ?? false,
      items: items,
      extras: <Widget>[
        Row(
          children: <Widget>[
            Text(_clock((fraction * total).round()), style: clockStyle),
            Expanded(
              child: Semantics(
                label: t.manga_audio_progress,
                child: FushiSlider(
                  key: const ValueKey<String>('manga_audio_progress'),
                  value: fraction,
                  onChanged: total <= 0
                      ? null
                      : (double v) => setState(() => _dragFraction = v),
                  onChangeEnd: total <= 0
                      ? null
                      : (double v) {
                          setState(() => _dragFraction = null);
                          unawaited(d.seekTo((v * total).round()));
                        },
                ),
              ),
            ),
            Text(_clock(total), style: clockStyle),
          ],
        ),
        if (_speedOpen)
          _SpeedRow(speed: d.speed, onChanged: (double v) => d.setSpeed(v)),
      ],
    );
  }
}
