import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

/// BUG-1692 守卫：Apple 平台上「平台视图之上不得压着大块 Flutter 绘制」。
///
/// 根因（macOS engine，`FlutterMutatorView.mm` / `FlutterCompositor.mm`）：
/// 合成时 engine 逐个遍历排在平台视图**之后**的 backing-store 图层，把它们的
/// `paint_region` 与该平台视图求交后写进 `_hitTestIgnoreRegion`；而
/// `FlutterMutatorView.hitTest:` 对落在忽略区里的点**直接 `return nil`**：
///
/// ```objc
/// for (const auto& region : _hitTestIgnoreRegion) {
///   if (CGRectContainsPoint(region, localPoint)) { return nil; }
/// }
/// return [super hitTest:point];
/// ```
///
/// 于是只要平台视图之后那张 PictureLayer 的 bounds 覆盖了它，WKWebView 就**一个
/// 鼠标事件都收不到**——用户看到的是「查词框点哪都没反应」「阅读器划词/翻页全失灵」。
///
/// 而 Flutter 侧默认会把「同一个 RepaintBoundary 内、平台视图之后的所有绘制」合并
/// 成**一张** PictureLayer，其 cull rect = 该 RepaintBoundary 的整个矩形。一个角落
/// 里的拖拽把手，足以让整块 WebView 失聪。
///
/// 两条可落地的解法，本守卫各钉一条：
/// 1. 排在平台视图之后的 chrome **各自包 RepaintBoundary**，让忽略区收缩到自身；
/// 2. 描边这类「天然横跨全域」的 foreground 绘制，改到子节点**之前**绘制
///    （[FushiPopupSurface.borderOnForeground] = false）。
void main() {
  group('BUG-1692 FushiPopupSurface.borderOnForeground', () {
    testWidgets('默认 true —— 与 Material 默认一致，纯 Flutter 子树观感不变',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: FushiPopupSurface(child: SizedBox(width: 40, height: 40)),
        ),
      );
      final Material material = tester.widget<Material>(
        find.descendant(
          of: find.byType(FushiPopupSurface),
          matching: find.byType(Material),
        ),
      );
      expect(material.borderOnForeground, isTrue);
    });

    testWidgets('传 false 时必须真的透到 Material —— 否则描边仍画在平台视图之后',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: FushiPopupSurface(
            borderOnForeground: false,
            child: SizedBox(width: 40, height: 40),
          ),
        ),
      );
      final Material material = tester.widget<Material>(
        find.descendant(
          of: find.byType(FushiPopupSurface),
          matching: find.byType(Material),
        ),
      );
      expect(
        material.borderOnForeground,
        isFalse,
        reason: '参数没透下去 ⇒ 描边回到 foregroundPainter ⇒ 查词浮层在 macOS 上'
            '整块失去鼠标输入（BUG-1692 回归）',
      );
    });
  });

  group('BUG-1692 源码守卫：平台视图之后的绘制', () {
    test('查词浮层 surface 必须 borderOnForeground: false', () {
      final File f = File(
        'lib/src/pages/implementations/dictionary_popup_layer.dart',
      );
      expect(f.existsSync(), isTrue, reason: '浮层文件被移动了，守卫需同步更新');
      final String src = f.readAsStringSync();

      // 定位浮层本体那个 FushiPopupSurface(...) 调用并检查其实参。
      final int at = src.indexOf('FushiPopupSurface(');
      expect(at, greaterThan(-1), reason: '浮层不再用 FushiPopupSurface，守卫需同步更新');
      final String call = src.substring(at, at + 900);
      expect(
        call.contains('borderOnForeground: false'),
        isTrue,
        reason: '查词浮层里装的是原生 WebView（平台视图）。描边走 foregroundPainter 时'
            '会画在 WebView 之后、bounds 覆盖整个浮层，macOS engine 据此把整块浮层写进'
            '_hitTestIgnoreRegion，hitTest: 处处 return nil ⇒「点哪都没反应」（BUG-1692）',
      );
    });

    test('浮层尺寸拖拽把手必须自带 RepaintBoundary', () {
      final String src = File(
        'lib/src/pages/implementations/dictionary_popup_layer.dart',
      ).readAsStringSync();
      final int at = src.indexOf('_PopupResizeGrip(');
      expect(at, greaterThan(-1), reason: '把手组件改名了，守卫需同步更新');
      // 把手排在 WebView 之后绘制：其前方 400 字符内必须出现 RepaintBoundary。
      final String before = src.substring((at - 400).clamp(0, at), at);
      expect(
        before.contains('RepaintBoundary'),
        isTrue,
        reason: '把手画在浮层 WebView 之后。不自带 RepaintBoundary 就会并进 cull rect ='
            '整个浮层的 PictureLayer，macOS 上整块 WebView 收不到鼠标事件（BUG-1692）',
      );
    });

    test('阅读器排在 WebView 之后的 chrome 必须自带 RepaintBoundary', () {
      final String chrome = File(
        'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
      ).readAsStringSync();

      // 底栏：_wrapBottomChromeBar 的 Positioned 直接子节点。
      final int bottomAt = chrome.indexOf('Widget _wrapBottomChromeBar(');
      expect(bottomAt, greaterThan(-1), reason: '底栏包装器改名了，守卫需同步更新');
      expect(
        chrome.substring(bottomAt, bottomAt + 900).contains('RepaintBoundary'),
        isTrue,
        reason: '底栏画在阅读器 WebView 之后。少了 RepaintBoundary，其 cull rect 就是'
            '整窗，macOS 上整块正文 WebView 失去点击/划词/翻页（BUG-1692）',
      );

      // 顶部进度 pill。
      final int topAt = chrome.indexOf('Widget _buildTopProgressBar(');
      expect(topAt, greaterThan(-1), reason: '顶部进度条改名了，守卫需同步更新');
      expect(
        chrome.substring(topAt).contains('RepaintBoundary(child: pill)'),
        isTrue,
        reason: '进度 pill 画在阅读器 WebView 之后，同上（BUG-1692）',
      );
    });

    test('阅读器 macOS 标题栏拖拽区必须自带 RepaintBoundary', () {
      final String page = File(
        'lib/src/pages/implementations/reader_fushi_page.dart',
      ).readAsStringSync();
      final int at = page.indexOf('fushi_reader_window_drag_area');
      expect(at, greaterThan(-1), reason: '拖拽区 key 改了，守卫需同步更新');
      final String before = page.substring((at - 600).clamp(0, at), at);
      expect(
        before.contains('RepaintBoundary'),
        isTrue,
        reason: 'macOS 标题栏拖拽区画在阅读器 WebView 之后，同上（BUG-1692）',
      );
    });
  });
}
