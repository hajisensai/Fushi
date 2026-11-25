import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

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

  final List<int> _lastInvolved = <int>[];

  /// 上一次 [commit] 的违约项涉及的节点 id（按出现顺序去重；「Nodes left pending」
  /// 先记父节点再记子节点）。哨兵拿它回框架的 [SemanticsOwner] 取现场。
  List<int> get lastInvolvedIds => List<int>.unmodifiable(_lastInvolved);

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
    _lastInvolved.clear();
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
    _lastInvolved.clear();
    if (sent.isEmpty) {
      return violations;
    }
    void involve(int id) {
      if (!_lastInvolved.contains(id)) {
        _lastInvolved.add(id);
      }
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
          involve(e.key);
          involve(child);
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
          involve(e.key);
          involve(child);
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
          involve(other);
          involve(e.key);
          involve(child);
        }
        claimedBy[child] = e.key;
      }
    }
    for (final int id in sent.keys) {
      if (!_children.containsKey(id) && !claimedBy.containsKey(id)) {
        violations.add(
          '${describe(id)} will not be in the tree and is not the new root',
        );
        involve(id);
      }
    }
    // 2c：挂上子节点。
    for (final MapEntry<int, AxSentNode> e in sent.entries) {
      if (e.value.traversal.toSet().length != e.value.traversal.length) {
        violations.add('node ${describe(e.key)} has duplicate child ids');
        involve(e.key);
      }
      for (final int child in e.value.traversal) {
        if (!_children.containsKey(child)) {
          if (!sent.containsKey(child)) {
            violations.add(
              'Nodes left pending by the update: ${describe(child)} (child of '
              '${e.key}${destroyedByReparent.contains(child) ? ', destroyed by '
                        'the reparent pass' : ''})',
            );
            involve(e.key);
            involve(child);
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

/// 失步帧的框架侧现场：违约节点此刻在 [SemanticsOwner] 里的真实状态。
///
/// 引擎那边只剩节点 id；同一 id 在框架里对应什么、为什么没被下发，只有在
/// `sendSemanticsUpdate` 刚序列化完（builder 的 `build()` 里）才看得到。这里只读
/// 公开 API，按下发规则把两条最可疑的机制直接判出来：
///
///  * **合并标记不一致**：`isMergedIntoParent` 与父节点的 `isPartOfNodeMerging`
///    对不上。框架靠这两个标记决定节点是自己下发、还是并进祖先。
///  * **被当成合并节点压掉、父节点却单列它**：`SemanticsOwner.sendSemanticsUpdate`
///    对「自己 `isPartOfNodeMerging` 且父节点也 `isPartOfNodeMerging`」的脏节点只标
///    父节点脏、不下发自己；而父节点只要不是合并根（`mergeAllDescendantsIntoThisNode`
///    为假）就会把它列进 `childrenInTraversalOrder`——这正是「父节点 child_ids 指向
///    从未下发的子节点」，引擎报「Nodes left pending by the update」。
///
/// 非 release 构建另外回查拥有该节点的 [RenderObject] 与其 widget 的 creator 链
/// （`debugSemantics` / `debugCreator` 只在非 release 有值）。
abstract final class AxDesyncForensics {
  /// 每帧最多描述的节点数（违约项涉及的节点按出现顺序取前几个）。
  static const int maxNodes = 6;

  static const int _maxText = 40;
  static const int _maxCreator = 300;
  static const int _maxAncestors = 8;

  /// 逐个描述 [ids] 对应的框架节点；[lookup] 按 id 取活节点（取不到 = 框架里已经
  /// 没有它），[ownerOf] 给出拥有它的 render object 摘要（取不到返回 null）。
  static List<String> describe(
    Iterable<int> ids, {
    required SemanticsNode? Function(int id) lookup,
    String? Function(SemanticsNode node)? ownerOf,
  }) => <String>[
    for (final int id in ids.take(maxNodes))
      describeNode(id, lookup(id), ownerOf: ownerOf),
  ];

  /// 一个节点的现场（可能多行，续行以两个空格缩进）。
  static String describeNode(
    int id,
    SemanticsNode? node, {
    String? Function(SemanticsNode node)? ownerOf,
  }) {
    if (node == null) {
      return '#$id: not in the SemanticsOwner (detached or never attached)';
    }
    final SemanticsNode? parent = node.parent;
    final bool parentMerging = parent?.isPartOfNodeMerging ?? false;
    final SemanticsData data = node.getSemanticsData();
    final Rect r = node.rect;
    final List<String> actions = <String>[
      for (final ui.SemanticsAction a in ui.SemanticsAction.values)
        if (data.actions & a.index != 0) a.name,
    ];
    final StringBuffer b = StringBuffer('#$id')
      ..write(' parent=${parent == null ? '-' : '#${parent.id}'}')
      ..write(' attached=${node.attached}')
      ..write(
        ' rect=${r.width.toStringAsFixed(0)}x${r.height.toStringAsFixed(0)}'
        '@(${r.left.toStringAsFixed(0)},${r.top.toStringAsFixed(0)})',
      )
      ..write(node.transform == null ? '' : ' transformed')
      ..write(' merged=${node.isMergedIntoParent}')
      ..write(' mergeAll=${node.mergeAllDescendantsIntoThisNode}')
      ..write(' parentMerging=$parentMerging')
      ..write(' children=${node.childrenCount}');
    if (node.traversalParentIdentifier case final Object tp?) {
      b.write(' traversalParent=${tp.runtimeType}');
    }
    if (node.traversalChildIdentifier case final Object tc?) {
      b.write(' traversalChild=${tc.runtimeType}');
    }
    if (node.tags case final Set<SemanticsTag> tags? when tags.isNotEmpty) {
      b.write(' tags=[${tags.map((SemanticsTag t) => t.name).join(',')}]');
    }
    final List<String> flags = data.flagsCollection.toStrings();
    if (flags.isNotEmpty) {
      b.write(' flags=[${flags.join(',')}]');
    }
    if (actions.isNotEmpty) {
      b.write(' actions=[${actions.join(',')}]');
    }
    for (final (String name, String value) in <(String, String)>[
      ('label', node.label),
      ('tooltip', node.tooltip),
      ('hint', node.hint),
      ('value', node.value),
    ]) {
      if (value.isNotEmpty) {
        b.write(' $name="${_short(value, _maxText)}"');
      }
    }
    if (node.isMergedIntoParent != parentMerging) {
      b.write(
        '\n  !! merge flag disagrees with the parent: isMergedIntoParent='
        '${node.isMergedIntoParent}, parent.isPartOfNodeMerging=$parentMerging',
      );
    }
    if (parent != null &&
        node.isPartOfNodeMerging &&
        parentMerging &&
        !parent.mergeAllDescendantsIntoThisNode) {
      b.write(
        '\n  !! sendSemanticsUpdate skips this node as merged, but its parent '
        '#${parent.id} is not a merge root and lists it as a child',
      );
    }
    final List<String> ancestors = <String>[];
    for (
      SemanticsNode? a = parent;
      a != null && ancestors.length < _maxAncestors;
      a = a.parent
    ) {
      final String marks =
          '${a.isMergedIntoParent ? 'M' : ''}'
          '${a.mergeAllDescendantsIntoThisNode ? 'A' : ''}';
      final String label = a.label.isEmpty ? '' : ' "${_short(a.label, 24)}"';
      ancestors.add('#${a.id}$label${marks.isEmpty ? '' : '[$marks]'}');
    }
    if (ancestors.isNotEmpty) {
      b.write('\n  ancestors: ${ancestors.join(' < ')}');
    }
    final String? owner = ownerOf?.call(node);
    if (owner != null) {
      b.write('\n  owner: ${_short(owner, _maxCreator)}');
    }
    return b.toString();
  }

  /// 生产用：按 id 在所有 view 的 [SemanticsOwner] 里取活节点。
  static SemanticsNode? liveNode(int id) {
    for (final RenderView view in RendererBinding.instance.renderViews) {
      final SemanticsNode? node = view.owner?.semanticsOwner?.getSemanticsNode(
        id,
      );
      if (node != null) {
        return node;
      }
    }
    return null;
  }

  /// 生产用：非 release 构建回查拥有 [node] 的 render object 及 widget creator 链；
  /// release 构建（`debugSemantics` 恒为 null）与「不归任何 render object 所有的
  /// 额外节点」（`assembleSemanticsNode` / 兄弟合并新建的）返回说明文字或 null。
  static String? debugOwnerOf(SemanticsNode node) {
    if (kReleaseMode) {
      return null;
    }
    RenderObject? found;
    void visit(RenderObject object) {
      if (found != null) {
        return;
      }
      if (identical(object.debugSemantics, node)) {
        found = object;
        return;
      }
      object.visitChildren(visit);
    }

    for (final RenderView view in RendererBinding.instance.renderViews) {
      visit(view);
    }
    final RenderObject? owner = found;
    if (owner == null) {
      return 'no RenderObject owns this node (extra node from '
          'assembleSemanticsNode or a sibling merge group)';
    }
    return '${owner.runtimeType} <- ${owner.debugCreator ?? '?'}';
  }

  static String _short(String text, int max) {
    final String oneLine = text.replaceAll('\n', ' ');
    return oneLine.length > max ? '${oneLine.substring(0, max)}…' : oneLine;
  }
}

/// 生产路径上的失步哨兵：桌面端语义开着（有 UIA / AT-SPI / VoiceOver 客户端）时
/// 逐帧复核，违约的那一帧记一条 `A11y.axTreeDesync`，并附上违约节点的框架现场
/// （[AxDesyncForensics]）。
///
/// 引擎一旦失败就停在失步状态，直到语义关掉再开（bridge 重建），所以每个语义会话
/// 只记第一帧，之后停止复核，避免在已失步的树上刷屏；UIA 客户端来回开关语义时，
/// 整个进程最多记 [maxLogsPerProcess] 条。
class AxTreeDesyncSentinel {
  AxTreeDesyncSentinel._();

  /// 每个进程最多记的失步条数（语义会话可能被外部客户端反复开关）。
  static const int maxLogsPerProcess = 5;

  static final AxTreeContractModel _model = AxTreeContractModel();
  static bool _tripped = false;
  static bool _listening = false;
  static int _logged = 0;

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
    return AxRecordingSemanticsUpdateBuilder(
      inner,
      (Map<int, AxSentNode> sent) => _onFrame(
        sent,
        lookup: AxDesyncForensics.liveNode,
        ownerOf: AxDesyncForensics.debugOwnerOf,
      ),
    );
  }

  static void _onEnabledChanged() {
    if (!SemanticsBinding.instance.semanticsEnabled) {
      _model.reset();
      _tripped = false;
    }
  }

  /// 测试入口：把一帧直接交给哨兵（等价于引擎 builder 的 build）；[lookup] /
  /// [ownerOf] 代替生产的 [AxDesyncForensics.liveNode] /
  /// [AxDesyncForensics.debugOwnerOf]。
  @visibleForTesting
  static void debugCommitFrame(
    Map<int, AxSentNode> sent, {
    SemanticsNode? Function(int id)? lookup,
    String? Function(SemanticsNode node)? ownerOf,
  }) => _onFrame(sent, lookup: lookup ?? (int _) => null, ownerOf: ownerOf);

  /// 测试入口：等价于语义关掉（bridge 销毁）；同时清零进程级条数上限。
  @visibleForTesting
  static void debugReset({bool resetProcessCap = true}) {
    _model.reset();
    _tripped = false;
    if (resetProcessCap) {
      _logged = 0;
    }
  }

  static void _onFrame(
    Map<int, AxSentNode> sent, {
    required SemanticsNode? Function(int id) lookup,
    String? Function(SemanticsNode node)? ownerOf,
  }) {
    if (_tripped) {
      return;
    }
    final List<String> violations = _model.commit(sent);
    if (violations.isEmpty) {
      return;
    }
    _tripped = true;
    if (_logged >= maxLogsPerProcess) {
      return;
    }
    _logged += 1;
    final List<String> forensics = AxDesyncForensics.describe(
      _model.lastInvolvedIds,
      lookup: lookup,
      ownerOf: ownerOf,
    );
    ErrorLogService.instance.log(
      'A11y.axTreeDesync',
      '语义更新违反桌面引擎 AXTree 契约，引擎会拒收或半应用这一帧，之后外部无障碍 / '
          '取词 / 输入法客户端查询可能让 app 崩溃（BUG-4073）：\n'
          '${violations.take(8).join('\n')}\n'
          '本帧下发 ${sent.length} 个节点，树中 ${_model.nodeCount} 个。\n'
          '框架现场（违约节点此刻在 SemanticsOwner 里的状态）：\n'
          '${forensics.join('\n')}',
    );
  }
}
