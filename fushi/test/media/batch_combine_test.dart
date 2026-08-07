import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/batch_combine.dart';

/// 块3 组合三档判定 + 合并目标选择的纯函数单测（widget/DB-free）。
void main() {
  group('classifyCombine 三档自适应', () {
    test('空选 → noop', () {
      expect(
        classifyCombine(collectionCount: 0, looseCount: 0),
        CombineTier.noop,
      );
    });

    test('仅散卡 → createNew', () {
      expect(
        classifyCombine(collectionCount: 0, looseCount: 3),
        CombineTier.createNew,
      );
    });

    test('恰 1 合集 + 散卡 → addToExisting', () {
      expect(
        classifyCombine(collectionCount: 1, looseCount: 2),
        CombineTier.addToExisting,
      );
    });

    test('仅 1 合集、无散卡 → noop（无可组合）', () {
      expect(
        classifyCombine(collectionCount: 1, looseCount: 0),
        CombineTier.noop,
      );
    });

    test('≥2 合集（无散卡）→ mergeCollections', () {
      expect(
        classifyCombine(collectionCount: 2, looseCount: 0),
        CombineTier.mergeCollections,
      );
    });

    test('≥2 合集 + 散卡 → mergeCollections', () {
      expect(
        classifyCombine(collectionCount: 3, looseCount: 5),
        CombineTier.mergeCollections,
      );
    });
  });

  group('chooseMergeTarget 目标 = 成员最多合集', () {
    test('取成员最多合集，其名作默认名', () {
      final MergeTargetChoice choice = chooseMergeTarget(
        <({int id, String name, int memberCount})>[
          (id: 1, name: 'A', memberCount: 2),
          (id: 2, name: 'B', memberCount: 5),
          (id: 3, name: 'C', memberCount: 3),
        ],
      );
      expect(choice.targetId, 2);
      expect(choice.defaultName, 'B');
    });

    test('平票取输入序第一个（调用方按 id 升序传入 → 最小 id 稳定）', () {
      final MergeTargetChoice choice = chooseMergeTarget(
        <({int id, String name, int memberCount})>[
          (id: 4, name: 'First', memberCount: 3),
          (id: 7, name: 'Second', memberCount: 3),
        ],
      );
      expect(choice.targetId, 4);
      expect(choice.defaultName, 'First');
    });
  });
}
