import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/clipboard_lookup_text_panel.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/misc/lookup_input_limits.dart';

void main() {
  Widget buildSubject({
    required String text,
    required void Function(String query, Rect rect, int charIndex) onLookup,
    double dictionaryHeadwordScale = 1.0,
    SourceLookupHighlight? highlight,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SourceLookupTextPanel(
          text: text,
          onLookup: onLookup,
          dictionaryHeadwordScale: dictionaryHeadwordScale,
          highlight: highlight,
        ),
      ),
    );
  }

  /// 本条内画在某个字底下的高亮框（条外的 Material chrome 也有 DecoratedBox，
  /// 必须先限定在本条子树里再往上找祖先）。
  Finder highlightBoxOf(String char) => find.ancestor(
        of: find.text(char),
        matching: find.descendant(
          of: find.byType(SourceLookupTextPanel),
          matching: find.byType(DecoratedBox),
        ),
      );

  Finder allHighlightBoxes() => find.descendant(
        of: find.byType(SourceLookupTextPanel),
        matching: find.byType(DecoratedBox),
      );

  testWidgets('tapping a character looks up the suffix from that character',
      (WidgetTester tester) async {
    String? query;
    Rect? rect;

    await tester.pumpWidget(
      buildSubject(
        text: 'abcdef',
        onLookup: (String value, Rect localRect, int _) {
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
        onLookup: (String value, Rect localRect, int _) {
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
                child: SourceLookupTextPanel(
                  text: 'abc',
                  onLookup: (_, Rect localRect, __) {
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
        onLookup: (_, __, ___) => called = true,
      ),
    );

    expect(find.byType(SourceLookupTextPanel), findsOneWidget);
    expect(find.byType(GestureDetector), findsNothing);
    expect(called, isFalse);
  });

  testWidgets('external lookup text renders as an unframed strip',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      buildSubject(
        text: 'abcdef',
        onLookup: (_, __, ___) {},
      ),
    );

    expect(find.byType(SourceLookupTextPanel), findsOneWidget);
    expect(find.byType(FushiCard), findsNothing);
  });

  testWidgets('generic source lookup panel has no clipboard-only identity',
      (WidgetTester tester) async {
    String? query;

    await tester.pumpWidget(
      buildSubject(
        text: 'abcdef',
        onLookup: (String value, Rect _, int __) {
          query = value;
        },
      ),
    );

    expect(find.byType(SourceLookupTextPanel), findsOneWidget);
    expect(find.textContaining('Clipboard'), findsNothing);
    expect(find.textContaining('剪贴板'), findsNothing);

    await tester.tap(find.text('d'));

    expect(query, 'def');
  });

  // BUG-175 / TODO-222：剪贴板查词标题必须和词典弹窗 headword 标题同级，
  // 不能退回到 metadata 的 labelMedium（≈12）或普通 bodyLarge（≈16）小字。
  testWidgets('characters render at dictionary headword title size',
      (WidgetTester tester) async {
    late final ThemeData theme;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              theme = Theme.of(context);
              return SourceLookupTextPanel(
                text: 'あ',
                onLookup: (_, __, ___) {},
              );
            },
          ),
        ),
      ),
    );

    final Text rendered = tester.widget<Text>(find.text('あ'));
    final double? fontSize = rendered.style?.fontSize;
    final double labelMedium = theme.textTheme.labelMedium?.fontSize ?? 12;

    expect(fontSize, isNotNull);
    expect(fontSize, 26);
    expect(rendered.style?.fontWeight, FontWeight.w600);
    expect(fontSize, greaterThan(labelMedium));
    expect(fontSize, greaterThan(theme.textTheme.bodyLarge?.fontSize ?? 16));
  });

  testWidgets('characters scale with the dictionary font ratio',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      buildSubject(
        text: 'あ',
        onLookup: (_, __, ___) {},
        dictionaryHeadwordScale: 1.5,
      ),
    );

    final Text rendered = tester.widget<Text>(find.text('あ'));

    expect(rendered.style?.fontSize, 39);
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
              SourceLookupTextPanel(
                text: 'あいう',
                onLookup: (_, __, ___) {},
              ),
            ],
          ),
        ),
      ),
    );

    // 占满父级宽度：本组件最外层撑满整屏宽。
    final double screenWidth = tester.getSize(find.byType(Scaffold)).width;
    final double panelWidth =
        tester.getSize(find.byType(SourceLookupTextPanel)).width;
    expect(panelWidth, equals(screenWidth));

    // 左对齐：第一个字符紧贴 16px 左内边距，不被居中推到屏幕中间。
    final double firstCharLeft = tester.getTopLeft(find.text('あ')).dx;
    expect(firstCharLeft, lessThan(screenWidth / 4));

    // Align 把内容钉在左上角。
    final Align align = tester.widget<Align>(
      find
          .descendant(
            of: find.byType(SourceLookupTextPanel),
            matching: find.byType(Align),
          )
          .first,
    );
    expect(align.alignment, Alignment.topLeft);
  });

  // BUG-442：超长剪贴板文本逐字符建可点 widget 会把主 isolate 撑爆。面板必须对
  // 渲染字符数硬截断到 kMaxLookupInputChars（即便上游漏截断，渲染层永不爆）。
  testWidgets('caps rendered characters to kMaxLookupInputChars (BUG-442)',
      (WidgetTester tester) async {
    final String longText = 'あ' * 10000;

    await tester.pumpWidget(
      buildSubject(
        text: longText,
        onLookup: (_, __, ___) {},
      ),
    );
    await tester.pump();

    // 不抛异常（pumpWidget 已经过）且可点字符数被钳到上限。
    final int gestureCount = find.byType(GestureDetector).evaluate().length;
    expect(gestureCount, lessThanOrEqualTo(kMaxLookupInputChars));
    expect(gestureCount, kMaxLookupInputChars,
        reason: '超过上限的输入应渲染恰好 kMaxLookupInputChars 个可点字符');
    expect(tester.takeException(), isNull);
  });

  testWidgets('lookup suffix is computed from the capped text (BUG-442)',
      (WidgetTester tester) async {
    String? query;
    // 上限个 'あ' 后跟一段永远不会被渲染的尾巴。点第一个可见字符 → 后缀必须是
    // 截断后的全部 kMax 个 'あ'，绝不能把被裁掉的尾部 'X...' 带进查询。
    final String tail = 'X' * 50;
    final String longText = '${'あ' * kMaxLookupInputChars}$tail';

    await tester.pumpWidget(
      buildSubject(
        text: longText,
        onLookup: (String value, Rect _, int __) {
          query = value;
        },
      ),
    );
    await tester.pump();

    final Finder visibleChars = find.text('あ');
    expect(visibleChars, findsWidgets);
    // 第一个字符总在视口内，点它取整段后缀（= 截断后的全部可点字符）。
    await tester.tap(visibleChars.first, warnIfMissed: false);

    expect(query, isNotNull);
    expect(query!.characters.length, kMaxLookupInputChars,
        reason: '后缀长度 = 截断后的字符数，被裁掉的尾部不计入');
    expect(query, isNot(contains('X')), reason: '后缀绝不能包含被裁掉的尾部');
  });

  // ── Yomitan 式扫描高亮 ───────────────────────────────────────────────

  testWidgets('highlight boxes exactly the matched span and nothing else',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      buildSubject(
        text: 'と言いつつ',
        onLookup: (_, __, ___) {},
        // 点第 1 个字（言）查「言いつつ」，引擎命中「言い」两个字。
        highlight: const SourceLookupHighlight(start: 1, length: 2),
      ),
    );

    expect(allHighlightBoxes(), findsNWidgets(2), reason: '只框住命中的两个字');
    expect(highlightBoxOf('言'), findsOneWidget);
    expect(highlightBoxOf('い'), findsOneWidget);
    expect(highlightBoxOf('と'), findsNothing, reason: '命中段之前的字不该被框');
    expect(highlightBoxOf('つ'), findsNothing, reason: '命中段之后的字不该被框');
  });

  testWidgets('no highlight parameter leaves the strip completely unboxed',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      buildSubject(text: 'と言いつつ', onLookup: (_, __, ___) {}),
    );

    expect(allHighlightBoxes(), findsNothing);
  });

  testWidgets(
      'highlight uses the popup in-card highlight color and only rounds the '
      'outer corners', (WidgetTester tester) async {
    late final ThemeData theme;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              theme = Theme.of(context);
              return SourceLookupTextPanel(
                text: 'あいう',
                onLookup: (_, __, ___) {},
                highlight: const SourceLookupHighlight(start: 0, length: 3),
              );
            },
          ),
        ),
      ),
    );

    BoxDecoration decorationOf(String char) =>
        tester.widget<DecoratedBox>(highlightBoxOf(char)).decoration
            as BoxDecoration;

    // 与 WebView 卡片内的 `--fushi-primary-highlight` 同色
    // （popup_theme_css.dart 的 cssRgba035(scheme.primary)）。
    expect(
      decorationOf('あ').color,
      theme.colorScheme.primary.withValues(alpha: 0.35),
    );

    const Radius corner = Radius.circular(FushiRadii.chipValue);
    final BorderRadius first = decorationOf('あ').borderRadius! as BorderRadius;
    final BorderRadius middle = decorationOf('い').borderRadius! as BorderRadius;
    final BorderRadius last = decorationOf('う').borderRadius! as BorderRadius;
    expect(first.topLeft, corner);
    expect(first.topRight, Radius.zero, reason: '首字右侧要与下一个字严丝合缝');
    expect(middle.topLeft, Radius.zero);
    expect(middle.topRight, Radius.zero, reason: '中间的字两侧都不能收圆角');
    expect(last.topLeft, Radius.zero);
    expect(last.topRight, corner);
  });

  testWidgets(
      'single-character match still renders one box with both corners rounded',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      buildSubject(
        text: 'あいう',
        onLookup: (_, __, ___) {},
        highlight: const SourceLookupHighlight(start: 1, length: 1),
      ),
    );

    expect(allHighlightBoxes(), findsNWidgets(1));
    final BorderRadius radius = (tester
            .widget<DecoratedBox>(highlightBoxOf('い'))
            .decoration as BoxDecoration)
        .borderRadius! as BorderRadius;
    const Radius corner = Radius.circular(FushiRadii.chipValue);
    expect(radius.topLeft, corner);
    expect(radius.topRight, corner);
  });

  testWidgets('out-of-range highlight is inert instead of throwing',
      (WidgetTester tester) async {
    // 源文本被换短、旧高亮还没来得及重算的那一帧。
    await tester.pumpWidget(
      buildSubject(
        text: 'あ',
        onLookup: (_, __, ___) {},
        highlight: const SourceLookupHighlight(start: 5, length: 3),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(allHighlightBoxes(), findsNothing);
  });

  group('SourceLookupScan.fromSuffix（后缀 → 查询串 + 高亮锚）', () {
    test('普通后缀原样带过，锚就是被点的那个字', () {
      final SourceLookupScan scan = SourceLookupScan.fromSuffix(
        suffix: '言いつつ',
        charIndex: 1,
      );
      expect(scan.query, '言いつつ');
      expect(scan.charIndex, 1);
    });

    test('串首空白折进锚：查词管线会 trim，锚不跟着右移就框在空白上', () {
      final SourceLookupScan scan = SourceLookupScan.fromSuffix(
        suffix: '  hello world',
        charIndex: 5,
      );
      expect(scan.query, 'hello world');
      expect(scan.charIndex, 7, reason: '5 + 两个空白字素簇');
    });

    test('全空白后缀不产出查询串（宿主据此早退，不发空查询）', () {
      final SourceLookupScan scan = SourceLookupScan.fromSuffix(
        suffix: '   ',
        charIndex: 3,
      );
      expect(scan.query, isEmpty);
    });

    test('串尾空白只影响查询串，不影响锚', () {
      final SourceLookupScan scan = SourceLookupScan.fromSuffix(
        suffix: 'あい  ',
        charIndex: 2,
      );
      expect(scan.query, 'あい');
      expect(scan.charIndex, 2);
    });
  });

  group('resolveSourceLookupHighlight（UTF-16 匹配长度 → 字素簇跨度）', () {
    test('从被点的字起，按引擎匹配长度框住整词', () {
      // 「と言いつつ」上点第 0 个字：查询串是整条，引擎命中「と言い」(3 unit)。
      expect(
        resolveSourceLookupHighlight(
          query: 'と言いつつ',
          tappedGraphemeIndex: 0,
          matchedUnits: 3,
          leadingStripUnits: 0,
        ),
        const SourceLookupHighlight(start: 0, length: 3),
      );
      // 点第 1 个字：查询串只剩后缀，命中「言い」——起点必须回到条上的绝对下标 1。
      expect(
        resolveSourceLookupHighlight(
          query: '言いつつ',
          tappedGraphemeIndex: 1,
          matchedUnits: 2,
          leadingStripUnits: 0,
        ),
        const SourceLookupHighlight(start: 1, length: 2),
      );
      expect(
        resolveSourceLookupHighlight(
          query: 'つつ',
          tappedGraphemeIndex: 3,
          matchedUnits: 2,
          leadingStripUnits: 0,
        ),
        const SourceLookupHighlight(start: 3, length: 2),
      );
    });

    test('句首标点被引擎剥掉时高亮右移那段长度（BUG-773 同一个坑）', () {
      // normalizeSearchTerm 把「「」剥掉后才去匹配，bestLength 以剥离串为坐标系；
      // 条上显示的是原串，不右移就会左吞括号、右缺词尾。
      expect(
        resolveSourceLookupHighlight(
          query: '「言いつつ',
          tappedGraphemeIndex: 0,
          matchedUnits: 2,
          leadingStripUnits: 1,
        ),
        const SourceLookupHighlight(start: 1, length: 2),
      );
    });

    test('匹配长度落在代理对中间时整字入框，绝不把一个字劈成两半', () {
      // 𠮟 = U+20B9F，占 2 个 UTF-16 code unit、1 个字素簇。
      expect(
        resolveSourceLookupHighlight(
          query: '𠮟る',
          tappedGraphemeIndex: 0,
          matchedUnits: 2,
          leadingStripUnits: 0,
        ),
        const SourceLookupHighlight(start: 0, length: 1),
      );
      expect(
        resolveSourceLookupHighlight(
          query: '𠮟る',
          tappedGraphemeIndex: 0,
          matchedUnits: 3,
          leadingStripUnits: 0,
        ),
        const SourceLookupHighlight(start: 0, length: 2),
      );
      // 长度停在代理对内部（1 unit）也要把整个字圈进来，而不是半个。
      expect(
        resolveSourceLookupHighlight(
          query: '𠮟る',
          tappedGraphemeIndex: 0,
          matchedUnits: 1,
          leadingStripUnits: 0,
        ),
        const SourceLookupHighlight(start: 0, length: 1),
      );
    });

    test('多码点字素簇（ZWJ 序列）算一个字', () {
      const String family = '\u{1F468}‍\u{1F469}‍\u{1F466}';
      expect(
        resolveSourceLookupHighlight(
          query: '$familyあ',
          tappedGraphemeIndex: 0,
          matchedUnits: 2,
          leadingStripUnits: 0,
        ),
        const SourceLookupHighlight(start: 0, length: 1),
      );
    });

    test('零命中退化成只框被点的那个字', () {
      expect(
        resolveSourceLookupHighlight(
          query: 'あいう',
          tappedGraphemeIndex: 2,
          matchedUnits: 0,
          leadingStripUnits: 0,
        ),
        const SourceLookupHighlight(start: 2, length: 1),
      );
    });

    test('匹配长度超出查询串时钳到串尾，不越界', () {
      expect(
        resolveSourceLookupHighlight(
          query: 'あい',
          tappedGraphemeIndex: 1,
          matchedUnits: 99,
          leadingStripUnits: 0,
        ),
        const SourceLookupHighlight(start: 1, length: 2),
      );
    });

    test('空查询串 / 整串都被剥掉时不产出非法跨度', () {
      expect(
        resolveSourceLookupHighlight(
          query: '',
          tappedGraphemeIndex: 4,
          matchedUnits: 3,
          leadingStripUnits: 0,
        ),
        const SourceLookupHighlight(start: 4, length: 1),
      );
      expect(
        resolveSourceLookupHighlight(
          query: '。。',
          tappedGraphemeIndex: 0,
          matchedUnits: 1,
          leadingStripUnits: 2,
        ).length,
        greaterThanOrEqualTo(1),
      );
    });
  });
}
