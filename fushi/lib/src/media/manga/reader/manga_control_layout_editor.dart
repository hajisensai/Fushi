/// 漫画阅读器工具栏按钮布局的拖拽编辑器（设置 → 漫画 → 显示与缩放，以及阅读器
/// 「阅读设置」面板里的「工具栏布局」入口）。与小说阅读器的编辑器同一套手感：
/// 上方所见即所得预览，下方「顶栏 / 底部工具栏 / 更多菜单 / 隐藏」四区，每颗按钮是
/// 一枚胶囊 chip——触屏长按拖、桌面直接拖；键盘在 chip 上按 Enter 弹「移到…」菜单。
/// 写操作全部经 [ControlLayout.moveItem]（模型不变式在那里）。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/controls/control_layout.dart';
import 'package:fushi/src/controls/control_layout_editor.dart';
import 'package:fushi/src/media/manga/reader/manga_control_layout.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart'
    show ReaderSideSheet, ReaderSideSheetSide, showReaderSideSheet;
import 'package:fushi/src/reader/reader_panel_chrome_kit.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 漫画按钮的代表图标（编辑器 chip / 预览用，语义图标层 [FushiIcons]）。阅读器里的
/// 按钮按运行态换字形（阅读模式、翻页方向、全屏……），这里只取代表形。
IconData mangaControlItemIcon(MangaControlItem item) => switch (item) {
  MangaControlItem.chapters => FushiIcons.toc,
  MangaControlItem.pageGrid => FushiIcons.gridView,
  MangaControlItem.readingMode => FushiIcons.readingMode,
  MangaControlItem.spreadPreference => FushiIcons.viewColumn,
  MangaControlItem.direction => FushiIcons.swap,
  MangaControlItem.quickSettings => FushiIcons.filter,
  MangaControlItem.ocrBoxes => FushiIcons.visibility,
  MangaControlItem.ocrCancel => FushiIcons.stop,
  MangaControlItem.fullscreen => FushiIcons.fullscreen,
  MangaControlItem.bookmarks => FushiIcons.bookmark,
  MangaControlItem.settings => FushiIcons.settings,
  MangaControlItem.ocrVolume => FushiIcons.ocr,
  MangaControlItem.backToStart => FushiIcons.firstPage,
  MangaControlItem.ocrRerun => FushiIcons.refresh,
  MangaControlItem.hideChrome => FushiIcons.visibilityOff,
};

/// 漫画按钮的名称（编辑器 chip / 菜单 / 无障碍语义）。
String mangaControlItemLabel(MangaControlItem item) => switch (item) {
  MangaControlItem.chapters => t.manga_series_chapters_action,
  MangaControlItem.pageGrid => t.manga_reader_page_grid,
  MangaControlItem.readingMode => t.manga_mode_toggle,
  MangaControlItem.spreadPreference => t.manga_reader_control_item_spread,
  MangaControlItem.direction => t.manga_reading_direction,
  MangaControlItem.quickSettings => t.manga_reader_quick_settings,
  MangaControlItem.ocrBoxes => t.manga_ocr_boxes_toggle,
  MangaControlItem.ocrCancel => t.manga_reader_control_item_ocr_cancel,
  MangaControlItem.fullscreen => t.shortcut_action_global_toggle_fullscreen,
  MangaControlItem.bookmarks => t.manga_reader_bookmarks,
  MangaControlItem.settings => t.manga_reader_settings,
  MangaControlItem.ocrVolume => t.manga_reader_ocr_volume,
  MangaControlItem.backToStart => t.manga_reader_back_to_start,
  MangaControlItem.ocrRerun => t.manga_reader_ocr_rerun,
  MangaControlItem.hideChrome => t.manga_interface_hide,
};

String _zoneLabel(MangaControlSlot slot) => switch (slot) {
  MangaControlSlot.top => t.manga_reader_control_zone_top,
  MangaControlSlot.toolbar => t.reader_control_zone_bottom_toolbar,
  MangaControlSlot.overflow => t.reader_control_slot_overflow,
  MangaControlSlot.hidden => t.reader_control_zone_hidden,
};

String _zoneHint(MangaControlSlot slot) => switch (slot) {
  MangaControlSlot.top => t.manga_reader_control_zone_top_hint,
  MangaControlSlot.toolbar => t.manga_reader_control_zone_toolbar_hint,
  MangaControlSlot.overflow => t.reader_control_zone_overflow_hint,
  MangaControlSlot.hidden => t.reader_control_zone_hidden_hint,
};

IconData _zoneIcon(MangaControlSlot slot) => switch (slot) {
  MangaControlSlot.top => FushiIcons.alignTop,
  MangaControlSlot.toolbar => FushiIcons.alignBottom,
  MangaControlSlot.overflow => FushiIcons.moreHoriz,
  MangaControlSlot.hidden => FushiIcons.visibilityOff,
};

/// 驳回提示（null = 允许）。纯函数，编辑器与测试共用。
String? mangaControlRejectionMessage(
  MangaControlItem item,
  MangaControlSlot target,
) {
  if (item.pinnedRequired && target == MangaControlSlot.hidden) {
    return t.reader_control_reject_required;
  }
  if (!item.canMoveToSlot(target)) return t.video_control_reject_unavailable;
  return null;
}

/// 漫画按钮布局编辑器（单个目标：宽窗或窄窗）。
class MangaControlLayoutEditor extends StatelessWidget {
  const MangaControlLayoutEditor({
    super.key,
    required this.layout,
    required this.onLayoutChanged,
    required this.isTouchControls,
    this.compact = false,
    this.defaults,
  });

  final MangaControlLayout layout;
  final Future<void> Function(MangaControlLayout layout)? onLayoutChanged;
  final bool isTouchControls;

  /// 预览按手机（窄窗）还是平板 / 桌面画。
  final bool compact;

  /// 「恢复默认」写回的布局；null 不显示该按钮。
  final MangaControlLayout? defaults;

  void _move(MangaControlItem item, MangaControlSlot target, {int? index}) {
    final Future<void> Function(MangaControlLayout)? changed = onLayoutChanged;
    if (changed == null) return;
    final String? reject = mangaControlRejectionMessage(item, target);
    if (reject != null) {
      FushiToast.show(msg: reject, severity: ToastSeverity.warning);
      return;
    }
    final ControlLayout<MangaControlSlot, MangaControlItem> next = layout.core
        .moveItem(item, target, index: index);
    if (next == layout.core) return;
    unawaited(changed(MangaControlLayout.fromCore(next)));
  }

  List<MangaControlItem> _itemsIn(MangaControlSlot slot) =>
      slot == MangaControlSlot.hidden
      ? List<MangaControlItem>.of(layout.core.removedItems)
      : layout.itemsIn(slot);

  Future<void> _showMoveMenu(
    BuildContext chipContext,
    MangaControlItem item,
  ) async {
    final RenderObject? box = chipContext.findRenderObject();
    final RenderObject? overlay = Overlay.of(
      chipContext,
    ).context.findRenderObject();
    if (box is! RenderBox || overlay is! RenderBox) return;
    final Offset topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final RelativeRect position = RelativeRect.fromRect(
      topLeft & box.size,
      Offset.zero & overlay.size,
    );
    final MangaControlSlot current = layout.core.slotOf(item);
    final List<MangaControlItem> siblings = _itemsIn(current);
    final int at = siblings.indexOf(item);
    final String? choice = await showFushiMenu<String>(
      context: chipContext,
      position: position,
      items: <PopupMenuEntry<String>>[
        if (current != MangaControlSlot.hidden && at > 0)
          PopupMenuItem<String>(
            value: 'earlier',
            child: _MenuRow(
              icon: FushiIcons.arrowUp,
              label: t.reader_control_move_earlier,
            ),
          ),
        if (current != MangaControlSlot.hidden &&
            at >= 0 &&
            at < siblings.length - 1)
          PopupMenuItem<String>(
            value: 'later',
            child: _MenuRow(
              icon: FushiIcons.arrowDown,
              label: t.reader_control_move_later,
            ),
          ),
        const PopupMenuDivider(),
        for (final MangaControlSlot slot in MangaControlSlot.editableSlots)
          if (slot != current)
            PopupMenuItem<String>(
              value: slot.storageValue,
              enabled: item.canMoveToSlot(slot),
              child: _MenuRow(
                icon: _zoneIcon(slot),
                label: '${t.reader_control_move_to} · ${_zoneLabel(slot)}',
              ),
            ),
      ],
    );
    if (choice == null || !chipContext.mounted) return;
    if (choice == 'earlier') {
      _move(item, current, index: at - 1);
    } else if (choice == 'later') {
      _move(item, current, index: at + 1);
    } else {
      for (final MangaControlSlot s in MangaControlSlot.values) {
        if (s.storageValue == choice) _move(item, s);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    Widget zone(MangaControlSlot slot, ReaderPanelCardTone tone) => _ZoneCard(
      title: _zoneLabel(slot),
      hint: _zoneHint(slot),
      tone: tone,
      child: _ZoneRow(
        key: ValueKey<String>('manga-control-edit-slot-${slot.storageValue}'),
        slot: slot,
        items: _itemsIn(slot),
        touch: isTouchControls,
        onDrop: (MangaControlItem item, int? index) =>
            _move(item, slot, index: index),
        onChipActivate: _showMoveMenu,
      ),
    );
    final List<Widget> sections = <Widget>[
      _MangaToolbarPreview(
        key: const ValueKey<String>('manga-control-editor-preview'),
        layout: layout,
        compact: compact,
      ),
      Text(
        t.reader_control_editor_drag_hint,
        style: controlLayoutEditorHintStyle(context),
      ),
      zone(MangaControlSlot.top, ReaderPanelCardTone.emphasis),
      zone(MangaControlSlot.toolbar, ReaderPanelCardTone.emphasis),
      zone(MangaControlSlot.overflow, ReaderPanelCardTone.neutral),
      zone(MangaControlSlot.hidden, ReaderPanelCardTone.neutral),
      if (defaults != null && onLayoutChanged != null)
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: FushiTextButton.icon(
            key: const ValueKey<String>('manga-control-restore-defaults'),
            onPressed: () => unawaited(onLayoutChanged!(defaults!)),
            icon: const FushiIcon(FushiIcons.restart),
            label: Text(t.reader_control_restore_defaults),
          ),
        ),
    ];
    return DefaultTextStyle.merge(
      style: TextStyle(
        color: glass
            ? appleColorsOf(context).label
            : theme.colorScheme.onSurface,
      ),
      child: FushiEntranceScope(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int i = 0; i < sections.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(height: 12),
              readerPanelStagger(i, sections[i]),
            ],
          ],
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      FushiIcon(icon, size: 20),
      const SizedBox(width: 12),
      Flexible(child: Text(label)),
    ],
  );
}

/// 一个区（标题 + 说明 + 放置区）。
class _ZoneCard extends StatelessWidget {
  const _ZoneCard({
    required this.title,
    required this.hint,
    required this.tone,
    required this.child,
  });

  final String title;
  final String hint;
  final ReaderPanelCardTone tone;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color fg = ReaderPanelCard.foregroundFor(context, tone);
    return ReaderPanelCard(
      tone: tone,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              color: fg,
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(
            hint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: fg.withValues(alpha: 0.72),
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// 一个区的放置面：胶囊 chip 流。落在 chip 上 = 插到它前面；落在空白 = 追加到末尾。
/// 拖动悬停时区底高亮（动画）。
class _ZoneRow extends StatelessWidget {
  const _ZoneRow({
    super.key,
    required this.slot,
    required this.items,
    required this.touch,
    required this.onDrop,
    required this.onChipActivate,
  });

  final MangaControlSlot slot;
  final List<MangaControlItem> items;
  final bool touch;
  final void Function(MangaControlItem item, int? index) onDrop;
  final Future<void> Function(BuildContext chipContext, MangaControlItem item)
  onChipActivate;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final Color accent = glass
        ? appleColorsOf(context).accent
        : theme.colorScheme.primary;
    return DragTarget<MangaControlItem>(
      onWillAcceptWithDetails: (DragTargetDetails<MangaControlItem> d) =>
          d.data.canMoveToSlot(slot),
      onAcceptWithDetails: (DragTargetDetails<MangaControlItem> d) =>
          onDrop(d.data, null),
      builder:
          (
            BuildContext context,
            List<MangaControlItem?> candidates,
            List<dynamic> rejected,
          ) {
            final bool hovering = candidates.isNotEmpty;
            return AnimatedContainer(
              duration: fushiMotionDuration(context, FushiMotion.short),
              curve: FushiMotion.standard,
              padding: const EdgeInsets.all(6),
              decoration: ShapeDecoration(
                color: hovering
                    ? accent.withValues(alpha: 0.14)
                    : accent.withValues(alpha: 0),
                shape: RoundedRectangleBorder(
                  borderRadius: const BorderRadius.all(Radius.circular(16)),
                  side: BorderSide(
                    color: rejected.isNotEmpty
                        ? theme.colorScheme.error
                        : hovering
                        ? accent
                        : accent.withValues(alpha: 0),
                    width: 1.5,
                  ),
                ),
              ),
              child: AnimatedSize(
                duration: fushiMotionDuration(context, FushiMotion.short),
                curve: FushiMotion.standard,
                alignment: Alignment.topLeft,
                child: items.isEmpty
                    ? SizedBox(
                        height: 40,
                        child: Center(
                          child: FushiIcon(
                            FushiIcons.add,
                            color: accent.withValues(alpha: 0.5),
                          ),
                        ),
                      )
                    : Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: <Widget>[
                          for (int i = 0; i < items.length; i++)
                            DragTarget<MangaControlItem>(
                              onWillAcceptWithDetails:
                                  (DragTargetDetails<MangaControlItem> d) =>
                                      d.data != items[i] &&
                                      d.data.canMoveToSlot(slot),
                              onAcceptWithDetails:
                                  (DragTargetDetails<MangaControlItem> d) =>
                                      onDrop(d.data, i),
                              builder:
                                  (
                                    BuildContext context,
                                    List<MangaControlItem?> c,
                                    List<dynamic> r,
                                  ) => _DraggableChip(
                                    key: ValueKey<String>(
                                      'manga-control-chip-${items[i].storageValue}',
                                    ),
                                    item: items[i],
                                    touch: touch,
                                    insertMarker: c.isNotEmpty,
                                    onActivate: onChipActivate,
                                  ),
                            ),
                        ],
                      ),
              ),
            );
          },
    );
  }
}

/// 一颗可拖动、可聚焦（Enter / 点击弹菜单）的按钮胶囊。
class _DraggableChip extends StatelessWidget {
  const _DraggableChip({
    super.key,
    required this.item,
    required this.touch,
    required this.insertMarker,
    required this.onActivate,
  });

  final MangaControlItem item;
  final bool touch;
  final bool insertMarker;
  final Future<void> Function(BuildContext chipContext, MangaControlItem item)
  onActivate;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double maxWidth = constraints.maxWidth;
        final Widget chip = _ChipFace(item: item, insertMarker: insertMarker);
        // 拖动反馈画在 Overlay 里，拿到的是无界宽度：套上源胶囊同样的最大宽度。
        final Widget feedback = Material(
          type: MaterialType.transparency,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxWidth.isFinite ? maxWidth : 320,
            ),
            child: Transform.scale(
              scale: 1.06,
              child: _ChipFace(item: item, lifted: true),
            ),
          ),
        );
        final Widget ghost = Opacity(opacity: 0.35, child: chip);
        final Widget draggable = touch
            ? LongPressDraggable<MangaControlItem>(
                data: item,
                feedback: feedback,
                childWhenDragging: ghost,
                child: chip,
              )
            : Draggable<MangaControlItem>(
                data: item,
                feedback: feedback,
                childWhenDragging: ghost,
                child: chip,
              );
        return Builder(
          builder: (BuildContext chipContext) => FushiPressScale(
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: () => unawaited(onActivate(chipContext, item)),
                child: Semantics(
                  button: true,
                  label: mangaControlItemLabel(item),
                  child: draggable,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ChipFace extends StatelessWidget {
  const _ChipFace({
    required this.item,
    this.insertMarker = false,
    this.lifted = false,
  });

  final MangaControlItem item;
  final bool insertMarker;
  final bool lifted;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final ColorScheme cs = theme.colorScheme;
    final Color bg = glass
        ? appleColorsOf(context).tertiaryGroupedBackground
        : cs.secondaryContainer;
    final Color fg = glass
        ? appleColorsOf(context).label
        : cs.onSecondaryContainer;
    final Color marker = glass ? appleColorsOf(context).accent : cs.primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AnimatedContainer(
          duration: fushiMotionDuration(context, FushiMotion.short),
          width: insertMarker ? 3 : 0,
          height: 28,
          margin: EdgeInsets.only(right: insertMarker ? 4 : 0),
          decoration: ShapeDecoration(
            color: marker,
            shape: const StadiumBorder(),
          ),
        ),
        Flexible(
          child: Container(
            constraints: const BoxConstraints(minHeight: 36),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: ShapeDecoration(
              color: bg,
              shape: StadiumBorder(
                side: item.pinnedRequired
                    ? BorderSide(color: marker.withValues(alpha: 0.6))
                    : BorderSide.none,
              ),
              shadows: lifted
                  ? <BoxShadow>[
                      BoxShadow(
                        color: cs.shadow.withValues(alpha: 0.25),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : const <BoxShadow>[],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                FushiIcon(mangaControlItemIcon(item), size: 18, color: fg),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    mangaControlItemLabel(item),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(color: fg),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 所见即所得预览：一张缩略页，顶部「← 标题 … 顶栏动作 ⋯」，底部纯图标悬浮工具栏
/// （按钮只读）。槽位预览：「更多」里的按钮恒在 ⋯ 里，与运行时按宽度自适应无关。
class _MangaToolbarPreview extends StatelessWidget {
  const _MangaToolbarPreview({
    super.key,
    required this.layout,
    required this.compact,
  });

  final MangaControlLayout layout;
  final bool compact;

  List<FushiToolbarItem> _items(MangaControlSlot slot) => <FushiToolbarItem>[
    for (final MangaControlItem i in layout.itemsIn(slot))
      FushiToolbarItem(
        icon: mangaControlItemIcon(i),
        label: mangaControlItemLabel(i),
        onPressed: null,
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final List<FushiToolbarItem> bottom = _items(MangaControlSlot.toolbar);
    final Color paper = glass
        ? appleColorsOf(context).secondaryGroupedBackground
        : theme.colorScheme.surfaceContainer;
    final Widget page = ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(20)),
      child: ColoredBox(
        color: paper,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              FushiFloatingTopBar(
                leading: <FushiToolbarItem>[
                  FushiToolbarItem(
                    icon: FushiIcons.back,
                    label: t.back,
                    onPressed: null,
                  ),
                ],
                title: t.manga_reader_control_zone_top,
                actions: <List<FushiToolbarItem>>[_items(MangaControlSlot.top)],
                overflow: _items(MangaControlSlot.overflow),
                adaptiveOverflow: false,
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 18, vertical: 18),
                child: ControlStageTextLines(),
              ),
              if (bottom.isNotEmpty)
                Center(
                  child: FushiFloatingToolbar(
                    groups: <List<FushiToolbarItem>>[bottom],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    // 预览按真实尺寸排版（手机 420 / 平板桌面 760），放不下时整体等比缩小。
    final double design = compact ? 420 : 760;
    return IgnorePointer(
      child: ExcludeFocus(
        child: AnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.medium),
          curve: FushiMotion.standard,
          alignment: Alignment.topCenter,
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(
                width: design,
                child: AnimatedSwitcher(
                  duration: fushiMotionDuration(context, FushiMotion.short),
                  child: KeyedSubtree(
                    key: ValueKey<int>(layout.hashCode),
                    child: page,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 完整编辑器：顶部「手机 / 平板与桌面」目标切换（默认按当前窗口），分别读写两份
/// 布局；下面是 [MangaControlLayoutEditor]。
class MangaControlLayoutTargetEditor extends StatefulWidget {
  const MangaControlLayoutTargetEditor({
    super.key,
    required this.read,
    required this.write,
    required this.isTouchControls,
  });

  /// 读某个目标（compact = 手机）当前的布局。
  final MangaControlLayout Function(bool compact) read;

  /// 写某个目标的布局（宿主写偏好 + 通知开着的阅读器）。
  final Future<void> Function(bool compact, MangaControlLayout layout) write;
  final bool isTouchControls;

  @override
  State<MangaControlLayoutTargetEditor> createState() =>
      _MangaControlLayoutTargetEditorState();
}

class _MangaControlLayoutTargetEditorState
    extends State<MangaControlLayoutTargetEditor> {
  bool? _compact;

  @override
  Widget build(BuildContext context) {
    final bool compact = _compact ??=
        MediaQuery.sizeOf(context).width < kMangaControlCompactWidth;
    final MangaControlLayout layout = widget.read(compact);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ReaderPanelTabs<bool>(
          padding: const EdgeInsets.only(bottom: 12),
          tabs: <ReaderPanelTab<bool>>[
            ReaderPanelTab<bool>(
              value: true,
              label: t.reader_control_layout_target_compact,
              icon: FushiIcons.phone,
              key: const ValueKey<String>('manga-control-target-compact'),
            ),
            ReaderPanelTab<bool>(
              value: false,
              label: t.reader_control_layout_target_wide,
              icon: FushiIcons.laptop,
              key: const ValueKey<String>('manga-control-target-wide'),
            ),
          ],
          selected: compact,
          onChanged: (bool v) => setState(() => _compact = v),
        ),
        AnimatedSwitcher(
          duration: fushiMotionDuration(context, FushiMotion.medium),
          switchInCurve: FushiMotion.enter,
          switchOutCurve: FushiMotion.exit,
          child: MangaControlLayoutEditor(
            key: ValueKey<bool>(compact),
            layout: layout,
            compact: compact,
            isTouchControls: widget.isTouchControls,
            defaults: compact
                ? MangaControlLayout.compactDefaults
                : MangaControlLayout.defaults,
            onLayoutChanged: (MangaControlLayout next) async {
              await widget.write(compact, next);
              if (mounted) setState(() {});
            },
          ),
        ),
      ],
    );
  }
}

/// 阅读器内打开工具栏布局编辑器（右侧侧板 / 窄窗底部 sheet，与阅读设置同一外壳）。
/// [write] 写偏好后由调用方重建 chrome，改动实时生效。
Future<void> showMangaControlLayoutEditorSheet({
  required BuildContext context,
  required MangaControlLayout Function(bool compact) read,
  required Future<void> Function(bool compact, MangaControlLayout layout) write,
}) => showReaderSideSheet<void>(
  context: context,
  side: ReaderSideSheetSide.right,
  bottomSheetWhenCompact: true,
  builder: (BuildContext sheetContext) => ReaderSideSheet(
    title: t.manga_reader_control_layout,
    icon: FushiIcons.dashboardCustomize,
    onClose: () => Navigator.of(sheetContext).maybePop(),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            t.manga_reader_control_layout_hint,
            style: controlLayoutEditorHintStyle(sheetContext),
          ),
        ),
        MangaControlLayoutTargetEditor(
          read: read,
          write: write,
          isTouchControls: !isDesktopPlatform,
        ),
      ],
    ),
  ),
);
