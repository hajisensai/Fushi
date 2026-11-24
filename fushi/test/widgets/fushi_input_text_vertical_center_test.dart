import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:material_ui/material_ui.dart';

// 公共输入框 / 搜索框的文字竖直居中（用户 2026-11-24：「无论 Material 还是
// Cupertino，输入框、搜索框的文字都没有做到上下居中」）。
//
// 判据：字形**实际墨迹**在可见框（M3E = InputDecorator 容器，Apple = 实色壳）
// 里的上下留白之差 ≤ 1px。测试字体（FlutterTest）的字形是整个 em 方块
// （ascent 0.75 / descent 0.25），墨迹 = 字体 ascent/descent 盒，所以这里量出
// 的偏差正是「行距在行盒里怎么分」造成的那部分——与具体平台字体无关的版面错误。
// 根因：字阶行高（M3E bodyLarge 1.5、Apple 1.25）多出的行距默认按 ascent :
// descent 比例分，几乎全加在字形上方，行盒居中了字形却偏下（16 号约 2px）；
// 修法是输入框正文 / 占位符一律上下均分（fushiFieldTextStyle）。
//
// 只量拉丁字：测试字体没有 CJK 字形（回退到 .notdef），墨迹不可信；CJK 由
// 「占位符与正文的行盒同高、基线一致」那条覆盖（版面层与字形无关）。

const double _pr = 4;

enum _Mode { m3eTouch, m3eDesktop, appleTouch, appleDesktop }

bool _apple(_Mode m) => m == _Mode.appleTouch || m == _Mode.appleDesktop;

TargetPlatform _platform(_Mode m) => switch (m) {
  _Mode.m3eTouch || _Mode.appleTouch => TargetPlatform.android,
  _Mode.m3eDesktop || _Mode.appleDesktop => TargetPlatform.windows,
};

typedef _FieldBuilder = Widget Function(TextEditingController controller);

class _Case {
  const _Case(this.name, this.build, {this.hint = 'Search'});
  final String name;
  final _FieldBuilder build;
  final String hint;
}

final List<_Case> _cases = <_Case>[
  _Case(
    'FushiSearchField regular',
    (TextEditingController c) => FushiSearchField(
      controller: c,
      focusNode: FocusNode(),
      hintText: 'Search',
      onChanged: (_) {},
      onSubmitted: (_) {},
      onClear: () {},
    ),
  ),
  _Case(
    'FushiSearchField large',
    (TextEditingController c) => FushiSearchField(
      size: FushiSearchFieldSize.large,
      controller: c,
      focusNode: FocusNode(),
      hintText: 'Search',
      onChanged: (_) {},
      onSubmitted: (_) {},
      onClear: () {},
    ),
  ),
  _Case(
    'FushiTextFieldControl',
    (TextEditingController c) => FushiTextFieldControl(
      controller: c,
      decoration: const InputDecoration(hintText: 'Search'),
    ),
  ),
  _Case(
    'FushiTextFieldControl dense',
    (TextEditingController c) => FushiTextFieldControl(
      controller: c,
      decoration: const InputDecoration(hintText: 'Search', isDense: true),
    ),
  ),
  // 调用方传主题里取的 inherit: false 样式（常见写法）：Apple 分支此前
  // merge 后整个顶掉了单行框的均分行距。
  _Case(
    'FushiTextFieldControl themed style',
    (TextEditingController c) => Builder(
      builder: (BuildContext context) => FushiTextFieldControl(
        controller: c,
        style: Theme.of(context).textTheme.bodyLarge,
        decoration: InputDecoration(
          hintText: 'Search',
          hintStyle: Theme.of(context).textTheme.bodyLarge,
        ),
      ),
    ),
  ),
  _Case(
    'FushiTextField',
    (TextEditingController c) =>
        FushiTextField(controller: c, hintText: 'Search'),
  ),
  _Case(
    'FushiTextField small',
    (TextEditingController c) => FushiTextField(
      controller: c,
      hintText: 'Search',
      size: FushiInputSize.small,
    ),
  ),
  _Case(
    'FushiCompactSearchRow',
    (TextEditingController c) => FushiCompactSearchRow(
      controller: c,
      focusNode: FocusNode(),
      hintText: 'Search',
      onSubmit: (_) {},
    ),
  ),
];

ThemeData _theme(_Mode mode, {bool ideographic = false}) {
  final bool apple = _apple(mode);
  return buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    // 中日韩 locale 的字阶（Typography.dense）带 textBaseline: ideographic。
    textTheme: FushiTypeScale.buildTextTheme(
      TextStyle(
        textBaseline: ideographic
            ? TextBaseline.ideographic
            : TextBaseline.alphabetic,
      ),
    ),
    glass: FushiGlassMaterial.off,
    glassDesign: apple,
  ).copyWith(platform: _platform(mode));
}

final GlobalKey _boundary = GlobalKey();

Future<void> _pump(
  WidgetTester tester,
  _Mode mode,
  _Case c,
  TextEditingController controller, {
  bool ideographic = false,
}) async {
  // Apple 桌面档要宽窗（窄于 600 回落 iOS 档）。
  tester.view.physicalSize = const Size(900, 400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: _theme(mode, ideographic: ideographic),
      debugShowCheckedModeBanner: false,
      home: FushiGlassScope(
        child: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: _boundary,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: SizedBox(width: 420, child: c.build(controller)),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 可见框：M3E 是 InputDecorator（填充 / 边框画在它的容器上），紧凑搜索行
/// 是外面那张 44 高的卡；Apple 是实色壳（第一个 AnimatedContainer）。
Rect _shell(WidgetTester tester, _Mode mode, _Case c) {
  if (_apple(mode)) {
    return tester.getRect(find.byType(AnimatedContainer).first);
  }
  if (c.name == 'FushiCompactSearchRow') {
    return tester.getRect(
      find
          .ancestor(
            of: find.byType(TextField),
            matching: find.byWidgetPredicate(
              (Widget w) => w is SizedBox && w.height == 44,
            ),
          )
          .first,
    );
  }
  return tester.getRect(find.byType(InputDecorator).first);
}

/// 文字所在的行盒（占位符的 RenderParagraph / 正文的 RenderEditable）。
({Rect box, double baseline}) _line(
  WidgetTester tester,
  String hint,
  bool empty,
) {
  final RenderBox box = empty
      ? tester.renderObject<RenderBox>(find.text(hint).last)
      : tester.renderObject<RenderEditable>(
          find.byWidgetPredicate(
            (Widget w) => w.runtimeType.toString() == '_Editable',
          ),
        );
  final Offset o = box.localToGlobal(Offset.zero);
  return (
    box: o & box.size,
    // 布局期之外不能调 getDistanceToBaseline（断言只许父级布局期读）；
    // 干基线按当前约束重算，同一结果。
    baseline:
        o.dy + box.getDryBaseline(box.constraints, TextBaseline.alphabetic)!,
  );
}

/// 在 [shell] 里、[text] 起始一段的横向范围内逐行扫，返回墨迹上下沿（逻辑像素）。
Future<({double top, double bottom})> _ink(
  WidgetTester tester,
  Rect shell,
  Rect text,
) async {
  final RenderRepaintBoundary b =
      _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final Offset origin = b.localToGlobal(Offset.zero);
  late int width;
  final ByteData bytes = (await tester.runAsync<ByteData?>(() async {
    final ui.Image image = await b.toImage(pixelRatio: _pr);
    width = image.width;
    final ByteData? data = await image.toByteData();
    image.dispose();
    return data;
  }))!;
  int pixel(int x, int y) => bytes.getUint32((y * width + x) * 4);
  int channelSum(int p) =>
      ((p >> 24) & 0xff) + ((p >> 16) & 0xff) + ((p >> 8) & 0xff);
  final int x0 = ((text.left - origin.dx + 1) * _pr).round();
  final int x1 = ((text.left - origin.dx + 30) * _pr).round();
  // 避开上下沿的描边 / 活动指示线 / 圆角外的页面底色。
  final int y0 = ((shell.top - origin.dy + 4) * _pr).round();
  final int y1 = ((shell.bottom - origin.dy - 4) * _pr).round();
  // 框的底色 = 扫描区里出现最多的像素值（文字只占一小部分）。
  final Map<int, int> counts = <int, int>{};
  for (int y = y0; y < y1; y++) {
    for (int x = x0; x < x1; x++) {
      counts.update(pixel(x, y), (int n) => n + 1, ifAbsent: () => 1);
    }
  }
  final int background = channelSum(
    counts.entries
        .reduce(
          (MapEntry<int, int> a, MapEntry<int, int> b) =>
              a.value >= b.value ? a : b,
        )
        .key,
  );
  int? top;
  int? bottom;
  for (int y = y0; y < y1; y++) {
    for (int x = x0; x < x1; x++) {
      if ((channelSum(pixel(x, y)) - background).abs() > 90) {
        top ??= y;
        bottom = y;
        break;
      }
    }
  }
  expect(top, isNotNull, reason: 'no text ink found inside the field');
  return (top: top! / _pr + origin.dy, bottom: (bottom! + 1) / _pr + origin.dy);
}

void main() {
  for (final _Mode mode in _Mode.values) {
    for (final _Case c in _cases) {
      for (final bool empty in <bool>[true, false]) {
        final String what = empty ? 'placeholder' : 'text';
        testWidgets('${mode.name} ${c.name}: $what is vertically centered', (
          WidgetTester tester,
        ) async {
          final TextEditingController controller = TextEditingController(
            text: empty ? '' : 'Hello',
          );
          addTearDown(controller.dispose);
          await _pump(tester, mode, c, controller);
          final Rect shell = _shell(tester, mode, c);
          final ({Rect box, double baseline}) line = _line(
            tester,
            c.hint,
            empty,
          );
          final ({double top, double bottom}) ink = await _ink(
            tester,
            shell,
            line.box,
          );
          final double topGap = ink.top - shell.top;
          final double bottomGap = shell.bottom - ink.bottom;
          expect(
            (topGap - bottomGap).abs(),
            lessThanOrEqualTo(1.0),
            reason:
                'shell ${shell.top}..${shell.bottom}, ink ${ink.top}..'
                '${ink.bottom} (top gap $topGap, bottom gap $bottomGap)',
          );
        });
      }
    }
  }

  // CJK 占位符与拉丁正文共用同一行盒：占位符换成中文、正文换成拉丁文时，
  // 行盒的高度与基线位置不变（两者同一样式、同一行距分配）。
  for (final _Mode mode in _Mode.values) {
    testWidgets('${mode.name}: CJK placeholder shares the text line box', (
      WidgetTester tester,
    ) async {
      final _Case cjk = _Case(
        'FushiSearchField regular',
        (TextEditingController c) => FushiSearchField(
          controller: c,
          focusNode: FocusNode(),
          hintText: '搜索书库',
          onChanged: (_) {},
          onSubmitted: (_) {},
        ),
        hint: '搜索书库',
      );
      final TextEditingController controller = TextEditingController();
      addTearDown(controller.dispose);
      await _pump(tester, mode, cjk, controller);
      final ({Rect box, double baseline}) hint = _line(tester, '搜索书库', true);
      controller.text = 'Hello';
      await tester.pumpAndSettle();
      final ({Rect box, double baseline}) text = _line(tester, '', false);
      expect(hint.box.height, moreOrLessEquals(text.box.height, epsilon: 0.5));
      expect(hint.baseline, moreOrLessEquals(text.baseline, epsilon: 0.5));
    });
  }

  // 中文界面（主题字阶 textBaseline: ideographic）下占位符不下沉：输入框把
  // 占位符按基线对齐到编辑区，RenderEditable 按 ideographic 报基线、
  // RenderParagraph（占位符）只报 alphabetic，差一个 descent（用户 2026-11-24
  // 「这个字还是没有上下居中」，设置页搜索框占位字低约 3px）。
  // fushiFieldTextStyle 把对齐基线钉成 alphabetic 后两者行盒重合。
  for (final _Mode mode in _Mode.values) {
    for (final _Case c in _cases) {
      testWidgets(
        '${mode.name} ${c.name}: placeholder line box sits on the editable '
        'line box under an ideographic-baseline theme',
        (WidgetTester tester) async {
          final TextEditingController controller = TextEditingController();
          addTearDown(controller.dispose);
          await _pump(tester, mode, c, controller, ideographic: true);
          final Rect hint = _line(tester, c.hint, true).box;
          final Rect editable = tester.getRect(
            find.byWidgetPredicate(
              (Widget w) => w.runtimeType.toString() == '_Editable',
            ),
          );
          expect(
            hint.center.dy,
            moreOrLessEquals(editable.center.dy, epsilon: 0.5),
            reason: 'placeholder $hint vs editable $editable',
          );
        },
      );
    }
  }
}
