/// 删除传播纯决策核心 + 墓碑标记编解码测试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/deletion_propagation.dart';

void main() {
  group('computeDeletionPropagation', () {
    test('本地墓碑 + 远端仍在库 → deleteRemote', () {
      final c = computeDeletionPropagation(
        localTombstones: {
          'book': {'BookA'}
        },
        remoteTombstones: {},
        localPresent: {},
        remotePresent: {
          'book': {'BookA', 'BookB'}
        },
      );
      expect(c, hasLength(1));
      expect(c.single.direction, DeletionPropagationDirection.deleteRemote);
      expect(c.single.itemKey, 'BookA');
    });

    test('远端墓碑 + 本地仍在库 → deleteLocal', () {
      final c = computeDeletionPropagation(
        localTombstones: {},
        remoteTombstones: {
          'video': {'video/v1'}
        },
        localPresent: {
          'video': {'video/v1'}
        },
        remotePresent: {},
      );
      expect(c.single.direction, DeletionPropagationDirection.deleteLocal);
      expect(c.single.mediaType, 'video');
    });

    test('两端都删（墓碑齐）不产生候选（已收敛）', () {
      final c = computeDeletionPropagation(
        localTombstones: {
          'book': {'BookA'}
        },
        remoteTombstones: {
          'book': {'BookA'}
        },
        localPresent: {},
        remotePresent: {},
      );
      expect(c, isEmpty);
    });

    test('本地墓碑但远端已不在库 → 无候选（无需再删远端）', () {
      final c = computeDeletionPropagation(
        localTombstones: {
          'book': {'BookA'}
        },
        remoteTombstones: {},
        localPresent: {},
        remotePresent: {},
      );
      expect(c, isEmpty);
    });

    test('确定性排序（mediaType→itemKey→方向）', () {
      final c = computeDeletionPropagation(
        localTombstones: {
          'video': {'v2'}
        },
        remoteTombstones: {
          'book': {'b1'}
        },
        localPresent: {
          'book': {'b1'}
        },
        remotePresent: {
          'video': {'v2'}
        },
      );
      expect(c.map((e) => e.mediaType).toList(), ['book', 'video']);
    });
  });

  group('墓碑标记编解码', () {
    test('assetName 确定性 + 文件系统安全', () {
      final n = deletionTombstoneAssetName('book', 'CJK 书/名');
      expect(n, endsWith('.json'));
      expect(n, startsWith('book__'));
      expect(RegExp(r'^[A-Za-z0-9._]+$').hasMatch(n), isTrue);
      expect(n, deletionTombstoneAssetName('book', 'CJK 书/名'),
          reason: 'deterministic');
    });

    test('json 往返', () {
      final j = deletionTombstoneJson('video', 'video/v1', 12345);
      final p = parseDeletionTombstoneJson(j);
      expect(p!.mediaType, 'video');
      expect(p.itemKey, 'video/v1');
      expect(p.deletedAt, 12345);
    });

    test('坏 json 安全返回 null', () {
      expect(parseDeletionTombstoneJson('nope'), isNull);
      expect(parseDeletionTombstoneJson({'mediaType': 'book'}), isNull);
      expect(
          parseDeletionTombstoneJson(
              {'mediaType': 'book', 'itemKey': 'x'}), // 缺 deletedAt
          isNull);
    });
  });
}
