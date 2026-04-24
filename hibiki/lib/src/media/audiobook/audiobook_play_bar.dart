import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/src/media/audiobook/audiobook_bridge.dart';
import 'package:hibiki/src/media/audiobook/audiobook_controller.dart';
import 'package:hibiki/src/media/sources/reader_ttu_source.dart';
import 'package:hibiki/utils.dart';

/// 有声书播放控制条（紧凑型，固定于阅读器底部）。
///
/// Row 只放最常用的实时控件：⏮ ⏯ ⏭、当前 cue、Follow 磁铁、设置齿轮。
/// 倍速 / 音画同步 / 阅读进度 / 章节列表 / 添加书签 / 全屏 / 退出 放进
/// [onOpenSettings] 回调展开的底部设置面板 —— ttu 原生顶部工具栏被隐藏
/// 后这些功能的统一入口。
class AudiobookPlayBar extends StatelessWidget {
  const AudiobookPlayBar({
    required this.controller,
    required this.onOpenSettings,
    super.key,
  });

  final AudiobookPlayerController controller;

  /// 用户点 ⚙ 设置按钮后触发。由 reader 页面侧注入，因为设置面板要
  /// 访问 WebView controller 才能 probe ttu 当前章节 / TOC、触发书签。
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: BottomAppBar(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.skip_previous),
              iconSize: 22,
              onPressed: controller.skipToPrevCue,
              tooltip: t.prev_sentence,
            ),
            IconButton.filledTonal(
              icon: Icon(
                controller.isPlaying ? Icons.pause : Icons.play_arrow,
              ),
              iconSize: 24,
              onPressed: controller.togglePlayPause,
              tooltip: controller.isPlaying ? t.pause : t.play,
            ),
            IconButton(
              icon: const Icon(Icons.skip_next),
              iconSize: 22,
              onPressed: controller.skipToNextCue,
              tooltip: t.next_sentence,
            ),
            const SizedBox(width: 4),
            // 字幕句号进度指示器（当前句 / 总句数）
            if (controller.chapterCueCount > 0)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  '${controller.currentCueIdx >= 0 ? controller.currentCueIdx + 1 : '-'}/${controller.chapterCueCount}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            Expanded(
              child: Text(
                controller.currentCue?.text ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            AudiobookFollowAudioButton(controller: controller),
            IconButton(
              icon: const Icon(Icons.tune),
              iconSize: 20,
              onPressed: onOpenSettings,
              tooltip: t.audiobook_settings,
            ),
          ],
        ),
      ),
    );
  }
}

/// Follow audio 开关按钮（磁铁图标；PR8b）。
///
/// 独立于 [AudiobookPlayBar] 的 [ListenableBuilder] 订阅 —— 按钮只随
/// [AudiobookPlayerController.followAudio] 变化重绘，避免每次 cue 更新
/// 整条 play bar 都跟着刷新时这颗按钮也 rebuild。点击 toggle 并持久化
/// （controller 侧内部调 onCrossChapter 用户传入的 persist 回调）。
class AudiobookFollowAudioButton extends StatelessWidget {
  const AudiobookFollowAudioButton({required this.controller, super.key});

  final AudiobookPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: controller.followAudio,
      builder: (BuildContext context, bool on, _) {
        final ColorScheme colors = Theme.of(context).colorScheme;
        return IconButton(
          icon: Icon(on ? Icons.link : Icons.link_off),
          iconSize: 20,
          color: on ? colors.primary : colors.onSurfaceVariant,
          tooltip: on ? t.follow_audio_on_tooltip : t.follow_audio_off_tooltip,
          onPressed: () {
            // persist 回调在 reader 页面把 controller 和 repo 绑上；这里
            // 只翻内存状态，controller.setFollowAudio 内部会用绑好的回调
            // 落库，按钮自己不碰 Isar。
            controller.setFollowAudio(!on);
          },
        );
      },
    );
  }
}

/// Reader 设置面板 —— ttu 原生顶部工具栏被隐藏后的统一入口。
///
/// 两种召唤场景：
/// 1. 有声书模式：播放栏的 ⚙ 打开，[controller] 非空，显示全部 —— 阅读
///    进度 + TOC + 倍速 + 音画同步 + action row
/// 2. 普通 EPUB：左下角 ⚙ FAB 打开，[controller] 为 null，省略倍速 /
///    音画同步两节，只显示阅读进度 + TOC + action row
///
/// 类名保留 `Audiobook*` 前缀因为控件和 audiobook 播放栏在同一文件里；
/// 语义上它已经是 reader-level 的设置面板。
///
/// [toc] / [readerProgress] 是 reader 页面 probe 后一次性传入的快照。
/// 面板生存期内不自动刷新（TOC 在一次阅读会话里是静态的；当前章节
/// 会随 follow audio 滚动变，但打开面板的当下已经 probe 了一次）。
class AudiobookSettingsSheet extends StatefulWidget {
  AudiobookSettingsSheet({
    required this.controller,
    required this.toc,
    required this.readerProgress,
    this.pageProgress,
    required this.onJumpSection,
    required this.onBookmark,
    required this.onToggleFullscreen,
    required this.onExitReader,
    required this.webViewController,
    super.key,
  });

  final AudiobookPlayerController? controller;
  final List<TtuTocEntry> toc;
  final (int section, int total)? readerProgress;
  final (int current, int total)? pageProgress;
  final Future<void> Function(int sectionIndex) onJumpSection;
  final Future<void> Function() onBookmark;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onExitReader;
  final InAppWebViewController webViewController;

  @override
  State<AudiobookSettingsSheet> createState() => _AudiobookSettingsSheetState();
}

class _AudiobookSettingsSheetState extends State<AudiobookSettingsSheet> {
  static const List<double> _speeds = [0.75, 1.0, 1.25, 1.5];

  TtuReaderSettings? _settings;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final TtuReaderSettings s =
        await AudiobookBridge.getReaderSettings(widget.webViewController);
    if (mounted) setState(() => _settings = s);
  }

  Future<void> _updateSetting(String key, Object value) async {
    await AudiobookBridge.setReaderSetting(
      widget.webViewController,
      key: key,
      value: value,
    );
    final ReaderTtuSource src = ReaderTtuSource.instance;
    switch (key) {
      case 'fontSize':
        await src.setTtuFontSize((value as num).toDouble());
      case 'lineHeight':
        await src.setTtuLineHeight((value as num).toDouble());
      case 'writingMode':
        await src.setTtuWritingMode(value as String);
      case 'viewMode':
        await src.setTtuViewMode(value as String);
      case 'theme':
        await src.setTtuTheme(value as String);
      case 'hideFurigana':
        await src.setTtuHideFurigana(value as bool);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.80,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildProgressSection(theme),
                if (widget.toc.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _buildTocSection(context, theme),
                ],
                if (widget.controller != null) ...[
                  const SizedBox(height: 20),
                  _buildSpeedSection(theme, widget.controller!),
                  const SizedBox(height: 20),
                  _buildDelaySection(theme, widget.controller!),
                ],
                const SizedBox(height: 20),
                _buildReaderSettingsSection(theme),
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 12),
                _buildActionRow(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProgressSection(ThemeData theme) {
    final (int section, int total)? prog = widget.readerProgress;
    final String chapterLabel;
    if (prog == null || prog.$2 <= 0) {
      chapterLabel = '—';
    } else {
      final int idx1 = prog.$1 + 1;
      final int total = prog.$2;
      final int pct = (idx1 / total * 100).clamp(0, 100).round();
      final String? title = widget.toc
          .where((TtuTocEntry e) => e.index == prog.$1)
          .map((TtuTocEntry e) => e.label)
          .firstOrNull;
      final String suffix = title != null && title.isNotEmpty ? '（$title）' : '';
      chapterLabel = t.chapter_progress(idx: idx1, total: total, suffix: suffix, pct: pct);
    }
    final String pageLabel;
    final (int current, int total)? pp = widget.pageProgress;
    if (pp != null && pp.$2 > 0) {
      pageLabel = t.page_progress(current: pp.$1, total: pp.$2);
    } else {
      pageLabel = '';
    }
    // 字幕句子进度
    final String cueLabel;
    final AudiobookPlayerController? ctrl = widget.controller;
    if (ctrl != null && ctrl.chapterCueCount > 0) {
      final int idx1 = ctrl.currentCueIdx >= 0 ? ctrl.currentCueIdx + 1 : 0;
      cueLabel = t.cue_progress(current: idx1, total: ctrl.chapterCueCount);
    } else {
      cueLabel = '';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.reading_progress, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(chapterLabel, style: theme.textTheme.bodyLarge),
        if (pageLabel.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(pageLabel, style: theme.textTheme.bodyMedium),
        ],
        if (cueLabel.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(cueLabel, style: theme.textTheme.bodyMedium),
        ],
      ],
    );
  }

  Widget _buildTocSection(BuildContext context, ThemeData theme) {
    final int? currentIdx = widget.readerProgress?.$1;
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: Text(
          t.toc_section(n: widget.toc.length),
          style: theme.textTheme.titleMedium,
        ),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: widget.toc.length,
              itemBuilder: (BuildContext ctx, int i) {
                final TtuTocEntry e = widget.toc[i];
                final bool isCurrent = currentIdx == e.index;
                final bool isChild = e.parent != null;
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.only(
                    left: isChild ? 24 : 0,
                    right: 8,
                  ),
                  title: Text(
                    e.label.isEmpty ? t.untitled_chapter : e.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: isCurrent
                        ? theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          )
                        : theme.textTheme.bodyMedium,
                  ),
                  trailing: isCurrent
                      ? Icon(Icons.chevron_right,
                          color: theme.colorScheme.primary, size: 20)
                      : null,
                  onTap: () async {
                    Navigator.of(ctx).pop();
                    await widget.onJumpSection(e.index);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSpeedSection(ThemeData theme, AudiobookPlayerController ctrl) {
    final double current = ctrl.speed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.playback_speed, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: _speeds.map((double s) {
            final bool selected = (s - current).abs() < 0.01;
            return ChoiceChip(
              label: Text('${s.toStringAsFixed(2)}x'),
              selected: selected,
              onSelected: (bool on) {
                if (on) ctrl.setSpeed(s);
              },
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildDelaySection(ThemeData theme, AudiobookPlayerController ctrl) {
    return ValueListenableBuilder<int>(
      valueListenable: ctrl.delayMs,
      builder: (BuildContext ctx, int ms, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(t.av_sync, style: theme.textTheme.titleMedium),
                const SizedBox(width: 4),
                TextButton.icon(
                  onPressed: ms == 0 ? null : () => ctrl.setDelayMs(0),
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: Text(t.av_sync_reset),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              t.av_sync_hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(
                '${ms > 0 ? '+' : ''}$ms ms',
                style: theme.textTheme.headlineSmall,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _stepBtn(ctrl, '-1s', -1000),
                _stepBtn(ctrl, '-200', -200),
                _stepBtn(ctrl, '-50', -50),
                _stepBtn(ctrl, '+50', 50),
                _stepBtn(ctrl, '+200', 200),
                _stepBtn(ctrl, '+1s', 1000),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _stepBtn(AudiobookPlayerController ctrl, String label, int delta) {
    return FilledButton.tonal(
      onPressed: () {
        ctrl.setDelayMs(ctrl.delayMs.value + delta);
      },
      style: FilledButton.styleFrom(
        minimumSize: const Size(52, 40),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        visualDensity: VisualDensity.compact,
      ),
      child: Text(label),
    );
  }

  Widget _buildReaderSettingsSection(ThemeData theme) {
    final TtuReaderSettings? s = _settings;
    if (s == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: SizedBox(
            width: 20, height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.reader_settings_section, style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),
        // 字体大小
        _settingRow(
          theme,
          label: t.ttu_font_size,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.remove, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  final double v = (s.fontSize - 1).clamp(8, 64);
                  s.fontSize = v;
                  setState(() {});
                  _updateSetting('fontSize', v);
                },
              ),
              SizedBox(
                width: 36,
                child: Text(
                  '${s.fontSize.round()}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  final double v = (s.fontSize + 1).clamp(8, 64);
                  s.fontSize = v;
                  setState(() {});
                  _updateSetting('fontSize', v);
                },
              ),
            ],
          ),
        ),
        // 行高
        _settingRow(
          theme,
          label: t.ttu_line_height,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.remove, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  final double v =
                      ((s.lineHeight - 0.1) * 100).roundToDouble() / 100;
                  s.lineHeight = v.clamp(1.0, 3.0);
                  setState(() {});
                  _updateSetting('lineHeight', s.lineHeight);
                },
              ),
              SizedBox(
                width: 42,
                child: Text(
                  s.lineHeight.toStringAsFixed(2),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  final double v =
                      ((s.lineHeight + 0.1) * 100).roundToDouble() / 100;
                  s.lineHeight = v.clamp(1.0, 3.0);
                  setState(() {});
                  _updateSetting('lineHeight', s.lineHeight);
                },
              ),
            ],
          ),
        ),
        // 排版方向
        _settingRow(
          theme,
          label: t.ttu_writing_direction,
          child: SegmentedButton<String>(
            segments: <ButtonSegment<String>>[
              ButtonSegment<String>(value: 'horizontal-tb', label: Text(t.ttu_horizontal)),
              ButtonSegment<String>(value: 'vertical-rl', label: Text(t.ttu_vertical)),
            ],
            selected: <String>{s.writingMode},
            onSelectionChanged: (Set<String> sel) {
              s.writingMode = sel.first;
              setState(() {});
              _updateSetting('writingMode', sel.first);
            },
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
        // 视图模式
        _settingRow(
          theme,
          label: t.ttu_view_mode_label,
          child: SegmentedButton<String>(
            segments: <ButtonSegment<String>>[
              ButtonSegment<String>(value: 'paginated', label: Text(t.ttu_paginated)),
              ButtonSegment<String>(value: 'continuous', label: Text(t.ttu_scroll)),
            ],
            selected: <String>{s.viewMode},
            onSelectionChanged: (Set<String> sel) {
              s.viewMode = sel.first;
              setState(() {});
              _updateSetting('viewMode', sel.first);
            },
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
        // 主题
        const SizedBox(height: 8),
        Text(t.ttu_theme, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: TtuReaderSettings.availableThemes.map((String t) {
            final bool selected = s.theme == t;
            return ChoiceChip(
              label: Text(TtuReaderSettings.themeLabels[t] ?? t),
              selected: selected,
              onSelected: (bool on) {
                if (!on) return;
                s.theme = t;
                setState(() {});
                _updateSetting('theme', t);
              },
            );
          }).toList(),
        ),
        // 隐藏假名
        const SizedBox(height: 8),
        _settingRow(
          theme,
          label: t.ttu_hide_furigana,
          child: Switch(
            value: s.hideFurigana,
            onChanged: (bool v) {
              s.hideFurigana = v;
              setState(() {});
              _updateSetting('hideFurigana', v);
            },
          ),
        ),
      ],
    );
  }

  Widget _settingRow(ThemeData theme,
      {required String label, required Widget child}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          child,
        ],
      ),
    );
  }

  Widget _buildActionRow(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _actionBtn(
          context,
          icon: Icons.bookmark_add_outlined,
          label: t.action_bookmark,
          onTap: () async {
            Navigator.of(context).pop();
            await widget.onBookmark();
          },
        ),
        _actionBtn(
          context,
          icon: Icons.fullscreen,
          label: t.action_fullscreen_toggle,
          onTap: () {
            Navigator.of(context).pop();
            widget.onToggleFullscreen();
          },
        ),
        _actionBtn(
          context,
          icon: Icons.exit_to_app,
          label: t.action_exit,
          onTap: () {
            Navigator.of(context).pop();
            widget.onExitReader();
          },
        ),
      ],
    );
  }

  Widget _actionBtn(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 26, color: theme.colorScheme.onSurface),
            const SizedBox(height: 6),
            Text(label, style: theme.textTheme.labelMedium),
          ],
        ),
      ),
    );
  }
}
