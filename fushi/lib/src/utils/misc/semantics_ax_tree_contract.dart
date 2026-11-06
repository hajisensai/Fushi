import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 桌面引擎（Windows / macOS / Linux）无障碍树的更新契约。
///
/// 引擎把框架每帧下发的语义更新交给 `AccessibilityBridge::CommitUpdates`
/// （`engine/src/flutter/shell/platform/common/accessibility_bridge.cc`），后者分两步
/// 喂给 `ui::AXTree::Unserialize`（`third_party/accessibility/ax/ax_tree.cc`）：
///
///  1. `CreateRemoveReparentedNodesUpdate`：本帧被换了父节点的子节点，先从旧父节点的
///     child_ids 里拿掉。AXTree 不支持一次更新里搬节点，这一步把被搬节点**连同整棵
///     子树**销毁。
///  2. 本帧全部节点按树序应用。新出现在 child_ids 里、树里又没有的节点当场被创建；
///     它的数据不在本次更新里时，`ValidatePendingChangesComplete` 报「Nodes left
///     pending by the update」并返回 false。
///
/// 第 2 步在**改完树之后**才失败：AXTree 已经建了 / 删了节点，而 bridge 的 observer
/// 回调（`OnNodeCreated` / `OnNodeDeleted`）只在成功末尾才发，id→delegate 映射从此
/// 与树脱节。外部 UIA 客户端（屏幕取词 / 输入法 / 讲述人）之后命中测试、枚举子节点、
/// 读属性就解引用空或已释放的 delegate——BUG-4073（`HitTestSync`）、BUG-2345
/// （`ChildAtIndex`）、BUG-2337（`GetStringAttribute`）、BUG-2839 是同一失步的不同崩点。
/// 更新被整份拒绝（「will not be in the tree」）不会立刻崩，但框架以为已经发过，下一帧
/// 的增量更新就会撞上第 2 步。
///
/// 引擎的 `Failed to update ui::AXTree` 只经 `fprintf(stderr)` 输出，而
/// `flutter_windows.dll` 静态链接 CRT（导入表里没有 ucrtbase / api-ms-win-crt-*），
/// 它的 stderr 在 DLL 初始化时就从进程标准句柄定死——资源管理器拉起的 GUI 进程没有
/// 标准句柄，runner 在 `main` 里再重定向也够不着。所以这里在框架出口按同一规则逐帧
/// 复核：会让引擎失败的帧**在引擎之前**被认出来，带上节点 label 记进错误日志。
class AxTreeContractModel {
  /// id → 当前引擎 AXTree 里的子节点（traversal 顺序：桥只用这一条链建树）。
  final Map<int, List<int>> _children = <int, List<int>>{};

  /// id → 当前引擎 AXTree 里的父节点（根没有）。
  final Map<int, int> _parent = <int, int>{};

  /// id → 最近一次下发的数据。
  final Map<int, AxSentNode> _data = <int, AxSentNode>{};

  bool _hasRoot = false;

  /// 引擎当前树里的节点数。
  int get nodeCount => _children.length;

  /// 树里是否有 label 含 [text] 的节点。
  bool hasLabel(String text) => _data.entries.any(
    (MapEntry<int, AxSentNode> e) =>
        _children.containsKey(e.key) && e.value.label.contains(text),
  );

  /// 回到空树（bridge 随语义开关重建时）。
  void reset() {
    _children.clear();
    _parent.clear();
    _data.clear();
    _hasRoot = false;
  }

  /// 按引擎的两步应用一帧更新，返回这帧违反的契约（空 = 引擎会照单全收）。
  ///
  /// [checkHitTestTree] 额外核对 hit-test 链与 traversal 链覆盖同一组节点
  /// （BUG-2839 的契约；要整树遍历，只在测试里开）。
  List<String> commit(
    Map<int, AxSentNode> sent, {
    bool checkHitTestTree = false,
  }) {
    final List<String> violations = <String>[];
    if (sent.isEmpty) {
      return violations;
    }
    String describe(int id) {
      final String label = (sent[id] ?? _data[id])?.label ?? '?';
      final String short = label.length > 32
          ? '${label.substring(0, 32)}…'
          : label;
      return '$id "$short"';
    }

    // 第 1 步：CreateRemoveReparentedNodesUpdate。
    final Set<int> destroyedByReparent = <int>{};
    for (final MapEntry<int, AxSentNode> e in sent.entries) {
      for (final int child in e.value.traversal) {
        if (!_children.containsKey(child)) {
          continue;
        }
        final int? oldParent = _parent[child];
        if (oldParent == null) {
          violations.add('root ${describe(child)} sent as a child of ${e.key}');
          continue;
        }
        if (oldParent == e.key) {
          continue;
        }
        if (!sent.containsKey(child)) {
          // 桥在这里只有 `assert`（release 不生效）；被搬节点整棵子树随即被销毁，
          // 第 2 步必然「Nodes left pending」。
          violations.add(
            'node ${describe(child)} moved from $oldParent to ${e.key} '
            'without being re-sent',
          );
        }
        _children[oldParent]!.remove(child);
        _destroySubtree(child, destroyedByReparent);
      }
    }

    // 第 2 步：本帧全部节点。
    if (!_hasRoot) {
      if (!sent.containsKey(0)) {
        violations.add('first update has no root');
        return violations;
      }
      _hasRoot = true;
      _children[0] = <int>[];
    }
    // 2a：拿掉被丢下的子节点（AXTree 把它们连子树销毁）。
    for (final MapEntry<int, AxSentNode> e in sent.entries) {
      final List<int>? oldChildren = _children[e.key];
      if (oldChildren == null) {
        continue;
      }
      final Set<int> next = e.value.traversal.toSet();
      for (final int child in List<int>.of(oldChildren)) {
        if (!next.contains(child)) {
          _destroySubtree(child, <int>{});
        }
      }
    }
    // 2b：本帧每个下发节点要么已在树里，要么被本帧某个下发节点新引用。
    final Map<int, int> claimedBy = <int, int>{};
    for (final MapEntry<int, AxSentNode> e in sent.entries) {
      for (final int child in e.value.traversal) {
        final int? other = claimedBy[child];
        if (other != null && other != e.key) {
          violations.add(
            'node ${describe(child)} claimed as a child by both $other and '
            '${e.key}',
          );
        }
        claimedBy[child] = e.key;
      }
    }
    for (final int id in sent.keys) {
      if (!_children.containsKey(id) && !claimedBy.containsKey(id)) {
        violations.add(
          '${describe(id)} will not be in the tree and is not the new root',
        );
      }
    }
    // 2c：挂上子节点。
    for (final MapEntry<int, AxSentNode> e in sent.entries) {
      if (e.value.traversal.toSet().length != e.value.traversal.length) {
        violations.add('node ${describe(e.key)} has duplicate child ids');
      }
      for (final int child in e.value.traversal) {
        if (!_children.containsKey(child)) {
          if (!sent.containsKey(child)) {
            violations.add(
              'Nodes left pending by the update: ${describe(child)} (child of '
              '${e.key}${destroyedByReparent.contains(child) ? ', destroyed by '
                        'the reparent pass' : ''})',
            );
          }
          _children[child] = <int>[];
        }
        _parent[child] = e.key;
      }
      _children[e.key] = List<int>.of(e.value.traversal);
      _data[e.key] = e.value;
    }
    // 没挂上的孤儿不留在模型里（引擎也不会有它）。
    for (final int id in sent.keys) {
      if (id != 0 && !_parent.containsKey(id)) {
        _destroySubtree(id, <int>{});
      }
    }

    if (checkHitTestTree && violations.isEmpty) {
      final Set<int> traversal = _reachable((int id) => _children[id]!);
      final Set<int> hitTest = _reachable(
        (int id) => _data[id]?.hitTest ?? const <int>[],
      );
      final Set<int> unreachable = _children.keys.toSet().difference(traversal);
      if (unreachable.isNotEmpty) {
        violations.add('unreachable nodes in the tree: $unreachable');
      }
      if (!setEquals(hitTest, traversal)) {
        violations.add(
          'hit-test tree differs from traversal tree: '
          'only hit-test ${hitTest.difference(traversal)}, '
          'only traversal ${traversal.difference(hitTest)}',
        );
      }
    }
    return violations;
  }

  void _destroySubtree(int id, Set<int> destroyed) {
    final List<int>? kids = _children.remove(id);
    final int? parent = _parent.remove(id);
    if (parent != null) {
      _children[parent]?.remove(id);
    }
    destroyed.add(id);
    for (final int kid in kids ?? const <int>[]) {
      _destroySubtree(kid, destroyed);
    }
  }

  Set<int> _reachable(List<int> Function(int id) children) {
    final Set<int> seen = <int>{};
    void walk(int id) {
      if (_children.containsKey(id) && seen.add(id)) {
        children(id).forEach(walk);
      }
    }

    if (_hasRoot) {
      walk(0);
    }
    return seen;
  }
}

/// 一个节点在某次更新里下发的结构数据。
typedef AxSentNode = ({String label, List<int> traversal, List<int> hitTest});

/// 只截 `updateNode` 的结构参数，其余调用原样转给真 builder。
///
/// 用 noSuchMethod 转发而不是手抄 `updateNode` 的完整签名：那份签名随 Flutter 版本
/// 加参数，手抄会在每次升级时编译失败，而这里只关心子节点链。
class AxRecordingSemanticsUpdateBuilder implements ui.SemanticsUpdateBuilder {
  AxRecordingSemanticsUpdateBuilder(this._inner, this._onBuild);

  final ui.SemanticsUpdateBuilder _inner;
  final void Function(Map<int, AxSentNode> sent) _onBuild;
  final Map<int, AxSentNode> _sent = <int, AxSentNode>{};

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
  ui.SemanticsUpdate build() {
    _onBuild(Map<int, AxSentNode>.of(_sent));
    _sent.clear();
    return _inner.build();
  }

  @override
  Object? noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #updateNode) {
      final Map<Symbol, Object?> args = invocation.namedArguments;
      _sent[args[#id]! as int] = (
        label: args[#label]! as String,
        traversal: List<int>.of(args[#childrenInTraversalOrder]! as Int32List),
        hitTest: List<int>.of(args[#childrenInHitTestOrder]! as Int32List),
      );
      return Function.apply(_inner.updateNode, const <Object?>[], args);
    }
    return super.noSuchMethod(invocation);
  }
}

/// 生产路径上的失步哨兵：桌面端语义开着（有 UIA / AT-SPI / VoiceOver 客户端）时
/// 逐帧复核，违约的那一帧记一条 `A11y.axTreeDesync`。
///
/// 引擎一旦失败就停在失步状态，直到语义关掉再开（bridge 重建），所以每个语义会话
/// 只记第一帧，之后停止复核，避免在已失步的树上刷屏。
class AxTreeDesyncSentinel {
  AxTreeDesyncSentinel._();

  static final AxTreeContractModel _model = AxTreeContractModel();
  static bool _tripped = false;
  static bool _listening = false;

  /// 桌面三端用 `ui::AXTree`；移动端 / Web 各自维护映射，不受这份契约约束。
  static bool get appliesToThisPlatform =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// 包住引擎 builder；非桌面端原样返回。
  static ui.SemanticsUpdateBuilder wrap(ui.SemanticsUpdateBuilder inner) {
    if (!appliesToThisPlatform) {
      return inner;
    }
    if (!_listening) {
      _listening = true;
      SemanticsBinding.instance.addSemanticsEnabledListener(_onEnabledChanged);
    }
    return AxRecordingSemanticsUpdateBuilder(inner, _onFrame);
  }

  static void _onEnabledChanged() {
    if (!SemanticsBinding.instance.semanticsEnabled) {
      _model.reset();
      _tripped = false;
    }
  }

  /// 测试入口：把一帧直接交给哨兵（等价于引擎 builder 的 build）。
  @visibleForTesting
  static void debugCommitFrame(Map<int, AxSentNode> sent) => _onFrame(sent);

  /// 测试入口：等价于语义关掉（bridge 销毁）。
  @visibleForTesting
  static void debugReset() {
    _model.reset();
    _tripped = false;
  }

  static void _onFrame(Map<int, AxSentNode> sent) {
    if (_tripped) {
      return;
    }
    final List<String> violations = _model.commit(sent);
    if (violations.isEmpty) {
      return;
    }
    _tripped = true;
    ErrorLogService.instance.log(
      'A11y.axTreeDesync',
      '语义更新违反桌面引擎 AXTree 契约，引擎会拒收或半应用这一帧，之后外部无障碍 / '
          '取词 / 输入法客户端查询可能让 app 崩溃（BUG-4073）：\n'
          '${violations.take(8).join('\n')}\n'
          '本帧下发 ${sent.length} 个节点，树中 ${_model.nodeCount} 个。',
    );
  }
}

/// app 主入口的 binding：只多了 [AxTreeDesyncSentinel]。
class FushiWidgetsBinding extends WidgetsFlutterBinding {
  FushiWidgetsBinding._();

  static bool _created = false;

  /// 与 [WidgetsFlutterBinding.ensureInitialized] 相同：进程里还没有 binding 时创建
  /// 本类，已有就原样返回。
  ///
  /// 集成测试（`IntegrationTestWidgetsFlutterBinding`）与 widget 测试在调用
  /// `app.main()` 之前就建好了自己的 binding。一个进程只能有一个 binding，再构造
  /// 第二个会在 [BindingBase] 构造函数里断言失败（「Binding is already
  /// initialized」），主入口整段中止、永远不 `runApp`。这时沿用已有的 binding，
  /// 哨兵不装（测试里另有逐帧契约断言）。
  ///
  /// 「已有 binding」用 [BindingBase.debugBindingType] 判：它只在 debug 构建记录
  /// 类型，release / profile 恒为 null。那两种构建里没有任何代码先于主入口建
  /// binding（测试只跑 debug），照常创建本类。
  static WidgetsBinding ensureInitialized() {
    if (!_created && BindingBase.debugBindingType() == null) {
      _created = true;
      FushiWidgetsBinding._();
    }
    return WidgetsBinding.instance;
  }

  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() =>
      AxTreeDesyncSentinel.wrap(super.createSemanticsUpdateBuilder());
}
