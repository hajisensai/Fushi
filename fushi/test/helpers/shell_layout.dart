// 库页布局钉子（PR #3397 外壳改版）：2026-11-15 起产品默认是封面网格
// （[ShellContentLayout.defaultLayout]），钉子保留以免默认再变；守「封面网格」结构（SliverGrid 格子、
// 封面下 ShelfCardMeta、首屏主卡 FushiContinueSpotlight、横滚行卡宽……）的用例
// 显式钉回网格；拼贴下的同一批行为由各文件里显式切到 collage 的用例另行断言。
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show FushiShellTheme, ShellContentLayout;
import 'package:material_ui/material_ui.dart';

/// [base]（默认空 [ThemeData]）上叠一层 [FushiShellTheme]，库页布局钉成 [layout]。
ThemeData shellLayoutTheme(ShellContentLayout layout, {ThemeData? base}) {
  final ThemeData theme = base ?? ThemeData();
  // 不写显式元素类型的列表字面量：展开进 `<ThemeExtension<dynamic>>[...]` 时
  // CFE 报元素类型不匹配（analyzer 不报）。
  return theme.copyWith(
    extensions: theme.extensions.values.toList()
      ..add(FushiShellTheme(contentLayout: layout)),
  );
}

/// 钉成封面网格的主题。
ThemeData gridShellTheme({ThemeData? base}) =>
    shellLayoutTheme(ShellContentLayout.grid, base: base);
