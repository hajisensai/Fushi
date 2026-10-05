/// 阅读器按钮布局的拖拽编辑器（设置 → 阅读 → 阅读界面）。泛型骨架
/// `ControlLayoutEditor` 管拖放状态机；这里只给阅读器的舞台几何（顶栏一行 /
/// 底栏一行，各左中右）、图标 / 文案与驳回提示。与视频页编辑器同一套手感。
library;

import 'package:flutter/material.dart';

import 'package:fushi/src/controls/control_layout.dart';
import 'package:fushi/src/controls/control_layout_editor.dart';
import 'package:fushi/src/reader/reader_control_layout.dart';
import 'package:fushi/utils.dart';

export 'package:fushi/src/controls/control_layout_editor.dart'
    show controlLayoutEditorHintStyle;

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
    case ReaderControlItem.studyTimer:
      return Icons.timer_outlined;
    case ReaderControlItem.title:
      return Icons.title;
    case ReaderControlItem.audiobook:
      return Icons.headphones_outlined;
    case ReaderControlItem.fullscreen:
      return Icons.fullscreen_rounded;
    case ReaderControlItem.toolbars:
      return Icons.web_asset_off_outlined;
    case ReaderControlItem.settings:
      return Icons.tune_outlined;
    case ReaderControlItem.audiobookPrev:
      return Icons.skip_previous_outlined;
    case ReaderControlItem.audiobookPlayPause:
      return Icons.play_arrow_outlined;
    case ReaderControlItem.audiobookNext:
      return Icons.skip_next_outlined;
    case ReaderControlItem.audiobookSeekBack:
      return Icons.replay_10_outlined;
    case ReaderControlItem.audiobookSeekForward:
      return Icons.forward_10_outlined;
    case ReaderControlItem.audiobookFollow:
      return Icons.link;
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
    case ReaderControlItem.studyTimer:
      return t.shortcut_action_reader_toggle_study_clock;
    case ReaderControlItem.title:
      return t.reader_control_title;
    case ReaderControlItem.audiobook:
      return t.section_audiobook;
    case ReaderControlItem.fullscreen:
      return t.shortcut_action_global_toggle_fullscreen;
    case ReaderControlItem.toolbars:
      return t.reader_toolbars_hide;
    case ReaderControlItem.settings:
      return t.reader_settings_section;
    case ReaderControlItem.audiobookPrev:
      return t.prev_sentence;
    case ReaderControlItem.audiobookPlayPause:
      return t.reader_control_item_play_pause;
    case ReaderControlItem.audiobookNext:
      return t.next_sentence;
    case ReaderControlItem.audiobookSeekBack:
      return t.reader_control_item_seek_back;
    case ReaderControlItem.audiobookSeekForward:
      return t.reader_control_item_seek_forward;
    case ReaderControlItem.audiobookFollow:
      return t.audiobook_follow_audio;
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
    case ReaderControlSlot.overflow:
      return t.reader_control_slot_overflow;
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
      paletteGroupOf: _paletteGroup,
      stageBuilder: _buildStage,
      iconOf: readerControlItemIcon,
      labelOf: readerControlItemLabel,
      slotLabelOf: readerControlSlotLabel,
      rejectionMessageOf: _rejectionMessage,
      keyPrefix: 'reader-control',
    );
  }

  /// 托盘分组：有声书相关的按钮单独一组，其余归「通用」。
  String _paletteGroup(ReaderControlItem item) {
    switch (item) {
      case ReaderControlItem.audiobook:
      case ReaderControlItem.audiobookPrev:
      case ReaderControlItem.audiobookPlayPause:
      case ReaderControlItem.audiobookNext:
      case ReaderControlItem.audiobookSeekBack:
      case ReaderControlItem.audiobookSeekForward:
      case ReaderControlItem.audiobookFollow:
        return t.section_audiobook;
      case ReaderControlItem.back:
      case ReaderControlItem.modeToggle:
      case ReaderControlItem.navigation:
      case ReaderControlItem.gallery:
      case ReaderControlItem.statistics:
      case ReaderControlItem.studyTimer:
      case ReaderControlItem.title:
      case ReaderControlItem.fullscreen:
      case ReaderControlItem.toolbars:
      case ReaderControlItem.settings:
        return t.settings_section_general;
    }
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

  /// 舞台：一张阅读器缩略画面——顶栏（左 / 中 / 右三区按真实位置排）、几行模拟
  /// 正文、底栏。窄窗整体等比缩小，栏内仍按左中右排（极窄时三区竖叠）。
  Widget _buildStage(
    BuildContext context,
    ControlSlotRegionBuilder<ReaderControlSlot> buildSlotRegion,
  ) {
    Widget bar(
      ReaderControlSlot left,
      ReaderControlSlot center,
      ReaderControlSlot right,
    ) =>
        ControlStageBar(
          start: buildSlotRegion(left, growToContent: true),
          center: buildSlotRegion(
            center,
            growToContent: true,
            alignment: WrapAlignment.center,
          ),
          end: buildSlotRegion(
            right,
            growToContent: true,
            alignment: WrapAlignment.end,
          ),
        );
    return ControlStagePanel(
      key: const ValueKey<String>('reader-control-editor-preview'),
      heightRatio: 0.62,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          bar(
            ReaderControlSlot.topLeft,
            ReaderControlSlot.topCenter,
            ReaderControlSlot.topRight,
          ),
          // 正文：几行模拟文字线，让「上 / 正文 / 下」一眼读出是书页。
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: ControlStageTextLines(),
          ),
          bar(
            ReaderControlSlot.bottomLeft,
            ReaderControlSlot.bottomCenter,
            ReaderControlSlot.bottomRight,
          ),
        ],
      ),
    );
  }
}
