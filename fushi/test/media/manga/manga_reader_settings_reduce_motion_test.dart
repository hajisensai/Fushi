import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_settings_sheet.dart';

/// 系统「减弱动态效果」下动效 token 归零（`fushiMotionDuration` → zero）。
/// 作用域条右侧的「重置」按钮随作用域显隐：零时长 [AnimatedSize] 在子尺寸变化
/// 时会在自身 performLayout 里重新弄脏自己，debug 下断言（BUG-3022 同源）。
void main() {
  testWidgets('reduce motion: switching scope resizes reset slot without '
      'layout assertions', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(400, 800),
            disableAnimations: true,
          ),
          child: Scaffold(
            body: SizedBox(
              width: 400,
              child: MangaReaderSettingsSheet(
                globalDefaults: const MangaReaderPreferences(),
                overrides: const <String, Object?>{'invertColors': true},
                onChanged: (Map<String, Object?> next) async {},
                onGlobalChanged: (Map<String, Object?> patch) async {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('manga_reader_restore')),
      findsOneWidget,
    );
    await tester.tap(find.text('Global'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('manga_reader_restore')),
      findsNothing,
    );
    await tester.tap(find.text('This title'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('manga_reader_restore')),
      findsOneWidget,
    );
  });
}
