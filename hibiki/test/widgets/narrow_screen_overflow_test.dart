import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';
import 'package:hibiki/src/utils/components/shelf_card_widgets.dart';

import 'widget_test_helpers.dart';

/// BUG-1184 回归守卫：窄屏 / 小窗口下内容被「显示不全」的几条根因。
///
/// 共同的错误模式是把「不抛 RenderFlex overflow」当成了目标——文字被钳成固定行数、
/// 控件被钳进固定像素、标题被允许压到 0 宽，都不会报错，但用户就是看不全内容。
/// 下面每个用例都锚定一条根因，修复前红。

/// 一段足够长、必然超过三行的设置项说明。
const String _longSubtitle = '这条说明足够长，长到在窄屏上无论如何都会超过三行：它会解释这个'
    '配置项在什么条件下生效、影响哪些页面、以及关掉之后会发生什么，末尾还会附上一条'
    '实际生效的路径，而路径恰恰是用户最需要看到的那一段信息。';

/// 从 widget 树里取出内容等于 [data] 的那个 [Text]。
Text _textWithData(WidgetTester tester, String data) {
  final Iterable<Text> matches = tester
      .widgetList<Text>(find.byType(Text))
      .where((Text w) => w.data == data);
  expect(matches.length, 1, reason: 'expected exactly one Text carrying $data');
  return matches.first;
}

void main() {
  group('设置行说明文字', () {
    testWidgets('默认不再钳行数——长说明整段显示，不被截成三行', (WidgetTester tester) async {
      await tester.pumpWidget(
        buildTestApp(
          const MediaQuery(
            data: MediaQueryData(size: Size(360, 720)),
            child: SizedBox(
              width: 360,
              child: AdaptiveSettingsRow(
                title: '设置项',
                subtitle: _longSubtitle,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final Text subtitle = _textWithData(tester, _longSubtitle);
      expect(
        subtitle.maxLines,
        isNull,
        reason: '说明文字的职责就是解释配置项，截断等于失效；设置行行高本就自由，'
            '不该有固定行数上限（BUG-1184）',
      );
    });

    testWidgets('显式传 subtitleMaxLines 时仍然生效（密度敏感处的逃生口）',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        buildTestApp(
          const MediaQuery(
            data: MediaQueryData(size: Size(360, 720)),
            child: SizedBox(
              width: 360,
              child: AdaptiveSettingsRow(
                title: '设置项',
                subtitle: _longSubtitle,
                subtitleMaxLines: kSettingsRowSubtitleMaxLines,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        _textWithData(tester, _longSubtitle).maxLines,
        kSettingsRowSubtitleMaxLines,
      );
    });
  });

  group('设置行窄屏堆叠', () {
    /// 窄行宽 + 一个 flexible trailing：修复前因为 `!trailingFlexible` 而永远走行内
    /// 布局，标题与控件五五分宽；修复后与非 flex trailing 同一规则，改为上下堆叠。
    const Key trailingKey = Key('narrow-row-trailing');

    Widget buildRow({required bool trailingFlexible, required double width}) {
      return buildTestApp(
        MediaQuery(
          data: const MediaQueryData(size: Size(320, 720)),
          child: SizedBox(
            width: width,
            child: AdaptiveSettingsRow(
              title: '设置项标题',
              trailingFlexible: trailingFlexible,
              trailing: const SizedBox(
                key: trailingKey,
                width: 120,
                height: 24,
              ),
            ),
          ),
        ),
      );
    }

    /// 堆叠 = 控件被放到标题**下方**（而不是并排抢宽）。
    bool isStacked(WidgetTester tester) {
      final double titleBottom = tester.getBottomLeft(find.text('设置项标题')).dy;
      final double trailingTop = tester.getTopLeft(find.byKey(trailingKey)).dy;
      return trailingTop >= titleBottom;
    }

    testWidgets('窄行里 flexible trailing 也会堆叠到标题下方', (WidgetTester tester) async {
      await tester.pumpWidget(
        buildRow(trailingFlexible: true, width: 200),
      );
      await tester.pump();

      expect(
        isStacked(tester),
        isTrue,
        reason: '修复前 flexible trailing 被 `!trailingFlexible` 排除在堆叠判定外，'
            '永远与标题并排五五分宽，标题只剩一半（BUG-1184）',
      );
    });

    testWidgets('非 flex trailing 的既有堆叠行为不变', (WidgetTester tester) async {
      await tester.pumpWidget(
        buildRow(trailingFlexible: false, width: 200),
      );
      await tester.pump();
      expect(isStacked(tester), isTrue);
    });

    testWidgets('行宽足够时仍并排，不误堆叠', (WidgetTester tester) async {
      await tester.pumpWidget(
        buildRow(trailingFlexible: true, width: 600),
      );
      await tester.pump();
      expect(
        isStacked(tester),
        isFalse,
        reason: '宽行必须维持原来的并排布局，堆叠只在真的放不下时发生',
      );
    });
  });

  group('独立分段条', () {
    /// 段标签故意用不可断行的长词：窄屏下 Material 会把每段钳到「可用宽 / 段数」
    /// 并静默裁字，[HibikiSegmentedStrip] 必须改走横向滚动。
    Widget buildStrip(double width) {
      return buildTestApp(
        MediaQuery(
          data: MediaQueryData(size: Size(width, 720)),
          child: SizedBox(
            width: width,
            child: HibikiSegmentedStrip<int>(
              segments: const <ButtonSegment<int>>[
                ButtonSegment<int>(value: 0, label: Text('qBittorrent')),
                ButtonSegment<int>(
                  value: 1,
                  label: Text('Built-in engine (desktop only)'),
                ),
              ],
              selected: 0,
              onChanged: _noop,
            ),
          ),
        ),
      );
    }

    testWidgets('装不下时套横向滚动视图（永不裁掉尾部分段）', (WidgetTester tester) async {
      await tester.pumpWidget(buildStrip(320));
      await tester.pump();

      expect(
        find.byType(SingleChildScrollView),
        findsOneWidget,
        reason: '窄屏放不下时必须可横向滚动，而不是让 Material 把标签钳成半个词'
            '（BUG-1184）',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('装得下时保持原样铺开，不引入多余滚动', (WidgetTester tester) async {
      await tester.pumpWidget(buildStrip(900));
      await tester.pump();

      expect(find.byType(SingleChildScrollView), findsNothing);
      expect(find.byType(Align), findsWidgets);
    });
  });

  group('对话框边距', () {
    testWidgets('窄屏收窄到 16，不再固定吃掉 80px', (WidgetTester tester) async {
      await tester.pumpWidget(
        buildTestApp(
          const MediaQuery(
            data: MediaQueryData(size: Size(320, 640)),
            child: HibikiDialogFrame(child: Text('内容')),
          ),
        ),
      );
      await tester.pump();

      final Dialog dialog = tester.widget<Dialog>(find.byType(Dialog));
      expect(
        dialog.insetPadding!.horizontal,
        32,
        reason: '320dp 上左右各 40 会让正文只剩 240px，标题普遍被省略成「…」'
            '（BUG-1184）',
      );
    });

    testWidgets('宽屏维持原来的 40', (WidgetTester tester) async {
      await tester.pumpWidget(
        buildTestApp(
          const MediaQuery(
            data: MediaQueryData(size: Size(1200, 900)),
            child: HibikiDialogFrame(child: Text('内容')),
          ),
        ),
      );
      await tester.pump();

      final Dialog dialog = tester.widget<Dialog>(find.byType(Dialog));
      expect(dialog.insetPadding!.horizontal, 80);
    });

    testWidgets('显式传入的 insetPadding 仍然优先', (WidgetTester tester) async {
      await tester.pumpWidget(
        buildTestApp(
          const MediaQuery(
            data: MediaQueryData(size: Size(320, 640)),
            child: HibikiDialogFrame(
              insetPadding: EdgeInsets.all(4),
              child: Text('内容'),
            ),
          ),
        ),
      );
      await tester.pump();

      final Dialog dialog = tester.widget<Dialog>(find.byType(Dialog));
      expect(dialog.insetPadding!.horizontal, 8);
    });
  });

  group('AppBar 动作折叠', () {
    List<HibikiAppBarAction> actions() => <HibikiAppBarAction>[
          HibikiAppBarAction(
            icon: Icons.drive_file_rename_outline,
            label: '重命名',
            onPressed: _noop2,
          ),
          HibikiAppBarAction(
            icon: Icons.sell_outlined,
            label: '标签',
            onPressed: _noop2,
          ),
          HibikiAppBarAction(
            icon: Icons.delete_outline,
            label: '删除',
            onPressed: _noop2,
          ),
        ];

    /// 照两个合集详情页的真实写法搭台：整窗宽 [windowWidth]，但这条 AppBar 只拿到
    /// [rowWidth] 的约束（分栏 / 受限宽容器）。返回 [LayoutBuilder] 实际观测到的
    /// 约束宽，供用例断言「喂进折叠判据的确实是局部宽而不是整窗宽」。
    Future<double> pumpAppBar(
      WidgetTester tester, {
      required double windowWidth,
      required double rowWidth,
    }) async {
      double observedWidth = double.nan;
      await tester.pumpWidget(
        buildTestApp(
          MediaQuery(
            data: MediaQueryData(size: Size(windowWidth, 900)),
            child: Center(
              child: SizedBox(
                width: rowWidth,
                height: 400,
                child: Scaffold(
                  appBar: PreferredSize(
                    preferredSize: const Size.fromHeight(kToolbarHeight),
                    child: LayoutBuilder(
                      builder: (BuildContext context, BoxConstraints c) {
                        observedWidth = c.maxWidth;
                        return AppBar(
                          title: const Text('合集名'),
                          actions: narrowAwareAppBarActions(
                            availableWidth: c.maxWidth,
                            collapsible: actions(),
                          ),
                        );
                      },
                    ),
                  ),
                  body: const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return observedWidth;
    }

    testWidgets('窄屏折成单个溢出菜单，给标题让出宽度', (WidgetTester tester) async {
      final double observed = await pumpAppBar(
        tester,
        windowWidth: 320,
        rowWidth: 320,
      );

      expect(observed, 320);
      expect(find.byType(PopupMenuButton<int>), findsOneWidget,
          reason: '三个动作必须折成一个溢出菜单（BUG-1184）');
      expect(find.byIcon(Icons.drive_file_rename_outline), findsNothing);
      // 折叠后动作一个都不能少：菜单里必须仍能找到全部三条。
      await tester.tap(find.byType(PopupMenuButton<int>));
      await tester.pumpAndSettle();
      expect(find.text('重命名'), findsOneWidget);
      expect(find.text('标签'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
    });

    testWidgets('窗口很宽但这条 AppBar 只有 360 时，仍按窄屏折叠', (WidgetTester tester) async {
      final double observed = await pumpAppBar(
        tester,
        windowWidth: 1200,
        rowWidth: 360,
      );

      expect(observed, 360, reason: '判据必须取 AppBar 的局部约束宽');
      expect(
        find.byType(PopupMenuButton<int>),
        findsOneWidget,
        reason: 'BUG-1186：折叠判据曾读 MediaQuery 的整窗宽（1200，不算窄），'
            '于是分栏 / 受限宽容器里三个动作照样平铺，把合集名挤没。'
            '真正决定塞不塞得下的是这条 AppBar 自己拿到的 360',
      );
      expect(find.byIcon(Icons.drive_file_rename_outline), findsNothing);
    });

    testWidgets('宽屏保持逐个平铺（零行为变化）', (WidgetTester tester) async {
      final double observed = await pumpAppBar(
        tester,
        windowWidth: 1200,
        rowWidth: 700,
      );

      expect(observed, 700);
      expect(find.byType(PopupMenuButton<int>), findsNothing);
      expect(find.byIcon(Icons.drive_file_rename_outline), findsOneWidget,
          reason: '宽屏必须零行为变化：三个动作逐个平铺');
      expect(find.byIcon(Icons.sell_outlined), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    });
  });

  group('书架卡标题 footer', () {
    testWidgets('高度随文字缩放变高，两行书名不会被裁', (WidgetTester tester) async {
      late double baseline;
      late double scaled;

      await tester.pumpWidget(
        buildTestApp(
          MediaQuery(
            data: const MediaQueryData(size: Size(360, 720)),
            child: Builder(
              builder: (BuildContext context) {
                baseline = ShelfCardFooter.heightFor(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.pumpWidget(
        buildTestApp(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(360, 720),
              textScaler: TextScaler.linear(1.6),
            ),
            child: Builder(
              builder: (BuildContext context) {
                scaled = ShelfCardFooter.heightFor(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        baseline,
        ShelfCardFooter.height,
        reason: '默认字号下维持原来的 40px 观感',
      );
      expect(
        scaled,
        greaterThan(baseline),
        reason: '大字号下 footer 必须长高，否则书名第二行的下半截被 SizedBox 切掉'
            '（BUG-1184）',
      );
    });
  });
}

void _noop(int _) {}

void _noop2() {}
