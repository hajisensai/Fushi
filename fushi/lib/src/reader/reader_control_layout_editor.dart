/// 阅读器按钮布局的拖拽编辑器（设置 → 阅读 → 阅读界面）。泛型骨架
/// `ControlLayoutEditor` 管拖放状态机；这里只给阅读器的舞台几何（顶栏一行 /
/// 底栏一行，各左中右）、图标 / 文案与驳回提示。与视频页编辑器同一套手感。
library;

import 'package:flutter/material.dart';

import 'package:fushi/src/controls/control_layout.dart';
import 'package:fushi/src/controls/control_layout_editor.dart';
import 'package:fushi/src/reader/reader_control_layout.dart';
import 'package:fushi/utils.dart';

/// 阅读器按钮图标：与顶栏渲染同一张表（`chrome.part.dart` 的 `_readerControlIcon`
/// 只是在这张表上按运行态换全屏 / 歌词两颗的图标）。
IconData readerControlItemIcon(ReaderControlItem item) {
  switch (item) {
    case ReaderControlItem.back:
      return Icons.arrow_back;
    case ReaderControlItem.modeToggle:
      return Icons.lyrics_outlined;
    case ReaderControlItem.navigation:
      return Icons.format_list_bulleted;
    case ReaderControlItem.gallery:
      return Icons.collections_outlined;
    case ReaderControlItem.statistics:
      return Icons.insights_outlined;
    case ReaderControlItem.title:
      return Icons.title;
    case ReaderControlItem.audiobook:
      return Icons.headphones_outlined;
    case ReaderControlItem.fullscreen:
      return Icons.fullscreen_rounded;
    case ReaderControlItem.settings:
      return Icons.tune_outlined;
  }
}

String readerControlItemLabel(ReaderControlItem item) {
  switch (item) {
    case ReaderControlItem.back:
      return t.back;
    case ReaderControlItem.modeToggle:
      return t.lyrics_mode;
    case ReaderControlItem.navigation:
      return t.section_navigation;
    case ReaderControlItem.gallery:
      return t.reader_gallery_tooltip;
    case ReaderControlItem.statistics:
      return t.reading_statistics;
    case ReaderControlItem.title:
      return t.reader_control_title;
    case ReaderControlItem.audiobook:
      return t.section_audiobook;
    case ReaderControlItem.fullscreen:
      return t.shortcut_action_global_toggle_fullscreen;
    case ReaderControlItem.settings:
      return t.reader_settings_section;
  }
}

String readerControlSlotLabel(ReaderControlSlot slot) {
  switch (slot) {
    case ReaderControlSlot.topLeft:
      return t.video_control_slot_top_left;
    case ReaderControlSlot.topCenter:
      return t.video_control_slot_top_center;
    case ReaderControlSlot.topRight:
      return t.video_control_slot_top_right;
    case ReaderControlSlot.bottomLeft:
      return t.video_control_slot_bottom_left;
    case ReaderControlSlot.bottomCenter:
      return t.video_control_slot_bottom_center;
    case ReaderControlSlot.bottomRight:
      return t.video_control_slot_bottom_right;
    case ReaderControlSlot.hidden:
      return t.reader_control_slot_hidden;
  }
}

class ReaderControlLayoutEditor extends StatelessWidget {
  const ReaderControlLayoutEditor({
    super.key,
    required this.layout,
    required this.onLayoutChanged,
    required this.isTouchControls,
  });

  final ReaderControlLayout layout;
  final Future<void> Function(ReaderControlLayout layout)? onLayoutChanged;
  final bool isTouchControls;

  @override
  Widget build(BuildContext context) {
    final Future<void> Function(ReaderControlLayout)? changed = onLayoutChanged;
    return ControlLayoutEditor<ReaderControlSlot, ReaderControlItem>(
      layout: layout.core,
      onLayoutChanged: changed == null
          ? null
          : (ControlLayout<ReaderControlSlot, ReaderControlItem> next) =>
              changed(ReaderControlLayout.fromCore(next)),
      isTouchControls: isTouchControls,
      paletteItems: ReaderControlItem.values,
      paletteTitle: t.video_control_palette_title,
      stageBuilder: _buildStage,
      iconOf: readerControlItemIcon,
      labelOf: readerControlItemLabel,
      slotLabelOf: readerControlSlotLabel,
      rejectionMessageOf: _rejectionMessage,
      keyPrefix: 'reader-control',
    );
  }

  String? _rejectionMessage(ReaderControlItem item, ReaderControlSlot target) {
    if (item.pinnedRequired && target == ReaderControlSlot.hidden) {
      return t.reader_control_reject_required;
    }
    if (item == ReaderControlItem.title ||
        target == ReaderControlSlot.topCenter) {
      if (!item.canMoveToSlot(target)) return t.reader_control_reject_title;
    }
    if (!item.canMoveToSlot(target)) return t.video_control_reject_unavailable;
    return null;
  }

  /// 舞台：一张「阅读器」示意——顶栏一行、正文留白、底栏一行。窄窗每行折成
  /// 两列 Wrap。
  Widget _buildStage(
    BuildContext context,
    ControlSlotRegionBuilder<ReaderControlSlot> buildSlotRegion,
  ) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    Widget row(List<ReaderControlSlot> slots) => LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double gap = tokens.spacing.gap;
            final bool compact = constraints.maxWidth < 480;
            final double itemWidth = compact
                ? (constraints.maxWidth < 260
                    ? constraints.maxWidth
                    : (constraints.maxWidth - gap) / 2)
                : (constraints.maxWidth - gap * 2) / 3;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: <Widget>[
                for (final ReaderControlSlot slot in slots)
                  SizedBox(
                    width: itemWidth,
                    child: buildSlotRegion(slot, growToContent: true),
                  ),
              ],
            );
          },
        );
    return DecoratedBox(
      key: const ValueKey<String>('reader-control-editor-preview'),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: tokens.radii.controlRadius,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.gap),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            row(const <ReaderControlSlot>[
              ReaderControlSlot.topLeft,
              ReaderControlSlot.topCenter,
              ReaderControlSlot.topRight,
            ]),
            // 正文占位：让两行读出「上 / 下」的方位感。
            Padding(
              padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap),
              child: Center(
                child: Icon(
                  Icons.menu_book_outlined,
                  size: 28,
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
            row(const <ReaderControlSlot>[
              ReaderControlSlot.bottomLeft,
              ReaderControlSlot.bottomCenter,
              ReaderControlSlot.bottomRight,
            ]),
          ],
        ),
      ),
    );
  }
}
