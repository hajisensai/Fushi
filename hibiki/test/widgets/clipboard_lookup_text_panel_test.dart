import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/clipboard_lookup_text_panel.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

void main() {
  Widget buildSubject({
    required String text,
    required void Function(String query, Rect rect) onLookup,
    TextStyle? headwordTextStyle,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: ClipboardLookupTextPanel(
          text: text,
          onLookup: onLookup,
          headwordTextStyle: headwordTextStyle,
        ),
      ),
    );
  }

  testWidgets('tapping a character looks up the suffix from that character',
      (WidgetTester tester) async {
    String? query;
    Rect? rect;

    await tester.pumpWidget(
      buildSubject(
        text: 'abcdef',
        onLookup: (String value, Rect localRect) {
          query = value;
          rect = localRect;
        },
      ),
    );

    await tester.tap(find.text('c'));

    expect(query, 'cdef');
    expect(rect, isNotNull);
    expect(rect, isNot(Rect.zero));
  });

  testWidgets('shift-hover looks up the suffix under the pointer',
      (WidgetTester tester) async {
    String? query;
    Rect? rect;

    await tester.pumpWidget(
      buildSubject(
        text: 'abcdef',
        onLookup: (String value, Rect localRect) {
          query = value;
          rect = localRect;
        },
      ),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final TestGesture mouse =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.text('c')));
    await tester.pump();
    await mouse.moveTo(tester.getCenter(find.text('c')));
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await mouse.removePointer();

    expect(query, 'cdef');
    expect(rect, isNotNull);
    expect(rect, isNot(Rect.zero));
  });

  testWidgets('tap rect is reported in the nearest stack coordinate space',
      (WidgetTester tester) async {
    Rect? rect;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              Positioned(
                left: 40,
                top: 30,
                child: ClipboardLookupTextPanel(
                  text: 'abc',
                  onLookup: (_, Rect localRect) {
                    rect = localRect;
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('a'));

    expect(rect, isNotNull);
    expect(rect!.left, greaterThanOrEqualTo(40));
    expect(rect!.top, greaterThanOrEqualTo(30));
    expect(rect!.width, greaterThan(0));
    expect(rect!.height, greaterThan(0));
  });

  testWidgets('blank text renders nothing and cannot trigger lookup',
      (WidgetTester tester) async {
    bool called = false;

    await tester.pumpWidget(
      buildSubject(
        text: '   ',
        onLookup: (_, __) => called = true,
      ),
    );

    expect(find.byType(ClipboardLookupTextPanel), findsOneWidget);
    expect(find.byType(GestureDetector), findsNothing);
    expect(called, isFalse);
  });

  testWidgets('external lookup text renders as an unframed strip',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      buildSubject(
        text: 'abcdef',
        onLookup: (_, __) {},
      ),
    );

    expect(find.byType(ClipboardLookupTextPanel), findsOneWidget);
    expect(find.byType(HibikiCard), findsNothing);
  });

  // BUG-175：剪贴板查词文字「小的可怜」。回归守卫——字号必须是正文级别
  // （bodyLarge≈16），不能退回到 metadata 的 labelMedium（≈12）小字。
  testWidgets('characters render at body-size font, not tiny metadata size',
      (WidgetTester tester) async {
    late final ThemeData theme;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              theme = Theme.of(context);
              return ClipboardLookupTextPanel(
                text: 'あ',
                onLookup: (_, __) {},
              );
            },
          ),
        ),
      ),
    );

    final Text rendered = tester.widget<Text>(find.text('あ'));
    final double? fontSize = rendered.style?.fontSize;
    final double bodyLarge = theme.textTheme.bodyLarge?.fontSize ?? 16;
    final double labelMedium = theme.textTheme.labelMedium?.fontSize ?? 12;

    expect(fontSize, isNotNull);
    // 字号取正文 bodyLarge，明显大于此前的 labelMedium 小字。
    expect(fontSize, equals(bodyLarge));
    expect(fontSize, greaterThan(labelMedium));
  });

  testWidgets('characters can render with caller-provided headword style',
      (WidgetTester tester) async {
    const TextStyle headwordStyle = TextStyle(
      fontSize: 26,
      fontWeight: FontWeight.w600,
    );

    await tester.pumpWidget(
      buildSubject(
        text: 'あ',
        onLookup: (_, __) {},
        headwordTextStyle: headwordStyle,
      ),
    );

    final Text rendered = tester.widget<Text>(find.text('あ'));

    expect(rendered.style?.fontSize, 26);
    expect(rendered.style?.fontWeight, FontWeight.w600);
  });

  // BUG-175：剪贴板查词文字「默认居中了」。回归守卫——本组件占满父级宽度并
  // 把内容左对齐，不依赖父级 Column 的 crossAxisAlignment。
  testWidgets('panel fills width and left-aligns its content',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            // 模拟 home_dictionary_page 把本条挂在默认居中的 Column 下。
            children: <Widget>[
              ClipboardLookupTextPanel(
                text: 'あいう',
                onLookup: (_, __) {},
              ),
            ],
          ),
        ),
      ),
    );

    // 占满父级宽度：本组件最外层撑满整屏宽。
    final double screenWidth = tester.getSize(find.byType(Scaffold)).width;
    final double panelWidth =
        tester.getSize(find.byType(ClipboardLookupTextPanel)).width;
    expect(panelWidth, equals(screenWidth));

    // 左对齐：第一个字符紧贴 16px 左内边距，不被居中推到屏幕中间。
    final double firstCharLeft = tester.getTopLeft(find.text('あ')).dx;
    expect(firstCharLeft, lessThan(screenWidth / 4));

    // Align 把内容钉在左上角。
    final Align align = tester.widget<Align>(
      find
          .descendant(
            of: find.byType(ClipboardLookupTextPanel),
            matching: find.byType(Align),
          )
          .first,
    );
    expect(align.alignment, Alignment.topLeft);
  });
}
