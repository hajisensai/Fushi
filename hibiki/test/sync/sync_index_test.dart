import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_index.dart';

// 增量同步索引的纯数据层（TODO-2656）。
//
// 这一层决定「哪本书可以整本跳过、不发任何网络请求」，所以它的每条判据都直接对应
// 一种漏同步的可能。测试因此集中在**保守方向**：格式不认识、版本比本端新、设备身份
// 解析歧义时，必须判为不可用而不是将就着用。

void main() {
  group('索引资产名 codec', () {
    test('往返', () {
      final String name =
          syncIndexAssetName(deviceId: 'devA', revision: 7, dirty: false);
      expect(name, 'index-devA-r7-clean.json');

      final SyncIndexAssetRef? ref = parseSyncIndexAssetName(name);
      expect(ref, isNotNull);
      expect(ref!.deviceId, 'devA');
      expect(ref.revision, 7);
      expect(ref.dirty, isFalse);
    });

    test('dirty 状态编在名字里，无需下载内容即可判读', () {
      final String name =
          syncIndexAssetName(deviceId: 'devA', revision: 3, dirty: true);
      final SyncIndexAssetRef? ref = parseSyncIndexAssetName(name);
      expect(ref!.dirty, isTrue);
      expect(ref.revision, 3);
    });

    test('deviceId 含连字符时仍解析出完整身份', () {
      // 从左往右分割会把 deviceId 切碎、把同一台设备认成好几台，进而让每台的记录
      // 互相覆盖。解析必须从右往左剥固定后缀。
      const String deviceId = 'my-laptop-r2-clean';
      final String name =
          syncIndexAssetName(deviceId: deviceId, revision: 11, dirty: false);
      final SyncIndexAssetRef? ref = parseSyncIndexAssetName(name);
      expect(ref, isNotNull);
      expect(ref!.deviceId, deviceId);
      expect(ref.revision, 11);
      expect(ref.dirty, isFalse);
    });

    test('非索引名 / 畸形名一律拒绝', () {
      const List<String> rejected = <String>[
        'collections-devA.json',
        'index-devA-r7.json',
        'index-devA-clean.json',
        'index-devA-rX-clean.json',
        'index--r7-clean.json',
        'index-devA-r7-clean.txt',
        'index-devA-r-1-clean.json',
        'index-devA-r007-clean.json',
      ];
      for (final String name in rejected) {
        expect(parseSyncIndexAssetName(name), isNull, reason: name);
      }
    });
  });

  group('清单解析', () {
    test('往返保真', () {
      const SyncIndexManifest manifest = SyncIndexManifest(
        deviceId: 'devA',
        revision: 2,
        publishedAt: 1234,
        books: <String, SyncIndexBookEntry>{
          'Book A': SyncIndexBookEntry(progressAt: 900, progressFraction: 0.5),
          'Book B': SyncIndexBookEntry(),
        },
        stages: <String, String>{'collections': 'abc'},
      );

      final SyncIndexManifest? parsed =
          SyncIndexManifest.tryDecode(manifest.encode());
      expect(parsed, isNotNull);
      expect(parsed!.deviceId, 'devA');
      expect(parsed.revision, 2);
      expect(parsed.books['Book A'],
          const SyncIndexBookEntry(progressAt: 900, progressFraction: 0.5));
      // 「远端没有 progress 文件」是一条**有内容的记录**，不能在往返中退化成缺失：
      // 少了它，从没读过的书永远命不中索引、每轮照旧发一次列举请求。
      expect(parsed.books.containsKey('Book B'), isTrue);
      expect(parsed.books['Book B'], const SyncIndexBookEntry());
      expect(parsed.stages['collections'], 'abc');
    });

    test('版本高于本端 → 不可用（宁可全量，不拿旧语义解释新数据）', () {
      final Map<String, dynamic> future = <String, dynamic>{
        'schemaVersion': SyncIndexManifest.schemaVersion + 1,
        'deviceId': 'devA',
        'revision': 1,
        'books': <String, dynamic>{},
      };
      expect(SyncIndexManifest.tryParse(future), isNull);
    });

    test('缺关键字段 / 非法结构 → null', () {
      expect(SyncIndexManifest.tryParse(null), isNull);
      expect(SyncIndexManifest.tryParse('not a map'), isNull);
      expect(
        SyncIndexManifest.tryParse(<String, dynamic>{
          'schemaVersion': 1,
          'revision': 1,
        }),
        isNull,
      );
      expect(
        SyncIndexManifest.tryParse(<String, dynamic>{
          'schemaVersion': 1,
          'deviceId': 'devA',
        }),
        isNull,
      );
      expect(SyncIndexManifest.tryDecode('{ broken'), isNull);
    });
  });

  group('跨设备折叠', () {
    test('同一本书取观测到的最大 progressAt', () {
      final Map<String, SyncIndexBookEntry> folded =
          foldSyncIndexBooks(<SyncIndexManifest>[
        const SyncIndexManifest(
          deviceId: 'a',
          revision: 1,
          publishedAt: 0,
          books: <String, SyncIndexBookEntry>{
            'B': SyncIndexBookEntry(progressAt: 100, progressFraction: 0.1),
          },
        ),
        const SyncIndexManifest(
          deviceId: 'b',
          revision: 1,
          publishedAt: 0,
          books: <String, SyncIndexBookEntry>{
            'B': SyncIndexBookEntry(progressAt: 300, progressFraction: 0.3),
          },
        ),
      ]);
      expect(folded['B']!.progressAt, 300);
      expect(folded['B']!.progressFraction, 0.3);
    });

    test('「我上次看的时候还没有」不能抹掉别人看到的真实文件', () {
      final Map<String, SyncIndexBookEntry> folded =
          foldSyncIndexBooks(<SyncIndexManifest>[
        const SyncIndexManifest(
          deviceId: 'a',
          revision: 1,
          publishedAt: 0,
          books: <String, SyncIndexBookEntry>{
            'B': SyncIndexBookEntry(progressAt: 500, progressFraction: 0.5),
          },
        ),
        const SyncIndexManifest(
          deviceId: 'b',
          revision: 1,
          publishedAt: 0,
          books: <String, SyncIndexBookEntry>{'B': SyncIndexBookEntry()},
        ),
      ]);
      expect(folded['B']!.progressAt, 500);
    });

    test('并集覆盖各设备各自见过的书', () {
      final Map<String, SyncIndexBookEntry> folded =
          foldSyncIndexBooks(<SyncIndexManifest>[
        const SyncIndexManifest(
          deviceId: 'a',
          revision: 1,
          publishedAt: 0,
          books: <String, SyncIndexBookEntry>{
            'X': SyncIndexBookEntry(progressAt: 1),
          },
        ),
        const SyncIndexManifest(
          deviceId: 'b',
          revision: 1,
          publishedAt: 0,
          books: <String, SyncIndexBookEntry>{
            'Y': SyncIndexBookEntry(progressAt: 2),
          },
        ),
      ]);
      expect(folded.keys.toSet(), <String>{'X', 'Y'});
    });
  });

  group('阶段跳过判据', () {
    const SyncIndexPlan usable = SyncIndexPlan(
      usable: true,
      remoteUnchanged: true,
      books: <String, SyncIndexBookEntry>{},
      ownStages: <String, String>{'collections': 'fp1'},
      ownRevision: 1,
      peerRevisions: <String, int>{},
      forcedFullSweep: false,
    );

    test('指纹一致且远端无人动过 → 可跳过', () {
      expect(usable.canSkipStage('collections', 'fp1'), isTrue);
    });

    test('本地指纹变了 → 不跳过', () {
      expect(usable.canSkipStage('collections', 'fp2'), isFalse);
    });

    test('算不出指纹 → 不跳过（不知道变没变，绝不当成没变）', () {
      expect(usable.canSkipStage('collections', null), isFalse);
    });

    test('上轮没记录过这个阶段 → 不跳过', () {
      expect(usable.canSkipStage('aggregate', 'anything'), isFalse);
    });

    test('远端有人动过 → 一律不跳过', () {
      const SyncIndexPlan changed = SyncIndexPlan(
        usable: true,
        remoteUnchanged: false,
        books: <String, SyncIndexBookEntry>{},
        ownStages: <String, String>{'collections': 'fp1'},
        ownRevision: 1,
        peerRevisions: <String, int>{},
        forcedFullSweep: false,
      );
      expect(changed.canSkipStage('collections', 'fp1'), isFalse);
    });

    test('索引不可用 → 一律不跳过', () {
      expect(
          SyncIndexPlan.disabled.canSkipStage('collections', 'fp1'), isFalse);
    });
  });

  group('指纹', () {
    test('与键的遍历顺序无关', () {
      expect(
        syncStageFingerprint(<String, Object?>{'a': 1, 'b': 2}),
        syncStageFingerprint(<String, Object?>{'b': 2, 'a': 1}),
      );
    });

    test('任一值变化即变', () {
      expect(
        syncStageFingerprint(<String, Object?>{'a': 1}),
        isNot(syncStageFingerprint(<String, Object?>{'a': 2})),
      );
    });

    test('哈希是确定性的（不依赖 hashCode 的运行间稳定性）', () {
      // 值写死在断言里：换了实现就必须显式承认「所有设备的阶段指纹都会失配一次」。
      expect(stableContentHash(''), 'cbf29ce484222325');
      expect(stableContentHash('hibiki'), stableContentHash('hibiki'));
      expect(stableContentHash('a'), isNot(stableContentHash('b')));
    });
  });

  test('阶段清单不含删除墓碑（它的候选确认不能被跳过吞掉）', () {
    expect(SyncIndexStage.all, isNot(contains('deletionTombstones')));
    expect(SyncIndexStage.all, contains(SyncIndexStage.books));
    expect(SyncIndexStage.all, contains(SyncIndexStage.collections));
  });
}
