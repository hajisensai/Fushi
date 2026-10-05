/// 有声书侧板内容（2026-10 重设计，用户：「有声书的侧边栏那块也优化一下」）。
///
/// 页头（图标 / 标题 / 当前章 / 关闭）由外壳 [ReaderSideSheet] 画；本组件是 body：
///  * 「正在播放」卡：M3E primaryContainer 饱和色块（Apple 分组卡）——封面、当前句
///    （交叉淡入）、可拖动的全书进度（章节刻度 + 随播放波动的波浪）、大号时间、
///    传输行（中间是形状变形的播放 FAB）、倍速滑块（与歌词模式同款）与跟随键；
///  * 页签「句子 / 章节 / 设置」：句子页列当前章的句子，当前句高亮并自动滚到视野
///    里（手动滚动后 5 秒不抢），点句跳过去；低频的资源（对齐 / 转录 / 导入）收进
///    设置页底部的次级分组。
/// 设置页内容由调用方经 [settingsBuilder] 提供（音量 / 延迟等行的写路径在设置 sheet）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/media/audiobook/audiobook_play_bar.dart'
    show AudiobookFollowAudioButton, AudiobookPlayFab;
import 'package:fushi/src/media/audiobook/audiobook_speed_slider.dart';
import 'package:fushi/src/pages/implementations/reader_fushi/reader_panel_kit.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/audiobook_bridge.dart'
    show TtuTocEntry;
import 'package:fushi/src/reader/ttu_toc_flatten.dart'
    show resolveCurrentTocEntry;
import 'package:fushi/utils.dart';

/// 「信息卡固定 + tab 内容独立滚动」形态所需的最小可用高度（dp）。
///
/// 固定部分（标题行 + 96×136 封面的信息卡 + 进度条 + 五颗播放键 + 标签栏 + 间距）
/// 实测约 312dp；再留 ≥128dp 给 tab 视口，才够看见几行章节。低于此高度就得整块
/// 面板一起滚——见 [readerAudiobookPanelPinsHero]。
const double kReaderAudiobookPanelPinnedMinHeight = 440.0;

/// 给定可用高度下，面板是否还能把信息卡钉住、只让 tab 内容滚。
///
/// 为什么需要这道判据：面板原先恒为「Column(min) + Flexible(tab 滚动区)」。
/// `Flexible` 在高度不够时**不会溢出报错，而是被压到 ~0**——手机横屏（如
/// 768×348dp，bottom sheet 只有 0.9×348≈313dp）下实测 tab 视口只剩 1.2px，
/// `maxScrollExtent` 也近乎 0：标签栏以下的资源 / 章节 / 设置既看不见、也**滚不
/// 出来**，且因为没有 overflow 报错而在测试里毫无痕迹。
bool readerAudiobookPanelPinsHero(double availableHeight) =>
    availableHeight.isFinite &&
    availableHeight >= kReaderAudiobookPanelPinnedMinHeight;

/// 标签页顺序（也是 [ReaderAudiobookPanel.initialTab] 的取值域）。
const List<String> kReaderAudiobookPanelTabs = <String>[
  'sentences',
  'chapters',
  'settings',
];

class ReaderAudiobookPanel extends StatefulWidget {
  const ReaderAudiobookPanel({
    super.key,
    required this.controller,
    required this.toc,
    required this.currentSection,
    this.currentCharOffset,
    required this.onJumpSection,
    required this.title,
    required this.chapterLabel,
    required this.coverPath,
    required this.settingsBuilder,
    this.onAudioImport,
    this.onPickAlignment,
    this.onTranscribe,
    this.initialTab = 'sentences',
    this.tick = const Duration(seconds: 1),
  });

  final AudiobookPlayerController? controller;
  final List<TtuTocEntry> toc;

  /// 阅读器当前章（用于「当前章节」标注）。
  final int? currentSection;

  /// 当前章内字符偏移（与 [TtuTocEntry.anchorCharOffset] 同尺），未知 null；
  /// 同一 spine 章下靠锚点分节的目录项靠它分清当前是哪一条。
  final int? currentCharOffset;
  final Future<void> Function(int sectionIndex, String? fragment) onJumpSection;
  final String title;
  final String? chapterLabel;

  /// 书籍封面文件路径；null 不显示。
  final String? coverPath;

  /// 「设置」tab 的内容（音量 / 速度 / 延迟 / 播放条开关…）。
  final WidgetBuilder settingsBuilder;

  final VoidCallback? onAudioImport;
  final VoidCallback? onPickAlignment;
  final VoidCallback? onTranscribe;

  /// sentences / chapters / settings（见 [kReaderAudiobookPanelTabs]）。
  final String initialTab;

  /// 进度条刷新周期（控制器只在 cue 切换 / 播放暂停时 notify，拖动条需要秒级 tick）。
  final Duration tick;

  @override
  State<ReaderAudiobookPanel> createState() => _ReaderAudiobookPanelState();
}

class _ReaderAudiobookPanelState extends State<ReaderAudiobookPanel> {
  late String _tab = kReaderAudiobookPanelTabs.contains(widget.initialTab)
      ? widget.initialTab
      : kReaderAudiobookPanelTabs.first;
  Timer? _ticker;

  /// 拖动整书进度条期间 / 跨文件 seek 落定前本地保留的目标位置（毫秒），避免松手
  /// 后拇指先跳回旧位置再追上。位置追上（±1.5s）或超过 2s 自动放手。
  int? _scrubTargetMs;
  DateTime? _scrubSetAt;

  /// 句子页：用户最近一次手动滚动的时刻；5 秒内不自动跟随到当前句。
  DateTime? _userScrolledAt;
  final ScrollController _sentenceScroll = ScrollController();

  /// 句子页上一次自动定位到的句子（同一句不重复滚）。
  AudioCue? _lastRevealedCue;

  /// 句子行的估算高度（引文卡两行正文 + 元信息 + 间距）：懒加载列表里不可见行
  /// 没有布局，按它先跳到附近，再对可见行 ensureVisible 精修。
  static const double _kSentenceExtent = 92;

  int? _effectiveScrubMs(Duration livePos) {
    final int? target = _scrubTargetMs;
    final DateTime? at = _scrubSetAt;
    if (target == null || at == null) return null;
    final bool stale = DateTime.now().difference(at).inMilliseconds > 2000;
    final bool caughtUp = (livePos.inMilliseconds - target).abs() < 1500;
    if (stale || caughtUp) {
      _scrubTargetMs = null;
      _scrubSetAt = null;
      return null;
    }
    return target;
  }

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(widget.tick, (_) {
      if (mounted) setState(() {});
    });
    widget.controller?.addListener(_onController);
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealCurrent());
  }

  @override
  void didUpdateWidget(ReaderAudiobookPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?.removeListener(_onController);
      widget.controller?.addListener(_onController);
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onController);
    _ticker?.cancel();
    _sentenceScroll.dispose();
    super.dispose();
  }

  void _onController() {
    if (!mounted) return;
    final AudioCue? cue = widget.controller?.currentCue;
    if (_tab == 'sentences' && !identical(cue, _lastRevealedCue)) {
      final DateTime? at = _userScrolledAt;
      if (at == null || DateTime.now().difference(at).inSeconds >= 5) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _revealCurrent());
      }
    }
  }

  /// 把句子列表滚到当前句（居中偏上）。
  void _revealCurrent({bool force = false}) {
    if (!mounted || _tab != 'sentences') return;
    final AudiobookPlayerController? ctrl = widget.controller;
    if (ctrl == null || !_sentenceScroll.hasClients) return;
    final List<AudioCue> cues = ctrl.chapterCuesSnapshot;
    final AudioCue? cue = ctrl.currentCue;
    final int index = cue == null ? -1 : cues.indexOf(cue);
    if (index < 0) return;
    _lastRevealedCue = cue;
    final ScrollPosition pos = _sentenceScroll.position;
    final double target =
        (index * _kSentenceExtent - pos.viewportDimension * 0.3)
            .clamp(0.0, pos.maxScrollExtent);
    final Duration d = fushiMotionDuration(context, FushiMotion.medium);
    if (d == Duration.zero || (pos.pixels - target).abs() > 2400) {
      _sentenceScroll.jumpTo(target);
    } else {
      unawaited(
        _sentenceScroll.animateTo(target,
            duration: d, curve: FushiMotion.standard),
      );
    }
    if (force) _userScrolledAt = null;
  }

  static String _formatDuration(Duration d) => FushiTimeFormat.clockPadded(d);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AudiobookPlayerController? ctrl = widget.controller;
    final Widget tabContent = switch (_tab) {
      'settings' => _buildSettingsTab(theme, ctrl),
      'chapters' => _buildChaptersTab(theme, ctrl),
      _ => _buildSentencesTab(theme, ctrl),
    };
    final List<Widget> head = <Widget>[
      _buildHero(theme, ctrl),
      const SizedBox(height: 4),
      ReaderPanelTabs<String>(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
        tabs: <ReaderPanelTab<String>>[
          ReaderPanelTab<String>(
            value: 'sentences',
            label: t.reader_audiobook_tab_sentences,
            icon: Icons.format_quote_rounded,
            key: const ValueKey<String>('fushi_audiobook_tab_button_sentences'),
          ),
          ReaderPanelTab<String>(
            value: 'chapters',
            label: t.reader_audiobook_tab_chapters,
            icon: Icons.format_list_bulleted,
            key: const ValueKey<String>('fushi_audiobook_tab_button_chapters'),
          ),
          ReaderPanelTab<String>(
            value: 'settings',
            label: t.settings,
            icon: Icons.tune_outlined,
            key: const ValueKey<String>('fushi_audiobook_tab_button_settings'),
          ),
        ],
        selected: _tab,
        onChanged: (String id) {
          setState(() => _tab = id);
          if (id == 'sentences') {
            _lastRevealedCue = null;
            WidgetsBinding.instance
                .addPostFrameCallback((_) => _revealCurrent(force: true));
          }
        },
      ),
    ];
    final Widget body = AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.short),
      switchInCurve: FushiMotion.enter,
      switchOutCurve: FushiMotion.exit,
      child: KeyedSubtree(
        key: ValueKey<String>('fushi_audiobook_tab_$_tab'),
        child: tabContent,
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // 高度够 → 「正在播放」卡钉住、只有页签内容滚；不够 → 整块面板一起滚
          // （手机横屏），否则 Expanded 被压到 ~0，页签以下滚不出来。
          final bool pinned =
              readerAudiobookPanelPinsHero(constraints.maxHeight);
          if (pinned) {
            return FushiEntranceScope(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  ...head,
                  Expanded(child: body),
                ],
              ),
            );
          }
          final Widget column = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ...head,
              SizedBox(
                height: math.max(320, constraints.maxHeight * 0.8),
                child: body,
              ),
            ],
          );
          if (!constraints.maxHeight.isFinite) return column;
          return SingleChildScrollView(
            key: ValueKey<String>('fushi_audiobook_scroll_$_tab'),
            primary: false,
            child: FushiEntranceScope(child: column),
          );
        },
      ),
    );
  }

  /// 「正在播放」卡：M3E primaryContainer 饱和色块（Apple 分组卡）——封面 + 当前句
  /// + 全书进度（可拖动，章节刻度）+ 大号时间 + 传输行（形状变形播放 FAB）+ 倍速与
  /// 跟随。没挂控制器时只给导入入口。
  Widget _buildHero(ThemeData theme, AudiobookPlayerController? ctrl) {
    const ReaderPanelCardTone tone = ReaderPanelCardTone.emphasis;
    final Color fg = ReaderPanelCard.foregroundFor(context, tone);
    final String? coverPath = widget.coverPath;
    if (ctrl == null) {
      return ReaderPanelCard(
        tone: tone,
        child: ReaderPanelEmpty(
          icon: Icons.headphones_outlined,
          message: widget.title,
          actionLabel: widget.onAudioImport == null ? null : t.audio_import,
          onAction: widget.onAudioImport == null
              ? null
              : () {
                  Navigator.of(context).pop();
                  widget.onAudioImport!();
                },
        ),
      );
    }
    final String cueText = ctrl.currentCue?.text.trim() ?? '';
    return ReaderPanelCard(
      key: const ValueKey<String>('fushi_audiobook_now_playing'),
      tone: tone,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (coverPath != null) ...<Widget>[
                ClipRRect(
                  borderRadius: const BorderRadius.all(Radius.circular(12)),
                  child: Image.file(
                    File(coverPath),
                    key: const ValueKey<String>('fushi_audiobook_cover'),
                    width: 56,
                    height: 80,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        const SizedBox(width: 56, height: 80),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      t.reader_audiobook_now_playing,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: fg.withValues(alpha: 0.75),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    AnimatedSwitcher(
                      duration: fushiMotionDuration(context, FushiMotion.short),
                      switchInCurve: FushiMotion.enter,
                      switchOutCurve: FushiMotion.exit,
                      layoutBuilder: (Widget? current, List<Widget> previous) =>
                          Stack(
                        alignment: AlignmentDirectional.topStart,
                        children: <Widget>[
                          ...previous,
                          if (current != null) current,
                        ],
                      ),
                      child: Text(
                        cueText.isEmpty ? widget.title : cueText,
                        key: ValueKey<String>('fushi_audiobook_cue_$cueText'),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: fg,
                          fontWeight: FontWeight.w600,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildTransport(theme, ctrl, fg),
        ],
      ),
    );
  }

  /// **全书**进度条（[AudiobookPlayerController.globalPosition] /
  /// [AudiobookPlayerController.totalDuration]，拖动经 `seekGlobalMs` 跨文件定位，
  /// 松手才 seek）+ 大号当前时间 / 总时长 + 「-10s / 上一句 / 播放 / 下一句 / +10s」
  /// + 倍速 / 跟随。
  Widget _buildTransport(
    ThemeData theme,
    AudiobookPlayerController ctrl,
    Color fg,
  ) {
    final bool glass = isGlassDesign(context);
    final Duration livePos = ctrl.globalPosition;
    final Duration dur = ctrl.totalDuration;
    final int durMs = dur.inMilliseconds;
    final int? scrub = _effectiveScrubMs(livePos);
    final Duration pos =
        scrub == null ? livePos : Duration(milliseconds: scrub);
    final double value =
        durMs > 0 ? (pos.inMilliseconds / durMs).clamp(0.0, 1.0) : 0.0;
    final List<double> ticks = <double>[
      if (durMs > 0)
        for (final TtuTocEntry e in widget.toc)
          if (ctrl.sectionStartGlobalMs(e.index) case final int ms
              when ms > 0 && ms < durMs)
            ms / durMs,
    ];
    final ButtonStyle flat = IconButton.styleFrom(foregroundColor: fg);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // M3E：拖动条之上叠一条随播放波动的波浪进度（暂停收平）；拖动条本身
        // 负责命中、章节刻度与拇指（轨道透明）。
        Stack(
          alignment: Alignment.center,
          children: <Widget>[
            if (!glass)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: FushiWavyLinearProgress(
                  value: value,
                  waving: ctrl.isPlaying,
                  color: fg,
                  trackColor: fg.withValues(alpha: 0.2),
                ),
              ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: glass ? 3 : 10,
                activeTrackColor: glass ? null : Colors.transparent,
                inactiveTrackColor: glass ? null : Colors.transparent,
                thumbColor: glass ? null : fg,
                trackShape: ReaderAudiobookChapterTrackShape(
                  fractions: ticks,
                  tickColor: fg.withValues(alpha: 0.55),
                ),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: FushiSlider(
                key: const ValueKey<String>('fushi_audiobook_panel_slider'),
                value: value,
                ticks: ticks,
                onChangeStart: durMs > 0
                    ? (double v) => setState(() {
                          _scrubTargetMs = (v * durMs).round();
                          _scrubSetAt = DateTime.now();
                        })
                    : null,
                onChanged: durMs > 0
                    ? (double v) => setState(() {
                          _scrubTargetMs = (v * durMs).round();
                          _scrubSetAt = DateTime.now();
                        })
                    : null,
                onChangeEnd: durMs > 0
                    ? (double v) {
                        final int target = (v * durMs).round();
                        setState(() {
                          _scrubTargetMs = target;
                          _scrubSetAt = DateTime.now();
                        });
                        unawaited(ctrl.seekGlobalMs(target));
                      }
                    : null,
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              ReaderStatNumber(
                value: _formatDuration(pos),
                color: fg,
                large: false,
              ),
              const Spacer(),
              Text(
                _formatDuration(dur),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: fg.withValues(alpha: 0.7),
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            FushiIconButtonControl(
              tooltip: '-10s',
              style: flat,
              icon: const FushiIcon(Icons.replay_10_rounded),
              onPressed: () => unawaited(ctrl.seekRelative(-10)),
            ),
            FushiIconButtonControl(
              tooltip: t.prev_sentence,
              style: flat,
              iconSize: 30,
              icon: const FushiIcon(Icons.skip_previous_rounded),
              onPressed: () => unawaited(ctrl.skipToPrevCue()),
            ),
            const SizedBox(width: 6),
            KeyedSubtree(
              key: const ValueKey<String>('fushi_audiobook_panel_play'),
              child: AudiobookPlayFab(controller: ctrl, size: 64),
            ),
            const SizedBox(width: 6),
            FushiIconButtonControl(
              tooltip: t.next_sentence,
              style: flat,
              iconSize: 30,
              icon: const FushiIcon(Icons.skip_next_rounded),
              onPressed: () => unawaited(ctrl.skipToNextCue()),
            ),
            FushiIconButtonControl(
              tooltip: '+10s',
              style: flat,
              icon: const FushiIcon(Icons.forward_10_rounded),
              onPressed: () => unawaited(ctrl.seekRelative(10)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: <Widget>[
            FushiIcon(Icons.speed_rounded, color: fg, size: 20),
            const SizedBox(width: 6),
            SizedBox(
              width: 52,
              child: Text(
                AudiobookSpeedSlider.format(ctrl.speed),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ),
            Expanded(
              child: AudiobookSpeedSlider(
                key: const ValueKey<String>('fushi_audiobook_panel_speed'),
                speed: ctrl.speed,
                onChanged: (double v) {
                  unawaited(ctrl.setSpeed(v));
                  setState(() {});
                },
              ),
            ),
            AudiobookFollowAudioButton(controller: ctrl, foregroundColor: fg),
          ],
        ),
      ],
    );
  }

  /// 「句子」页：当前章的句子，当前句高亮并自动滚到视野里；点句跳过去（不关面板）。
  Widget _buildSentencesTab(ThemeData theme, AudiobookPlayerController? ctrl) {
    final List<AudioCue> cues = ctrl?.chapterCuesSnapshot ?? const <AudioCue>[];
    if (ctrl == null || cues.isEmpty) {
      return ReaderPanelEmpty(
        icon: Icons.format_quote_rounded,
        message: t.reader_audiobook_no_sentences,
      );
    }
    final AudioCue? current = ctrl.currentCue;
    return Stack(
      children: <Widget>[
        NotificationListener<UserScrollNotification>(
          onNotification: (UserScrollNotification n) {
            if (n.direction != ScrollDirection.idle) {
              _userScrolledAt = DateTime.now();
            }
            return false;
          },
          child: ListView.builder(
            key: const ValueKey<String>('fushi_audiobook_sentences'),
            controller: _sentenceScroll,
            padding: const EdgeInsets.only(bottom: 64),
            itemCount: cues.length,
            itemBuilder: fushiStaggeredItemBuilder(
              (BuildContext context, int i) {
                final AudioCue cue = cues[i];
                final bool isCurrent = identical(cue, current);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ReaderQuoteCard(
                    key: ValueKey<String>('fushi_audiobook_sentence_$i'),
                    text: cue.text.trim(),
                    meta: _formatDuration(Duration(milliseconds: cue.startMs)),
                    current: isCurrent,
                    maxLines: 3,
                    onTap: () => unawaited(ctrl.skipToCue(cue)),
                  ),
                );
              },
            ),
          ),
        ),
        PositionedDirectional(
          end: 4,
          bottom: 8,
          child: FushiFilledButton.tonalIcon(
            key: const ValueKey<String>('fushi_audiobook_jump_current'),
            icon: const FushiIcon(Icons.my_location_rounded),
            label: Text(t.reader_audiobook_jump_to_current),
            onPressed: () => _revealCurrent(force: true),
          ),
        ),
      ],
    );
  }

  /// 「设置」页：音量 / 速度 / 延迟等（调用方提供），底部次级分组收低频的资源操作
  /// （音频文件、对齐文件、转录、导入音频）。
  Widget _buildSettingsTab(ThemeData theme, AudiobookPlayerController? ctrl) {
    return ListView(
      key: const ValueKey<String>('fushi_audiobook_settings_list'),
      primary: false,
      children: <Widget>[
        widget.settingsBuilder(context),
        ReaderPanelSectionLabel(t.reader_audiobook_section_tools),
        _buildFilesTab(theme, ctrl),
      ],
    );
  }

  /// 资源分组：音频文件列表 + 对齐文件（当前文件名）+ 转录生成字幕 + 导入音频。
  Widget _buildFilesTab(ThemeData theme, AudiobookPlayerController? ctrl) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<File> files = ctrl?.audioFiles ?? const <File>[];
    final String? alignmentPath = ctrl?.audiobook?.alignmentPath;
    final String? alignmentName = alignmentPath == null || alignmentPath.isEmpty
        ? null
        : p.basename(alignmentPath);
    void closeThen(VoidCallback action) {
      Navigator.of(context).pop();
      action();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AdaptiveSettingsSection(
          children: <Widget>[
            if (widget.onPickAlignment != null)
              AdaptiveSettingsRow(
                key: const ValueKey<String>('fushi_audiobook_panel_alignment'),
                title: t.audiobook_pick_alignment,
                subtitle: alignmentName,
                icon: Icons.align_horizontal_left,
                showIcon: true,
                onTap: () => closeThen(widget.onPickAlignment!),
              ),
            if (widget.onTranscribe != null)
              AdaptiveSettingsRow(
                key: const ValueKey<String>('fushi_audiobook_panel_transcribe'),
                title: t.audiobook_transcribe_action,
                icon: Icons.record_voice_over_outlined,
                showIcon: true,
                onTap: () => closeThen(widget.onTranscribe!),
              ),
            if (widget.onAudioImport != null)
              AdaptiveSettingsRow(
                key: const ValueKey<String>('fushi_audiobook_panel_import'),
                title: t.audio_import,
                icon: Icons.headphones_outlined,
                showIcon: true,
                onTap: () => closeThen(widget.onAudioImport!),
              ),
          ],
        ),
        if (files.isNotEmpty) ...<Widget>[
          SizedBox(height: tokens.spacing.gap),
          AdaptiveSettingsSection(
            children: <Widget>[
              for (int i = 0; i < files.length; i++)
                AdaptiveSettingsRow(
                  title: p.basename(files[i].path),
                  subtitle: '${i + 1} / ${files.length}',
                  icon: Icons.audio_file_outlined,
                  showIcon: true,
                ),
            ],
          ),
        ],
      ],
    );
  }

  /// 「章节」页：目录 + 该章首句在全书音频时间轴上的起点；当前章高亮。点击先跳
  /// 阅读器到该章，再把音频定位到该章首句（无 cue 的章只跳文字）。
  Widget _buildChaptersTab(ThemeData theme, AudiobookPlayerController? ctrl) {
    final int currentEntry = resolveCurrentTocEntry(
          widget.toc,
          widget.currentSection,
          widget.currentCharOffset,
        ) ??
        -1;
    final int totalMs = ctrl?.totalDuration.inMilliseconds ?? 0;
    final List<int?> starts = <int?>[
      for (final TtuTocEntry e in widget.toc)
        ctrl?.sectionStartGlobalMs(e.index),
    ];
    int? durationFor(int i) {
      final int? start = starts[i];
      if (start == null) return null;
      for (int j = i + 1; j < starts.length; j++) {
        final int? next = starts[j];
        if (next != null && next > start) return next - start;
      }
      return totalMs > start ? totalMs - start : null;
    }

    return ListView.builder(
      key: const ValueKey<String>('fushi_audiobook_chapters'),
      primary: false,
      itemCount: widget.toc.length,
      itemBuilder: fushiStaggeredItemBuilder((BuildContext context, int i) {
        final TtuTocEntry entry = widget.toc[i];
        final int? startMs = starts[i];
        final int? dms = durationFor(i);
        final String? subtitle = <String>[
          if (i == currentEntry) t.reader_audiobook_current_chapter,
          if (dms != null) _formatDuration(Duration(milliseconds: dms)),
        ].join(' · ').let((String s) => s.isEmpty ? null : s);
        return ReaderPanelListItem(
          title: entry.label,
          subtitle: subtitle,
          current: i == currentEntry,
          trailing: Text(
            startMs == null
                ? '—'
                : _formatDuration(Duration(milliseconds: startMs)),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          onTap: () async {
            Navigator.of(context).pop();
            await widget.onJumpSection(entry.index, entry.fragment);
            final AudioCue? first = ctrl?.sectionFirstCue(entry.index);
            if (ctrl != null && first != null) {
              await ctrl.skipToCue(first);
            }
          },
        );
      }),
    );
  }
}

/// 全书进度条的轨道：先画默认圆角轨道，再在**同一个 trackRect** 上画章节刻度
/// （每章首句在全书时间轴上的位置）。
///
/// 刻度曾是 slider 下方单独一条 `CustomPaint`，左右硬写 24px 内缩；而 slider 的
/// 轨道内缩是 `max(overlay, thumb) / 2`（本面板 overlayRadius 12 → 12px），两者
/// 对不上，刻度整体被往中间压、离两端越远偏得越多，拇指走到章首时和刻度错开。
/// 非离散 slider 的拇指中心就是 `trackRect.left + value * trackRect.width`，刻度
/// 用同一公式即与进度恒对齐。
class ReaderAudiobookChapterTrackShape extends SliderTrackShape {
  const ReaderAudiobookChapterTrackShape({
    required this.fractions,
    required this.tickColor,
    this.inner = const RoundedRectSliderTrackShape(),
  });

  /// 章首在全书时间轴上的位置（0~1，已去掉两端）。
  final List<double> fractions;
  final Color tickColor;
  final SliderTrackShape inner;

  /// 刻度 x 坐标：与非离散 slider 的拇指中心同一公式。
  static double tickX(Rect trackRect, double fraction, TextDirection dir) {
    final double f = dir == TextDirection.rtl ? 1 - fraction : fraction;
    return trackRect.left + f * trackRect.width;
  }

  @override
  bool get isRounded => inner.isRounded;

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) =>
      inner.getPreferredRect(
        parentBox: parentBox,
        offset: offset,
        sliderTheme: sliderTheme,
        isEnabled: isEnabled,
        isDiscrete: isDiscrete,
      );

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    inner.paint(
      context,
      offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      enableAnimation: enableAnimation,
      thumbCenter: thumbCenter,
      secondaryOffset: secondaryOffset,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
      textDirection: textDirection,
    );
    if (fractions.isEmpty) return;
    final Rect trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final double half = trackRect.height / 2 + 3;
    final Paint paint = Paint()
      ..color = tickColor
      ..strokeWidth = 1.5;
    for (final double f in fractions) {
      final double x = tickX(trackRect, f, textDirection);
      context.canvas.drawLine(
        Offset(x, trackRect.center.dy - half),
        Offset(x, trackRect.center.dy + half),
        paint,
      );
    }
  }
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
