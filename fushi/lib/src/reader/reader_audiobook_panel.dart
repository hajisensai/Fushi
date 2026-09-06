/// 有声书居中面板（Niratan「Sasayaki」形态），从 ReaderQuickSettingsSheet 抽出成
/// 独立组件：封面 + 书名 + 当前章 + **全书**进度条 + 播放控制，下接「资源 / 章节 /
/// 设置」分段，底部全宽「关闭」。设置页内容由调用方经 [settingsBuilder] 提供
/// （音量 / 速度 / 延迟等行仍由设置 sheet 持有其写路径）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/audiobook_bridge.dart'
    show TtuTocEntry;
import 'package:fushi/utils.dart';

class ReaderAudiobookPanel extends StatefulWidget {
  const ReaderAudiobookPanel({
    super.key,
    required this.controller,
    required this.toc,
    required this.currentSection,
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
  final Future<void> Function(int sectionIndex) onJumpSection;
  final String title;
  final String? chapterLabel;

  /// 书籍封面文件路径；null 不显示。
  final String? coverPath;

  /// 「设置」tab 的内容（音量 / 速度 / 延迟 / 播放条开关…）。
  final WidgetBuilder settingsBuilder;

  final VoidCallback? onAudioImport;
  final VoidCallback? onPickAlignment;
  final VoidCallback? onTranscribe;

  /// files / chapters / settings。
  final String initialTab;

  /// 进度条刷新周期（控制器只在 cue 切换 / 播放暂停时 notify，拖动条需要秒级 tick）。
  final Duration tick;

  @override
  State<ReaderAudiobookPanel> createState() => _ReaderAudiobookPanelState();
}

class _ReaderAudiobookPanelState extends State<ReaderAudiobookPanel> {
  late String _tab = widget.initialTab;
  Timer? _ticker;

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
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  static String _formatDuration(Duration d) => FushiTimeFormat.clockPadded(d);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final AudiobookPlayerController? ctrl = widget.controller;
    final List<ButtonSegment<String>> segments = <ButtonSegment<String>>[
      ButtonSegment<String>(
        value: 'files',
        label: Text(t.reader_audiobook_tab_files),
      ),
      ButtonSegment<String>(
        value: 'chapters',
        label: Text(t.reader_audiobook_tab_chapters),
      ),
      ButtonSegment<String>(value: 'settings', label: Text(t.settings)),
    ];
    final Widget tabContent = switch (_tab) {
      'files' => _buildFilesTab(theme, ctrl),
      'settings' => widget.settingsBuilder(context),
      _ => _buildChaptersTab(theme, ctrl),
    };
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.page,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
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
          SizedBox(height: tokens.spacing.gap * 1.5),
          FushiSegmentedStrip<String>(
            segments: segments,
            selected: _tab,
            alignment: Alignment.center,
            onChanged: (String id) => setState(() => _tab = id),
          ),
          SizedBox(height: tokens.spacing.gap),
          Flexible(
            child: SingleChildScrollView(
              child: KeyedSubtree(
                key: ValueKey<String>('fushi_audiobook_tab_$_tab'),
                child: tabContent,
              ),
            ),
          ),
          SizedBox(height: tokens.spacing.gap * 1.5),
          Semantics(
            identifier: 'hibiki.reader.audiobook_panel.close',
            child: FilledButton(
              key: const ValueKey<String>('fushi_audiobook_panel_close_button'),
              onPressed: () => Navigator.of(context).maybePop(),
              child: Text(MaterialLocalizations.of(context).closeButtonLabel),
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部信息卡：左封面（有则显示），右书名 / 当前章 / 进度条 / 播放控制。
  Widget _buildHero(ThemeData theme, AudiobookPlayerController? ctrl) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String title = widget.title.trim();
    final String chapter = widget.chapterLabel?.trim() ?? '';
    final String? coverPath = widget.coverPath;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: tokens.radii.cardRadius,
      ),
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.gap * 1.5),
        child: Row(
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
                  SizedBox(height: tokens.spacing.gap),
                  if (ctrl != null)
                    _buildTransport(theme, ctrl)
                  else if (widget.onAudioImport != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.tonalIcon(
                        icon: const Icon(Icons.headphones_outlined),
                        label: Text(t.audio_import),
                        onPressed: () {
                          Navigator.of(context).pop();
                          widget.onAudioImport!();
                        },
                      ),
                    ),
                ],
              ),
            ),
          ],
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
            // 章节刻度：每章首句在全书时间轴上的位置（控制器按章缓存）。
            if (ticks.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: SizedBox(
                  height: 4,
                  child: CustomPaint(
                    key:
                        const ValueKey<String>('fushi_audiobook_chapter_ticks'),
                    painter: _ChapterTickPainter(
                      fractions: ticks,
                      color: theme.colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.6),
                    ),
                  ),
                ),
              ),
            Row(
              children: <Widget>[
                Text(_formatDuration(pos), style: timeStyle),
                const Spacer(),
                Text(_formatDuration(dur), style: timeStyle),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
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
    final int currentSection = widget.currentSection ?? -1;
    int currentEntry = -1;
    for (int i = 0; i < widget.toc.length; i++) {
      if (widget.toc[i].index <= currentSection) currentEntry = i;
    }
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
        await widget.onJumpSection(entry.index);
        final AudioCue? first = ctrl?.sectionFirstCue(entry.index);
        if (ctrl != null && first != null) {
          await ctrl.skipToCue(first);
        }
      },
    );
  }
}

/// 进度条下方的章节刻度（每章首句位置的竖线）。
class _ChapterTickPainter extends CustomPainter {
  const _ChapterTickPainter({required this.fractions, required this.color});

  final List<double> fractions;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (final double f in fractions) {
      final double x = f * size.width;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ChapterTickPainter old) =>
      old.color != color || old.fractions != fractions;
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
