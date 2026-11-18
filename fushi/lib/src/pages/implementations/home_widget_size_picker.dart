/// 首页小组件的尺寸选择网格（spec `docs/specs/2026-11-15-home-widgets-design.md`
/// 「改尺寸」）：编辑态点右下角柄弹出，像 Word「插入表格」那样一格一格的网格。
///
/// 网格画出该组件在当前网格里允许的最大范围（[HomeWidgetKind.maxFor]）；悬停 /
/// 聚焦某格时从左上角到那一格整块高亮，下方标签实时显示「3×2」；点按 / Enter /
/// 手柄 A 选定。低于下限的格子画成浅色，落在那里的选择钳到下限。方向键在格子间
/// 移焦（默认方向遍历），打开时焦点落在当前尺寸那一格。
library;

import 'package:flutter/gestures.dart' show PointerExitEvent;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show FushiAlertDialog;
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 尺寸网格里一格的测试 / 定位 key。
ValueKey<String> homeWidgetSizeCellKey(HomeWidgetSize size) =>
    ValueKey<String>('home-widget-size-cell/${size.cols}x${size.rows}');

/// 弹出 [kind] 在 [grid] 里的尺寸选择网格；选定返回尺寸（已钳进范围），取消返回
/// null。
Future<HomeWidgetSize?> showHomeWidgetSizePicker(
  BuildContext context, {
  required HomeWidgetKind kind,
  required HomeGridKind grid,
  required HomeWidgetSize current,
  required String label,
}) => showAppDialog<HomeWidgetSize>(
  context: context,
  builder: (BuildContext dialogContext) => FushiAlertDialog.adaptive(
    title: Text(label),
    content: HomeWidgetSizePicker(
      kind: kind,
      grid: grid,
      current: current,
      onSelected: (HomeWidgetSize size) =>
          popAppDialog<HomeWidgetSize>(dialogContext, size),
    ),
  ),
);

/// 尺寸选择网格本体（对话框内容；测试也直接 pump 它）。
class HomeWidgetSizePicker extends StatefulWidget {
  const HomeWidgetSizePicker({
    super.key,
    required this.kind,
    required this.grid,
    required this.current,
    required this.onSelected,
  });

  final HomeWidgetKind kind;
  final HomeGridKind grid;
  final HomeWidgetSize current;
  final ValueChanged<HomeWidgetSize> onSelected;

  @override
  State<HomeWidgetSizePicker> createState() => _HomeWidgetSizePickerState();
}

class _HomeWidgetSizePickerState extends State<HomeWidgetSizePicker> {
  /// 指针悬停的格子（优先于聚焦格）。
  HomeWidgetSize? _hover;

  /// 键盘 / 手柄聚焦的格子。
  HomeWidgetSize? _focused;

  static const double _cell = 30;
  static const double _gap = 4;

  HomeWidgetSize _clamp(HomeWidgetSize s) =>
      clampHomeWidgetSize(widget.kind, widget.grid, s);

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final HomeWidgetSize lo = widget.kind.minFor(widget.grid);
    final HomeWidgetSize hi = widget.kind.maxFor(widget.grid);
    final HomeWidgetSize current = _clamp(widget.current);
    final HomeWidgetSize target = _clamp(_hover ?? _focused ?? current);
    final Color primary = tokens.surfaces.primary;
    final Color outline = tokens.surfaces.outline;
    final Duration fade = fushiMotionDuration(context, FushiMotion.short);

    Widget cell(int c, int r) {
      final HomeWidgetSize size = HomeWidgetSize(c, r);
      final bool lit = c <= target.cols && r <= target.rows;
      final bool belowMin = c < lo.cols || r < lo.rows;
      return FocusableActionDetector(
        key: homeWidgetSizeCellKey(size),
        autofocus: size == current,
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (bool on) => setState(() {
          if (on) {
            _hover = size;
          } else if (_hover == size) {
            _hover = null;
          }
        }),
        onFocusChange: (bool on) => setState(() {
          if (on) {
            _focused = size;
          } else if (_focused == size) {
            _focused = null;
          }
        }),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (ActivateIntent _) {
              widget.onSelected(_clamp(size));
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onSelected(_clamp(size)),
          child: AnimatedContainer(
            duration: fade,
            curve: FushiMotion.standard,
            width: _cell,
            height: _cell,
            decoration: BoxDecoration(
              color: lit
                  ? primary.withValues(alpha: belowMin ? 0.55 : 0.85)
                  : (belowMin
                        ? outline.withValues(alpha: 0.08)
                        : outline.withValues(alpha: 0.16)),
              borderRadius: FushiBorderRadius.chip,
              border: Border.all(
                color: _focused == size
                    ? primary
                    : outline.withValues(alpha: lit ? 0 : 0.5),
                width: _focused == size ? 2 : 1,
              ),
            ),
          ),
        ),
      );
    }

    return Semantics(
      container: true,
      label: target.toString(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FocusTraversalGroup(
            policy: ReadingOrderTraversalPolicy(),
            child: MouseRegion(
              onExit: (PointerExitEvent _) => setState(() => _hover = null),
              // 格子从起始侧往结束侧数（Row 随 Directionality，RTL 自动镜像）。
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: _gap,
                children: <Widget>[
                  for (int r = 1; r <= hi.rows; r++)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: _gap,
                      children: <Widget>[
                        for (int c = 1; c <= hi.cols; c++) cell(c, r),
                      ],
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            target.toString(),
            key: const ValueKey<String>('home-widget-size-picker-label'),
            style: tokens.type.listTitle.copyWith(
              fontWeight: FontWeight.w700,
              color: tokens.surfaces.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            t.home_widget_size_range(min: lo.toString(), max: hi.toString()),
            style: tokens.type.metadata.copyWith(
              color: tokens.surfaces.onVariant,
            ),
          ),
        ],
      ),
    );
  }
}
