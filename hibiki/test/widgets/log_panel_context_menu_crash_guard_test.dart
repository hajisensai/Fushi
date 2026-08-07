import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/hibiki_material_components.dart';

import '../helpers/source_guard.dart';

// TODO-1380 / BUG-694：日志面板选中文本弹出右键菜单后崩溃
// `Null check operator used on a null value`（用户日志 2026-07-10 01:21，两条同栈
// 连发：#0 SelectableRegionState.startGlyphHeight → #1 contextMenuAnchors →
// #2 _HibikiLogPanelState._buildContextMenu）。
//
// 崩溃链（Flutter 3.44 selectable_region.dart）：
//  * `contextMenuAnchors` 只在首次求值用「右键位置」`_lastSecondaryTapDownPosition`
//    当锚点，且**用一次即清空**（SDK 注释 "Clear the state ... after use"）；
//  * 之后任何一次 toolbar 重建（选区几何变化 → SelectionOverlay.markNeedsBuild →
//    ContextMenuController.markNeedsBuild → overlay entry 重建，或 LayoutBuilder
//    重建链）再求值 contextMenuAnchors 都退回 glyph 路径：`startGlyphHeight` 对
//    `_selectionDelegate.value.startSelectionPoint!` 空断言；
//  * 而日志面板是「懒加载 ListView.builder + 持续追加的日志流」：选区端点所在行
//    的 render object 可被滚动回收 / 内容更新 detach，框架 getSelectionGeometry
//    对 detached selectable 求 transform 得 NaN（SDK 注释 "It can be NaN if it is
//    detached or off-screen"）→ `if (start.isFinite)` 不成立 → 端点为 null 但
//    `_hasSelectionOverlayGeometry`（OR 语义）仍为真 → 菜单不被框架收走，重建即崩。
//
// 修复：锚点自持——菜单只能由面板内的一次 pointer down（右键 / 长按）召出，面板
// 的 Listener 先于 SelectionArea 看到它并记下全局坐标；`_buildContextMenu` 用这个
// 稳定锚点构造 TextSelectionToolbarAnchors，**每次重建幂等**，彻底不再读依赖完整
// 选区几何的 `contextMenuAnchors`。
//
// 复现边界（为什么 headless 测不到那次空断言本身）：flutter_test 里 ListView 回收
// 离屏行时 Selectable 的 remove 是同步簿记——起点行被回收会把选区索引清成 -1，几何
// 直接变「整体 none」→ 框架自己 dispose 掉 SelectionOverlay 顺带收走菜单；「起点
// null 而终点仍在」的部分几何来自真渲染的 detach/NaN 瞬态，headless 打不出来（与
// BUG-119/423/448 同类限制）。故本守卫在最强可落地层钉两件事：
//  ① 行为——toolbar 重建走的就是事故代码路径：修复前重建后锚点会退回 glyph 路径
//     （锚点从右键位置跳走 = 真机上崩溃点），修复后锚点必须钉在召出位置不动；
//  ② 源码——禁止 _buildContextMenu 再读任何依赖完整选区几何的 getter。
void main() {
  Widget buildSubject(Widget child) {
    return MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 400,
          child: child,
        ),
      ),
    );
  }

  /// 在 [linePos]（某可见日志行中心）上做一次鼠标右键点击，呼出上下文菜单。
  Future<void> rightClickAt(WidgetTester tester, Offset linePos) async {
    final TestGesture gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.down(linePos);
    await tester.pump();
    await gesture.up();
    await tester.pump();
  }

  TextSelectionToolbarAnchors menuAnchors(WidgetTester tester) {
    return tester
        .widget<AdaptiveTextSelectionToolbar>(
          find.byType(AdaptiveTextSelectionToolbar),
        )
        .anchors;
  }

  testWidgets(
      'TODO-1380: menu anchor stays pinned to the summoning right-click across '
      'toolbar rebuilds (no contextMenuAnchors glyph fallback), and the menu '
      'keeps working', (WidgetTester tester) async {
    // 拦截剪贴板通道，供菜单项「复制全部」断言真写穿。
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    final List<String> lines =
        List<String>.generate(200, (int i) => 'log-line-$i');
    final String log = lines.join('\n');
    await tester.pumpWidget(
      buildSubject(HibikiLogPanel(log: log, shareAction: (_) {})),
    );
    await tester.pump();

    // 菜单打开前抓 ScrollableState（菜单自身可能带 Scrollable）。
    final ScrollableState scrollable =
        tester.state<ScrollableState>(find.byType(Scrollable).first);

    // 全选（懒加载语义：只命中已注册的视口+cache 行），选区起点=行 0。
    final SelectableRegionState region =
        tester.state<SelectableRegionState>(find.byType(SelectableRegion));
    region.selectAll();
    await tester.pump();

    // 在选区内某可见行上右键 → 呼出上下文菜单，锚点=右键位置。
    final Offset clickPos = tester.getCenter(find.text('log-line-5'));
    await rightClickAt(tester, clickPos);
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget,
        reason: '右键选区内应弹出上下文菜单');
    expect(menuAnchors(tester).primaryAnchor,
        offsetMoreOrLessEquals(clickPos, epsilon: 0.01),
        reason: '菜单首帧应锚在右键位置');

    // 菜单挂着时小幅滚动：选区几何变化 → SelectionOverlay.markNeedsBuild →
    // 菜单 post-frame 重建——这正是事故的重建代码路径。修复前重建再求
    // contextMenuAnchors：右键位置已被首帧消费清空 → 退回 glyph 路径 → 锚点
    // 从右键位置跳走（真机上此路径遇到 detach/NaN 瞬态就是 startGlyphHeight
    // 空断言崩溃）；修复后锚点自持，重建幂等、纹丝不动。
    scrollable.position.jumpTo(120);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull, reason: '菜单重建不得抛异常（TODO-1380 事故路径）');
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget,
        reason: '选区仍在时重建后菜单应保持打开');
    expect(menuAnchors(tester).primaryAnchor,
        offsetMoreOrLessEquals(clickPos, epsilon: 0.01),
        reason: '重建后锚点必须仍钉在右键位置——一旦跳走说明退回了 '
            'contextMenuAnchors 的 glyph 路径（TODO-1380 崩溃根因）');

    // 重建后的菜单必须仍可用：点「复制全部」→ 真写穿剪贴板（全量）且菜单关闭。
    await tester.tap(
      find.descendant(
        of: find.byType(AdaptiveTextSelectionToolbar),
        matching: find.text(t.log_copy_all),
      ),
    );
    await tester.pumpAndSettle();
    expect(copied, equals(log), reason: '菜单「复制全部」应复制整段日志');
    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing,
        reason: '点完菜单项菜单应关闭');
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets(
      'TODO-1380: when the whole selection is evicted the framework closes the '
      'menu gracefully (no exception)', (WidgetTester tester) async {
    final String log =
        List<String>.generate(200, (int i) => 'log-line-$i').join('\n');
    await tester.pumpWidget(
      buildSubject(HibikiLogPanel(log: log, shareAction: (_) {})),
    );
    await tester.pump();

    final ScrollableState scrollable =
        tester.state<ScrollableState>(find.byType(Scrollable).first);
    final SelectableRegionState region =
        tester.state<SelectableRegionState>(find.byType(SelectableRegion));
    region.selectAll();
    await tester.pump();
    await rightClickAt(tester, tester.getCenter(find.text('log-line-5')));
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);

    // 大幅滚动把整段选区行全部回收：选区索引清成 -1 → 几何整体 none →
    // 框架 dispose SelectionOverlay 顺带收走菜单。全程不得抛异常。
    scrollable.position.jumpTo(600);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull, reason: '选区整体消亡时菜单应被框架优雅收走而非崩溃');
    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing,
        reason: '选区没了菜单应随之关闭');
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets(
      'TODO-1380: menu stays open, anchored and crash-free while log content '
      'keeps appending (live log stream UX)', (WidgetTester tester) async {
    final List<String> lines =
        List<String>.generate(50, (int i) => 'log-line-$i');
    await tester.pumpWidget(
      buildSubject(
        HibikiLogPanel(log: lines.join('\n'), shareAction: (_) {}),
      ),
    );
    await tester.pump();

    final SelectableRegionState region =
        tester.state<SelectableRegionState>(find.byType(SelectableRegion));
    region.selectAll();
    await tester.pump();

    final Offset clickPos = tester.getCenter(find.text('log-line-3'));
    await rightClickAt(tester, clickPos);
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);

    // 菜单挂着时日志持续追加（真实事故场景：错误/调试日志流不断进新行）。
    // 用户正在选中复制日志，新行进来不得崩溃、不得把菜单打断或挪走。
    for (int round = 1; round <= 5; round++) {
      lines.add('appended-line-$round');
      await tester.pumpWidget(
        buildSubject(
          HibikiLogPanel(log: lines.join('\n'), shareAction: (_) {}),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull,
          reason: '日志追加第 $round 轮后菜单重建不得崩溃（TODO-1380）');
    }
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget,
        reason: '日志流追加期间菜单应保持打开（不许用「内容一变就关菜单」绕过）');
    expect(menuAnchors(tester).primaryAnchor,
        offsetMoreOrLessEquals(clickPos, epsilon: 0.01),
        reason: '日志追加期间菜单锚点应保持在召出位置');
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  // 源码守卫：_buildContextMenu 绝不允许再读 SelectableRegionState 上依赖完整
  // 选区几何的锚点/度量 getter——contextMenuAnchors / startGlyphHeight /
  // endGlyphHeight / selectionEndpoints 都对选区端点做空断言，而懒加载 + 日志流
  // 面板不保证端点存在（TODO-1380 崩溃根因）。锚点必须来自面板自持的 pointer down。
  test(
      'TODO-1380 source guard: context menu anchors come from the tracked '
      'pointer-down position, never from geometry-dependent getters', () {
    final String source = File(
      'lib/src/utils/components/hibiki_material_components.dart',
    ).readAsStringSync();
    // 只扫代码：注释统一换成**等长空白**（共享 `maskComments`），避免误伤注释里
    // 解释这些 getter 为何被禁的文字。旧写法只丢整行 `//`，块注释与行尾注释都漏
    // ——`anchors: ctx.contextMenuAnchors, /* 待办 */` 这种既能骗过禁止型断言，也
    // 能让下面两条**要求型**断言只靠注释里的同名文字就绿。掩码等长，故先掩码再
    // 按下标切片与直接切原文完全等价。
    final String code = maskComments(source);
    final String panel = code.substring(
      code.indexOf('class _HibikiLogPanelState'),
      code.indexOf('class _LogSelectionScrollController'),
    );

    for (final String banned in <String>[
      '.contextMenuAnchors',
      '.startGlyphHeight',
      '.endGlyphHeight',
      '.selectionEndpoints',
    ]) {
      expect(panel, isNot(contains(banned)),
          reason: '$banned 对选区端点空断言；懒加载日志面板的端点可被滚动回收/'
              '内容更新清空（TODO-1380 崩溃根因），禁止使用');
    }
    // 自持锚点在场：记录面板内最近一次 pointer down，并用于 toolbar 锚点。
    // 这两条以前扫的是含注释的原文——本文件的注释里就写着这两个名字，等于让文档
    // 给自己背书；现在只认代码。
    expect(panel, contains('TextSelectionToolbarAnchors('),
        reason: '菜单必须用自持的稳定锚点构造 TextSelectionToolbarAnchors');
    expect(panel, contains('_lastPointerDownGlobalPosition'),
        reason: '面板必须记录最近一次 pointer down 全局坐标当菜单锚点');
  });
}
