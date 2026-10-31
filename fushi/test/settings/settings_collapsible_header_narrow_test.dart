/// 折叠分组头的「标题 + 尾随（摘要 + 箭头）」横排。
///
/// - 手机宽度下长摘要不能把标题挤到只剩几个字宽（LLM 设置页「功能提供商」折成
///   三行）；
/// - 尾随区上限 = max(半宽, 总宽 − 标题天然宽)：标题短时摘要不必被无谓截到半宽；
/// - 头部直接当 AlertDialog 正文时要能回答 intrinsic 宽度（对话框把正文包在
///   `IntrinsicWidth` 里；`LayoutBuilder` 回答不了，见 BUG-3501）。
///
/// MD3 与 Apple（玻璃）两套设计系统走的是两条不同的折叠头装配路径（分段分组 /
/// 分组卡），各跑一遍。
library;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show FushiAlertDialog;
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:material_ui/material_ui.dart';

const String _shortTitle = 'Providers';
const String _longTitle = 'Feature providers for every assistant tool';
const String _longSummary =
    'All features use the default provider and more words to overflow';

ThemeData _theme({required bool apple}) => ThemeData(
  useMaterial3: true,
  extensions: <ThemeExtension<dynamic>>[
    FushiGlassTheme(FushiGlassMaterial.off, glassDesign: apple),
  ],
);

Widget _app({required bool apple, required Widget home}) => MaterialApp(
  theme: _theme(apple: apple),
  // 测试字体（Ahem）的字形远宽于真字体：缩到 0.5 倍，只量布局判据。
  builder: (BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: const TextScaler.linear(0.5)),
    child: child!,
  ),
  home: home,
);

Widget _section({required String title, required String summary}) =>
    AdaptiveSettingsSection(
      title: title,
      titlePlacement: SettingsSectionTitlePlacement.inside,
      collapsible: true,
      summary: summary,
      children: const <Widget>[SizedBox(height: 40)],
    );

double _naturalWidth(RenderParagraph paragraph) {
  final TextPainter painter = TextPainter(
    text: paragraph.text,
    textDirection: TextDirection.ltr,
    textScaler: paragraph.textScaler,
  )..layout();
  final double width = painter.width;
  painter.dispose();
  return width;
}

/// 折叠头整行（标题与尾随的共同父级）的宽：取标题段落往上第一个比它宽两倍以上
/// 的祖先不稳；直接量包着标题与摘要的最近共同 RenderBox——即摘要段落父链上同样
/// 是标题段落祖先的第一个盒子。
RenderBox _headerBox(WidgetTester tester, String title, String summary) {
  final RenderObject titleRo = tester.renderObject(find.text(title));
  final Set<RenderObject> titleAncestors = <RenderObject>{};
  for (RenderObject? r = titleRo; r != null; r = r.parent) {
    titleAncestors.add(r);
  }
  RenderObject? r = tester.renderObject(find.text(summary));
  while (r != null && !titleAncestors.contains(r)) {
    r = r.parent;
  }
  return r! as RenderBox;
}

void main() {
  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    group('[$ds]', () {
      Future<void> pumpAt(
        WidgetTester tester,
        double width,
        Widget section,
      ) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _app(
            apple: apple,
            home: Scaffold(body: SingleChildScrollView(child: section)),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      testWidgets('窄屏长标题 + 长摘要：标题至少保有半宽，摘要在半宽内省略', (WidgetTester tester) async {
        await pumpAt(
          tester,
          360,
          _section(title: _longTitle, summary: _longSummary),
        );
        final RenderBox header = _headerBox(tester, _longTitle, _longSummary);
        final double half = header.size.width / 2;
        final RenderParagraph summary = tester.renderObject<RenderParagraph>(
          find.text(_longSummary),
        );
        expect(summary.size.width, lessThanOrEqualTo(half + 0.5));
        expect(
          summary.size.width,
          lessThan(_naturalWidth(summary) - 1),
          reason: '摘要应被省略',
        );
        final RenderParagraph title = tester.renderObject<RenderParagraph>(
          find.text(_longTitle),
        );
        expect(title.size.width, greaterThan(half * 0.6));
      });

      testWidgets('窄屏短标题 + 长摘要：标题单行完整，摘要可越过半宽占用余量', (
        WidgetTester tester,
      ) async {
        await pumpAt(
          tester,
          360,
          _section(title: _shortTitle, summary: _longSummary),
        );
        final RenderBox header = _headerBox(tester, _shortTitle, _longSummary);
        final RenderParagraph title = tester.renderObject<RenderParagraph>(
          find.text(_shortTitle),
        );
        expect(
          title.size.width,
          greaterThanOrEqualTo(_naturalWidth(title) - 0.5),
          reason: '标题被摘要挤窄、折成了多行',
        );
        final RenderParagraph summary = tester.renderObject<RenderParagraph>(
          find.text(_longSummary),
        );
        expect(
          summary.size.width,
          greaterThan(header.size.width / 2),
          reason: '短标题时摘要不该被无谓截到半宽',
        );
      });

      testWidgets('宽屏：摘要完整显示，不省略', (WidgetTester tester) async {
        await pumpAt(
          tester,
          1200,
          _section(title: _longTitle, summary: _longSummary),
        );
        final RenderParagraph summary = tester.renderObject<RenderParagraph>(
          find.text(_longSummary),
        );
        expect(
          summary.size.width,
          greaterThanOrEqualTo(_naturalWidth(summary) - 0.5),
        );
        final RenderParagraph title = tester.renderObject<RenderParagraph>(
          find.text(_longTitle),
        );
        expect(
          title.size.width,
          greaterThanOrEqualTo(_naturalWidth(title) - 0.5),
        );
      });

      testWidgets('折叠分组直接当 AlertDialog 正文：不抛 intrinsic 错，对话框按内容取宽', (
        WidgetTester tester,
      ) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _app(
            apple: apple,
            home: Scaffold(
              body: Center(
                child: FushiAlertDialog(
                  title: const Text('Dialog'),
                  content: _section(title: _longTitle, summary: _longSummary),
                  actions: <Widget>[
                    TextButton(onPressed: () {}, child: const Text('OK')),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final RenderBox header = _headerBox(tester, _longTitle, _longSummary);
        // 对话框按正文的 intrinsic 宽取宽：头部回答不了 intrinsic 时（release 答 0）
        // 对话框只有标题 / 按钮那么宽，标题与摘要都被挤成几个字。
        expect(header.size.width, greaterThan(280));
        final RenderParagraph title = tester.renderObject<RenderParagraph>(
          find.text(_longTitle),
        );
        expect(title.size.width, greaterThan(header.size.width / 2 - 40));
      });
    });
  }
}
