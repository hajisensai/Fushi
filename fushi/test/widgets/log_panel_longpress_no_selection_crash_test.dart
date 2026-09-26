import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

/// BUG-1582 · 错误日志面板长按触发选区端点空断言。
///
/// 用户栈（release 构建，2026-08-12 19:33:43）：
/// `_ScrollableSelectionContainerDelegate._updateDragLocationsFromGeometries`
/// (`scrollable.dart:1361` = `geometry.endSelectionPoint!`) ← `handleSelectWord`
/// ← `SelectableRegionState._handleTouchLongPressStart`。
///
/// `handleSelectWord` **无条件**调 `_updateDragLocationsFromGeometries()`（同文件
/// `handleSelectAll` 是有 `currentSelectionStartIndex != -1` 守卫的），所以只要
/// 长按后 `currentSelectionEndIndex != -1` 而那个 selectable 的
/// `SelectionGeometry.endSelectionPoint` 为 null，release 下（`assert` 不执行）
/// 就抛空断言。
///
/// 本文件用来**定位真实触发位置**：逐个候选长按点做实验，看哪个能让端点为 null。
/// 未复现的候选也留着当回归网。
void main() {
  Widget buildSubject(String log) {
    return MaterialApp(
      home: Scaffold(
        body: FushiLogPanel(log: log, shareAction: (String _) {}),
      ),
    );
  }

  String longLog({int lines = 400}) {
    final StringBuffer buf = StringBuffer();
    for (int i = 0; i < lines; i++) {
      buf
        ..writeln('[2026-08-12 19:33:43.$i] SomeSource.someMethod')
        ..writeln('#$i      SomeFrame.someCall (package:flutter/src/x.dart:$i)')
        // 真实 ErrorLogEntry.format() 会在这里多出一个空行（writeln 给本已以
        // '\n' 结尾的堆栈再补一个换行）。
        ..writeln()
        ..writeln('─' * 60);
    }
    return buf.toString();
  }

  testWidgets('候选①：长按夹在两条可见行之间的空行', (WidgetTester tester) async {
    const String log = 'first visible line\n\nsecond visible line\n';
    await tester.pumpWidget(buildSubject(log));
    await tester.pumpAndSettle();

    final Offset a = tester.getBottomLeft(find.text('first visible line'));
    final Offset b = tester.getTopLeft(find.text('second visible line'));
    await tester.longPressAt(Offset(a.dx + 8, (a.dy + b.dy) / 2));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('候选②：长按最后一行下方的空白区（无子节点包含该点）', (WidgetTester tester) async {
    const String log = 'only line\n';
    await tester.pumpWidget(buildSubject(log));
    await tester.pumpAndSettle();

    // 列表底部远离任何行的空白处。
    final Rect listRect = tester.getRect(find.byType(ListView));
    final Offset below = Offset(listRect.center.dx, listRect.bottom - 8);
    await tester.longPressAt(below);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('候选③：长按被视口裁掉一半的行（端点在视口外）', (WidgetTester tester) async {
    await tester.pumpWidget(buildSubject(longLog()));
    await tester.pumpAndSettle();

    // 滚到中段，让顶边那一行只露出一条缝。
    await tester.drag(find.byType(ListView), const Offset(0, -1234.5));
    await tester.pumpAndSettle();

    final Rect listRect = tester.getRect(find.byType(ListView));
    await tester.longPressAt(Offset(listRect.center.dx, listRect.top + 2));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('候选④：长按超视口长行的右端（ClipRect 外，BUG-925 同族坐标）',
      (WidgetTester tester) async {
    final String log = '${'x' * 4000}\nshort\n';
    await tester.pumpWidget(buildSubject(log));
    await tester.pumpAndSettle();

    final Rect listRect = tester.getRect(find.byType(ListView));
    final Offset longLineRight = Offset(
      listRect.right - 4,
      tester.getCenter(find.textContaining('xxxx')).dy,
    );
    await tester.longPressAt(longLineRight);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  // ── 上游 flutter/flutter#119355 给出的真实复现序列 ──────────────────────
  // 「SelectionArea 包 scrollable → 先选中文字 → 滚动到别处 → 再长按」。
  // 前 4 条候选都漏了「先有既有选区」这一步，所以永远碰不到：delegate 的
  // currentSelectionEndIndex 还指着旧选区那一行，而 ListView.builder 已经把它
  // 回收/detach（框架 getSelectionGeometry 明说 detached/off-screen 时端点可为
  // null），下一次 handleSelectWord 读它的 geometry 就是 null 端点。
  // 与本仓 BUG-694 注释记录的机制同源。
  testWidgets('候选⑤：先选中 → 滚走（端点行被回收）→ 再长按', (WidgetTester tester) async {
    await tester.pumpWidget(buildSubject(longLog()));
    await tester.pumpAndSettle();

    // ① 先在顶部建立一个真实选区。
    final Rect listRect = tester.getRect(find.byType(ListView));
    await tester.longPressAt(Offset(listRect.center.dx, listRect.top + 40));
    await tester.pumpAndSettle();

    // ② 滚很远，让①的端点行被 ListView.builder 回收。
    await tester.drag(find.byType(ListView), const Offset(0, -6000));
    await tester.pumpAndSettle();

    // ③ 在新位置再长按一次 —— 崩溃就发生在这一步。
    await tester.longPressAt(Offset(listRect.center.dx, listRect.center.dy));
    await tester.pumpAndSettle();

    expect(
      tester.takeException(),
      isNull,
      reason: '既有选区的端点行被回收后再长按，触发了框架的选区端点空断言'
          '（BUG-1582 / flutter#119355）',
    );
  });

  testWidgets('候选⑥：全选 → 滚走 → 再长按（上游原始序列）', (WidgetTester tester) async {
    await tester.pumpWidget(buildSubject(longLog()));
    await tester.pumpAndSettle();

    final Rect listRect = tester.getRect(find.byType(ListView));
    // ① 全选（上游 issue 用的是右键菜单「全选」，等价于对 region 发 selectAll）。
    final SelectableRegionState region =
        tester.state<SelectableRegionState>(find.byType(SelectableRegion));
    region.selectAll();
    await tester.pumpAndSettle();

    // ② 滚到远处。
    await tester.drag(find.byType(ListView), const Offset(0, -6000));
    await tester.pumpAndSettle();

    // ③ 长按已高亮的片段。
    await tester.longPressAt(Offset(listRect.center.dx, listRect.center.dy));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  // ── BUG-2715：行集合被**非滚动**原因换掉 ─────────────────────────────────
  // BUG-1582 只在用户滚动时清选区；另两个来源——日志内容变化（错误日志页
  // 监听日志服务，新条目一来整段重拼）、视口变高度（转屏 / 分屏）——同样让
  // 选区端点行的 Selectable 离开 registrar，下标只被减一、指向无选区的片段。
  // 之后长按空白处（空行 / 行尾 / 内边距都命不中 Selectable）就读到空端点。
  group('BUG-2715 selection longpress null crash', () {
    // 真实错误日志形状：新条目在最前，每条之间有空行和分隔线。
    String entries(int count, {int from = 0}) {
      final StringBuffer buf = StringBuffer();
      for (int i = from + count - 1; i >= from; i--) {
        buf
          ..writeln('[2026-09-26 10:00:$i] Source$i.method')
          ..writeln('#0 Frame$i.call (package:x/y.dart:$i)')
          ..writeln()
          ..writeln('─' * 60);
      }
      return buf.toString();
    }

    Finder frameLine(int i) =>
        find.text('#0 Frame$i.call (package:x/y.dart:$i)');

    // 真机触屏长按：touch 指针按住超过 kLongPressTimeout 再抬起。
    Future<void> touchLongPress(WidgetTester tester, Offset at) async {
      final TestGesture gesture =
          await tester.startGesture(at, kind: PointerDeviceKind.touch);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pump();
    }

    // 面板内是否有非折叠选区（逐个 RenderParagraph 看它自己的选区）。
    bool hasSelectedText(WidgetTester tester) => tester
        .renderObjectList<RenderParagraph>(find.byType(RichText))
        .any((RenderParagraph p) =>
            p.selections.any((TextSelection s) => !s.isCollapsed));

    Future<void> longPressBlankCorner(WidgetTester tester) async {
      final Rect list = tester.getRect(find.byType(ListView));
      await touchLongPress(tester, Offset(list.right - 10, list.bottom - 10));
      await tester.pump();
    }

    test('BUG-2715 logUpdateReplacesRows：只有换掉既有文字行才算', () {
      // 纯尾部追加（TODO-1380 要求菜单保持打开的场景）不换行。
      expect(logUpdateReplacesRows(<String>['a', 'b'], <String>['a', 'b', 'c']),
          isFalse);
      // 末尾空行被填上文字：空行本就没有选区片段。
      expect(logUpdateReplacesRows(<String>['a', ''], <String>['a', 'x', '']),
          isFalse);
      // 新条目插在最前（错误 / 调试日志页真实顺序）。
      expect(logUpdateReplacesRows(<String>['a', 'b'], <String>['n', 'a', 'b']),
          isTrue);
      // 截断 / 清空。
      expect(logUpdateReplacesRows(<String>['a', 'b'], <String>['a']), isTrue);
      expect(logUpdateReplacesRows(<String>['a'], <String>['']), isTrue);
    });

    testWidgets('BUG-2715 日志内容变化后长按空白处不崩', (WidgetTester tester) async {
      await tester.pumpWidget(buildSubject(entries(5)));
      await tester.pump();

      // ① 长按选中一个词（真实选区）。
      await touchLongPress(tester, tester.getCenter(frameLine(1)));
      expect(hasSelectedText(tester), isTrue, reason: '前置：长按确实建立了选区');

      // ② 日志服务推来新内容（ErrorLogPage._onLogChanged 同路径）。
      await tester.pumpWidget(buildSubject(entries(2, from: 10)));
      await tester.pump();
      await tester.pump();
      expect(
        hasSelectedText(tester),
        isFalse,
        reason: '内容换了，旧选区已不指向同一段文字，必须被清掉',
      );

      // ③ 长按命不中任何行的空白处 —— 修复前这里抛
      //    scrollable.dart `_updateDragLocationsFromGeometries` 的端点断言。
      await longPressBlankCorner(tester);
      expect(tester.takeException(), isNull);

      // ④ 选区能力不受影响：再长按一行文字仍能选中。
      await touchLongPress(tester, tester.getCenter(frameLine(11)));
      expect(tester.takeException(), isNull);
      expect(hasSelectedText(tester), isTrue);
    });

    testWidgets('BUG-2715 视口变矮回收端点行后长按空白处不崩', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(buildSubject(entries(200)));
      await tester.pump();

      // ① 在竖屏视口底部选中一行。
      final Rect portrait = tester.getRect(find.byType(ListView));
      await touchLongPress(
        tester,
        Offset(portrait.left + 40, portrait.bottom - 30),
      );

      // ② 转成矮视口：端点行落出 cacheExtent 被回收。
      tester.view.physicalSize = const Size(2400, 600);
      await tester.pump();
      await tester.pump();

      // ③ 修复前这里抛外层 StaticSelectionContainerDelegate 的空断言。
      await longPressBlankCorner(tester);
      expect(tester.takeException(), isNull);
    });
  });
}
