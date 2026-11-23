// rethemeFushiWithScheme 重走工厂时没把外壳样式传回去：工厂缺省的
// const FushiShellTheme() 在扩展合并里排在后面，盖掉了用户那份。重新取色的子树
// （色块取色 FushiBlockColorScope、歌词、视频面板、遥控页）里平滑圆角、侧栏样式、
// 库页布局、色块摆放都被打回默认。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  const FushiShellTheme custom = FushiShellTheme(
    railStyle: ShellRailStyle.spine,
    contentLayout: ShellContentLayout.grid,
    blockArrangement: ShellBlockArrangement.scattered,
    smoothCorners: false,
  );
  final ColorScheme recolor = ColorScheme.fromSeed(seedColor: Colors.orange);

  ThemeData base({required bool glassDesign}) => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
    textTheme: const TextTheme(),
    glassDesign: glassDesign,
    shell: custom,
  );

  for (final bool glassDesign in <bool>[false, true]) {
    final String label = glassDesign ? 'glass' : 'material';

    test('$label: reschemed theme keeps the user shell theme', () {
      final ThemeData rebuilt = rethemeFushiWithScheme(
        base(glassDesign: glassDesign),
        recolor,
      );
      expect(rebuilt.extension<FushiShellTheme>(), custom);
    });

    test('$label: baked component shapes follow the user smoothCorners', () {
      final ThemeData original = base(glassDesign: glassDesign);
      final ThemeData rebuilt = rethemeFushiWithScheme(original, recolor);
      final ThemeData defaults = buildFushiThemeData(
        scheme: recolor,
        textTheme: const TextTheme(),
        glassDesign: glassDesign,
      );
      // 与用户的（smoothCorners: false）同形，而不是与工厂缺省（平滑）同形。
      expect(
        rebuilt.cardTheme.shape.runtimeType,
        original.cardTheme.shape.runtimeType,
      );
      expect(
        rebuilt.cardTheme.shape.runtimeType,
        isNot(defaults.cardTheme.shape.runtimeType),
      );
    });
  }
}
