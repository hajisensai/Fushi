// BUG-2839：Windows 上 app 崩在 flutter_windows.dll 的 UIA 命中测试 / 焦点查询里。
//
// 根因链：框架往引擎发了一个「孤儿」语义节点——OverlayPortal 的 traversal child
// 已下发，但它的 traversal parent（锚点）在这一帧不在树里（被 opacity 0 的路由转场
// 排除，Slider / Tooltip / MenuAnchor / DropdownMenu 都走 OverlayPortal）。引擎
// `AXTree::Unserialize` 拒绝这份更新时已经改了一半树、又不通知 AccessibilityBridge，
// bridge 的 id→delegate 映射从此与树脱节，屏幕阅读器 / 输入法 / 触控键盘等外部
// UIA 客户端一查就解引用空或已释放的 delegate。
//
// 修复在框架层（`ci/patches/flutter-sdk/3.47.6/`，回移上游 #186118 / #186826 /
// #193372）。这里在 app 侧钉住引擎要求的契约：**每帧下发的每个节点都必须能从根
// 沿 childrenInTraversalOrder 与 childrenInHitTestOrder 到达，且两条链覆盖同一组
// 节点**。SDK 补丁丢了（升级 Flutter 没回移 / apply-patches 没跑）这里就红。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一个节点在某次更新里下发的子节点链。
typedef _SentNode = ({String label, List<int> traversal, List<int> hitTest});

/// 本帧（自上次 [_SpyBinding.takeSent] 以来）下发给引擎的节点。
final Map<int, _SentNode> _sent = <int, _SentNode>{};

class _SpyBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() =>
      _SemanticsUpdateBuilderSpy(super.createSemanticsUpdateBuilder());
}

/// 只截 `updateNode` 的参数，其余调用原样转给真 builder。
///
/// 用 noSuchMethod 转发而不是手抄 `updateNode` 的完整签名：那份签名随 Flutter
/// 版本加参数，手抄会在每次升级时编译失败，而这里只关心子节点链。
class _SemanticsUpdateBuilderSpy implements ui.SemanticsUpdateBuilder {
  _SemanticsUpdateBuilderSpy(this._inner);

  final ui.SemanticsUpdateBuilder _inner;

  @override
  void updateCustomAction({
    required int id,
    String? label,
    String? hint,
    int overrideId = -1,
  }) => _inner.updateCustomAction(
    id: id,
    label: label,
    hint: hint,
    overrideId: overrideId,
  );

  @override
  ui.SemanticsUpdate build() => _inner.build();

  @override
  Object? noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #updateNode) {
      final Map<Symbol, Object?> args = invocation.namedArguments;
      final int id = args[#id]! as int;
      expect(_sent.containsKey(id), isFalse, reason: 'node $id sent twice');
      _sent[id] = (
        label: args[#label]! as String,
        traversal: List<int>.of(args[#childrenInTraversalOrder]! as Int32List),
        hitTest: List<int>.of(args[#childrenInHitTestOrder]! as Int32List),
      );
      return Function.apply(_inner.updateNode, const <Object?>[], args);
    }
    return super.noSuchMethod(invocation);
  }
}

/// 引擎侧的累计树：与 `AXTree` 一样，未在本帧重发的节点沿用上次的子链。
class _EngineTreeModel {
  final Map<int, _SentNode> _tree = <int, _SentNode>{};

  /// 把本帧更新并入，断言它满足 `AXTree::Unserialize` 的连通契约。
  void commitFrame(String step) {
    if (_sent.isEmpty) {
      return;
    }
    _tree.addAll(_sent);
    final Set<int> traversal = _reachable((_SentNode n) => n.traversal, step);
    final Set<int> hitTest = _reachable((_SentNode n) => n.hitTest, step);
    for (final int id in _sent.keys) {
      expect(
        traversal,
        contains(id),
        reason: '$step: node $id "${_sent[id]!.label}" is a traversal orphan',
      );
      expect(
        hitTest,
        contains(id),
        reason: '$step: node $id "${_sent[id]!.label}" is a hit-test orphan',
      );
    }
    expect(traversal, equals(hitTest), reason: step);
    _tree.removeWhere((int id, _) => !traversal.contains(id));
    _sent.clear();
  }

  Set<int> _reachable(List<int> Function(_SentNode) children, String step) {
    final Set<int> seen = <int>{};
    void walk(int id) {
      expect(
        _tree.containsKey(id),
        isTrue,
        reason: '$step: node $id is referenced but was never sent',
      );
      if (seen.add(id)) {
        children(_tree[id]!).forEach(walk);
      }
    }

    walk(0);
    return seen;
  }

  bool hasLabel(String label) =>
      _tree.values.any((_SentNode n) => n.label.contains(label));
}

/// 带 OverlayPortal 的真 Material 控件：Slider（数值气泡）、Tooltip、MenuAnchor。
Widget _overlayPortalControls(String tag) {
  return Material(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text('$tag body'),
        Slider(value: 0.5, divisions: 4, label: tag, onChanged: (_) {}),
        Tooltip(message: '$tag tip', child: Text('$tag tooltip')),
        MenuAnchor(
          menuChildren: <Widget>[
            MenuItemButton(onPressed: () {}, child: Text('$tag item')),
          ],
          builder: (BuildContext context, MenuController controller, _) =>
              TextButton(onPressed: controller.open, child: Text('$tag menu')),
        ),
      ],
    ),
  );
}

Future<void> _stepFrames(
  WidgetTester tester,
  _EngineTreeModel engine,
  String step,
) async {
  for (int i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    engine.commitFrame('$step frame $i');
  }
}

void main() {
  _SpyBinding();

  testWidgets(
    'pushing/popping routes and dialogs with OverlayPortal controls never '
    'sends orphan semantics nodes (BUG-2839)',
    (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final _EngineTreeModel engine = _EngineTreeModel();
      final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
      _sent.clear();

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(body: _overlayPortalControls('home')),
        ),
      );
      engine.commitFrame('home');

      // 路由转场首帧 opacity 为 0：锚点被排除、OverlayPortal 子节点仍挂在 Overlay 上。
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              Scaffold(body: _overlayPortalControls('page')),
        ),
      );
      await _stepFrames(tester, engine, 'push page');
      expect(engine.hasLabel('page body'), isTrue);

      showDialog<void>(
        context: navigator.currentContext!,
        builder: (BuildContext context) =>
            Dialog(child: _overlayPortalControls('dialog')),
      );
      await _stepFrames(tester, engine, 'show dialog');
      expect(engine.hasLabel('dialog body'), isTrue);

      navigator.currentState!.pop();
      await _stepFrames(tester, engine, 'pop dialog');
      navigator.currentState!.pop();
      await _stepFrames(tester, engine, 'pop page');
      expect(engine.hasLabel('home body'), isTrue);

      handle.dispose();
    },
  );
}
