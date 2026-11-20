/// 漫画朗读时的浮动播放卡：一张卡片收齐「谁在说 / 说什么 / 播到哪 / 怎么控」。
///
/// ```
/// ┌──────────────────────────────────────────────┐
/// │ ● 長崎 そよ                       第 12 页  ✕ │  说话人 · 页码 · 停止
/// │ あ、ううん、お母さんがね一緒に晩御飯食べようって  │  台词（两行）
/// │ ━━━━━━━●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │  进度（仅成品音频）
/// │ 2:29                                   47:21  │
/// │ ⟲          ⏮    ( ▶ )    ⏭          1.0×   │  跟随 / 声音 · 上下句 · 倍速
/// └──────────────────────────────────────────────┘
/// ```
///
/// 两种音源共用同一张卡（[_MangaPlayerCard]）：现场合成用 [MangaReadAloudBar]（左下角
/// 是「声音」，没有进度）；成品音频用 [MangaAudioPlaybackBar]（左下角是「跟随翻页」，
/// 多进度与说话人）。点倍速胶囊在卡内展开倍速条。
///
/// 卡片画在 [MangaChromeSurface] 上（MD3 / Apple 两套材质），按钮走 [FushiIconButton]
/// （tooltip / Semantics / 命中区齐全），主按钮与倍速胶囊带 [FushiPressScale]，整卡
/// [FushiHoverLift]，展开收起走 [FushiAnimatedSize] + [FushiMotion]。按钮提示括注
/// 键盘快捷键（[MangaPlaybackKeyHints]，桌面才有）。显隐由阅读器跟着界面一起管。
library;

import 'dart:async';

import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart'
    show MangaRenderedLine;
import 'package:fushi_engine/tts/render/tts_cast.dart'
    show kTtsNarrator, kTtsUnknown;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/audiobook_speed_slider.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_playback_driver.dart';
import 'package:fushi/src/media/manga/reader/manga_read_aloud_controller.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_chrome.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 播放控制的键盘快捷键显示名（`K` / `J` / `L`），由阅读器按快捷键注册表填；触屏
/// 平台与没绑键时为 null（提示里不括注）。
class MangaPlaybackKeyHints {
  const MangaPlaybackKeyHints({this.playPause, this.previous, this.next});

  static const MangaPlaybackKeyHints none = MangaPlaybackKeyHints();

  final String? playPause;
  final String? previous;
  final String? next;
}

String _hinted(String label, String? key) =>
    key == null ? label : '$label ($key)';

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

/// 现场合成的播放卡：声音 / 上一句 / 暂停·继续 / 下一句 / 倍速，右上角停止。
class MangaReadAloudBar extends StatefulWidget {
  const MangaReadAloudBar({
    super.key,
    required this.controller,
    required this.onVoice,
    this.keyHints = MangaPlaybackKeyHints.none,
  });

  final MangaReadAloudController controller;

  /// 声音快速切换（选中即热切换，「朗读声音」项进设置页）。
  final VoidCallback onVoice;

  final MangaPlaybackKeyHints keyHints;

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
    final MangaPlaybackKeyHints keys = widget.keyHints;
    final MangaReadAloudState state = c.state;
    final bool running =
        state == MangaReadAloudState.playing ||
        state == MangaReadAloudState.synthesizing ||
        state == MangaReadAloudState.preparingText;
    final bool failed = state == MangaReadAloudState.failed;

    final _PrimaryAction primary = running
        ? _PrimaryAction(
            key: const ValueKey<String>('manga_read_aloud_pause'),
            icon: FushiIcons.pause,
            tooltip: _hinted(t.pause, keys.playPause),
            onPressed: c.pause,
          )
        : failed
        ? _PrimaryAction(
            key: const ValueKey<String>('manga_read_aloud_retry'),
            icon: FushiIcons.refresh,
            tooltip: t.retry,
            onPressed: c.resume,
          )
        : _PrimaryAction(
            key: const ValueKey<String>('manga_read_aloud_resume'),
            icon: FushiIcons.play,
            tooltip: _hinted(t.manga_read_aloud_resume, keys.playPause),
            onPressed: state == MangaReadAloudState.paused ? c.resume : null,
          );

    return _MangaPlayerCard(
      status: mangaReadAloudStatusText(c),
      warning: failed,
      closeKey: const ValueKey<String>('manga_read_aloud_stop'),
      onClose: c.stop,
      leading: FushiIconButton(
        key: const ValueKey<String>('manga_read_aloud_voice'),
        icon: FushiIcons.voice,
        tooltip: t.audiobook_tts_voices_section,
        padTouchTarget: true,
        onTap: widget.onVoice,
      ),
      previous: FushiIconButton(
        key: const ValueKey<String>('manga_read_aloud_previous'),
        icon: FushiIcons.skipPrevious,
        tooltip: _hinted(t.manga_read_aloud_previous, keys.previous),
        padTouchTarget: true,
        enabled: c.isActive,
        onTap: c.previous,
      ),
      primary: primary,
      next: FushiIconButton(
        key: const ValueKey<String>('manga_read_aloud_next'),
        icon: FushiIcons.skipNext,
        tooltip: _hinted(t.manga_read_aloud_next, keys.next),
        padTouchTarget: true,
        enabled: c.isActive,
        onTap: c.next,
      ),
      speed: c.speed,
      speedKey: const ValueKey<String>('manga_read_aloud_speed'),
      speedOpen: _speedOpen,
      onToggleSpeed: () => setState(() => _speedOpen = !_speedOpen),
      onSpeedChanged: (double v) => c.setSpeed(v),
    );
  }
}

/// 成品音频状态行：正在读的句子原文（没配上音的句子标出来），静音段显示页码。
String mangaAudioStatusText(MangaAudioPlaybackDriver d) {
  final MangaRenderedLine? line = d.currentLine;
  if (line == null) return t.manga_audio_status_page(page: d.currentPage + 1);
  final String text = line.text.isEmpty
      ? t.manga_audio_status_page(page: line.page + 1)
      : line.text;
  return line.placeholder ? '${t.manga_audio_unvoiced} · $text' : text;
}

/// 说话人显示名：旁白 / 未知用现有文案，其余是角色名本身；静音段没有说话人。
String? mangaAudioSpeakerLabel(MangaRenderedLine? line) {
  if (line == null || line.speaker.isEmpty) return null;
  return switch (line.speaker) {
    kTtsNarrator => t.audiobook_studio_cast_narrator,
    kTtsUnknown => t.audiobook_studio_cast_unknown,
    final String name => name,
  };
}

/// 成品音频播放卡：说话人 + 台词 + 进度，跟随翻页 / 上一句 / 播放·暂停 / 下一句 / 倍速，
/// 右上角停止。
class MangaAudioPlaybackBar extends StatefulWidget {
  const MangaAudioPlaybackBar({
    super.key,
    required this.driver,
    required this.onStop,
    this.keyHints = MangaPlaybackKeyHints.none,
  });

  final MangaAudioPlaybackDriver driver;

  /// 停止成品音频会话（会话级，不只是暂停）。
  final VoidCallback onStop;

  final MangaPlaybackKeyHints keyHints;

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
    final MangaPlaybackKeyHints keys = widget.keyHints;
    final MangaChromePalette colors = MangaChromePalette.of(context);
    final ThemeData theme = Theme.of(context);
    final int total = d.totalMs;
    final double live = total <= 0
        ? 0
        : (d.positionMs / total).clamp(0.0, 1.0).toDouble();
    final double fraction = _dragFraction ?? live;
    final TextStyle? clockStyle = theme.textTheme.labelSmall?.copyWith(
      color: colors.secondaryForeground,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    final MangaRenderedLine? line = d.currentLine;

    return _MangaPlayerCard(
      speaker: mangaAudioSpeakerLabel(line),
      pageLabel: t.manga_audio_status_page(page: d.currentPage + 1),
      status: mangaAudioStatusText(d),
      warning: line?.placeholder ?? false,
      closeKey: const ValueKey<String>('manga_audio_stop'),
      onClose: widget.onStop,
      progress: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Semantics(
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: <Widget>[
                Text(_clock((fraction * total).round()), style: clockStyle),
                const Spacer(),
                Text(_clock(total), style: clockStyle),
              ],
            ),
          ),
        ],
      ),
      leading: FushiIconButton(
        key: const ValueKey<String>('manga_audio_follow_page'),
        icon: FushiIcons.sync,
        tooltip: t.manga_audio_follow_page,
        padTouchTarget: true,
        selected: d.followPage,
        onTap: () => d.setFollowPage(!d.followPage),
      ),
      previous: FushiIconButton(
        key: const ValueKey<String>('manga_audio_previous'),
        icon: FushiIcons.skipPrevious,
        tooltip: _hinted(t.manga_read_aloud_previous, keys.previous),
        padTouchTarget: true,
        onTap: () => unawaited(d.previous()),
      ),
      primary: d.isPlaying
          ? _PrimaryAction(
              key: const ValueKey<String>('manga_audio_pause'),
              icon: FushiIcons.pause,
              tooltip: _hinted(t.pause, keys.playPause),
              onPressed: () => unawaited(d.pause()),
            )
          : _PrimaryAction(
              key: const ValueKey<String>('manga_audio_play'),
              icon: FushiIcons.play,
              tooltip: _hinted(t.manga_read_aloud_resume, keys.playPause),
              onPressed: () => unawaited(d.play()),
            ),
      next: FushiIconButton(
        key: const ValueKey<String>('manga_audio_next'),
        icon: FushiIcons.skipNext,
        tooltip: _hinted(t.manga_read_aloud_next, keys.next),
        padTouchTarget: true,
        onTap: () => unawaited(d.next()),
      ),
      speed: d.speed,
      speedKey: const ValueKey<String>('manga_audio_speed'),
      speedOpen: _speedOpen,
      onToggleSpeed: () => setState(() => _speedOpen = !_speedOpen),
      onSpeedChanged: (double v) => d.setSpeed(v),
    );
  }
}

/// 中间的大号主按钮（播放 / 暂停 / 重试）。
class _PrimaryAction {
  const _PrimaryAction({
    required this.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final Key key;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
}

/// 播放卡本体（两种音源共用）。
class _MangaPlayerCard extends StatelessWidget {
  const _MangaPlayerCard({
    required this.status,
    required this.warning,
    required this.closeKey,
    required this.onClose,
    required this.leading,
    required this.previous,
    required this.primary,
    required this.next,
    required this.speed,
    required this.speedKey,
    required this.speedOpen,
    required this.onToggleSpeed,
    required this.onSpeedChanged,
    this.speaker,
    this.pageLabel,
    this.progress,
  });

  final String? speaker;
  final String? pageLabel;
  final String status;
  final bool warning;
  final Key closeKey;
  final VoidCallback onClose;
  final Widget? progress;
  final Widget leading;
  final Widget previous;
  final _PrimaryAction primary;
  final Widget next;
  final double speed;
  final Key speedKey;
  final bool speedOpen;
  final VoidCallback onToggleSpeed;
  final ValueChanged<double> onSpeedChanged;

  @override
  Widget build(BuildContext context) {
    final MangaChromePalette colors = MangaChromePalette.of(context);
    final ThemeData theme = Theme.of(context);
    final Duration motion = fushiMotionDuration(context, FushiMotion.short);
    final String? speakerName = speaker;
    final String? page = pageLabel;
    final Widget? progressRow = progress;

    final Widget header = Row(
      children: <Widget>[
        if (speakerName != null) ...<Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: colors.accent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              speakerName,
              key: const ValueKey<String>('manga_read_aloud_speaker'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge?.copyWith(
                color: colors.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
        const Spacer(),
        if (page != null)
          Text(
            page,
            style: theme.textTheme.labelMedium?.copyWith(
              color: colors.secondaryForeground,
            ),
          ),
        FushiIconButton(
          key: closeKey,
          icon: FushiIcons.close,
          size: 20,
          tooltip: t.manga_read_aloud_stop,
          padTouchTarget: true,
          onTap: onClose,
        ),
      ],
    );

    final Widget statusText = Semantics(
      liveRegion: true,
      child: Text(
        status,
        key: const ValueKey<String>('manga_read_aloud_status'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium?.copyWith(
          color: warning ? colors.warning : colors.foreground,
          height: 1.35,
        ),
      ),
    );

    final Widget controls = Row(
      children: <Widget>[
        Expanded(
          child: Align(alignment: Alignment.centerLeft, child: leading),
        ),
        previous,
        const SizedBox(width: 12),
        _PrimaryButton(action: primary),
        const SizedBox(width: 12),
        next,
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: _SpeedChip(
              key: speedKey,
              speed: speed,
              open: speedOpen,
              onPressed: onToggleSpeed,
            ),
          ),
        ),
      ],
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: kMangaChromeBottomMaxWidth),
      child: FushiHoverLift(
        builder: (BuildContext context, bool _) => MangaChromeSurface(
          radius: 28,
          child: KeyedSubtree(
            key: const ValueKey<String>('manga_read_aloud_bar'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 8, 10),
              child: FushiAnimatedSize(
                duration: motion,
                curve: FushiMotion.standard,
                alignment: Alignment.bottomCenter,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    header,
                    if (status.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: statusText,
                      ),
                    if (progressRow != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6, right: 12),
                        child: progressRow,
                      ),
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: controls,
                    ),
                    if (speedOpen)
                      Padding(
                        padding: const EdgeInsets.only(top: 4, right: 12),
                        child: _SpeedRow(
                          speed: speed,
                          onChanged: onSpeedChanged,
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

/// 大号主按钮：强调色实心圆（56dp），图标实心字形。
class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.action});

  final _PrimaryAction action;

  @override
  Widget build(BuildContext context) {
    final MangaChromePalette colors = MangaChromePalette.of(context);
    return FushiPressScale(
      enabled: action.onPressed != null,
      child: FushiIconButton(
        key: action.key,
        icon: FushiIcons.filled(action.icon),
        size: 30,
        tooltip: action.tooltip,
        backgroundColor: colors.accent,
        enabledColor: colors.onAccent,
        disabledColor: colors.onAccent.withValues(alpha: 0.38),
        constraints: const BoxConstraints.tightFor(width: 56, height: 56),
        enabled: action.onPressed != null,
        onTap: action.onPressed,
      ),
    );
  }
}

/// 倍速胶囊：图标 + 当前倍速，点开 / 收起卡内倍速条。
class _SpeedChip extends StatelessWidget {
  const _SpeedChip({
    super.key,
    required this.speed,
    required this.open,
    required this.onPressed,
  });

  final double speed;
  final bool open;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final String label = AudiobookSpeedSlider.format(speed);
    return FushiIconButton(
      icon: FushiIcons.speed,
      label: label,
      tooltip: '${t.playback_speed} $label',
      padTouchTarget: true,
      selected: open,
      onTap: onPressed,
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
    return Row(
      children: <Widget>[
        FushiIcon(
          FushiIcons.speed,
          size: 20,
          color: colors.secondaryForeground,
        ),
        const SizedBox(width: 8),
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
