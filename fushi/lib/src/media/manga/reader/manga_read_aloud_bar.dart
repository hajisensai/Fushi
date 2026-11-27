/// 漫画朗读 / 有声播放条：播放期间**替换底部工具栏那一行**（与小说阅读器的
/// `AudiobookPlayBar` 同一思路），画面上不再有单独的浮动卡片。
///
/// ```
/// ╭──────────────────────────────────────────────────────────────╮
/// │ ⏮ (⏯) ⏭  ● 長崎 そよ     [底栏原有按钮…]  │ ⟳  ⏱1.0×  🔊  ⏹ │
/// ╰━━━━━━━━●──────────────────────────────────────────────────────╯
///   传输三联键 · 说话人 / 状态   中间横向滚动   跟随(声音) 倍速 (音量) 停止
/// ```
///
/// 用户 2026-11-21：「和小说一样，播放条替换底栏，不要把画面挤上去」——播放条坐在
/// 底部 chrome 原工具栏的位置、同高（[kMangaChromeToolbarHeight]），所以固定态正文
/// 让位高度不变、悬浮态照旧浮在页图上并跟着底栏一起收起；不显示台词（页面上的
/// 高亮框就是当前句），进度是条底边一条细线（成品音频才有，可点 / 可拖）。倍速
/// 胶囊点开时在条上方弹出倍速条；成品音频另有音量按钮，点开弹出与有声书快捷设置
/// 同一口径的音量条（[AudiobookVolumeSlider]，按书持久化）。
///
/// 两种音源共用 [_MangaPlayBar]：现场合成用 [MangaReadAloudBar]（右侧是「声音」，
/// 没有进度）；成品音频用 [MangaAudioPlaybackBar]（右侧是「跟随翻页」，多进度线与
/// 说话人）。阅读器把底栏原有按钮作为 [middle] 传进来，放不下时横向滚动。
///
/// 条画在 [MangaChromeSurface] 上（MD3 / Apple 两套材质），按钮走 [FushiIconButton]
/// （tooltip / Semantics / 命中区齐全），主按钮与倍速 / 音量按钮带 [FushiPressScale]，
/// 整条 [FushiHoverLift]，状态文字切换与弹层出现走 [FushiMotion]。按钮提示括注
/// 键盘快捷键（[MangaPlaybackKeyHints]，桌面才有）。
library;

import 'dart:async';

import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart'
    show MangaRenderedLine;
import 'package:fushi_engine/tts/render/tts_cast.dart'
    show kTtsNarrator, kTtsUnknown;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/state_resource_scope.dart';
import 'package:fushi/src/media/audiobook/audiobook_speed_slider.dart';
import 'package:fushi/src/media/audiobook/audiobook_volume_slider.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_playback_driver.dart';
import 'package:fushi/src/media/manga/reader/manga_read_aloud_controller.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_chrome.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

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

/// 现场合成播放条的状态读数：等待 / 合成 / 暂停 / 失败 / 读完的说明；正常朗读中
/// 为 null（不显示台词，页面上的高亮框就是当前句）。
String? mangaReadAloudNoticeText(MangaReadAloudController c) {
  return switch (c.state) {
    MangaReadAloudState.idle || MangaReadAloudState.playing => null,
    MangaReadAloudState.preparingText => t.manga_read_aloud_waiting_ocr,
    MangaReadAloudState.synthesizing =>
      c.currentUtterance == null ? t.audiobook_tts_preparing : null,
    MangaReadAloudState.paused => t.pause,
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

/// 现场合成的播放条：上一句 / 暂停·继续 / 下一句 + 状态，右侧声音 / 倍速 / 停止。
class MangaReadAloudBar extends StatelessWidget {
  const MangaReadAloudBar({
    super.key,
    required this.controller,
    required this.onVoice,
    this.keyHints = MangaPlaybackKeyHints.none,
    this.middle,
  });

  final MangaReadAloudController controller;

  /// 声音快速切换（选中即热切换，「朗读声音」项进设置页）。
  final VoidCallback onVoice;

  final MangaPlaybackKeyHints keyHints;

  /// 底栏原有按钮（阅读器传入），夹在状态与右侧控件之间，放不下横向滚动。
  final Widget? middle;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final MangaReadAloudController c = controller;
    final MangaPlaybackKeyHints keys = keyHints;
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

    final String? notice = mangaReadAloudNoticeText(c);
    return _MangaPlayBar(
      label: notice == null
          ? null
          : _BarLabel(
              key: const ValueKey<String>('manga_read_aloud_status'),
              text: notice,
              tone: failed ? _LabelTone.warning : _LabelTone.secondary,
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
      middle: middle,
      trailing: FushiIconButton(
        key: const ValueKey<String>('manga_read_aloud_voice'),
        icon: FushiIcons.voice,
        tooltip: t.audiobook_tts_voices_section,
        padTouchTarget: true,
        onTap: onVoice,
      ),
      speed: c.speed,
      speedKey: const ValueKey<String>('manga_read_aloud_speed'),
      onSpeedChanged: (double v) => c.setSpeed(v),
      stopKey: const ValueKey<String>('manga_read_aloud_stop'),
      onStop: c.stop,
    );
  }
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

/// 成品音频播放条：上一句 / 播放·暂停 / 下一句 + 说话人，右侧跟随翻页 / 倍速 /
/// 音量 / 停止，底边进度线。
class MangaAudioPlaybackBar extends StatefulWidget {
  const MangaAudioPlaybackBar({
    super.key,
    required this.driver,
    required this.onStop,
    this.keyHints = MangaPlaybackKeyHints.none,
    this.middle,
    this.onExportClip,
    this.exportingClip = false,
  });

  final MangaAudioPlaybackDriver driver;

  /// 把正框着的那句导出成片段视频（页图 + 句子音频）；null 时不画这颗按钮。
  final VoidCallback? onExportClip;

  /// 导出进行中（按钮转圈）。
  final bool exportingClip;

  /// 停止成品音频会话（会话级，不只是暂停）。
  final VoidCallback onStop;

  final MangaPlaybackKeyHints keyHints;

  /// 底栏原有按钮（阅读器传入），夹在说话人与右侧控件之间，放不下横向滚动。
  final Widget? middle;

  @override
  State<MangaAudioPlaybackBar> createState() => _MangaAudioPlaybackBarState();
}

class _MangaAudioPlaybackBarState extends State<MangaAudioPlaybackBar>
    with StateResourceScope<MangaAudioPlaybackBar> {
  /// 拖动中的进度（松手才 seek）。
  double? _dragFraction;

  @override
  void initState() {
    super.initState();
    // 播放中位置流不是每个 tick 都通知（控制器只在换句 / 换状态时通知）：进度线自己
    // 按固定节拍刷新。
    ownTimer(
      Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (mounted && widget.driver.isPlaying && _dragFraction == null) {
          setState(() {});
        }
      }),
    );
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
    final VoidCallback? onExportClip = widget.onExportClip;
    final int? displayedLine = d.displayedLineIndex;
    final bool exportableLine =
        displayedLine != null && !d.manifest.lines[displayedLine].placeholder;
    final int total = d.totalMs;
    final double live = total <= 0
        ? 0
        : (d.positionMs / total).clamp(0.0, 1.0).toDouble();
    final double? drag = _dragFraction;
    final double fraction = drag ?? live;
    final MangaRenderedLine? line = d.currentLine;
    final String? speaker = mangaAudioSpeakerLabel(line);
    final bool unvoiced = line?.placeholder ?? false;

    // 读数优先级：拖动中显示拖到的时间；否则说话人（没配上音的句子标告警色并在
    // 提示里说明）；静音段没有说话人时显示页码。
    final _BarLabel label = drag != null
        ? _BarLabel(
            key: const ValueKey<String>('manga_audio_scrub_clock'),
            text: '${_clock((drag * total).round())} / ${_clock(total)}',
            tone: _LabelTone.secondary,
            tabular: true,
          )
        : speaker != null
        ? _BarLabel(
            key: const ValueKey<String>('manga_read_aloud_speaker'),
            text: speaker,
            tone: unvoiced ? _LabelTone.warning : _LabelTone.accent,
            dot: true,
            tooltip: unvoiced ? '${t.manga_audio_unvoiced} · $speaker' : null,
          )
        : _BarLabel(
            key: const ValueKey<String>('manga_audio_page_label'),
            text: t.manga_audio_status_page(page: d.currentPage + 1),
            tone: _LabelTone.secondary,
          );

    return _MangaPlayBar(
      label: label,
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
      middle: widget.middle,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (onExportClip != null)
            FushiIconButton(
              key: const ValueKey<String>('manga_audio_export_clip'),
              icon: FushiIcons.video,
              tooltip: t.audiobook_export_clip,
              padTouchTarget: true,
              busy: widget.exportingClip,
              // 整页无台词（页停留）或框着的是没配上音的占位句：没有可导出的声音。
              enabled: exportableLine,
              onTap: onExportClip,
            ),
          FushiIconButton(
            key: const ValueKey<String>('manga_audio_follow_page'),
            icon: FushiIcons.sync,
            tooltip: t.manga_audio_follow_page,
            padTouchTarget: true,
            selected: d.followPage,
            onTap: () => d.setFollowPage(!d.followPage),
          ),
        ],
      ),
      speed: d.speed,
      speedKey: const ValueKey<String>('manga_audio_speed'),
      onSpeedChanged: (double v) => d.setSpeed(v),
      volume: d.volume,
      volumeKey: const ValueKey<String>('manga_audio_volume'),
      onVolumeChanged: (double v) => unawaited(d.setVolume(v)),
      stopKey: const ValueKey<String>('manga_audio_stop'),
      onStop: widget.onStop,
      progress: _ScrubLine(
        key: const ValueKey<String>('manga_audio_progress'),
        fraction: fraction,
        enabled: total > 0,
        valueLabel: (double v) =>
            '${_clock((v * total).round())} / ${_clock(total)}',
        onDrag: (double v) => setState(() => _dragFraction = v),
        onCommit: (double v) {
          setState(() => _dragFraction = null);
          unawaited(d.seekTo((v * total).round()));
        },
      ),
    );
  }
}

/// 主按钮（播放 / 暂停 / 重试）的描述。
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

/// 条左侧读数的配色档。
enum _LabelTone { accent, secondary, warning }

/// 条左侧读数：说话人 / 状态 / 拖动时间，单行省略，完整文字进 tooltip。
class _BarLabel extends StatelessWidget {
  const _BarLabel({
    required super.key,
    required this.text,
    required this.tone,
    this.dot = false,
    this.tabular = false,
    this.tooltip,
  });

  final String text;
  final _LabelTone tone;
  final bool dot;
  final bool tabular;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final MangaChromePalette colors = MangaChromePalette.of(context);
    final Color color = switch (tone) {
      _LabelTone.accent => colors.accent,
      _LabelTone.secondary => colors.secondaryForeground,
      _LabelTone.warning => colors.warning,
    };
    return FushiTooltip(
      message: tooltip ?? text,
      child: Semantics(
        liveRegion: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (dot) ...<Widget>[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: color,
                  fontWeight: tone == _LabelTone.accent
                      ? FontWeight.w600
                      : null,
                  fontFeatures: tabular
                      ? const <FontFeature>[FontFeature.tabularFigures()]
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 窄于此宽度时倍速胶囊只画图标（倍速读数进 tooltip），把宽度留给中间的按钮。
const double _kSpeedLabelMinWidth = 520;

/// 播放条本体（两种音源共用）：一行 [kMangaChromeToolbarHeight] 高的胶囊。
///
/// `[⏮ ⏯ ⏭][读数] [middle…横滚] │ [trailing][倍速][音量][停止]`，[progress] 叠在
/// 底边；[onVolumeChanged] 为 null（现场合成）时没有音量按钮。
class _MangaPlayBar extends StatelessWidget {
  const _MangaPlayBar({
    required this.previous,
    required this.primary,
    required this.next,
    required this.trailing,
    required this.speed,
    required this.speedKey,
    required this.onSpeedChanged,
    required this.stopKey,
    required this.onStop,
    this.label,
    this.middle,
    this.progress,
    this.volume = 1.0,
    this.volumeKey,
    this.onVolumeChanged,
  });

  final Widget previous;
  final _PrimaryAction primary;
  final Widget next;
  final Widget? label;
  final Widget? middle;
  final Widget trailing;
  final double speed;
  final Key speedKey;
  final ValueChanged<double> onSpeedChanged;
  final Key stopKey;
  final VoidCallback onStop;
  final Widget? progress;
  final double volume;
  final Key? volumeKey;
  final ValueChanged<double>? onVolumeChanged;

  @override
  Widget build(BuildContext context) {
    final MangaChromePalette colors = MangaChromePalette.of(context);
    final Duration motion = fushiMotionDuration(context, FushiMotion.short);
    final Widget? labelWidget = label;
    final Widget? middleWidget = middle;
    final Widget? progressWidget = progress;
    final ValueChanged<double>? onVolume = onVolumeChanged;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: kMangaChromeBottomMaxWidth),
      child: SizedBox(
        height: kMangaChromeToolbarHeight,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool showSpeedLabel =
                constraints.maxWidth >= _kSpeedLabelMinWidth;
            final Widget row = Row(
              children: <Widget>[
                previous,
                _PrimaryButton(action: primary),
                next,
                const SizedBox(width: 8),
                Flexible(
                  flex: 2,
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: AnimatedSwitcher(
                      duration: motion,
                      switchInCurve: FushiMotion.enter,
                      switchOutCurve: FushiMotion.exit,
                      layoutBuilder:
                          (Widget? current, List<Widget> previousChildren) =>
                              Stack(
                                alignment: AlignmentDirectional.centerStart,
                                children: <Widget>[
                                  ...previousChildren,
                                  ?current,
                                ],
                              ),
                      child:
                          labelWidget ??
                          const SizedBox.shrink(
                            key: ValueKey<String>('manga_play_bar_no_label'),
                          ),
                    ),
                  ),
                ),
                if (middleWidget != null)
                  Expanded(
                    flex: 3,
                    child: Align(
                      alignment: AlignmentDirectional.centerEnd,
                      // 桌面默认 dragDevices 不含鼠标：不包这层，按钮放不下时
                      // 鼠标拖不动中段。
                      child: HorizontalDragScrollable(
                        child: SingleChildScrollView(
                          key: const ValueKey<String>('manga_play_bar_middle'),
                          scrollDirection: Axis.horizontal,
                          reverse: true,
                          child: middleWidget,
                        ),
                      ),
                    ),
                  )
                else
                  const Spacer(flex: 3),
                Container(
                  width: 1,
                  height: 24,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  color: colors.groupDivider,
                ),
                trailing,
                _SpeedButton(
                  key: speedKey,
                  speed: speed,
                  showLabel: showSpeedLabel,
                  onChanged: onSpeedChanged,
                ),
                if (onVolume != null)
                  _VolumeButton(
                    key: volumeKey,
                    volume: volume,
                    onChanged: onVolume,
                  ),
                FushiIconButton(
                  key: stopKey,
                  icon: FushiIcons.stop,
                  tooltip: t.manga_read_aloud_stop,
                  padTouchTarget: true,
                  onTap: onStop,
                ),
              ],
            );
            return FushiHoverLift(
              builder: (BuildContext context, bool _) => MangaChromeSurface(
                child: KeyedSubtree(
                  key: const ValueKey<String>('manga_read_aloud_bar'),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(kMangaChromePillRadius),
                    child: Stack(
                      children: <Widget>[
                        Positioned.fill(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: row,
                          ),
                        ),
                        if (progressWidget != null)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: progressWidget,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 主按钮：强调色实心圆（48dp，放进 64 高的条里上下各留 8），图标实心字形。
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
        size: 26,
        tooltip: action.tooltip,
        backgroundColor: colors.accent,
        enabledColor: colors.onAccent,
        disabledColor: colors.onAccent.withValues(alpha: 0.38),
        constraints: const BoxConstraints.tightFor(width: 48, height: 48),
        enabled: action.onPressed != null,
        onTap: action.onPressed,
      ),
    );
  }
}

/// 进度线的命中带高度：条底边到按钮下沿之间的留白（64 高条里 48 的按钮居中，
/// 下方留 8）。再高就会盖住按钮下沿，点按钮底边会变成跳转进度。
const double _kScrubBandHeight = 8;

/// 进度线本身的粗细。
const double _kScrubLineHeight = 3;

/// 条底边的进度线：点一下 / 横向拖动 = 在整卷时间轴上定位，松手才 seek；拖动期间
/// 父级显示拖到的时间。读屏走 Semantics 的 slider 语义（增减各 5%）。
class _ScrubLine extends StatelessWidget {
  const _ScrubLine({
    super.key,
    required this.fraction,
    required this.enabled,
    required this.valueLabel,
    required this.onDrag,
    required this.onCommit,
  });

  final double fraction;
  final bool enabled;

  /// 任意进度比例的读数（`6:15 / 47:21`），给读屏的当前值与增减后的值。
  final String Function(double fraction) valueLabel;
  final ValueChanged<double> onDrag;
  final ValueChanged<double> onCommit;

  @override
  Widget build(BuildContext context) {
    final MangaChromePalette colors = MangaChromePalette.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        double at(Offset local) =>
            width <= 0 ? 0 : (local.dx / width).clamp(0.0, 1.0).toDouble();
        final double up = (fraction + 0.05).clamp(0.0, 1.0).toDouble();
        final double down = (fraction - 0.05).clamp(0.0, 1.0).toDouble();
        return Semantics(
          slider: true,
          label: t.manga_audio_progress,
          value: valueLabel(fraction),
          increasedValue: valueLabel(up),
          decreasedValue: valueLabel(down),
          onIncrease: enabled ? () => onCommit(up) : null,
          onDecrease: enabled ? () => onCommit(down) : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: enabled
                ? (TapUpDetails d) => onCommit(at(d.localPosition))
                : null,
            onHorizontalDragStart: enabled
                ? (DragStartDetails d) => onDrag(at(d.localPosition))
                : null,
            onHorizontalDragUpdate: enabled
                ? (DragUpdateDetails d) => onDrag(at(d.localPosition))
                : null,
            onHorizontalDragEnd: enabled
                ? (DragEndDetails _) => onCommit(fraction)
                : null,
            child: SizedBox(
              height: _kScrubBandHeight,
              child: Align(
                alignment: Alignment.bottomLeft,
                child: SizedBox(
                  height: _kScrubLineHeight,
                  width: width,
                  child: Stack(
                    children: <Widget>[
                      Positioned.fill(
                        child: ColoredBox(
                          color: colors.foreground.withValues(alpha: 0.12),
                        ),
                      ),
                      FractionallySizedBox(
                        widthFactor: fraction,
                        heightFactor: 1,
                        child: ColoredBox(color: colors.accent),
                      ),
                    ],
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

/// 倍速胶囊：图标 + 当前倍速（窄条只画图标），点开 / 收起条上方的倍速条。
class _SpeedButton extends StatelessWidget {
  const _SpeedButton({
    super.key,
    required this.speed,
    required this.showLabel,
    required this.onChanged,
  });

  final double speed;
  final bool showLabel;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final String label = AudiobookSpeedSlider.format(speed);
    return _PopoverButton(
      icon: FushiIcons.speed,
      label: showLabel ? label : null,
      tooltip: '${t.playback_speed} $label',
      panel: _SpeedRow(speed: speed, onChanged: onChanged),
    );
  }
}

/// 音量按钮（成品音频）：静音时画静音图标，读数进 tooltip；点开 / 收起条上方的
/// 音量条。
class _VolumeButton extends StatelessWidget {
  const _VolumeButton({
    super.key,
    required this.volume,
    required this.onChanged,
  });

  final double volume;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return _PopoverButton(
      icon: volume <= 0 ? FushiIcons.volumeOff : FushiIcons.volumeUp,
      tooltip: '${t.audio_volume} ${AudiobookVolumeSlider.format(volume)}',
      panel: _VolumeRow(volume: volume, onChanged: onChanged),
    );
  }
}

/// 条上的弹层按钮（倍速 / 音量共用）：点按钮开关条上方的 [panel]，点组外收起；
/// 弹层贴按钮右上角、带淡入 + 轻微放大（[FushiMotion]，减弱动态效果直接出现）。
class _PopoverButton extends StatefulWidget {
  const _PopoverButton({
    required this.icon,
    required this.tooltip,
    required this.panel,
    this.label,
  });

  final IconData icon;
  final String? label;
  final String tooltip;
  final Widget panel;

  @override
  State<_PopoverButton> createState() => _PopoverButtonState();
}

class _PopoverButtonState extends State<_PopoverButton> {
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();

  /// 按钮与弹层同属一组：点按钮是开关，点组外才收起。
  final Object _tapGroup = Object();

  void _toggle() => setState(_portal.toggle);

  void _hide() {
    if (_portal.isShowing) setState(_portal.hide);
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (BuildContext context) => Align(
          alignment: Alignment.topLeft,
          child: CompositedTransformFollower(
            link: _link,
            targetAnchor: Alignment.topRight,
            followerAnchor: Alignment.bottomRight,
            offset: const Offset(0, -12),
            child: TapRegion(
              groupId: _tapGroup,
              onTapOutside: (PointerDownEvent _) => _hide(),
              child: ExcludeFocus(
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: 1),
                  duration: fushiMotionDuration(context, FushiMotion.short),
                  curve: FushiMotion.enter,
                  builder: (BuildContext context, double v, Widget? child) =>
                      Opacity(
                        opacity: v,
                        child: Transform.scale(
                          scale: 0.96 + 0.04 * v,
                          alignment: Alignment.bottomRight,
                          child: child,
                        ),
                      ),
                  // 按内容定高（BUG：倍速面板撑满屏高）：浮层里的约束是放松后的
                  // 0～整屏高，Material Slider 是 sizedByParent、高度有界就直接取
                  // maxHeight，面板会从按钮上方一路撑到屏顶。IntrinsicHeight 让
                  // 面板高度收回到内容的固有高度。
                  child: SizedBox(
                    width: 320,
                    child: IntrinsicHeight(
                      child: MangaChromeSurface(
                        radius: 20,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
                          child: widget.panel,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        child: TapRegion(
          groupId: _tapGroup,
          child: FushiPressScale(
            child: FushiIconButton(
              icon: widget.icon,
              label: widget.label,
              tooltip: widget.tooltip,
              padTouchTarget: true,
              selected: _portal.isShowing,
              onTap: _toggle,
            ),
          ),
        ),
      ),
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

/// 音量一行（成品音频）：图标 + 与有声书快捷设置同一口径的音量条 + 百分比读数
/// （1% / 5% 的细步进没有常驻读数等于白调）。
class _VolumeRow extends StatelessWidget {
  const _VolumeRow({required this.volume, required this.onChanged});

  final double volume;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final MangaChromePalette colors = MangaChromePalette.of(context);
    return Row(
      children: <Widget>[
        FushiIcon(
          FushiIcons.volumeUp,
          size: 20,
          color: colors.secondaryForeground,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: AudiobookVolumeSlider(
            key: const ValueKey<String>('manga_audio_volume_slider'),
            volume: volume,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            AudiobookVolumeSlider.format(volume),
            key: const ValueKey<String>('manga_audio_volume_readout'),
            textAlign: TextAlign.end,
            maxLines: 1,
            style: TextStyle(
              color: colors.secondaryForeground,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}
