import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/library_layout/library_grid_zoom.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_page_masthead.dart'
    show fushiMastheadCompact;
import 'package:fushi/src/utils/components/glass/fushi_apple_bar_cluster.dart'
    show FushiAppleBarCluster;
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart'
    show appleColorsOf;
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show FushiMenuAnchor;
import 'package:fushi/src/utils/fushi_icons.dart';

/// Apple 库页导航栏的「每行数量」钮（2026-11-24 用户：缩放滑杆不要裸露在
/// 工具栏里，一个按钮按出来再弹出滑杆）：与「导入」同一形态的中性玻璃圆钮
/// （[FushiAppleBarCluster]，窄窗 44 / 宽窗 36，tooltip + Semantics 由
/// [FushiIconButton] 给），点开在按钮下沿弹出 Apple 玻璃菜单面板
/// （[FushiMenuAnchor]），里面是「小图标 + 滑杆 + 大图标」
/// （[LibraryGridZoomSlider]）。点外部 / Esc 关闭；滑杆即时写回，不关面板。
///
/// 双指捏合与 ⌘ / Ctrl ± 快捷键在 [LibraryGridZoom] 上，与本钮无关。只在
/// Apple 外壳（[AppleLibraryLayout]）里出现。
class AppleLibraryZoomButton extends StatefulWidget {
  const AppleLibraryZoomButton({required this.port, super.key});

  final LibraryGridZoomPort port;

  @override
  State<AppleLibraryZoomButton> createState() => _AppleLibraryZoomButtonState();
}

class _AppleLibraryZoomButtonState extends State<AppleLibraryZoomButton> {
  final MenuController _menu = MenuController();

  @override
  Widget build(BuildContext context) {
    if (widget.port.choices.toSet().length < 2) return const SizedBox.shrink();
    return FushiMenuAnchor(
      controller: _menu,
      menuChildren: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: LibraryGridZoomSlider(port: widget.port),
        ),
      ],
      builder: (BuildContext context, MenuController menu, Widget? _) =>
          FushiAppleBarCluster(
            compact: fushiMastheadCompact(context),
            items: <Widget>[
              FushiIconButton(
                key: const ValueKey<String>('library-grid-zoom-button'),
                icon: FushiIcons.gridView,
                tooltip: t.library_grid_columns,
                selected: menu.isOpen,
                alwaysVisible: true,
                onTap: () => menu.isOpen ? menu.close() : menu.open(),
                shapeBorder: const CircleBorder(),
                backgroundColor: Colors.transparent,
                enabledColor: appleColorsOf(context).label,
              ),
            ],
          ),
    );
  }
}
