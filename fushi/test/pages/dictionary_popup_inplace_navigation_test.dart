import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';

import '../widgets/widget_test_helpers.dart';

/// 查词弹窗「原地跳转 + ← → 历史」（对齐 Hoshi Reader iOS：点词头 / 交叉引用链接 /
/// 汉字在同一个 WebView 里换词，顶栏 ← → 在历史页间来回；释义正文点词仍叠子层）。
///
/// 三层：
/// ① 顶栏 widget 行为：传 [DictionaryPopupHistoryNav] 才画两颗按钮、不可去的方向置灰
///    不消失、点按回调接线正确；不传 = 顶栏与从前一模一样。
/// ② 宿主接线源码守卫：三个建层宿主（书内 / mixin 家族 / 安卓独立查词窗）的
///    `onLinkClick` 都走 `navigatePopupInPlace`（不再 push 子层），都把 `historyNav` /
///    `restoreScrollTop` 传进 [DictionaryPopupLayer]；load-more 续查带词身份门。
/// ③ 滚动位恢复链路守卫：Dart 侧把 `restoreScrollTop` 注进 `__fushiPendingScrollTop`，
///    popup.js 在首发 / 尾批切片 / 尾批完成三处应用；三份 popup.js 镜像逐字节一致。
/// 控制器纯逻辑（后退 / 前进栈）在 dictionary_popup_controller_test.dart。
void main() {
  Future<void> pumpLayer(
    WidgetTester tester, {
    DictionaryPopupHistoryNav? historyNav,
  }) async {
    await tester.pumpWidget(
      buildTestApp(
        SizedBox(
          width: 360,
          height: 240,
          child: DictionaryPopupLayer(
            result: null,
            isSearching: false,
            webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
            historyNav: historyNav,
            onClose: () {},
            onDismiss: () {},
            onTextSelected: (text, rect) {},
            onLinkClick: (query, rect) {},
            onMineEntry: (fields) async => const MinePopupResult(),
            onDuplicateCheck: (expression, reading) async => false,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  FushiIconButton navButton(WidgetTester tester, String key) {
    final Finder f = find.byKey(ValueKey<String>(key));
    expect(f, findsOneWidget, reason: '顶栏必须有 $key');
    return tester.widget<FushiIconButton>(f);
  }

  testWidgets('不传 historyNav：顶栏没有 ← →（没跳过就不占顶栏，与 Hoshi 默认一致）',
      (WidgetTester tester) async {
    await pumpLayer(tester);
    expect(
        find.byKey(const ValueKey<String>('popup_history_back')), findsNothing);
    expect(find.byKey(const ValueKey<String>('popup_history_forward')),
        findsNothing);
    expect(find.byIcon(Icons.text_decrease), findsOneWidget,
        reason: 'A−/A+ 与关闭照旧');
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('传 historyNav：两颗按钮都画；不可去的方向置灰而不是消失', (WidgetTester tester) async {
    int backs = 0;
    int forwards = 0;
    await pumpLayer(
      tester,
      historyNav: DictionaryPopupHistoryNav(
        canGoBack: true,
        canGoForward: false,
        onBack: () => backs++,
        onForward: () => forwards++,
      ),
    );
    final FushiIconButton back = navButton(tester, 'popup_history_back');
    final FushiIconButton forward = navButton(tester, 'popup_history_forward');
    expect(back.enabled, true);
    expect(forward.enabled, false, reason: '栈顶没有前进页：按钮仍在（位置不跳），只是置灰');
    expect(back.icon, Icons.arrow_back);
    expect(forward.icon, Icons.arrow_forward);

    // 顺序：← → 在 A− 左边（左簇行首），关闭仍在最右。
    final double backX = tester
        .getRect(find.byKey(const ValueKey<String>('popup_history_back')))
        .left;
    final double forwardX = tester
        .getRect(find.byKey(const ValueKey<String>('popup_history_forward')))
        .left;
    final double zoomOutX =
        tester.getRect(find.byIcon(Icons.text_decrease)).left;
    final double closeX = tester.getRect(find.byIcon(Icons.close)).left;
    expect(backX, lessThan(forwardX));
    expect(forwardX, lessThan(zoomOutX));
    expect(zoomOutX, lessThan(closeX));

    await tester.tap(find.byKey(const ValueKey<String>('popup_history_back')));
    await tester.pump();
    expect(backs, 1);
    await tester
        .tap(find.byKey(const ValueKey<String>('popup_history_forward')));
    await tester.pump();
    expect(forwards, 0, reason: '置灰的方向点了不触发');
  });

  group('宿主接线源码守卫', () {
    // 本机 autocrlf 检出是 CRLF，CI 是 LF：统一成 LF 再找块边界。
    String read(String path) =>
        File(path).readAsStringSync().replaceAll('\r\n', '\n');

    test('三个建层宿主：onLinkClick 原地跳转，historyNav / restoreScrollTop 传进层', () {
      const Map<String, String> hosts = <String, String>{
        '书内 base_source_page': 'lib/src/pages/base_source_page.dart',
        'mixin 家族 dictionary_page_mixin':
            'lib/src/pages/implementations/dictionary_page_mixin.dart',
        '安卓独立查词窗 popup_dictionary_page':
            'lib/src/pages/implementations/popup_dictionary_page.dart',
      };
      hosts.forEach((String name, String path) {
        final String src = read(path);
        final RegExp linkClick =
            RegExp(r'onLinkClick:\s*\(query, localRect\)\s*=>\s*[\s\S]{0,120}?'
                r'navigat\w*InPlace\(');
        expect(linkClick.hasMatch(src), isTrue,
            reason: '$name 的 onLinkClick 必须原地跳转（不再 push 子层）');
        expect(
            src.contains('historyNav: entry.hasNavigationHistory') ||
                src.contains('historyNav: item.hasNavigationHistory'),
            isTrue,
            reason: '$name 必须按 hasNavigationHistory 把 ← → 传进层');
        expect(
            src.contains('restoreScrollTop: entry.restoreScrollTop') ||
                src.contains('restoreScrollTop: item.restoreScrollTop'),
            isTrue,
            reason: '$name 必须把待恢复滚动位透传进层');
      });
    });

    test('原地跳转：空结果不跳、迟到结果按词身份丢弃（两份 navigatePopupInPlace）', () {
      for (final String path in <String>[
        'lib/src/pages/base_source_page.dart',
        'lib/src/pages/implementations/dictionary_page_mixin.dart',
      ]) {
        final String src = read(path);
        final int start = src.indexOf('Future<void> navigatePopupInPlace(');
        expect(start, isNonNegative, reason: '$path 缺 navigatePopupInPlace');
        final int end = src.indexOf('\n  }\n', start);
        final String fn = src.substring(start, end);
        expect(
            fn.contains(
                'result.entries.isEmpty && result.kanjiResults.isEmpty'),
            isTrue,
            reason: '$path：空结果不跳（Hoshi：count > 0 才 redirect）');
        expect(fn.contains('searchTerm != termAtStart'), isTrue,
            reason: '$path：往返期间本层已换词的迟到结果必须丢弃');
        expect(fn.contains('currentScrollTop()'), isTrue,
            reason: '$path：离开当前页前必须记滚动位');
        expect(fn.contains('.navigateInPlace('), isTrue);
      }
    });

    test('load-more 续查带词身份门（同一 entry 会被原地换词）', () {
      final String base = read('lib/src/pages/base_source_page.dart');
      final int s1 = base.indexOf('Future<void> loadMoreForLayer(');
      final String f1 = base.substring(s1, base.indexOf('\n  }\n', s1));
      expect(f1.contains('entry.searchTerm != term'), isTrue,
          reason: 'base_source_page.loadMoreForLayer 必须核对词未变');

      final String mixin =
          read('lib/src/pages/implementations/dictionary_page_mixin.dart');
      final int s2 = mixin.indexOf('Future<void> loadMoreForEntry(');
      final String f2 = mixin.substring(s2, mixin.indexOf('\n  }\n', s2));
      expect(f2.contains('entry.searchTerm == term'), isTrue,
          reason: 'mixin.loadMoreForEntry 必须核对词未变');
    });
  });

  group('滚动位恢复链路', () {
    test('Dart 全量渲染前注入 __fushiPendingScrollTop（load-more 增量不注）', () {
      final String src = File(
        'lib/src/pages/implementations/dictionary_popup_webview.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final int start = src.indexOf('void _pushResults()');
      final String fn = src.substring(start, src.indexOf('\n  }\n', start));
      expect(fn.contains('widget.restoreScrollTop ?? 0'), isTrue);
      final int incremental = fn.indexOf('window.updatePopupIncremental();');
      final int pending = fn.indexOf('window.__fushiPendingScrollTop =');
      final int reset = fn.indexOf('window.__fushiResetPopupScroll();');
      expect(incremental, isNonNegative);
      expect(pending, greaterThan(reset),
          reason: '先归零再写 pending，pending 才是渲染后的最终落点');
      expect(pending, greaterThan(incremental),
          reason: 'pending 只在全量渲染分支（增量追加保持当前滚动位）');
    });

    test('popup.js：首发 / 尾批切片 / 尾批完成三处应用 pending，三份镜像一致', () {
      String readJs(String path) =>
          File(path).readAsStringSync().replaceAll('\r\n', '\n');
      final String js = readJs('assets/popup/popup.js');
      expect(js.contains('function __fushiApplyPendingScrollTop(isFinal)'),
          isTrue);
      final int fire = js.indexOf('function _firePopupRendered(');
      final String fireFn = js.substring(fire, js.indexOf('\n}\n', fire));
      expect(fireFn.contains('__fushiApplyPendingScrollTop(!stillRendering)'),
          isTrue,
          reason: '首发（仍在渲染 → 够高才滚）与尾批完成（final → 兜底必滚）');
      final int tail =
          js.indexOf('scheduleRenderTail(renderNextDictionaryBlock);');
      final String beforeTail = js.substring(tail - 200, tail);
      expect(beforeTail.contains('__fushiApplyPendingScrollTop(false)'), isTrue,
          reason: '每个尾批切片后试一次：内容一够高就恢复，不等全部渲完');

      for (final String mirror in <String>[
        'assets/browser_extension/vendor/popup.js',
        '../tools/browser-extension/vendor/popup.js',
      ]) {
        expect(readJs(mirror), js,
            reason: '$mirror 必须与 assets/popup/popup.js 逐字节一致');
      }
    });
  });
}
