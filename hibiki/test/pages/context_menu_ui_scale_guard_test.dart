import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';

import '../helpers/source_guard.dart';

/// BUG-1438（与 BUG-129/261/381/781 同族）守卫：**右键 / 上下文菜单在界面大小≠100%
/// 时的坐标空间与内容尺寸**。
///
/// 生产拓扑（两层，必须同时理解才不会改错）：
///  1. 全局 [HibikiAppUiScale] 挂在 `MaterialApp.builder`（main.dart），用
///     `FittedBox(BoxFit.fill)` 把整棵子树渲染进一个「缩放画布」（尺寸 = 真实视口 /
///     scale）再拉满屏。**根 Navigator / 根 Overlay 都在它之内** → Overlay 本地坐标
///     是画布空间，且画布→屏幕这一跳会把其中一切按 scale 放大一次。
///  2. 阅读器 / 漫画 / PDF / 视频页在**路由层**再套 [HibikiAppUiScaleNeutralizer]，
///     把页面子树净缩放还原成 1.0（让 WebView / Texture 按原生密度渲染）→ 页面内部
///     拿到的坐标和 `MediaQuery.size` 都是**真实屏幕**空间。
///
/// 由此得到两条不变式，本文件各用一个真渲染测试锁定：
///  A. **锚点**：页面手里的真实屏幕坐标喂给 `showMenu` 前，必须经
///     `Overlay.globalToLocal` 换算（边界同样用 `overlay.size` 而非
///     `MediaQuery.of(context).size`）。否则菜单渲染在「点击点 × scale」。
///  B. **内容尺寸**：菜单在中和器**之外**，已经天然跟随界面大小；代码**不得**再手动
///     乘 scale。旧阅读器代码复用了 chrome 的 `menuScale`，视觉尺寸变成 scale²。
void main() {
  /// 复刻生产拓扑：全局缩放包住 Navigator/Overlay，页面再被中和。
  Widget wrap({required double scale, required Widget page}) => MaterialApp(
        builder: (BuildContext context, Widget? child) =>
            HibikiAppUiScale(scale: scale, child: child!),
        home: HibikiAppUiScaleNeutralizer(child: page),
      );

  group('不变式 A：菜单锚点经 Overlay 换算后贴住真实点击点', () {
    /// 被测页面：整屏右键热区。[mapThroughOverlay] 切换「正确范式 / 修复前写法」，
    /// 让同一个测试既能证明修复有效，也能证明它抓得住回归（变异对照）。
    Widget menuPage({required bool mapThroughOverlay}) => Builder(
          builder: (BuildContext context) => Scaffold(
            body: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onSecondaryTapDown: (TapDownDetails d) {
                final RenderBox overlay = Overlay.of(context)
                    .context
                    .findRenderObject()! as RenderBox;
                final RelativeRect position;
                if (mapThroughOverlay) {
                  final Offset anchor = overlay.globalToLocal(d.globalPosition);
                  position = RelativeRect.fromRect(
                    Rect.fromLTWH(anchor.dx, anchor.dy, 1, 1),
                    Offset.zero & overlay.size,
                  );
                } else {
                  // 修复前：真实屏幕坐标直接当画布坐标，边界取 MediaQuery（中和层内
                  // 是真实视口，比 overlay.size 大 scale 倍）。
                  final Size size = MediaQuery.of(context).size;
                  position = RelativeRect.fromLTRB(
                    d.globalPosition.dx,
                    d.globalPosition.dy,
                    size.width - d.globalPosition.dx,
                    size.height - d.globalPosition.dy,
                  );
                }
                showMenu<String>(
                  context: context,
                  position: position,
                  items: const <PopupMenuEntry<String>>[
                    PopupMenuItem<String>(value: 'a', child: Text('ITEM')),
                  ],
                );
              },
              child: const SizedBox.expand(),
            ),
          ),
        );

    /// 右键点屏幕中心偏右下（离原点足够远，放大缩放偏移），返回菜单项与点击点的距离。
    Future<double> menuOffsetFromClick(
      WidgetTester tester, {
      required double scale,
      required bool mapThroughOverlay,
    }) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 900);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap(
          scale: scale, page: menuPage(mapThroughOverlay: mapThroughOverlay)));
      await tester.pumpAndSettle();

      const Offset click = Offset(700, 520);
      final TestGesture gesture = await tester.startGesture(
        click,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.text('ITEM'), findsOneWidget, reason: '右键应弹出菜单');
      final Rect itemRect = tester.getRect(
        find.byWidgetPredicate((Widget w) => w is PopupMenuItem),
      );
      // 「贴住点击点」= 点击点到菜单矩形的距离，不是到 topLeft 的距离：点击点落在
      // 屏幕右半边时 Flutter 会把菜单**向左展开**（右边缘对齐点击点），那是正确
      // 行为，用 topLeft 度量会把它误判成偏移。
      return _distanceToRect(itemRect, click);
    }

    // 修复后菜单与点击点的间隙恒为「菜单自身垂直 padding × scale」（实测 8×scale：
    // 0.5→4.0 / 1.0→8.1 / 2.0→16.1）；阈值按 scale 取 3 倍余量，既容得下不同主题的
    // padding，又远小于修复前的偏移量（scale=0.5 实测 302）。
    for (final double scale in <double>[0.5, 1.0, 2.0]) {
      testWidgets('缩放 $scale：换算后菜单贴住点击点', (WidgetTester tester) async {
        final double dist = await menuOffsetFromClick(tester,
            scale: scale, mapThroughOverlay: true);
        expect(dist, lessThan(24.0 * scale),
            reason: 'overlay.globalToLocal 换算后菜单应贴住右键点，实测间隙=$dist');
      });
    }

    // 变异对照：证明上面的阈值真能抓住回归，而不是恒真断言。
    testWidgets('对照：不换算（修复前写法）在缩放下必然偏离', (WidgetTester tester) async {
      final double dist = await menuOffsetFromClick(tester,
          scale: 0.5, mapThroughOverlay: false);
      expect(dist, greaterThan(200.0),
          reason: '修复前把真实坐标当画布坐标，菜单应明显偏离点击点，实测间隙=$dist');
    });
  });

  group('不变式 B：菜单内容尺寸随界面大小线性缩放，不是平方', () {
    /// 返回菜单里 `fontSize: 14` 文字的**真实屏幕**渲染高度。
    Future<double> menuTextHeight(
      WidgetTester tester, {
      required double scale,
      required bool doubleScaleBug,
    }) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      late BuildContext pageContext;
      await tester.pumpWidget(wrap(
        scale: scale,
        page: Builder(builder: (BuildContext c) {
          pageContext = c;
          return const Scaffold(body: SizedBox.expand());
        }),
      ));
      await tester.pumpAndSettle();

      // 修复前：中和层内页面读 appUiScale 当 menuScale 再乘一次。
      final double menuScale = doubleScaleBug ? scale : 1.0;
      showMenu<String>(
        context: pageContext,
        position: const RelativeRect.fromLTRB(20, 20, 20, 20),
        items: <PopupMenuEntry<String>>[
          PopupMenuItem<String>(
            value: 'a',
            child: Text('ITEM', style: TextStyle(fontSize: 14.0 * menuScale)),
          ),
        ],
      );
      await tester.pumpAndSettle();
      // 同一个 test 内会连测两个 scale；pumpWidget 复用 Element 树，上一轮的
      // PopupMenuRoute 会留在 Navigator 栈里叠加出第二个 'ITEM'。必须断言唯一并在
      // measure 后 pop 掉，否则 `.first` 量到的是上一轮的菜单（会把 scale² 回归量成
      // 正常值，测试假绿）。
      expect(find.text('ITEM'), findsOneWidget,
          reason: '菜单应唯一——出现多个说明上一轮 route 未清理');
      final double h = tester.getRect(find.text('ITEM')).height;
      Navigator.of(pageContext).pop();
      await tester.pumpAndSettle();
      return h;
    }

    testWidgets('scale=2 时菜单文字恰好是 scale=1 的 2 倍', (WidgetTester tester) async {
      final double at1 =
          await menuTextHeight(tester, scale: 1.0, doubleScaleBug: false);
      final double at2 =
          await menuTextHeight(tester, scale: 2.0, doubleScaleBug: false);
      expect(at2 / at1, closeTo(2.0, 0.01),
          reason: '菜单落在缩放画布内，画布→屏幕已放大一次，比值应恰为 scale；'
              '实测 $at1 -> $at2');
    });

    // 变异对照：手动再乘一次 scale 会变成 4 倍（scale²），证明上面的断言抓得住回归。
    testWidgets('对照：手动乘 menuScale 会变成 4 倍（scale²）',
        (WidgetTester tester) async {
      final double at1 =
          await menuTextHeight(tester, scale: 1.0, doubleScaleBug: true);
      final double at2 =
          await menuTextHeight(tester, scale: 2.0, doubleScaleBug: true);
      expect(at2 / at1, closeTo(4.0, 0.01),
          reason: '双重缩放应产生 scale² 放大；实测 $at1 -> $at2');
    });
  });

  group('源码守卫：生产代码钉在正确范式上', () {
    String read(String path) =>
        File(path).readAsStringSync().replaceAll('\r\n', '\n');

    /// 剥掉整行注释：负向断言（`isNot(contains(...))`）必须只看真代码，否则解释
    /// 这段历史的注释本身会让守卫红——那是假失败，比假绿更容易被人删掉守卫。
    String stripComments(String s) => maskComments(s);

    String slice(String source, String start, String end) {
      final int s = source.indexOf(start);
      expect(s, isNonNegative, reason: '找不到起始标记：$start');
      final int e = source.indexOf(end, s + start.length);
      expect(e, isNonNegative, reason: '找不到结束标记：$end');
      return source.substring(s, e);
    }

    test('漫画阅读器右键菜单：锚点经 Overlay 换算，边界用 overlay.size', () {
      final String source =
          read('lib/src/media/manga/reader/manga_hibiki_page.dart');
      final String fn = slice(
        source,
        'Future<void> _showReaderContextMenu(String payloadJson)',
        'if (!mounted || action == null) return;',
      );

      expect(fn, contains('Overlay.of(context).context.findRenderObject()'),
          reason: '必须拿根 Overlay 的 RenderBox 做坐标换算');
      expect(fn, contains('overlay.globalToLocal(Offset(x, y))'),
          reason: 'JS 报的 clientX/clientY 是真实屏幕坐标，必须映射到 Overlay 本地');
      expect(
        RegExp(r'Rect\.fromLTWH\(\s*anchor\.dx,\s*anchor\.dy').hasMatch(fn),
        isTrue,
        reason: 'RelativeRect 必须锚在换算后的 anchor 上，不能是裸 x/y',
      );
      expect(fn, contains('Offset.zero & overlay.size'),
          reason: '边界必须用 overlay.size（画布空间）');
      expect(
        stripComments(fn),
        isNot(contains('MediaQuery.of(context).size')),
        reason: '中和层内 MediaQuery.size 是真实视口，不是 Overlay 边界（BUG-1438）',
      );
    });

    test('阅读器菜单 / 选区操作条：不得手动乘界面缩放', () {
      final String chrome =
          read('lib/src/pages/implementations/reader_hibiki/chrome.part.dart');
      final String shell =
          read('lib/src/pages/implementations/reader_hibiki_page.dart');

      // 注释里可以解释这段历史，但代码里不能再出现该 getter 与乘法。
      expect(
        stripComments(shell),
        isNot(contains('_readerImageMenuScale')),
        reason: '该 getter 是双重缩放根源，已删除（BUG-1438）',
      );
      expect(
        stripComments(chrome),
        isNot(contains('menuScale')),
        reason: '菜单在缩放画布内已天然跟随界面大小，再乘一次得 scale²（BUG-1438）',
      );
    });

    test('日志面板选区工具条：锚点经 Overlay 换算', () {
      final String source =
          read('lib/src/utils/components/hibiki_material_components.dart');
      final String fn = slice(
        source,
        'Widget _buildContextMenu(',
        'buttonItems: items,',
      );
      expect(fn, contains('overlayBox.globalToLocal(rawAnchor)'),
          reason: 'toolbar 挂根 Overlay（画布空间），锚点须换算（BUG-1438）');
      expect(
        fn,
        isNot(contains(
            'primaryAnchor: _lastPointerDownGlobalPosition ?? Offset.zero')),
        reason: '不得把真实屏幕坐标直接当 Overlay 锚点',
      );
    });
  });
}

/// 点 [p] 到矩形 [r] 的最短距离（点落在矩形内为 0）。
double _distanceToRect(Rect r, Offset p) {
  final double dx = math.max(0, math.max(r.left - p.dx, p.dx - r.right));
  final double dy = math.max(0, math.max(r.top - p.dy, p.dy - r.bottom));
  return math.sqrt(dx * dx + dy * dy);
}
