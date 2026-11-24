import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart' show FushiFocusId;
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiPopupMenuItem;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show showFushiMenu;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 标题菜单里的一个一级分组（「媒体库」/「在线」）。
@immutable
class AppleLibraryTitleMenuEntry {
  const AppleLibraryTitleMenuEntry({
    required this.label,
    required this.selected,
    required this.onSelect,
    this.icon,
  });

  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onSelect;
}

/// Apple 库页的大标题本身是下拉菜单（方案 A，照 Apple Books / TV「资料库」）：
/// 标题后跟一枚灰色下箭头，点开是一级分组（媒体库 / 在线，当前组打勾）+ 分隔
/// 线 +「调整页签顺序…」。真 iOS 按 store_compliance 没有「在线」组时只剩
/// 「媒体库」与排序项（由调用方决定条目）。
///
/// 菜单走设计系统分派的 [showFushiMenu]（Apple 下是玻璃菜单面板、中性灰无
/// 强调色）。标题是一个焦点停靠点，Enter / 手柄 A 打开菜单。
class AppleLibraryTitleMenu extends StatelessWidget {
  const AppleLibraryTitleMenu({
    required this.title,
    required this.titleStyle,
    required this.entries,
    required this.focusIdPrefix,
    this.onReorder,
    super.key,
  });

  /// 已按导航栏字阶画好的标题（随大标题收起缩放，箭头一起缩）。
  final Widget title;

  /// 标题字阶（下箭头按它取大小）。
  final TextStyle titleStyle;
  final List<AppleLibraryTitleMenuEntry> entries;
  final String focusIdPrefix;

  /// 「调整页签顺序…」；null = 当前组不可调（不出这一项）。
  final VoidCallback? onReorder;

  Future<void> _open(BuildContext context) async {
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    final RenderBox? overlay =
        Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null || !box.hasSize) return;
    final Offset topLeft = box.localToGlobal(
      Offset(0, box.size.height),
      ancestor: overlay,
    );
    final int? picked = await showFushiMenu<int>(
      context: context,
      position: RelativeRect.fromRect(
        topLeft & Size(box.size.width, 0),
        Offset.zero & overlay.size,
      ),
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 320),
      items: <PopupMenuEntry<int>>[
        for (int i = 0; i < entries.length; i++)
          FushiPopupMenuItem<int>(
            value: i,
            label: entries[i].label,
            icon: entries[i].icon,
            selected: entries[i].selected,
          ),
        if (onReorder != null) ...<PopupMenuEntry<int>>[
          const PopupMenuDivider(),
          FushiPopupMenuItem<int>(
            value: -1,
            label: '${t.section_tabs_order_title}…',
            icon: FushiIcons.sort,
          ),
        ],
      ],
    );
    if (picked == null) return;
    if (picked < 0) {
      onReorder?.call();
      return;
    }
    if (picked < entries.length) entries[picked].onSelect();
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final double fontSize = titleStyle.fontSize ?? 17;
    return Builder(
      builder: (BuildContext anchor) => Actions(
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (ActivateIntent intent) {
              unawaited(_open(anchor));
              return null;
            },
          ),
        },
        child: FushiFocusTarget(
          id: FushiFocusId('$focusIdPrefix-title-menu'),
          child: Semantics(
            button: true,
            child: FushiPressScale(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  key: ValueKey<String>('$focusIdPrefix-title-menu'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => unawaited(_open(anchor)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      Flexible(child: title),
                      const SizedBox(width: 4),
                      FushiIcon(
                        FushiIcons.expandMore,
                        size: (fontSize * 0.7).clamp(14.0, 24.0),
                        color: apple.tertiaryLabel,
                        fontWeight: FontWeight.w700,
                      ),
                    ],
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
