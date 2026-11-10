import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_layout.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_horizontal_edge_fade.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart'
    show FushiDragHandle;
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_column.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 分区在布局编辑器里的显示名（与对话框里分区卡的标题同一份文案）。
String advancedMiningPanelLabel(AdvancedMiningPanelId id) => switch (id) {
  AdvancedMiningPanelId.deck => t.popup_advanced_mining_deck_section,
  AdvancedMiningPanelId.fields => t.popup_advanced_mining_fields_section,
  AdvancedMiningPanelId.wordAudio => t.popup_advanced_mining_word_audio_section,
  AdvancedMiningPanelId.sentenceAudio => t.popup_advanced_mining_audio_section,
  AdvancedMiningPanelId.image => t.popup_advanced_mining_image_section,
};

/// 打开「自定义布局」（反馈 aZ99bm9R6K）：拖动排序、选左 / 右栏、显示 / 隐藏。
///
/// 只列出 [present]（这个页面实际有的分区）；每改一下就经 [onChanged] 交出新布局，
/// 高级制卡对话框在背后即时重排，所见即所得，「完成」只是关窗。
Future<void> showAdvancedMiningLayoutEditor({
  required BuildContext context,
  required AdvancedMiningLayout initial,
  required Set<AdvancedMiningPanelId> present,
  required ValueChanged<AdvancedMiningLayout> onChanged,
  bool showColumns = true,
}) => showAppDialog<void>(
  context: context,
  // 盖在高级制卡（制卡流程的一部分）上面，同样不停学习计时（BUG-3994）。
  studyClockTransparent: true,
  builder: (_) => AdvancedMiningLayoutEditor(
    initial: initial,
    present: present,
    onChanged: onChanged,
    showColumns: showColumns,
  ),
);

/// 「自定义布局」对话框本体。
///
/// 重排沿用 `FushiReorderableColumn`（局部坐标拖拽，界面缩放下也跟手）；行尾把手
/// 是可聚焦的菜单按钮，「上移 / 下移」是键盘、手柄与读屏的重排路径。
class AdvancedMiningLayoutEditor extends StatefulWidget {
  const AdvancedMiningLayoutEditor({
    super.key,
    required this.initial,
    required this.present,
    required this.onChanged,
    this.showColumns = true,
  });

  final AdvancedMiningLayout initial;
  final Set<AdvancedMiningPanelId> present;
  final ValueChanged<AdvancedMiningLayout> onChanged;

  /// 是否给「左栏 / 右栏」选择：只有宽屏双栏（且不是漫画——漫画左栏整高是裁切
  /// 工作区）时栏位才有意义，窄屏只排顺序与显隐。
  final bool showColumns;

  @override
  State<AdvancedMiningLayoutEditor> createState() =>
      _AdvancedMiningLayoutEditorState();
}

class _AdvancedMiningLayoutEditorState
    extends State<AdvancedMiningLayoutEditor> {
  late AdvancedMiningLayout _layout = widget.initial;

  void _set(AdvancedMiningLayout next) {
    if (next == _layout) return;
    setState(() => _layout = next);
    widget.onChanged(next);
  }

  void _move(int from, int to) =>
      _set(_layout.reorderAmong(widget.present, from, to));

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double maxHeight = (MediaQuery.sizeOf(context).height * 0.6).clamp(
      160.0,
      460.0,
    );
    return FushiDialogFrame(
      maxWidth: 520,
      maxHeightFactor: 0.92,
      insetPadding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.card,
      ),
      scrollable: false,
      child: FushiModalSheetFrame(
        title: t.popup_advanced_mining_layout_title,
        leadingIcon: FushiIcons.dashboardCustomize,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: double.maxFinite,
            maxHeight: maxHeight,
          ),
          child: FushiHorizontalEdgeFade(
            axis: Axis.vertical,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    widget.showColumns
                        ? t.popup_advanced_mining_layout_hint
                        : t.popup_advanced_mining_layout_hint_single,
                    style: context.fushiType.bodySmall.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildList(context),
                ],
              ),
            ),
          ),
        ),
        footer: Row(
          children: <Widget>[
            Flexible(
              child: adaptiveDialogAction(
                context: context,
                onPressed: _layout.isDefault
                    ? null
                    : () => _set(AdvancedMiningLayout.defaults),
                child: Text(t.popup_advanced_mining_layout_reset),
              ),
            ),
            const Spacer(),
            adaptiveDialogAction(
              context: context,
              isDefaultAction: true,
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.popup_advanced_mining_crop_done),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    final List<AdvancedMiningPanelSlot> rows = _layout.slotsAmong(
      widget.present,
    );
    return FushiEntranceScope(
      child: FushiReorderableColumn(
        itemCount: rows.length,
        spacing: fushiGroupedListGap(context),
        keyForIndex: (int index) =>
            ValueKey<String>('advanced-mining-layout-${rows[index].id.name}'),
        onReorder: _move,
        itemBuilder: (BuildContext context, int index) {
          final AdvancedMiningPanelSlot slot = rows[index];
          return FushiStaggeredEntrance(
            index: index,
            child: FushiGroupedListItem(
              index: index,
              count: rows.length,
              includeGap: false,
              child: AnimatedOpacity(
                opacity: slot.hidden ? 0.55 : 1,
                duration: context.fushiMotion.effectsFast.duration,
                curve: context.fushiMotion.effectsFast.curve,
                child: AdaptiveSettingsRow(
                  title: advancedMiningPanelLabel(slot.id),
                  subtitle: slot.hidden
                      ? t.popup_advanced_mining_layout_hidden
                      : null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (widget.showColumns)
                        _ColumnPicker(
                          key: ValueKey<String>(
                            'advanced-mining-layout-column-${slot.id.name}',
                          ),
                          value: slot.column,
                          enabled: !slot.hidden,
                          onChanged: (AdvancedMiningColumn column) =>
                              _set(_layout.withColumn(slot.id, column)),
                        ),
                      FushiIconButtonControl(
                        key: ValueKey<String>(
                          'advanced-mining-layout-visibility-${slot.id.name}',
                        ),
                        tooltip: slot.hidden
                            ? t.popup_advanced_mining_layout_show
                            : t.popup_advanced_mining_layout_hide,
                        onPressed: () =>
                            _set(_layout.withHidden(slot.id, !slot.hidden)),
                        icon: FushiIcon(
                          slot.hidden
                              ? FushiIcons.visibilityOff
                              : FushiIcons.visibility,
                          size: 20,
                        ),
                      ),
                      _reorderHandle(rows, index),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 行尾重排把手：整行按下 / 长按即可拖（手势归外层 [FushiReorderableColumn]）；
  /// 把手本身点按 / Enter 弹出「上移 / 下移」。
  Widget _reorderHandle(List<AdvancedMiningPanelSlot> rows, int index) {
    if (rows.length < 2) return const SizedBox.shrink();
    return FushiPopupMenuButton<int>(
      key: ValueKey<String>(
        'advanced-mining-layout-handle-${rows[index].id.name}',
      ),
      tooltip: t.popup_advanced_mining_layout_reorder,
      padding: EdgeInsets.zero,
      borderRadius: BorderRadius.circular(kMinInteractiveDimension / 2),
      onSelected: (int delta) => _move(index, index + delta),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<int>>[
        PopupMenuItem<int>(
          value: -1,
          enabled: index > 0,
          child: _menuLabel(FushiIcons.expandLess, t.move_up),
        ),
        PopupMenuItem<int>(
          value: 1,
          enabled: index < rows.length - 1,
          child: _menuLabel(FushiIcons.expandMore, t.move_down),
        ),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: kMinInteractiveDimension,
          minHeight: kMinInteractiveDimension,
        ),
        child: Center(
          widthFactor: 1,
          heightFactor: 1,
          child: FushiDragHandle(),
        ),
      ),
    );
  }

  Widget _menuLabel(IconData icon, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      FushiIcon(icon, size: 20),
      const SizedBox(width: 12),
      Flexible(child: Text(label)),
    ],
  );
}

/// 「左栏 / 右栏」单选分段（设计系统分段：MD3 胶囊 / Apple 分段）。
class _ColumnPicker extends StatelessWidget {
  const _ColumnPicker({
    super.key,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final AdvancedMiningColumn value;
  final bool enabled;
  final ValueChanged<AdvancedMiningColumn> onChanged;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !enabled,
    child: SizedBox(
      width: 132,
      child: adaptiveSegmentedButton<AdvancedMiningColumn>(
        context: context,
        segments: <ButtonSegment<AdvancedMiningColumn>>[
          ButtonSegment<AdvancedMiningColumn>(
            value: AdvancedMiningColumn.left,
            label: Text(t.popup_advanced_mining_layout_left),
          ),
          ButtonSegment<AdvancedMiningColumn>(
            value: AdvancedMiningColumn.right,
            label: Text(t.popup_advanced_mining_layout_right),
          ),
        ],
        selected: <AdvancedMiningColumn>{value},
        onSelectionChanged: (Set<AdvancedMiningColumn> next) {
          if (next.isNotEmpty) onChanged(next.first);
        },
      ),
    ),
  );
}
