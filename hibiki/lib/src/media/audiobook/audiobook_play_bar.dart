import 'package:flutter/material.dart';
import 'package:hibiki/src/media/audiobook/audiobook_bridge.dart';
import 'package:hibiki/src/media/audiobook/audiobook_controller.dart';

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
              tooltip: '上一句',
            ),
            IconButton.filledTonal(
              icon: Icon(
                controller.isPlaying ? Icons.pause : Icons.play_arrow,
              ),
              iconSize: 24,
              onPressed: controller.togglePlayPause,
              tooltip: controller.isPlaying ? '暂停' : '播放',
            ),
            IconButton(
              icon: const Icon(Icons.skip_next),
              iconSize: 22,
              onPressed: controller.skipToNextCue,
              tooltip: '下一句',
            ),
            const SizedBox(width: 4),
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
              tooltip: '有声书设置',
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
          tooltip: on ? 'Follow audio: ON（跨章自动跳转）' : 'Follow audio: OFF',
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
class AudiobookSettingsSheet extends StatelessWidget {
  const AudiobookSettingsSheet({
    required this.controller,
    required this.toc,
    required this.readerProgress,
    required this.onJumpSection,
    required this.onBookmark,
    required this.onToggleFullscreen,
    required this.onExitReader,
    super.key,
  });

  /// null 表示普通 EPUB 场景（没有 audiobook controller）—— 倍速 /
  /// 音画同步两节不渲染。
  final AudiobookPlayerController? controller;

  /// 章节列表。空列表表示 ttu 未就绪或 fork 无 `__ttuGetToc`。
  final List<TtuTocEntry> toc;

  /// (currentSection0, totalSections)；未 probe 时 null。
  final (int section, int total)? readerProgress;

  /// 点 TOC 里某一章 → 触发跳转。参数是 ttu sectionIndex（0-based）。
  final Future<void> Function(int sectionIndex) onJumpSection;

  /// 点"添加书签" → 触发 ttu 内部的 `bookmarkPage()`。
  final Future<void> Function() onBookmark;

  /// 点"全屏切换" → reader 页面侧在 immersive / edgeToEdge 间翻。
  final VoidCallback onToggleFullscreen;

  /// 点"退出阅读" → reader 页面侧 Navigator.pop。
  final VoidCallback onExitReader;

  static const List<double> _speeds = [0.75, 1.0, 1.25, 1.5];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildProgressSection(theme),
                if (toc.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _buildTocSection(context, theme),
                ],
                if (controller != null) ...[
                  const SizedBox(height: 20),
                  _buildSpeedSection(theme, controller!),
                  const SizedBox(height: 20),
                  _buildDelaySection(theme, controller!),
                ],
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
    final (int section, int total)? prog = readerProgress;
    final String label;
    if (prog == null || prog.$2 <= 0) {
      label = '—';
    } else {
      final int idx1 = prog.$1 + 1;
      final int total = prog.$2;
      final int pct = (idx1 / total * 100).clamp(0, 100).round();
      // 能从 TOC 里拿到章节名就带上，便于用户定位
      final String? title = toc
          .where((TtuTocEntry e) => e.index == prog.$1)
          .map((TtuTocEntry e) => e.label)
          .firstOrNull;
      final String suffix = title != null && title.isNotEmpty ? '（$title）' : '';
      label = '第 $idx1 / $total 章$suffix · $pct%';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('阅读进度', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(label, style: theme.textTheme.bodyLarge),
      ],
    );
  }

  Widget _buildTocSection(BuildContext context, ThemeData theme) {
    final int? currentIdx = readerProgress?.$1;
    return Theme(
      // 去掉 ExpansionTile 外框的 divider
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: Text(
          '章节列表（${toc.length}）',
          style: theme.textTheme.titleMedium,
        ),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: toc.length,
              itemBuilder: (BuildContext ctx, int i) {
                final TtuTocEntry e = toc[i];
                final bool isCurrent = currentIdx == e.index;
                final bool isChild = e.parent != null;
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.only(
                    left: isChild ? 24 : 0,
                    right: 8,
                  ),
                  title: Text(
                    e.label.isEmpty ? '（无标题）' : e.label,
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
                    await onJumpSection(e.index);
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
        Text('倍速', style: theme.textTheme.titleMedium),
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
            Text('音画同步', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '正数 = 音频先于文字，向回拨 cue；负数 = 音频滞后。',
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
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: ms == 0 ? null : () => ctrl.setDelayMs(0),
                icon: const Icon(Icons.restart_alt, size: 18),
                label: const Text('归零'),
              ),
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

  Widget _buildActionRow(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _actionBtn(
          context,
          icon: Icons.bookmark_add_outlined,
          label: '书签',
          onTap: () async {
            Navigator.of(context).pop();
            await onBookmark();
          },
        ),
        _actionBtn(
          context,
          icon: Icons.fullscreen,
          label: '全屏切换',
          onTap: () {
            Navigator.of(context).pop();
            onToggleFullscreen();
          },
        ),
        _actionBtn(
          context,
          icon: Icons.exit_to_app,
          label: '退出',
          onTap: () {
            Navigator.of(context).pop();
            onExitReader();
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
