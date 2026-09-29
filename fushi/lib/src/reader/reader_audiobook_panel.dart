/// 有声书居中面板（Niratan「Sasayaki」形态），从 ReaderQuickSettingsSheet 抽出成
/// 独立组件：封面 + 书名 + 当前章 + **全书**进度条 + 播放控制，下接「资源 / 章节 /
/// 设置」三个 MD3 标签页。设置页内容由调用方经 [settingsBuilder] 提供
/// （音量 / 速度 / 延迟等行仍由设置 sheet 持有其写路径）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
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
  'files',
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
    this.initialTab = 'chapters',
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

  /// files / chapters / settings（见 [kReaderAudiobookPanelTabs]）。
  final String initialTab;

  /// 进度条刷新周期（控制器只在 cue 切换 / 播放暂停时 notify，拖动条需要秒级 tick）。
  final Duration tick;

  @override
  State<ReaderAudiobookPanel> createState() => _ReaderAudiobookPanelState();
}

class _ReaderAudiobookPanelState extends State<ReaderAudiobookPanel>
    with SingleTickerProviderStateMixin {
  late String _tab = kReaderAudiobookPanelTabs.contains(widget.initialTab)
      ? widget.initialTab
      : 'chapters';
  Timer? _ticker;

  /// 标签栏指示器的 controller。真相仍是 [_tab]：这里没有 [TabBarView]（tab 内容
  /// 高度各异，矮窗形态还要和信息卡一起滚，放不进定高的横滑视口），点击 / 键盘
  /// 激活都经 [TabBar.onTap] 回到 [_tab]。
  TabController? _tabController;

  /// eink 下指示器不滑（滑动 = 一串局部刷新的残影）；Theme 在 initState 读不到，
  /// 故 controller 在 didChangeDependencies 里按当前时长建 / 重建。
  Duration? _tabAnimationDuration;

  /// 拖动整书进度条期间 / 跨文件 seek 落定前本地保留的目标位置（毫秒），避免松手
  /// 后拇指先跳回旧位置再追上。位置追上（±1.5s）或超过 2s 自动放手。
  int? _scrubTargetMs;
  DateTime? _scrubSetAt;

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
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final Duration duration = einkSafeDuration(context, kTabScrollDuration);
    if (duration == _tabAnimationDuration) return;
    _tabAnimationDuration = duration;
    _tabController?.dispose();
    _tabController = TabController(
      length: kReaderAudiobookPanelTabs.length,
      initialIndex: kReaderAudiobookPanelTabs.indexOf(_tab),
      animationDuration: duration,
      vsync: this,
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _tabController?.dispose();
    super.dispose();
  }

  static String _formatDuration(Duration d) => FushiTimeFormat.clockPadded(d);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final AudiobookPlayerController? ctrl = widget.controller;
    final Widget tabContent = switch (_tab) {
      'files' => _buildFilesTab(theme, ctrl),
      'settings' => widget.settingsBuilder(context),
      _ => _buildChaptersTab(theme, ctrl),
    };
    // 标签栏及其之上的固定部分（钉住形态下不随 tab 内容滚动）。
    final List<Widget> head = <Widget>[
      Row(
        children: <Widget>[
          Expanded(
            child: Text(
              t.section_audiobook,
              style: theme.textTheme.titleMedium,
            ),
          ),
          IconButton(
            key: const ValueKey<String>('fushi_audiobook_panel_close'),
            icon: const Icon(Icons.close),
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
      SizedBox(height: tokens.spacing.gap),
      _buildHero(theme, ctrl),
      SizedBox(height: tokens.spacing.gap),
      _buildTabBar(theme),
      SizedBox(height: tokens.spacing.gap),
    ];
    // 侧栏 / bottom sheet 形态：标题行的 × 与点外面即关已够，底部不再摆一颗
    // 整宽「关闭」（那是居中对话框时代的产物，在 400px 侧栏里只是占掉一行
    // 章节）。
    final Widget body = KeyedSubtree(
      key: ValueKey<String>('fushi_audiobook_tab_$_tab'),
      child: tabContent,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.page,
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // 高度够 → 信息卡钉住、只有 tab 内容滚（400px 侧栏 / 竖屏 sheet 的既有
          // 形态）；不够 → 整块面板一起滚，否则 Flexible 会被压到 ~0，标签栏以下
          // 的内容滚不出来（手机横屏）。滚动区的 key 带 tab，切 tab 即回到顶部。
          final bool pinned =
              readerAudiobookPanelPinsHero(constraints.maxHeight);
          final Widget column = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ...head,
              if (pinned)
                Flexible(
                  child: SingleChildScrollView(
                    key: ValueKey<String>('fushi_audiobook_scroll_$_tab'),
                    primary: false,
                    child: body,
                  ),
                )
              else
                body,
            ],
          );
          // 无界高度（父级自己就是滚动容器）时不再套一层 viewport。
          if (pinned || !constraints.maxHeight.isFinite) return column;
          return SingleChildScrollView(
            key: ValueKey<String>('fushi_audiobook_scroll_$_tab'),
            primary: false,
            child: column,
          );
        },
      ),
    );
  }

  /// 「资源 / 章节 / 设置」标签栏：三等分铺满面板宽（与漫画阅读器设置 sheet 的
  /// 标签栏同形），图标 + 文案同行以保住 48dp 行高（上下叠放要 72dp，会把矮窗
  /// 的钉住判据再往上推）。长译文按比例缩小，不截断、不换行。
  Widget _buildTabBar(ThemeData theme) {
    Widget tab(String id, IconData icon, String label) => Tab(
          key: ValueKey<String>('fushi_audiobook_tab_button_$id'),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(icon, size: 18),
                const SizedBox(width: 6),
                Text(label),
              ],
            ),
          ),
        );
    return TabBar(
      controller: _tabController,
      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
      onTap: (int index) {
        final String id = kReaderAudiobookPanelTabs[index];
        if (id != _tab) setState(() => _tab = id);
      },
      tabs: <Widget>[
        for (final String id in kReaderAudiobookPanelTabs)
          switch (id) {
            'files' => tab(
                id,
                Icons.library_music_outlined,
                t.reader_audiobook_tab_files,
              ),
            'settings' => tab(id, Icons.tune_outlined, t.settings),
            _ => tab(
                id,
                Icons.format_list_bulleted,
                t.reader_audiobook_tab_chapters,
              ),
          },
      ],
    );
  }

  /// 顶部信息卡：左封面（有则显示），右书名 / 当前章 / 进度条 / 播放控制。
  Widget _buildHero(ThemeData theme, AudiobookPlayerController? ctrl) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String title = widget.title.trim();
    final String chapter = widget.chapterLabel?.trim() ?? '';
    final String? coverPath = widget.coverPath;
    final Widget details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (title.isNotEmpty)
          Text(
            title,
            style: theme.textTheme.titleSmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        if (chapter.isNotEmpty)
          Text(
            chapter,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
    final Widget? transport = ctrl != null
        ? _buildTransport(theme, ctrl)
        : widget.onAudioImport != null
            ? Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.headphones_outlined),
                  label: Text(t.audio_import),
                  onPressed: () {
                    Navigator.of(context).pop();
                    widget.onAudioImport!();
                  },
                ),
              )
            : null;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: tokens.radii.cardRadius,
      ),
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.gap * 1.5),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // Five transport buttons need their full touch targets. Move them
            // below the cover when the adjacent column cannot accommodate them.
            final bool stacked = coverPath != null &&
                constraints.maxWidth < 96 + tokens.spacing.gap * 1.5 + 248;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (coverPath != null) ...<Widget>[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.file(
                          File(coverPath),
                          key: const ValueKey<String>('fushi_audiobook_cover'),
                          width: 96,
                          height: 136,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              const SizedBox(width: 96, height: 136),
                        ),
                      ),
                      SizedBox(width: tokens.spacing.gap * 1.5),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          details,
                          if (!stacked && transport != null) ...<Widget>[
                            SizedBox(height: tokens.spacing.gap),
                            transport,
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                if (stacked && transport != null) ...<Widget>[
                  SizedBox(height: tokens.spacing.gap),
                  transport,
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  /// **全书**进度条（[AudiobookPlayerController.globalPosition] /
  /// [AudiobookPlayerController.totalDuration]，拖动经 `seekGlobalMs` 跨文件定位）
  /// + 两端时间 + 「-10s / 上一句 / 播放 / 下一句 / +10s」。
  Widget _buildTransport(ThemeData theme, AudiobookPlayerController ctrl) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (BuildContext context, _) {
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
        final TextStyle? timeStyle = theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                // 章节刻度画在 slider 自己的轨道上：刻度与拇指共用同一个
                // trackRect（左右内缩由 thumb / overlay 尺寸决定），任何内缩
                // 变化下刻度都与进度对齐。
                trackShape: ReaderAudiobookChapterTrackShape(
                  fractions: ticks,
                  tickColor: theme.colorScheme.onSurfaceVariant,
                ),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                key: const ValueKey<String>('fushi_audiobook_panel_slider'),
                value: value,
                // 拖动期间只更新本地目标（不发 seek），松手一次性 seek；落定前拇指
                // 留在目标处（见 _effectiveScrubMs）。
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
            Row(
              children: <Widget>[
                Text(_formatDuration(pos), style: timeStyle),
                const Spacer(),
                Text(_formatDuration(dur), style: timeStyle),
              ],
            ),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                IconButton(
                  tooltip: '-10s',
                  icon: const Icon(Icons.replay_10_outlined),
                  onPressed: () => unawaited(ctrl.seekRelative(-10)),
                ),
                IconButton(
                  tooltip: t.prev_sentence,
                  icon: const Icon(Icons.skip_previous_outlined),
                  onPressed: () => unawaited(ctrl.skipToPrevCue()),
                ),
                IconButton.filledTonal(
                  key: const ValueKey<String>('fushi_audiobook_panel_play'),
                  iconSize: 28,
                  tooltip: ctrl.isPlaying ? t.pause : t.play,
                  icon: Icon(
                    ctrl.isPlaying
                        ? Icons.pause_outlined
                        : Icons.play_arrow_outlined,
                  ),
                  onPressed: () => unawaited(ctrl.togglePlayPause()),
                ),
                IconButton(
                  tooltip: t.next_sentence,
                  icon: const Icon(Icons.skip_next_outlined),
                  onPressed: () => unawaited(ctrl.skipToNextCue()),
                ),
                IconButton(
                  tooltip: '+10s',
                  icon: const Icon(Icons.forward_10_outlined),
                  onPressed: () => unawaited(ctrl.seekRelative(10)),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  /// 「资源」tab：音频文件列表 + 对齐文件（当前文件名）+ 转录生成字幕 + 导入音频。
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
        if (files.isNotEmpty)
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
        if (files.isNotEmpty) SizedBox(height: tokens.spacing.gap),
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
      ],
    );
  }

  /// 「章节」tab：目录 + 该章首句在全书音频时间轴上的起点（控制器按章缓存）；当前
  /// 章加标注。点击先跳阅读器到该章，再把音频定位到该章首句（无 cue 的章只跳文字）。
  Widget _buildChaptersTab(ThemeData theme, AudiobookPlayerController? ctrl) {
    final int currentEntry = resolveCurrentTocEntry(
          widget.toc,
          widget.currentSection,
          widget.currentCharOffset,
        ) ??
        -1;
    final TextStyle? timeStyle = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    // 每章时长 = 下一有音频的章起点 − 本章起点；最后一章到全书末尾。
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

    return AdaptiveSettingsSection(
      children: <Widget>[
        for (int i = 0; i < widget.toc.length; i++)
          _chapterRow(
            entry: widget.toc[i],
            ctrl: ctrl,
            isCurrent: i == currentEntry,
            durationMs: durationFor(i),
            timeStyle: timeStyle,
          ),
      ],
    );
  }

  Widget _chapterRow({
    required TtuTocEntry entry,
    required AudiobookPlayerController? ctrl,
    required bool isCurrent,
    required int? durationMs,
    required TextStyle? timeStyle,
  }) {
    final int? startMs = ctrl?.sectionStartGlobalMs(entry.index);
    final String time = startMs == null
        ? '—'
        : _formatDuration(Duration(milliseconds: startMs));
    final String? duration = durationMs == null
        ? null
        : _formatDuration(Duration(milliseconds: durationMs));
    final String? subtitle = <String>[
      if (isCurrent) t.reader_audiobook_current_chapter,
      if (duration != null) duration,
    ].join(' · ').let((String s) => s.isEmpty ? null : s);
    return AdaptiveSettingsRow(
      title: entry.label,
      subtitle: subtitle,
      trailing: Text(time, style: timeStyle),
      onTap: () async {
        Navigator.of(context).pop();
        await widget.onJumpSection(entry.index, entry.fragment);
        final AudioCue? first = ctrl?.sectionFirstCue(entry.index);
        if (ctrl != null && first != null) {
          await ctrl.skipToCue(first);
        }
      },
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
