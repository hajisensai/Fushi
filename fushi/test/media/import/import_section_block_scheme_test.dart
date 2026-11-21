// BUG-5055：从深色主方式块（「导入书」反色块）弹出的导入对话框里，浅色表单
// 色块 [ImportSectionBlock] 上的输入字 / 下拉值读的是外层深色块的主题
// （浅色字），压在浅色块上看不见。表单块必须下发自己的块配色。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/import/import_dialog_blocks.dart';
import 'package:fushi/src/media/import/import_surface_spec.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/components/fushi_block_color_scope.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';

void main() {
  for (final Brightness brightness in Brightness.values) {
    testWidgets('${brightness.name}：深色外层块里的表单块，子树主题取表单块自己的配色', (
      WidgetTester tester,
    ) async {
      final ThemeData theme = buildFushiThemeData(
        scheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6750A4),
          brightness: brightness,
        ),
        textTheme: const TextTheme(),
        glassDesign: false,
      );
      const Key field = ValueKey<String>('field');
      late FushiCoverBlockColors outer;
      late FushiCoverBlockColors inner;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) {
                outer = importToneColors(
                  context,
                  ImportTone.coral,
                  inverse: true,
                );
                return FushiBlockColorScope(
                  colors: outer,
                  child: Builder(
                    builder: (BuildContext scoped) {
                      inner = importToneColors(scoped, ImportTone.coral);
                      return const ImportSectionBlock(
                        tone: ImportTone.coral,
                        children: <Widget>[TextField(key: field)],
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ),
      );
      // 前提：外层（反色）与表单块前景确实不同，否则测不出问题。
      expect(outer.onContainer, isNot(inner.onContainer));
      final ThemeData fieldTheme = Theme.of(tester.element(find.byKey(field)));
      expect(fieldTheme.colorScheme.onSurface, inner.onContainer);
      expect(fieldTheme.colorScheme.surface, inner.container);
      final EditableText editable = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(field),
          matching: find.byType(EditableText),
        ),
      );
      expect(editable.style.color, inner.onContainer);
    });
  }
}
