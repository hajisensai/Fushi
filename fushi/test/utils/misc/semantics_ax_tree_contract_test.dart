// AxTreeContractModel 自身的契约：它必须与引擎 `AccessibilityBridge::CommitUpdates`
// + `ui::AXTree::Unserialize` 的判定一致，否则语义回归测试与生产哨兵都会误判。
// 每条用例对应引擎源码里的一个失败点（Flutter 3.47.6）：
//   accessibility_bridge.cc:197-260  CreateRemoveReparentedNodesUpdate
//   ax_tree.cc:1346                  「will not be in the tree and is not the new root」
//   ax_tree.cc:1394 / 1447           「already pending for creation」
//   ax_tree.cc:1781                  「Nodes left pending by the update」
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/semantics_ax_tree_contract.dart';

AxSentNode _n(List<int> children, [String label = '']) =>
    (label: label, traversal: children, hitTest: children);

void main() {
  late AxTreeContractModel model;

  setUp(() {
    model = AxTreeContractModel();
    expect(
      model.commit(<int, AxSentNode>{
        0: _n(<int>[1, 2]),
        1: _n(<int>[3]),
        2: _n(<int>[]),
        3: _n(<int>[4]),
        4: _n(<int>[]),
      }, checkHitTestTree: true),
      isEmpty,
    );
  });

  test('incremental updates that only touch dirty nodes are accepted', () {
    expect(model.commit(<int, AxSentNode>{2: _n(<int>[], 'relabel')}), isEmpty);
    // 新增子节点并带上它的数据。
    expect(
      model.commit(<int, AxSentNode>{
        2: _n(<int>[5]),
        5: _n(<int>[]),
      }, checkHitTestTree: true),
      isEmpty,
    );
    // 删掉一棵子树只需重发父节点。
    expect(model.commit(<int, AxSentNode>{1: _n(<int>[])}), isEmpty);
    expect(model.nodeCount, 4);
  });

  test(
    'moving a subtree is accepted when the whole moved subtree is re-sent',
    () {
      expect(
        model.commit(<int, AxSentNode>{
          1: _n(<int>[]),
          2: _n(<int>[3]),
          3: _n(<int>[4]),
          4: _n(<int>[]),
        }, checkHitTestTree: true),
        isEmpty,
      );
    },
  );

  test('moving a node without re-sending it is rejected', () {
    final List<String> v = model.commit(<int, AxSentNode>{
      1: _n(<int>[]),
      2: _n(<int>[3]),
    });
    expect(v, contains(contains('moved from 1 to 2 without being re-sent')));
    expect(v, contains(contains('Nodes left pending by the update: 3')));
  });

  test('moving a node re-sends it but not its unchanged children', () {
    // 桥的第 1 步连子树一起销毁，节点 4 不在更新里就是「Nodes left pending」。
    final List<String> v = model.commit(<int, AxSentNode>{
      1: _n(<int>[]),
      2: _n(<int>[3]),
      3: _n(<int>[4]),
    });
    expect(
      v,
      contains(
        'Nodes left pending by the update: 4 "" (child of 3, destroyed by '
        'the reparent pass)',
      ),
    );
  });

  test('a node that no sent node references is an orphan', () {
    expect(
      model.commit(<int, AxSentNode>{9: _n(<int>[], 'orphan')}),
      contains('9 "orphan" will not be in the tree and is not the new root'),
    );
  });

  test('a node dropped by its parent but still sent is an orphan', () {
    expect(
      model.commit(<int, AxSentNode>{
        1: _n(<int>[]),
        3: _n(<int>[4]),
      }),
      contains(contains('3 "" will not be in the tree')),
    );
  });

  test('two parents claiming one new child is rejected', () {
    expect(
      model.commit(<int, AxSentNode>{
        1: _n(<int>[3, 6]),
        2: _n(<int>[6]),
        6: _n(<int>[]),
      }),
      contains(contains('claimed as a child by both 1 and 2')),
    );
  });

  test('a new child without data is left pending', () {
    expect(
      model.commit(<int, AxSentNode>{
        2: _n(<int>[7]),
      }),
      contains('Nodes left pending by the update: 7 "?" (child of 2)'),
    );
  });

  test('hit-test check flags a traversal child missing from hit-test', () {
    expect(
      model.commit(<int, AxSentNode>{
        1: (label: '', traversal: <int>[3], hitTest: <int>[]),
      }, checkHitTestTree: true),
      contains(contains('hit-test tree differs from traversal tree')),
    );
  });

  test('reset starts a new tree', () {
    model.reset();
    expect(model.nodeCount, 0);
    expect(model.commit(<int, AxSentNode>{1: _n(<int>[])}), <String>[
      'first update has no root',
    ]);
  });

  group('AxTreeDesyncSentinel', () {
    setUp(() async {
      final Directory tmp = await Directory.systemTemp.createTemp(
        'ax_sentinel',
      );
      await ErrorLogService.instance.init(directoryOverride: tmp);
      await ErrorLogService.instance.clear();
      AxTreeDesyncSentinel.debugReset();
    });

    test('logs the first violating frame once per semantics session', () {
      AxTreeDesyncSentinel.debugCommitFrame(<int, AxSentNode>{
        0: _n(<int>[1]),
        1: _n(<int>[], 'ok'),
      });
      expect(ErrorLogService.instance.entries, isEmpty);

      AxTreeDesyncSentinel.debugCommitFrame(<int, AxSentNode>{
        0: _n(<int>[2]),
      });
      AxTreeDesyncSentinel.debugCommitFrame(<int, AxSentNode>{
        5: _n(<int>[], 'later'),
      });
      expect(ErrorLogService.instance.entries, hasLength(1));
      final String message = ErrorLogService.instance.entries.single.error;
      expect(
        ErrorLogService.instance.entries.single.source,
        'A11y.axTreeDesync',
      );
      expect(message, contains('Nodes left pending by the update: 2'));

      // 语义关掉再开 = 新 bridge，从空树重新复核。
      AxTreeDesyncSentinel.debugReset();
      AxTreeDesyncSentinel.debugCommitFrame(<int, AxSentNode>{0: _n(<int>[])});
      expect(ErrorLogService.instance.entries, hasLength(1));
    });

    // 3.3.0 现场三份日志的同一形态（6w4NCIxzoR / T--XrKRrZ8 / lGXdQ_RHiN）：只下发
    // 父节点等两三个节点，父节点 child_ids 却多出连续几个从未下发过的新 id。
    test('field shape: parent lists consecutive never-sent children', () {
      AxTreeDesyncSentinel.debugCommitFrame(<int, AxSentNode>{
        0: _n(<int>[7]),
        7: _n(<int>[8]),
        8: _n(<int>[], 'deck'),
      });
      AxTreeDesyncSentinel.debugCommitFrame(<int, AxSentNode>{
        7: _n(<int>[8, 5932, 5933, 5934]),
        8: _n(<int>[], 'deck'),
      });
      final String message = ErrorLogService.instance.entries.single.error;
      for (final int id in <int>[5932, 5933, 5934]) {
        expect(
          message,
          contains('Nodes left pending by the update: $id "?" (child of 7)'),
        );
      }
      expect(message, contains('本帧下发 2 个节点'));
    });

    test('records the framework state of the violating nodes', () {
      // 复现怀疑的机制：父节点 P 不是合并根，却带着过期的 isMergedIntoParent=true
      // 挂在不合并的根下；它的子节点 C 因此被 sendSemanticsUpdate 当成合并节点压掉，
      // P 却照样把 C 列进 childrenInTraversalOrder。
      final SemanticsNode root = SemanticsNode();
      final SemanticsNode parent = SemanticsNode();
      final SemanticsNode child = SemanticsNode()
        ..rect = const Rect.fromLTWH(0, 0, 40, 20);
      parent
        ..rect = const Rect.fromLTWH(0, 0, 100, 50)
        ..updateWith(
          config: SemanticsConfiguration()
            ..label = 'card'
            ..textDirection = TextDirection.ltr,
          childrenInInversePaintOrder: <SemanticsNode>[child],
        );
      root
        ..rect = const Rect.fromLTWH(0, 0, 800, 600)
        ..updateWith(
          config: SemanticsConfiguration(),
          childrenInInversePaintOrder: <SemanticsNode>[parent],
        );
      parent.isMergedIntoParent = true;
      child.isMergedIntoParent = true;
      final Map<int, SemanticsNode> live = <int, SemanticsNode>{
        10: parent,
        11: child,
      };

      AxTreeDesyncSentinel.debugCommitFrame(<int, AxSentNode>{
        0: _n(<int>[10]),
        10: _n(<int>[], 'card'),
      });
      AxTreeDesyncSentinel.debugCommitFrame(
        <int, AxSentNode>{
          10: _n(<int>[11, 12], 'card'),
        },
        lookup: (int id) => live[id],
        ownerOf: (SemanticsNode node) =>
            identical(node, parent) ? 'RenderCard <- Card <- DeckTile' : null,
      );

      final String message = ErrorLogService.instance.entries.single.error;
      expect(message, contains('框架现场'));
      // 父节点：合并标记与它的父节点对不上，且带上拥有者摘要。
      expect(message, contains('#10 parent=#${root.id}'));
      expect(message, contains('label="card"'));
      expect(
        message,
        contains(
          'merge flag disagrees with the parent: isMergedIntoParent=true, '
          'parent.isPartOfNodeMerging=false',
        ),
      );
      expect(message, contains('owner: RenderCard <- Card <- DeckTile'));
      // 子节点：被当成合并节点压掉、父节点却单列它。
      expect(message, contains('#11 parent=#${parent.id}'));
      expect(
        message,
        contains(
          'sendSemanticsUpdate skips this node as merged, but its parent '
          '#${parent.id} is not a merge root and lists it as a child',
        ),
      );
      expect(message, contains('ancestors: #${parent.id} "card"[M]'));
      // 框架里已经没有的节点照实说。
      expect(
        message,
        contains('#12: not in the SemanticsOwner (detached or never attached)'),
      );
    });

    test('lastInvolvedIds lists the parent before its pending children', () {
      final AxTreeContractModel m = AxTreeContractModel();
      expect(
        m.commit(<int, AxSentNode>{
          0: _n(<int>[1]),
          1: _n(<int>[]),
        }),
        isEmpty,
      );
      expect(m.lastInvolvedIds, isEmpty);
      m.commit(<int, AxSentNode>{
        1: _n(<int>[5, 6]),
      });
      expect(m.lastInvolvedIds, <int>[1, 5, 6]);
      m.commit(<int, AxSentNode>{
        0: _n(<int>[1]),
      });
      expect(m.lastInvolvedIds, isEmpty);
    });

    test('logs at most maxLogsPerProcess sessions per process', () {
      for (
        int session = 0;
        session < AxTreeDesyncSentinel.maxLogsPerProcess + 3;
        session++
      ) {
        AxTreeDesyncSentinel.debugReset(resetProcessCap: false);
        AxTreeDesyncSentinel.debugCommitFrame(<int, AxSentNode>{
          0: _n(<int>[1]),
        });
      }
      expect(
        ErrorLogService.instance.entries,
        hasLength(AxTreeDesyncSentinel.maxLogsPerProcess),
      );
    });
  });
}
