import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';

/// 浏览页工具栏（地址栏一行）的底色。贴着网页的功能侧栏（字幕列表）也用它，
/// 让侧栏读作浏览器 chrome 的延伸，而不是另一张带色调的卡片。
Color webBrowserBarColor(BuildContext context) => isGlassDesign(context)
    ? appleColorsOf(context).secondaryGroupedBackground
    : Theme.of(context).colorScheme.surfaceContainer;
