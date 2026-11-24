import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_page_masthead.dart'
    show fushiMastheadCompact;
import 'package:fushi/src/utils/components/glass/fushi_apple_bar_cluster.dart'
    show FushiAppleBarCluster;
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart'
    show appleColorsOf;
import 'package:fushi/src/utils/fushi_icons.dart';

/// Apple 库页导航栏的「导入」钮：iOS 27 导航栏的中性玻璃圆钮
/// （[FushiAppleBarCluster]，`separate`、不着强调色，label 色图标；窄窗 44 /
/// 宽窗 36），与右侧其它动作同一形态。切换型：停在导入页时呈选中态。
///
/// 只在 Apple 设计系统下出现（[AppleLibraryLayout]、以及尚未迁到
/// `LibraryLayout` 的库页经 `libraryImportChromeButton` 的 Apple 分支）。
class AppleLibraryImportButton extends StatelessWidget {
  const AppleLibraryImportButton({
    required this.selected,
    required this.onTap,
    super.key,
  });

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool compact = fushiMastheadCompact(context);
    return FushiAppleBarCluster(
      compact: compact,
      items: <Widget>[
        FushiIconButton(
          icon: FushiIcons.libraryAdd,
          tooltip: t.library_view_import,
          selected: selected,
          alwaysVisible: true,
          onTap: onTap,
          shapeBorder: const CircleBorder(),
          backgroundColor: Colors.transparent,
          enabledColor: appleColorsOf(context).label,
        ),
      ],
    );
  }
}
