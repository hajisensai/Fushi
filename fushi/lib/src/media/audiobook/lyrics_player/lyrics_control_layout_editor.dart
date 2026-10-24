/// 歌词模式次要按钮布局的拖拽编辑器（阅读设置 →「歌词模式」页的「按钮布局」
/// 入口）。与漫画 / 小说阅读器的编辑器同一套手感：上方所见即所得预览，下方
/// 「顶部 / 播放卡工具条 / 更多菜单 / 隐藏」四区，每颗按钮是一枚胶囊 chip——触屏
/// 长按拖、桌面直接拖；键盘在 chip 上按 Enter 弹「移到…」菜单。写操作全部经
/// [ControlLayout.moveItem]（模型不变式在那里）。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/controls/control_layout.dart';
import 'package:fushi/src/controls/control_layout_editor.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_control_layout.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart'
    show lyricsPlayerIsWide;
import 'package:fushi/src/reader/reader_desktop_chrome.dart'
    show ReaderSideSheet, ReaderSideSheetSide, showReaderSideSheet;
import 'package:fushi/src/reader/reader_panel_chrome_kit.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 歌词按钮的代表图标（编辑器 chip / 预览 / ⋯ 菜单，语义图标层 [FushiIcons]）。
IconData lyricsControlItemIcon(LyricsControlItem item) => switch (item) {
  LyricsControlItem.speed => FushiIcons.speed,
  LyricsControlItem.studyTimer => FushiIcons.timer,
  LyricsControlItem.replayCue => FushiIcons.replay,
  LyricsControlItem.mask => FushiIcons.visibility,
  LyricsControlItem.typography => FushiIcons.textFields,
  LyricsControlItem.statistics => FushiIcons.statistics,
  LyricsControlItem.bookMode => FushiIcons.readingMode,
  LyricsControlItem.swapSides => FushiIcons.swap,
};

/// 歌词按钮的名称（编辑器 chip / 菜单 / 无障碍语义）。
String lyricsControlItemLabel(LyricsControlItem item) => switch (item) {
  LyricsControlItem.speed => t.playback_speed,
  LyricsControlItem.studyTimer => t.lyrics_control_item_study_timer,
  LyricsControlItem.replayCue => t.lyrics_sentence_replay,
  LyricsControlItem.mask => t.lyrics_blur,
  LyricsControlItem.typography => t.lyrics_typography_title,
  LyricsControlItem.statistics => t.reading_statistics,
  LyricsControlItem.bookMode => t.book_mode,
  LyricsControlItem.swapSides => t.lyrics_layout_swap_sides,
};

String _zoneLabel(LyricsControlSlot slot) => switch (slot) {
  LyricsControlSlot.top => t.lyrics_control_zone_top,
  LyricsControlSlot.toolbar => t.lyrics_control_zone_toolbar,
  LyricsControlSlot.overflow => t.reader_control_slot_overflow,
  LyricsControlSlot.hidden => t.reader_control_zone_hidden,
};

String _zoneHint(LyricsControlSlot slot) => switch (slot) {
  LyricsControlSlot.top => t.lyrics_control_zone_top_hint,
  LyricsControlSlot.toolbar => t.lyrics_control_zone_toolbar_hint,
  LyricsControlSlot.overflow => t.reader_control_zone_overflow_hint,
  LyricsControlSlot.hidden => t.lyrics_control_zone_hidden_hint,
};

IconData _zoneIcon(LyricsControlSlot slot) => switch (slot) {
  LyricsControlSlot.top => FushiIcons.alignTop,
  LyricsControlSlot.toolbar => FushiIcons.alignBottom,
  LyricsControlSlot.overflow => FushiIcons.moreHoriz,
  LyricsControlSlot.hidden => FushiIcons.visibilityOff,
};

/// 驳回提示（null = 允许）。纯函数，编辑器与测试共用。
String? lyricsControlRejectionMessage(
  LyricsControlItem item,
  LyricsControlSlot target,
) {
  if (!item.canMoveToSlot(target)) return t.video_control_reject_unavailable;
  return null;
}

/// 歌词按钮布局编辑器（单个目标：宽屏或窄屏）。
class LyricsControlLayoutEditor extends StatelessWidget {
  const LyricsControlLayoutEditor({
    super.key,
    required this.layout,
    required this.onLayoutChanged,
    required this.isTouchControls,
    this.compact = false,
    this.defaults,
  });

  final LyricsControlLayout layout;
  final Future<void> Function(LyricsControlLayout layout)? onLayoutChanged;
  final bool isTouchControls;

  /// 预览按手机（窄窗）还是平板 / 桌面画。
  final bool compact;

  /// 「恢复默认」写回的布局；null 不显示该按钮。
  final LyricsControlLayout? defaults;

  void _move(LyricsControlItem item, LyricsControlSlot target, {int? index}) {
    final Future<void> Function(LyricsControlLayout)? changed = onLayoutChanged;
    if (changed == null) return;
    final String? reject = lyricsControlRejectionMessage(item, target);
    if (reject != null) {
      FushiToast.show(msg: reject, severity: ToastSeverity.warning);
      return;
    }
    final ControlLayout<LyricsControlSlot, LyricsControlItem> next = layout.core
        .moveItem(item, target, index: index);
    if (next == layout.core) return;
    unawaited(changed(LyricsControlLayout.fromCore(next)));
  }

  List<LyricsControlItem> _itemsIn(LyricsControlSlot slot) =>
      slot == LyricsControlSlot.hidden
      ? List<LyricsControlItem>.of(layout.core.removedItems)
      : layout.itemsIn(slot);

  Future<void> _showMoveMenu(
    BuildContext chipContext,
    LyricsControlItem item,
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
    final LyricsControlSlot current = layout.core.slotOf(item);
    final List<LyricsControlItem> siblings = _itemsIn(current);
    final int at = siblings.indexOf(item);
    final String? choice = await showFushiMenu<String>(
      context: chipContext,
      position: position,
      items: <PopupMenuEntry<String>>[
        if (current != LyricsControlSlot.hidden && at > 0)
          PopupMenuItem<String>(
            value: 'earlier',
            child: _MenuRow(
              icon: FushiIcons.arrowUp,
              label: t.reader_control_move_earlier,
            ),
          ),
        if (current != LyricsControlSlot.hidden &&
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
        for (final LyricsControlSlot slot in LyricsControlSlot.editableSlots)
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
      for (final LyricsControlSlot s in LyricsControlSlot.values) {
        if (s.storageValue == choice) _move(item, s);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    Widget zone(LyricsControlSlot slot, ReaderPanelCardTone tone) => _ZoneCard(
      title: _zoneLabel(slot),
      hint: _zoneHint(slot),
      tone: tone,
      child: _ZoneRow(
        key: ValueKey<String>('lyrics-control-edit-slot-${slot.storageValue}'),
        slot: slot,
        items: _itemsIn(slot),
        touch: isTouchControls,
        onDrop: (LyricsControlItem item, int? index) =>
            _move(item, slot, index: index),
        onChipActivate: _showMoveMenu,
      ),
    );
    final List<Widget> sections = <Widget>[
      _LyricsControlsPreview(
        key: const ValueKey<String>('lyrics-control-editor-preview'),
        layout: layout,
        compact: compact,
      ),
      Text(
        t.reader_control_editor_drag_hint,
        style: controlLayoutEditorHintStyle(context),
      ),
      zone(LyricsControlSlot.top, ReaderPanelCardTone.emphasis),
      zone(LyricsControlSlot.toolbar, ReaderPanelCardTone.emphasis),
      zone(LyricsControlSlot.overflow, ReaderPanelCardTone.neutral),
      zone(LyricsControlSlot.hidden, ReaderPanelCardTone.neutral),
      if (defaults != null && onLayoutChanged != null)
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: FushiTextButton.icon(
            key: const ValueKey<String>('lyrics-control-restore-defaults'),
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

  final LyricsControlSlot slot;
  final List<LyricsControlItem> items;
  final bool touch;
  final void Function(LyricsControlItem item, int? index) onDrop;
  final Future<void> Function(BuildContext chipContext, LyricsControlItem item)
  onChipActivate;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final Color accent = glass
        ? appleColorsOf(context).accent
        : theme.colorScheme.primary;
    return DragTarget<LyricsControlItem>(
      onWillAcceptWithDetails: (DragTargetDetails<LyricsControlItem> d) =>
          d.data.canMoveToSlot(slot),
      onAcceptWithDetails: (DragTargetDetails<LyricsControlItem> d) =>
          onDrop(d.data, null),
      builder:
          (
            BuildContext context,
            List<LyricsControlItem?> candidates,
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
              child: FushiAnimatedSize(
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
                            DragTarget<LyricsControlItem>(
                              onWillAcceptWithDetails:
                                  (DragTargetDetails<LyricsControlItem> d) =>
                                      d.data != items[i] &&
                                      d.data.canMoveToSlot(slot),
                              onAcceptWithDetails:
                                  (DragTargetDetails<LyricsControlItem> d) =>
                                      onDrop(d.data, i),
                              builder:
                                  (
                                    BuildContext context,
                                    List<LyricsControlItem?> c,
                                    List<dynamic> r,
                                  ) => _DraggableChip(
                                    key: ValueKey<String>(
                                      'lyrics-control-chip-${items[i].storageValue}',
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

  final LyricsControlItem item;
  final bool touch;
  final bool insertMarker;
  final Future<void> Function(BuildContext chipContext, LyricsControlItem item)
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
            ? LongPressDraggable<LyricsControlItem>(
                data: item,
                feedback: feedback,
                childWhenDragging: ghost,
                child: chip,
              )
            : Draggable<LyricsControlItem>(
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
                  label: lyricsControlItemLabel(item),
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

  final LyricsControlItem item;
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
                FushiIcon(lyricsControlItemIcon(item), size: 18, color: fg),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    lyricsControlItemLabel(item),
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

/// 所见即所得预览：一张缩略歌词页，右上角是「顶部」区按钮，底部播放卡是「播放卡
/// 工具条」区按钮 + 恒在末尾的 ⋯（按钮只读）。「更多」里的按钮恒在 ⋯ 里。
class _LyricsControlsPreview extends StatelessWidget {
  const _LyricsControlsPreview({
    super.key,
    required this.layout,
    required this.compact,
  });

  final LyricsControlLayout layout;
  final bool compact;

  List<FushiToolbarItem> _items(LyricsControlSlot slot) => <FushiToolbarItem>[
    for (final LyricsControlItem i in layout.itemsIn(slot))
      // 左右互换只在宽屏双栏渲染：窄屏预览与运行时一致，不画它。
      if (!(compact && i == LyricsControlItem.swapSides))
        FushiToolbarItem(
          icon: lyricsControlItemIcon(i),
          label: lyricsControlItemLabel(i),
          onPressed: null,
        ),
  ];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final List<FushiToolbarItem> top = _items(LyricsControlSlot.top);
    final List<FushiToolbarItem> toolbar = <FushiToolbarItem>[
      ..._items(LyricsControlSlot.toolbar),
      FushiToolbarItem(
        icon: FushiIcons.moreHoriz,
        label: t.reader_control_slot_overflow,
        onPressed: null,
      ),
    ];
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
                title: t.lyrics_mode,
                actions: <List<FushiToolbarItem>>[
                  top,
                  <FushiToolbarItem>[
                    FushiToolbarItem(
                      icon: FushiIcons.close,
                      label: t.lyrics_exit_to_library,
                      onPressed: null,
                    ),
                  ],
                ],
                adaptiveOverflow: false,
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 18, vertical: 18),
                child: ControlStageTextLines(),
              ),
              Center(
                child: FushiFloatingToolbar(
                  groups: <List<FushiToolbarItem>>[
                    <FushiToolbarItem>[
                      FushiToolbarItem(
                        icon: FushiIcons.skipPrevious,
                        label: t.reader_control_item_play_pause,
                        onPressed: null,
                      ),
                      FushiToolbarItem(
                        icon: FushiIcons.play,
                        label: t.reader_control_item_play_pause,
                        onPressed: null,
                      ),
                      FushiToolbarItem(
                        icon: FushiIcons.skipNext,
                        label: t.reader_control_item_play_pause,
                        onPressed: null,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: FushiFloatingToolbar(
                  groups: <List<FushiToolbarItem>>[toolbar],
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
        child: FushiAnimatedSize(
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

/// 完整编辑器：顶部「手机 / 平板与桌面」目标切换（默认按当前窗口的单栏 / 双栏
/// 判据），分别读写两份布局；下面是 [LyricsControlLayoutEditor]。
class LyricsControlLayoutTargetEditor extends StatefulWidget {
  const LyricsControlLayoutTargetEditor({
    super.key,
    required this.read,
    required this.write,
    required this.isTouchControls,
  });

  /// 读某个目标（compact = 手机）当前的布局。
  final LyricsControlLayout Function(bool compact) read;

  /// 写某个目标的布局（宿主写偏好 + 通知开着的阅读器）。
  final Future<void> Function(bool compact, LyricsControlLayout layout) write;
  final bool isTouchControls;

  @override
  State<LyricsControlLayoutTargetEditor> createState() =>
      _LyricsControlLayoutTargetEditorState();
}

class _LyricsControlLayoutTargetEditorState
    extends State<LyricsControlLayoutTargetEditor> {
  bool? _compact;

  @override
  Widget build(BuildContext context) {
    final bool compact = _compact ??= !lyricsPlayerIsWide(
      MediaQuery.sizeOf(context),
    );
    final LyricsControlLayout layout = widget.read(compact);
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
              key: const ValueKey<String>('lyrics-control-target-compact'),
            ),
            ReaderPanelTab<bool>(
              value: false,
              label: t.reader_control_layout_target_wide,
              icon: FushiIcons.laptop,
              key: const ValueKey<String>('lyrics-control-target-wide'),
            ),
          ],
          selected: compact,
          onChanged: (bool v) => setState(() => _compact = v),
        ),
        AnimatedSwitcher(
          duration: fushiMotionDuration(context, FushiMotion.medium),
          switchInCurve: FushiMotion.enter,
          switchOutCurve: FushiMotion.exit,
          child: LyricsControlLayoutEditor(
            key: ValueKey<bool>(compact),
            layout: layout,
            compact: compact,
            isTouchControls: widget.isTouchControls,
            defaults: compact
                ? LyricsControlLayout.compactDefaults
                : LyricsControlLayout.defaults,
            onLayoutChanged: (LyricsControlLayout next) async {
              await widget.write(compact, next);
              if (mounted) setState(() {});
            },
          ),
        ),
      ],
    );
  }
}

/// 歌词模式内打开按钮布局编辑器（右侧侧板 / 窄窗底部 sheet，与阅读设置同一外壳）。
/// [write] 写偏好后由调用方重建覆盖层，改动实时生效。
Future<void> showLyricsControlLayoutEditorSheet({
  required BuildContext context,
  required LyricsControlLayout Function(bool compact) read,
  required Future<void> Function(bool compact, LyricsControlLayout layout)
  write,
}) => showReaderSideSheet<void>(
  context: context,
  side: ReaderSideSheetSide.right,
  bottomSheetWhenCompact: true,
  builder: (BuildContext sheetContext) => ReaderSideSheet(
    title: t.lyrics_control_layout,
    icon: FushiIcons.dashboardCustomize,
    onClose: () => Navigator.of(sheetContext).maybePop(),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            t.lyrics_control_layout_hint,
            style: controlLayoutEditorHintStyle(sheetContext),
          ),
        ),
        LyricsControlLayoutTargetEditor(
          read: read,
          write: write,
          isTouchControls: !isDesktopPlatform,
        ),
      ],
    ),
  ),
);
