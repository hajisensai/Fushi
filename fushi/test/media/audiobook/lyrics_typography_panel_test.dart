import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_control_layout.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_typography_panel.dart';

import '../../helpers/source_guard.dart';

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
    // 2026-10-25（#2523）次要按钮改由 [LyricsControlLayout] 驱动：宽 / 窄各一份
    // 布局，两套设计都经同一个按钮工厂按区渲染。「宽 / 窄都有 Aa」于是拆成三件事：
    // ① 出厂宽 / 窄布局都把 Aa 摆在可见区（不是 ⋯ / 移出）；
    for (final (String name, LyricsControlLayout layout)
        in <(String, LyricsControlLayout)>[
          ('宽屏', LyricsControlLayout.defaults),
          ('窄屏', LyricsControlLayout.compactDefaults),
        ]) {
      expect(
        <LyricsControlSlot>[LyricsControlSlot.top, LyricsControlSlot.toolbar],
        contains(layout.core.slotOf(LyricsControlItem.typography)),
        reason: '$name出厂布局必须把 Aa 摆在顶部或播放卡工具条',
      );
    }
    // ② 两套设计的按钮工厂把 typography 项接到 onTypography 回调；
    final String md3Code = compactCode(md3);
    final String appleCode = compactCode(apple);
    expect(
      md3Code,
      contains(
        'caseLyricsControlItem.typography:'
        'finalValueChanged<LyricsMenuAnchor>?onTypography=callbacks.onTypography;'
        'if(onTypography==null)returnnull;'
        'return_TypographyButton(onTypography:onTypography',
      ),
      reason: 'MD3 按钮工厂必须把 Aa 项渲染成 _TypographyButton',
    );
    expect(
      appleCode,
      contains(
        'caseLyricsControlItem.typography:'
        'finalValueChanged<LyricsMenuAnchor>?onTypography=callbacks.onTypography;'
        'if(onTypography==null)returnnull;',
      ),
      reason: 'Apple 按钮工厂必须处理 Aa 项',
    );
    expect(
      appleCode,
      contains('onPressedWithRect:onTypography'),
      reason: 'Apple Aa 键按下要回调 onTypography',
    );
    // ③ 两套设计的宽 / 窄控件条都把两个可见区（顶部 + 工具条）交给按钮工厂。
    for (final (String design, String code, String factory)
        in <(String, String, String)>[
          ('MD3', md3Code, '_md3ControlButtons('),
          ('Apple', appleCode, '_appleControlButtons('),
        ]) {
      for (final String controls in <String>[
        'wideControls',
        'compactControls',
      ]) {
        for (final String slot in <String>['top', 'toolbar']) {
          final String zone = 'data.$controls.itemsIn(LyricsControlSlot.$slot';
          expect(
            code,
            contains(zone),
            reason: '$design 要渲染 $controls 的 $slot 区',
          );
        }
      }
      expect(code, contains(factory), reason: '$design 经共享按钮工厂渲染');
    }
    final String page = File(
      'lib/src/pages/implementations/reader_fushi/lyrics.part.dart',
    ).readAsStringSync();
    expect(page, contains('onTypography: (LyricsMenuAnchor anchor)'));
    expect(page, contains('applyLive: _updateLyricsStyleLive'));
  });
}
