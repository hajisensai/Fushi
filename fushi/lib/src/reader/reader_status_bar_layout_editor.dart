import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/controls/control_layout.dart';
import 'package:fushi/src/controls/control_layout_editor.dart';
import 'package:fushi/src/reader/reader_status_bar_layout.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 读数在编辑器 chip / 托盘里的图标。
IconData readerStatusBarItemIcon(ReaderStatusBarItem item) => switch (item) {
  ReaderStatusBarItem.clock => FushiIcons.schedule,
  ReaderStatusBarItem.battery => FushiIcons.flash,
  ReaderStatusBarItem.chapterTitle => FushiIcons.toc,
  ReaderStatusBarItem.bookTitle => FushiIcons.books,
  ReaderStatusBarItem.chapterPage => FushiIcons.numberedList,
  ReaderStatusBarItem.chapterProgress => FushiIcons.viewAgenda,
  ReaderStatusBarItem.chapterChars => FushiIcons.textFields,
  ReaderStatusBarItem.bookProgress => FushiIcons.dataUsage,
  ReaderStatusBarItem.bookChars => FushiIcons.title,
};

/// 读数的显示名（托盘、chip、无障碍标签共用）。
String readerStatusBarItemLabel(ReaderStatusBarItem item) => switch (item) {
  ReaderStatusBarItem.clock => t.reader_status_bar_item_clock,
  ReaderStatusBarItem.battery => t.reader_status_bar_item_battery,
  ReaderStatusBarItem.chapterTitle => t.reader_status_bar_item_chapter_title,
  ReaderStatusBarItem.bookTitle => t.reader_status_bar_item_book_title,
  ReaderStatusBarItem.chapterPage => t.reader_status_bar_item_chapter_page,
  ReaderStatusBarItem.chapterProgress =>
    t.reader_status_bar_item_chapter_progress,
  ReaderStatusBarItem.chapterChars => t.reader_status_bar_item_chapter_chars,
  ReaderStatusBarItem.bookProgress => t.reader_status_bar_item_book_progress,
  ReaderStatusBarItem.bookChars => t.reader_status_bar_item_book_chars,
};

String readerStatusBarSlotLabel(ReaderStatusBarSlot slot) => switch (slot) {
  ReaderStatusBarSlot.headerLeft => t.reader_status_bar_slot_header_left,
  ReaderStatusBarSlot.headerCenter => t.reader_status_bar_slot_header_center,
  ReaderStatusBarSlot.headerRight => t.reader_status_bar_slot_header_right,
  ReaderStatusBarSlot.footerLeft => t.reader_status_bar_slot_footer_left,
  ReaderStatusBarSlot.footerCenter => t.reader_status_bar_slot_footer_center,
  ReaderStatusBarSlot.footerRight => t.reader_status_bar_slot_footer_right,
  ReaderStatusBarSlot.hidden => t.reader_status_bar_slot_hidden,
};

/// 页眉 / 页脚拖放编辑器：与阅读器 / 视频工具栏同一个泛型 [ControlLayoutEditor]
/// （拖放、键盘 / 手柄搬运、两套设计系统的放置区与动效都在那边），这里只提供
/// 舞台几何——上方页眉一条、中间几行正文、下方页脚一条，各分左 / 中 / 右。
class ReaderStatusBarLayoutEditor extends StatelessWidget {
  const ReaderStatusBarLayoutEditor({
    super.key,
    required this.layout,
    required this.onLayoutChanged,
  });

  final ReaderStatusBarLayout layout;
  final ValueChanged<ReaderStatusBarLayout> onLayoutChanged;

  @override
  Widget build(BuildContext context) {
    return ControlLayoutEditor<ReaderStatusBarSlot, ReaderStatusBarItem>(
      layout: layout.core,
      onLayoutChanged:
          (ControlLayout<ReaderStatusBarSlot, ReaderStatusBarItem> next) =>
              onLayoutChanged(ReaderStatusBarLayout.fromCore(next)),
      isTouchControls: false,
      paletteItems: ReaderStatusBarItem.values,
      paletteTitle: t.reader_status_bar_palette_title,
      stageBuilder: _buildStage,
      iconOf: readerStatusBarItemIcon,
      labelOf: readerStatusBarItemLabel,
      slotLabelOf: readerStatusBarSlotLabel,
      rejectionMessageOf: (ReaderStatusBarItem item, ReaderStatusBarSlot to) =>
          null,
      slotOrder: ReaderStatusBarSlot.values,
      keyPrefix: 'reader-status-bar',
    );
  }

  Widget _buildStage(
    BuildContext context,
    ControlSlotRegionBuilder<ReaderStatusBarSlot> buildSlotRegion,
  ) {
    Widget bar(List<ReaderStatusBarSlot> slots) => ControlStageBar(
      start: buildSlotRegion(slots[0], growToContent: true),
      center: buildSlotRegion(
        slots[1],
        growToContent: true,
        alignment: WrapAlignment.center,
      ),
      end: buildSlotRegion(
        slots[2],
        growToContent: true,
        alignment: WrapAlignment.end,
      ),
    );
    return ControlStagePanel(
      key: const ValueKey<String>('reader-status-bar-editor-preview'),
      heightRatio: 0.62,
      minHeight: 240,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          bar(ReaderStatusBarSlot.headerSlots),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: ControlStageTextLines(),
          ),
          bar(ReaderStatusBarSlot.footerSlots),
        ],
      ),
    );
  }
}
