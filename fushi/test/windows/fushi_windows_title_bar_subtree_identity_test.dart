import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_windows_title_bar.dart';
import 'package:window_manager/window_manager.dart';

/// [FushiWindowsTitleBar] 把整棵 app 子树（`FushiAppUiScale` → 全局快捷键 Focus 节点
/// → `FushiFocusRoot` 焦点控制器 → Navigator）挂在自己下面。这些层里除 Navigator 外
/// 都没有 key，所以**它们的 Element 身份完全由本组件 build 出的 widget 树形状决定**。
///
/// 原实现在同一个 slot 上按全屏态换 widget 类型
/// （`hideFrame ? frame : DragToResizeArea(child: frame)`）：
/// `Widget.canUpdate(DragToResizeArea, ColoredBox)` 恒为 false，于是每次进/出全屏
/// （视频 media_kit 全屏、漫画 / 任意页 F11）都会把该 slot 以下整棵 Element 树
/// deactivate 再重新 inflate——全局快捷键 Focus 节点与焦点控制器被销毁重建，焦点丢失。
///
/// 修法是用**参数**表达状态（`enableResizeEdges: const []` = 每条边都是无手势目标的
/// 裸 `Container()`，零命中区），widget 类型在两种状态下保持不变。
///
/// 本测试直接钉住可观察后果：全屏进出后，子树的 State 实例必须是同一个，且焦点必须
/// 还在原处。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final Object owner = Object();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), (
      MethodCall call,
    ) async {
      switch (call.method) {
        case 'isMaximized':
        case 'isFullScreen':
        case 'isFocused':
          return false;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    // 静态 owner 集合是进程级的，用例之间必须归零，否则会污染后续用例。
    FushiWindowsTitleBar.setContentFullscreen(owner: owner, enabled: false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  testWidgets('进出全屏不重建标题栏下方子树，焦点保持原位', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home:
            FushiWindowsTitleBar(title: Text('Fushi'), child: _SubtreeProbe()),
      ),
    );
    await tester.pump();

    final _SubtreeProbeState before = tester.state<_SubtreeProbeState>(
      find.byType(_SubtreeProbe),
    );
    before.node.requestFocus();
    await tester.pump();
    expect(before.node.hasFocus, isTrue, reason: '前置条件：焦点先落在子树里');

    // 进全屏。
    FushiWindowsTitleBar.setContentFullscreen(owner: owner, enabled: true);
    await tester.pump();

    expect(
      identical(
          tester.state<_SubtreeProbeState>(find.byType(_SubtreeProbe)), before),
      isTrue,
      reason: '进全屏时标题栏下方子树被重建了——全局快捷键 Focus 节点与焦点控制器'
          '（都没有 key）会一起销毁重建，焦点必然丢失。',
    );
    expect(before.node.hasFocus, isTrue, reason: '进全屏后焦点必须仍在原处');

    // 出全屏。
    FushiWindowsTitleBar.setContentFullscreen(owner: owner, enabled: false);
    await tester.pump();

    expect(
      identical(
          tester.state<_SubtreeProbeState>(find.byType(_SubtreeProbe)), before),
      isTrue,
      reason: '出全屏时标题栏下方子树被重建了（同上）。',
    );
    expect(before.node.hasFocus, isTrue, reason: '出全屏后焦点必须仍在原处');
  });

  testWidgets('全屏态下 resize 边框零命中区，widget 类型不变', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home:
            FushiWindowsTitleBar(title: Text('Fushi'), child: _SubtreeProbe()),
      ),
    );
    await tester.pump();

    DragToResizeArea area() =>
        tester.widget<DragToResizeArea>(find.byType(DragToResizeArea));

    expect(
      area().enableResizeEdges,
      const <ResizeEdge>[
        ResizeEdge.topLeft,
        ResizeEdge.top,
        ResizeEdge.topRight
      ],
      reason: 'window_manager 的 TitleBarStyle.hidden 只吃掉顶边，顶边三个 resize '
          '把手必须由 Flutter 侧补。',
    );
    // 顶栏可见。
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);

    FushiWindowsTitleBar.setContentFullscreen(owner: owner, enabled: true);
    await tester.pump();

    expect(
      find.byType(DragToResizeArea),
      findsOneWidget,
      reason: '全屏态必须仍是 DragToResizeArea——换成别的 widget 类型会让整棵子树重建。',
    );
    expect(
      area().enableResizeEdges,
      isEmpty,
      reason: '全屏时不得留任何 resize 命中区。',
    );
    // 顶栏隐藏。
    expect(find.byIcon(Icons.close_rounded), findsNothing);
  });
}

/// 无 key 的有状态子树探针：它的 State 身份就是「子树有没有被重新 inflate」的判据。
class _SubtreeProbe extends StatefulWidget {
  const _SubtreeProbe();

  @override
  State<_SubtreeProbe> createState() => _SubtreeProbeState();
}

class _SubtreeProbeState extends State<_SubtreeProbe> {
  final FocusNode node = FocusNode(debugLabel: 'subtree-probe');

  @override
  void dispose() {
    node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(focusNode: node, child: const SizedBox.expand());
  }
}
