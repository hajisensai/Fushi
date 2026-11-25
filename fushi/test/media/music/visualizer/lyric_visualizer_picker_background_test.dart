// 选择面板的「背景设置」入口对的是当前样式实际画的背景（样式请求专属背景时调那个）。

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/pages/implementations/music/music_lyric_visualizer_view.dart';

Future<void> _openPicker(
  WidgetTester tester,
  LyricVisualizerMode current,
  String backgroundId,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => Center(
            child: GestureDetector(
              key: const ValueKey<String>('open'),
              behavior: HitTestBehavior.opaque,
              onTap: () => showLyricVisualizerPicker(
                context: context,
                current: current,
                random: false,
                tunings: const <String, Map<String, Object?>>{},
                onTuningsChanged: (_, _) async {},
                backgroundId: backgroundId,
              ),
              child: const SizedBox(width: 40, height: 40),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey<String>('open')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('莫奈样式：背景设置调莫奈背景，不管用户选了哪个共享背景', (WidgetTester tester) async {
    await _openPicker(tester, LyricVisualizerMode.monet, 'solid');
    final Finder button = find.byKey(
      const ValueKey<String>('music_visualizer_background_tuning'),
    );
    expect(button, findsOneWidget);
    expect(
      find.descendant(
        of: button,
        matching: find.textContaining(t.music_visualizer_background_monet),
      ),
      findsOneWidget,
    );
  });

  testWidgets('跟随共享背景的样式：背景设置调用户选的那个', (WidgetTester tester) async {
    await _openPicker(tester, LyricVisualizerMode.luminous, 'monet');
    expect(
      find.descendant(
        of: find.byKey(
          const ValueKey<String>('music_visualizer_background_tuning'),
        ),
        matching: find.textContaining(t.music_visualizer_background_monet),
      ),
      findsOneWidget,
    );
  });
}
