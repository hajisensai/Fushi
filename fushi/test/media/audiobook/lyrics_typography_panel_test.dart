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
    // 85857ec154 起歌词次要按钮布局化（[LyricsControlLayout]）：宽 / 窄控件条不再各写
    // 一份 `_TypographyButton(...)`，而是按布局区遍历同一个按钮工厂。不变量因此分三层钉：
    // ① 出厂宽 / 窄布局都把 Aa 摆在页上可见区（顶部或工具条，不收进 ⋯、不移出）；
    // ② 两套设计的按钮工厂里 Aa 分支确实画出接 onTypography 的入口；
    // ③ 两套设计的宽 / 窄控件条都经同一工厂渲染布局区（宽 = wideControls，窄 =
    //    compactControls），所以 ① 的出厂摆位真落到两套控件条上。
    for (final MapEntry<String, LyricsControlLayout> layout
        in <String, LyricsControlLayout>{
          'wide': LyricsControlLayout.defaults,
          'compact': LyricsControlLayout.compactDefaults,
        }.entries) {
      expect(
        <LyricsControlItem>[
          ...layout.value.itemsIn(LyricsControlSlot.top),
          ...layout.value.itemsIn(LyricsControlSlot.toolbar),
        ],
        contains(LyricsControlItem.typography),
        reason: '${layout.key} 出厂布局必须把 Aa 摆在控件条上（顶部或工具条）',
      );
    }

    final String md3 = File(
      'lib/src/media/audiobook/lyrics_player/lyrics_player_md3.dart',
    ).readAsStringSync();
    final String apple = File(
      'lib/src/media/audiobook/lyrics_player/lyrics_player_apple.dart',
    ).readAsStringSync();

    final String md3Factory = compactCode(
      switchCaseBody(
        topLevelFunctionBody(md3, '_md3ControlButton')!,
        'case LyricsControlItem.typography:',
        nextLabels: const <String>['case LyricsControlItem.'],
      ),
    );
    expect(
      md3Factory,
      contains('return_TypographyButton(onTypography:onTypography'),
      reason: 'MD3 按钮工厂的 Aa 分支必须画出接 onTypography 的 Aa 键',
    );
    final String appleFactory = compactCode(
      switchCaseBody(
        topLevelFunctionBody(apple, '_appleControlButtons')!,
        'case LyricsControlItem.typography:',
        nextLabels: const <String>['case LyricsControlItem.'],
      ),
    );
    expect(
      appleFactory,
      contains('onPressedWithRect:onTypography'),
      reason: 'Apple 按钮工厂的 Aa 分支必须画出接 onTypography 的 Aa 键',
    );

    final String md3Code = compactCode(md3);
    final String appleCode = compactCode(apple);
    for (final String form in <String>['wide', 'compact']) {
      // MD3：顶部区直接经工厂渲染，工具条区交给 _SecondaryActions（其体内同样走工厂）。
      expect(
        md3Code,
        contains(
          '_md3ControlButtons(data.${form}Controls.itemsIn(LyricsControlSlot.top',
        ),
        reason: 'MD3 $form 顶部要经按钮工厂渲染布局 top 区',
      );
      expect(
        md3Code,
        contains(
          '_SecondaryActions(data:data,callbacks:callbacks,'
          'items:data.${form}Controls.itemsIn(LyricsControlSlot.toolbar',
        ),
        reason: 'MD3 $form 播放卡工具条要渲染布局 toolbar 区',
      );
      for (final String slot in <String>['top', 'toolbar']) {
        expect(
          appleCode,
          contains(
            '_appleControlButtons(data.${form}Controls.itemsIn(LyricsControlSlot.$slot',
          ),
          reason: 'Apple $form 控件条要经按钮工厂渲染布局 $slot 区',
        );
      }
    }
    expect(
      compactCode(
        methodBody(
          md3.substring(md3.indexOf('class _SecondaryActions')),
          'Widget build(BuildContext context)',
        ),
      ),
      contains('..._md3ControlButtons(items,data,callbacks,'),
      reason: 'MD3 工具条 _SecondaryActions 必须经同一按钮工厂渲染它拿到的布局区',
    );
    final String page = File(
      'lib/src/pages/implementations/reader_fushi/lyrics.part.dart',
    ).readAsStringSync();
    expect(page, contains('onTypography: (LyricsMenuAnchor anchor)'));
    expect(page, contains('applyLive: _updateLyricsStyleLive'));
  });
}
