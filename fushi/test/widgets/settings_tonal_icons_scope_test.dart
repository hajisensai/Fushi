import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

/// 着色图标作用域（视频播放器面板去灰，2026-10-14）：作用域内 MD3 行首图标画成
/// M3E 色调容器上的色块；作用域外保持全局设置页的单色字形不变。
Widget _row({SettingsTonalIconTone? tone}) {
  final Widget row = Scaffold(
    body: AdaptiveSettingsSwitchRow(
      title: 'Tap to pause',
      icon: Icons.touch_app,
      showIcon: true,
      value: true,
      onChanged: (_) {},
    ),
  );
  return MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      platform: TargetPlatform.android,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF6750A4),
        brightness: Brightness.dark,
      ),
    ),
    home: tone == null ? row : SettingsTonalIconsScope(tone: tone, child: row),
  );
}

Iterable<Color?> _iconBlockFills(WidgetTester tester) => tester
    .widgetList<DecoratedBox>(
      find.ancestor(
        of: find.byIcon(Icons.touch_app),
        matching: find.byType(DecoratedBox),
      ),
    )
    .map((DecoratedBox box) => (box.decoration as BoxDecoration?)?.color);

void main() {
  testWidgets('outside the scope the row icon keeps the plain glyph', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_row());
    final ColorScheme cs = Theme.of(
      tester.element(find.byIcon(Icons.touch_app)),
    ).colorScheme;
    for (final Color? fill in _iconBlockFills(tester)) {
      expect(
        fill,
        isNot(anyOf(cs.primaryContainer, cs.secondaryContainer)),
        reason: '全局设置页不受着色作用域影响',
      );
    }
  });

  for (final SettingsTonalIconTone tone in SettingsTonalIconTone.values) {
    testWidgets(
      'inside the scope the icon sits on the ${tone.name} container',
      (WidgetTester tester) async {
        await tester.pumpWidget(_row(tone: tone));
        final ColorScheme cs = Theme.of(
          tester.element(find.byIcon(Icons.touch_app)),
        ).colorScheme;
        final Color expected = switch (tone) {
          SettingsTonalIconTone.primary => cs.primaryContainer,
          SettingsTonalIconTone.secondary => cs.secondaryContainer,
          SettingsTonalIconTone.tertiary => cs.tertiaryContainer,
        };
        expect(_iconBlockFills(tester), contains(expected));
      },
    );
  }

  test('section tone is stable per section id and spreads across tones', () {
    expect(
      SettingsTonalIconsScope.toneForSection('video.subtitle.appearance'),
      SettingsTonalIconsScope.toneForSection('video.subtitle.appearance'),
    );
    final Set<SettingsTonalIconTone> tones = <SettingsTonalIconTone>{
      for (final String id in <String>[
        'playback',
        'gestures',
        'display',
        'hdr',
        'audio',
        'subtitle',
        'danmaku',
        'controls',
      ])
        SettingsTonalIconsScope.toneForSection(id),
    };
    expect(tones.length, greaterThan(1), reason: '相邻分组应能错开色调');
  });
}
