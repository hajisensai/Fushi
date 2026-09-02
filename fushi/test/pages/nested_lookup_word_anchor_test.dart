import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';

/// BUG-2054：弹窗内嵌套查词的子弹窗必须锚在**整词 bbox** 上，不是「点击的首字符」。
///
/// 触发路径：视频页字幕查词 → 弹窗内选中跨两行的词（「とりとめ」在第一行末、
/// 「もなく」在第二行头）→ 子弹窗压在第一行下方，把选区所在的第二行整个盖住。
/// 根因是锚点语义：selection.js `getSelectionRect()` 只返回首字符矩形（发
/// textSelected 时词典还没查、匹配长度未知），而查词命中后 `highlightSelection`
/// 返回的整词 bbox（跨行时 bottom 落在最后一行）此前被 Dart 侧丢弃。
///
/// 与 popupWordScreenRect 的 BUG-129、阅读器正文车道的 BUG-767 是同一条不变式：
/// **弹窗不覆盖被查词**。
void main() {
  // 父卡在屏幕 (100,50)，宽 200 高 300，header 48px ⇒ 其 WebView 视口原点 (100,98)。
  const double headerHeight = 48;
  const Rect parentCard = Rect.fromLTWH(100, 50, 200, 300);

  // 被查词在父卡 WebView 视口内的坐标（CSS px）：
  // 第一行 y 20..36 的「とりとめ」+ 第二行 y 36..56 的「もなく」。
  const Rect firstCharLocal = Rect.fromLTWH(10, 20, 16, 16); // 点击的「と」
  const Rect wholeWordLocal = Rect.fromLTWH(10, 20, 120, 36); // 高亮回报的整词 bbox

  // 映射到屏幕：x + 100，y + 98。
  const Rect firstCharScreen = Rect.fromLTWH(110, 118, 16, 16);
  const Rect wholeWordScreen = Rect.fromLTWH(110, 118, 120, 36);

  Future<GlobalKey> pumpParentCard(WidgetTester tester) async {
    final GlobalKey webViewKey = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: <Widget>[
            Positioned(
              left: parentCard.left,
              top: parentCard.top,
              width: parentCard.width,
              height: parentCard.height,
              // 与 DictionaryPopupLayer._buildContent 同构：header 在上，WebView 在下。
              child: Column(
                children: <Widget>[
                  const SizedBox(height: headerHeight),
                  Expanded(child: Container(key: webViewKey)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return webViewKey;
  }

  /// 父层（index 0，可见）+ 刚 push 的子层（index 1）。[childVisible] false 模拟
  /// 「已挂结果、正等自己的 WebView 渲染完才翻可见」（markPendingReveal）——高亮
  /// eval 的往返通常早于那次 reveal，这正是重锚到达时的真实状态。
  DictionaryPopupController stackWithChild({bool childVisible = false}) {
    final DictionaryPopupController c =
        DictionaryPopupController(lowMemory: false);
    c.beginTop(
      term: '親',
      rect: const Rect.fromLTWH(0, 0, 1, 1),
      reuseWarmSlot: false,
      replaceStack: false,
      visible: true,
    );
    c.pushChild(
      term: 'とりとめもなく',
      rect: firstCharScreen,
      parentIndex: 0,
      visible: childVisible,
    );
    return c;
  }

  group('BUG-2054 嵌套子弹窗按整词 bbox 重锚', () {
    testWidgets('跨行选区：子层锚点从首字符矩形改成整词 bbox（含第二行）', (tester) async {
      final GlobalKey webViewKey = await pumpParentCard(tester);
      final DictionaryPopupController c = stackWithChild();

      // 前置：子层现有锚点确实就是「首字符」经同一条转换落到屏幕的矩形
      // （即 textSelected 送上来的 args[1]），不是手写常量。
      expect(
        popupWordScreenRect(
          webViewKey: webViewKey,
          localRect: firstCharLocal,
          fallback: Rect.zero,
        ),
        firstCharScreen,
      );

      final bool changed = reanchorNestedPopupToWord(
        controller: c,
        parentWebViewKey: webViewKey,
        parentIndex: 0,
        wordLocalRect: wholeWordLocal,
        fallback: firstCharScreen,
      );

      expect(changed, isTrue);
      expect(c.entries[1].selectionRect, wholeWordScreen);
      // 关键：锚点底边必须落到选区**最后一行**的底，而不是第一行的底。
      expect(
        c.entries[1].selectionRect.bottom,
        greaterThan(firstCharScreen.bottom),
        reason: '锚点仍停在第一行 ⇒ 子弹窗会盖住选区的第二行',
      );
    });

    testWidgets('已可见的子层同样重锚（reveal 早于高亮回报时）', (tester) async {
      final GlobalKey webViewKey = await pumpParentCard(tester);
      final DictionaryPopupController c = stackWithChild(childVisible: true);

      expect(
        reanchorNestedPopupToWord(
          controller: c,
          parentWebViewKey: webViewKey,
          parentIndex: 0,
          wordLocalRect: wholeWordLocal,
          fallback: firstCharScreen,
        ),
        isTrue,
      );
      expect(c.entries[1].selectionRect, wholeWordScreen);
    });

    testWidgets('无 bbox（无匹配 / eval 失败）：保持原锚点，不动栈', (tester) async {
      final GlobalKey webViewKey = await pumpParentCard(tester);
      final DictionaryPopupController c = stackWithChild();

      expect(
        reanchorNestedPopupToWord(
          controller: c,
          parentWebViewKey: webViewKey,
          parentIndex: 0,
          wordLocalRect: null,
          fallback: firstCharScreen,
        ),
        isFalse,
      );
      expect(c.entries[1].selectionRect, firstCharScreen);
    });

    testWidgets('零面积 bbox：视为无效，保持原锚点', (tester) async {
      final GlobalKey webViewKey = await pumpParentCard(tester);
      final DictionaryPopupController c = stackWithChild();

      expect(
        reanchorNestedPopupToWord(
          controller: c,
          parentWebViewKey: webViewKey,
          parentIndex: 0,
          wordLocalRect: const Rect.fromLTWH(10, 20, 0, 0),
          fallback: firstCharScreen,
        ),
        isFalse,
      );
      expect(c.entries[1].selectionRect, firstCharScreen);
    });

    testWidgets('子层已被更新的查词清出栈：迟到的重锚 no-op（不错位到别的层）',
        (tester) async {
      final GlobalKey webViewKey = await pumpParentCard(tester);
      final DictionaryPopupController c = stackWithChild();
      c.truncateTo(1); // 只剩父层
      final Rect parentRect = c.entries[0].selectionRect;

      expect(
        reanchorNestedPopupToWord(
          controller: c,
          parentWebViewKey: webViewKey,
          parentIndex: 0,
          wordLocalRect: wholeWordLocal,
          fallback: firstCharScreen,
        ),
        isFalse,
      );
      expect(c.entries[0].selectionRect, parentRect, reason: '不得改到父层身上');
    });

    testWidgets('父卡 RenderBox 不可用：退回既有锚点，不写入 fallback', (tester) async {
      await pumpParentCard(tester);
      final GlobalKey orphan = GlobalKey(); // 从未挂载
      final DictionaryPopupController c = stackWithChild();

      expect(
        reanchorNestedPopupToWord(
          controller: c,
          parentWebViewKey: orphan,
          parentIndex: 0,
          wordLocalRect: wholeWordLocal,
          fallback: firstCharScreen,
        ),
        isFalse,
      );
      expect(c.entries[1].selectionRect, firstCharScreen);
    });
  });

  group('BUG-2054 重锚后的落位（用户报告的现象）', () {
    // 屏幕坐标下的两行：第一行 118..134，第二行 134..154。
    const Size screen = Size(800, 600);

    test('锚在首字符 ⇒ 弹窗压住选区的第二行', () {
      final Rect popup = calcPopupPosition(
        selectionRect: firstCharScreen,
        screen: screen,
        maxHeight: 360,
      );
      expect(popup.top, lessThan(wholeWordScreen.bottom),
          reason: '这就是用户截图里的现象：弹窗顶边在第二行之上');
    });

    test('锚在整词 bbox ⇒ 弹窗完整落在选区之下', () {
      final Rect popup = calcPopupPosition(
        selectionRect: wholeWordScreen,
        screen: screen,
        maxHeight: 360,
      );
      expect(popup.top, greaterThanOrEqualTo(wholeWordScreen.bottom));
      expect(popup.bottom, lessThanOrEqualTo(screen.height));
    });
  });

  group('BUG-2054 reanchorEntry 的门是「隐身热槽」而非「不可见」', () {
    test('等待 reveal 的子层（非热槽、暂不可见）可以重锚', () {
      final DictionaryPopupController c = stackWithChild();
      final DictionaryPopupEntry child = c.entries[1];
      expect(child.visible, isFalse);
      expect(child.isWarmSlot, isFalse);

      int notifies = 0;
      c.addListener(() => notifies++);
      c.reanchorEntry(child, wholeWordScreen);

      expect(child.selectionRect, wholeWordScreen);
      expect(notifies, 1, reason: 'reveal 前改锚点才能一次到位、零跳变');
    });

    test('隐身热槽仍不受迟到回调影响（BUG-717 ② 既有不变式）', () {
      final DictionaryPopupController c =
          DictionaryPopupController(lowMemory: false)..seedWarmSlot();
      final DictionaryPopupEntry warm = c.entries.first;
      expect(warm.isWarmSlot, isTrue);

      int notifies = 0;
      c.addListener(() => notifies++);
      c.reanchorEntry(warm, wholeWordScreen);

      expect(warm.selectionRect, isNot(wholeWordScreen));
      expect(notifies, 0);
    });
  });

  group('BUG-2054 源码守卫：四条嵌套车道都不得再丢弃 highlightSelection 的 bbox', () {
    // flutter test 的 cwd 是 fushi 包根。
    final File webview = File(
      'lib/src/pages/implementations/dictionary_popup_webview.dart',
    );
    final File mixin = File(
      'lib/src/pages/implementations/dictionary_page_mixin.dart',
    );
    final File base = File('lib/src/pages/base_source_page.dart');

    test('弹窗 WebView 的 highlightSelection 交回 Rect（不是 void 裸 eval）', () {
      final String src = webview.readAsStringSync();
      expect(
        src.contains('Future<Rect?> highlightSelection(int charCount)'),
        isTrue,
        reason: 'highlightSelection 退回 void ⇒ 整词 bbox 又被丢掉',
      );
      expect(
        src.contains('ReaderSelectionScripts.highlightRectFromResult('),
        isTrue,
        reason: '必须复用阅读器车道的解析器，不另造第二份',
      );
      expect(
        src.contains('ReaderSelectionScripts.highlightInvocation('),
        isTrue,
        reason: 'eval 必须走带 JSON.stringify 的共享调用串，否则拿不到返回值',
      );
    });

    test('mixin 车道两个回调都取回 bbox 并重锚子层', () {
      final String src = mixin.readAsStringSync();
      expect(
        'await entry.webViewKey.currentState?.highlightSelection(count)'
            .allMatches(src)
            .length,
        greaterThanOrEqualTo(2),
        reason: 'onTextSelected / onLinkClick 未各自取回整词 bbox',
      );
      expect(
        'reanchorNestedPopupToWord('.allMatches(src).length,
        greaterThanOrEqualTo(2),
        reason: 'mixin 两个回调未各自重锚子层',
      );
    });

    test('阅读器车道两个回调都取回 bbox 并重锚子层', () {
      final String src = base.readAsStringSync();
      expect(
        'await item.webViewKey.currentState?.highlightSelection(count)'
            .allMatches(src)
            .length,
        greaterThanOrEqualTo(2),
        reason: 'onTextSelected / onLinkClick 未各自取回整词 bbox',
      );
      expect(
        'reanchorNestedPopupToWord('.allMatches(src).length,
        greaterThanOrEqualTo(2),
        reason: 'base_source_page 两个回调未各自重锚子层',
      );
    });
  });
}
