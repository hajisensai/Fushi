import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_typography_panel.dart';

/// 歌词模式「Aa」文字快捷面板（2026-10）：入口在覆盖层控件条上，调字号写偏好并
/// 走热更样式通道（不重载歌词页）。
void main() {
  Widget host(Widget child) => MaterialApp(
    home: Scaffold(
      body: Center(child: SizedBox(width: 340, child: child)),
    ),
  );

  testWidgets('字号 ± 与键盘调节回调新值，竖排开关回调', (WidgetTester tester) async {
    final List<double> sizes = <double>[];
    final List<bool> verticals = <bool>[];
    int more = 0;
    await tester.pumpWidget(
      host(
        LyricsTypographyPanel(
          fontSize: 24,
          vertical: false,
          onFontSizeChanged: sizes.add,
          onVerticalChanged: verticals.add,
          onOpenMore: () => more++,
        ),
      ),
    );
    expect(find.byKey(kLyricsTypographyPanelKey), findsOneWidget);
    expect(find.text('24'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('lyrics_typography_font_plus')),
    );
    await tester.pump();
    expect(sizes, <double>[25]);
    expect(find.text('25'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('lyrics_typography_font_minus')),
    );
    await tester.pump();
    expect(sizes, <double>[25, 24]);
    // 滑块自动聚焦：→ 一档。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(sizes.last, 25);
    await tester.tap(
      find.byKey(const ValueKey<String>('lyrics_typography_vertical')),
    );
    await tester.pump();
    expect(verticals, <bool>[true]);
    await tester.tap(
      find.byKey(const ValueKey<String>('lyrics_typography_more')),
    );
    expect(more, 1);
  });

  test('字号写偏好后再热更样式（不重载）', () async {
    final List<String> calls = <String>[];
    await applyLyricsFontSize(
      value: 30,
      write: (double v) async => calls.add('write:$v'),
      applyLive: () async => calls.add('live'),
    );
    expect(calls, <String>['write:30.0', 'live']);
  });

  test('竖排写偏好后整页重建', () async {
    final List<String> calls = <String>[];
    await applyLyricsVertical(
      value: true,
      write: (bool v) async => calls.add('write:$v'),
      reload: () async => calls.add('reload'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls, <String>['write:true', 'reload']);
  });

  test('覆盖层两套设计都挂了 Aa 入口，页面接到热更通道', () {
    final String md3 = File(
      'lib/src/media/audiobook/lyrics_player/lyrics_player_md3.dart',
    ).readAsStringSync();
    final String apple = File(
      'lib/src/media/audiobook/lyrics_player/lyrics_player_apple.dart',
    ).readAsStringSync();
    expect(
      RegExp(r'_TypographyButton\(onTypography').allMatches(md3).length,
      2,
      reason: 'MD3 宽 / 窄两套控件条都要有 Aa',
    );
    expect(
      RegExp(r'_TypographyButton\(').allMatches(apple).length,
      greaterThanOrEqualTo(3),
      reason: 'Apple 宽 / 窄两套控件条 + 类定义',
    );
    final String page = File(
      'lib/src/pages/implementations/reader_fushi/lyrics.part.dart',
    ).readAsStringSync();
    expect(page, contains('onTypography: (LyricsMenuAnchor anchor)'));
    expect(page, contains('applyLive: _updateLyricsStyleLive'));
  });
}
