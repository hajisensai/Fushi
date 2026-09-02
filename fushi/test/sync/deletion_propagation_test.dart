/// 删除传播纯决策核心 + 墓碑标记编解码测试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/deletion_propagation.dart';

void main() {
  // 墓碑值 = deletedAt；在库值 = 存在起始时刻（null = 该类资产不记时刻）。
  const int t0 = 1000; // 早
  const int t1 = 2000; // 墓碑删除时刻
  const int t2 = 3000; // 晚（删除之后重新加回来）

  group('computeDeletionPropagation', () {
    test('本地墓碑 + 远端仍在库 → deleteRemote', () {
      final c = computeDeletionPropagation(
        localTombstones: {
          'book': {'BookA': t1},
        },
        remoteTombstones: {},
        localPresent: {},
        remotePresent: {
          'book': {'BookA': t0, 'BookB': t0},
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
          'video': {'video/v1': t1},
        },
        localPresent: {
          'video': {'video/v1': t0},
        },
        remotePresent: {},
      );
      expect(c.single.direction, DeletionPropagationDirection.deleteLocal);
      expect(c.single.mediaType, 'video');
    });

    test('两端都删（墓碑齐）不产生候选（已收敛）', () {
      final c = computeDeletionPropagation(
        localTombstones: {
          'book': {'BookA': t1},
        },
        remoteTombstones: {
          'book': {'BookA': t1},
        },
        localPresent: {},
        remotePresent: {},
      );
      expect(c, isEmpty);
    });

    test('本地墓碑但远端已不在库 → 无候选（无需再删远端）', () {
      final c = computeDeletionPropagation(
        localTombstones: {
          'book': {'BookA': t1},
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
          'video': {'v2': t1},
        },
        remoteTombstones: {
          'book': {'b1': t1},
        },
        localPresent: {
          'book': {'b1': t0},
        },
        remotePresent: {
          'video': {'v2': t0},
        },
      );
      expect(c.map((e) => e.mediaType).toList(), ['book', 'video']);
    });
  });

  // BUG-2044：墓碑只对「删除时刻之前就存在」的那条生效。删后重加的新条目不是墓碑指
  // 的那一条，不产候选——否则本机自己取消收藏、发布到远端且永不 GC 的那条墓碑，会在
  // 用户重新收藏同一句之后被读回来，弹「其他设备已删除」问用户要不要删自己刚收藏的东西。
  group('删后重加仲裁（BUG-2044）', () {
    test('重新收藏晚于墓碑 → 不产 deleteLocal（回归用例）', () {
      final c = computeDeletionPropagation(
        localTombstones: {},
        remoteTombstones: {
          'favoritesentence': {'20:背 伸びたね|video/x|<null>|1159370': t1},
        },
        localPresent: {
          'favoritesentence': {'20:背 伸びたね|video/x|<null>|1159370': t2},
        },
        remotePresent: {},
      );
      expect(c, isEmpty, reason: '本地这条是删除之后重新收藏的，远端旧墓碑管不着它');
    });

    test('本地条目早于墓碑 → 仍产 deleteLocal（真实跨端删除不被压制）', () {
      final c = computeDeletionPropagation(
        localTombstones: {},
        remoteTombstones: {
          'favoritesentence': {'k': t1},
        },
        localPresent: {
          'favoritesentence': {'k': t0},
        },
        remotePresent: {},
      );
      expect(c, hasLength(1));
      expect(c.single.direction, DeletionPropagationDirection.deleteLocal);
    });

    test('时刻相等 → 不产候选（写墓碑与重加同一毫秒，判给重加）', () {
      final c = computeDeletionPropagation(
        localTombstones: {},
        remoteTombstones: {
          'favoritesentence': {'k': t1},
        },
        localPresent: {
          'favoritesentence': {'k': t1},
        },
        remotePresent: {},
      );
      expect(c, isEmpty);
    });

    test('时刻未知（null）→ 保持旧语义仍产候选（localaudio / audiobook）', () {
      final c = computeDeletionPropagation(
        localTombstones: {},
        remoteTombstones: {
          'localaudio': {'JMdict audio': t1},
        },
        localPresent: {
          'localaudio': {'JMdict audio': null},
        },
        remotePresent: {},
      );
      expect(c, hasLength(1), reason: '缺时刻时宁可多问一次，也不静默压制一次真实的跨端删除');
    });

    test('deleteRemote 方向共用同一条判据（远端是删后重加）', () {
      final c = computeDeletionPropagation(
        localTombstones: {
          'book': {'BookA': t1},
        },
        remoteTombstones: {},
        localPresent: {},
        remotePresent: {
          'book': {'BookA': t2},
        },
      );
      expect(c, isEmpty, reason: '远端那条是本地删除之后才建立的，不该被本地旧墓碑要求删掉');
    });
  });

  group('tombstoneAppliesTo', () {
    test('删除晚于存在起始时刻 → 管得着', () {
      expect(tombstoneAppliesTo(deletedAt: t1, presentSinceMs: t0), isTrue);
    });
    test('删除早于/等于存在起始时刻 → 管不着', () {
      expect(tombstoneAppliesTo(deletedAt: t1, presentSinceMs: t2), isFalse);
      expect(tombstoneAppliesTo(deletedAt: t1, presentSinceMs: t1), isFalse);
    });
    test('存在起始时刻未知 → 保守判管得着', () {
      expect(tombstoneAppliesTo(deletedAt: t1, presentSinceMs: null), isTrue);
    });
  });

  group('墓碑标记编解码', () {
    test('assetName 确定性 + 文件系统安全', () {
      final n = deletionTombstoneAssetName('book', 'CJK 书/名');
      expect(n, endsWith('.json'));
      expect(n, startsWith('book__'));
      expect(RegExp(r'^[A-Za-z0-9._]+$').hasMatch(n), isTrue);
      expect(
        n,
        deletionTombstoneAssetName('book', 'CJK 书/名'),
        reason: 'deterministic',
      );
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
        parseDeletionTombstoneJson({
          'mediaType': 'book',
          'itemKey': 'x',
        }), // 缺 deletedAt
        isNull,
      );
    });
  });
}
