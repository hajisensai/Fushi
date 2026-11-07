// AxTreeContractModel 自身的契约：它必须与引擎 `AccessibilityBridge::CommitUpdates`
// + `ui::AXTree::Unserialize` 的判定一致，否则语义回归测试与生产哨兵都会误判。
// 每条用例对应引擎源码里的一个失败点（Flutter 3.47.6）：
//   accessibility_bridge.cc:197-260  CreateRemoveReparentedNodesUpdate
//   ax_tree.cc:1346                  「will not be in the tree and is not the new root」
//   ax_tree.cc:1394 / 1447           「already pending for creation」
//   ax_tree.cc:1781                  「Nodes left pending by the update」
import 'dart:io';

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
  });
}
