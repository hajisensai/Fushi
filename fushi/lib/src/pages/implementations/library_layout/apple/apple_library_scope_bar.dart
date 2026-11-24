import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart' show FushiFocusId;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart'
    show fushiAppleChip;
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show fushiAppleUsesMacMetrics;
import 'package:fushi/src/utils/components/library_section_tab.dart';
import 'package:fushi/src/utils/components/settings_shared.dart'
    show FushiAdjustableSegmented;

/// Apple 库页标题下的分区胶囊行（方案 A，Apple Music「资料库」式）：组内每个
/// 分区一枚胶囊，选中项反白（label 色实底 + 背景色字），其余 tertiaryFill 灰
/// 胶囊；放不下时整行横滑。iOS 档（窄屏）与没有侧栏承载分区时出现；macOS 档
/// 宽窗由侧栏子项承载（见 `AppleLibraryLayout`）。
///
/// 焦点契约与 M3E 页签相同：整排是一个焦点停靠点（[FushiAdjustableSegmented]），
/// 左右方向键 / 手柄原地切分区；胶囊本身不进焦点遍历。
class AppleLibraryScopeBar<T extends Object> extends StatelessWidget {
  const AppleLibraryScopeBar({
    required this.sections,
    required this.selected,
    required this.onSelect,
    required this.focusIdPrefix,
    this.selectedIsCurrent = true,
    super.key,
  });

  /// 组内分区（已按用户顺序排好）。
  final List<LibrarySectionTab<T>> sections;

  /// 高亮的分区；不在 [sections] 里（停在导入页）时没有胶囊高亮。
  final T? selected;
  final ValueChanged<T> onSelect;
  final String focusIdPrefix;

  /// false = [selected] 只是视觉锚点，点它也照常回调（BUG-4706）。
  final bool selectedIsCurrent;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final double gap = fushiAppleUsesMacMetrics(context) ? 6 : 8;
    final List<T> values = <T>[
      for (final LibrarySectionTab<T> tab in sections) tab.value,
    ];
    final T? current = selected;
    final bool onRow = current != null && values.contains(current);
    final Widget row = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      child: Row(
        children: <Widget>[
          for (int i = 0; i < sections.length; i++) ...<Widget>[
            if (i > 0) SizedBox(width: gap),
            FushiPressScale(
              child: KeyedSubtree(
                key: sections[i].labelKey,
                child: _ScopeCapsule(
                  label: sections[i].label,
                  selected: onRow && sections[i].value == current,
                  selectedFill: apple.label,
                  onTap: () {
                    final T value = sections[i].value;
                    if (value == current && selectedIsCurrent && onRow) return;
                    onSelect(value);
                  },
                ),
              ),
            ),
          ],
        ],
      ),
    );
    return FushiAdjustableSegmented<T>(
      values: values,
      selected: onRow ? current : values.first,
      selectedIsCurrent: onRow && selectedIsCurrent,
      onChanged: onSelect,
      focusIdPrefix: focusIdPrefix,
      focusId: FushiFocusId('$focusIdPrefix-sections'),
      child: row,
    );
  }
}

/// 一枚分区胶囊：选中反白的底色随 [FushiMotion.short] 渐变。
class _ScopeCapsule extends StatelessWidget {
  const _ScopeCapsule({
    required this.label,
    required this.selected,
    required this.selectedFill,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Color selectedFill;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.short),
      switchInCurve: FushiMotion.standard,
      switchOutCurve: FushiMotion.standard,
      child: KeyedSubtree(
        key: ValueKey<bool>(selected),
        child: fushiAppleChip(
          context,
          label: Text(label),
          onTap: onTap,
          selected: selected,
          selectedColor: selectedFill,
          focusable: false,
        ),
      ),
    );
  }
}
