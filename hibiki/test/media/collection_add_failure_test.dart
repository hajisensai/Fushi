import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/src/media/collections/collection_drag.dart';
import 'package:hibiki/utils.dart';

/// 「拖进合集」落库失败必须给用户明确提示，**不得静默**。
///
/// 根因背景：书架 / 视频库 / 游戏库三处 `_addMediaToCollection` 各抄一遍
/// 「查成员 → 幂等提示 → 落库」，都没有 try/catch，又都以 unawaited Future 挂在
/// `CollectionDropTarget.onMediaDropped` 这个 `void` 回调上。`addToCollection`
/// 抛出时异常直接漂进 zone，用户看到的只是「拖了没反应」——他会以为加成功了，
/// 而合集里其实什么都没有，随后基于这个错误信息做决定（不再重试、以为已归类）。
///
/// 收口成 [addMediaRefToCollection] 之后本套用例钉三条结局各自的可见后果，
/// 其中 failed 这条就是上面那个缺陷的回归守卫。
void main() {
  const MediaRef bookRef = MediaRef(kind: MediaKind.epub, entryKey: 'book-key');
  const int collectionId = 1;

  Future<HibikiDatabase> openDb() async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async {
      try {
        await db.close();
      } catch (_) {
        // 用例里可能已经关过（模拟失败那条），重复 close 无害。
      }
    });
    return db;
  }

  test('落库失败 → 返回 failed、给出明确提示，且函数本身不抛', () async {
    final _FailingWriteDatabase db = _FailingWriteDatabase();
    addTearDown(db.close);

    final List<String> messages = <String>[];
    late final CollectionAddOutcome outcome;
    // 不抛是硬要求：调用点是 void 回调，抛出去就等于静默。
    await expectLater(
      () async {
        outcome = await addMediaRefToCollection(
          database: db,
          collectionId: collectionId,
          mediaRef: bookRef,
          notify: messages.add,
        );
      }(),
      completes,
    );

    expect(outcome, CollectionAddOutcome.failed);
    expect(
      await db.getCollectionItems(collectionId),
      isEmpty,
      reason: '失败就是没写进去——提示必须与真实落库结果一致',
    );
    expect(
      messages,
      <String>[t.collection_add_failed],
      reason: '落库失败必须让用户看到——静默失败会让他以为已经加进合集了',
    );
  });

  test('首次加入 → 返回 added，且不抢调用方的成功提示', () async {
    final HibikiDatabase db = await openDb();
    final List<String> messages = <String>[];

    final CollectionAddOutcome outcome = await addMediaRefToCollection(
      database: db,
      collectionId: collectionId,
      mediaRef: bookRef,
      notify: messages.add,
    );

    expect(outcome, CollectionAddOutcome.added);
    expect(messages, isEmpty, reason: '成功提示由调用方在刷新后报，此处不得抢发');
    final List<MediaCollectionItemRow> items =
        await db.getCollectionItems(collectionId);
    expect(items.map((MediaCollectionItemRow it) => it.entryKey), <String>[
      bookRef.entryKey,
    ]);
  });

  test('重复拖入 → 返回 alreadyPresent 并提示（幂等 no-op 不得静默）', () async {
    final HibikiDatabase db = await openDb();
    await db.addToCollection(collectionId, bookRef.kind, bookRef.entryKey);
    final List<String> messages = <String>[];

    final CollectionAddOutcome outcome = await addMediaRefToCollection(
      database: db,
      collectionId: collectionId,
      mediaRef: bookRef,
      notify: messages.add,
    );

    expect(outcome, CollectionAddOutcome.alreadyPresent);
    expect(messages, <String>[t.collection_already_has_item]);
  });

  test('三个库页都必须走这一份编排，不得再各自裸调 addToCollection', () {
    const List<String> pages = <String>[
      'lib/src/pages/implementations/reader_hibiki_history_page.dart',
      'lib/src/pages/implementations/home_video_page.dart',
      'lib/src/pages/implementations/games_library_page.dart',
    ];
    for (final String path in pages) {
      final String source = _readSource(path);
      final int start = source.indexOf('Future<void> _addMediaToCollection(');
      expect(start, isNonNegative, reason: '$path 里找不到 _addMediaToCollection');
      final String body = source.substring(
        start,
        source.indexOf('\n  }', start) + 4,
      );
      expect(
        body,
        contains('addMediaRefToCollection('),
        reason: '$path 的拖入合集必须走共享编排（内含 try/catch + 失败提示）',
      );
      expect(
        body,
        isNot(contains('.addToCollection(')),
        reason: '$path 不得绕过共享编排裸调 DAO——那正是失败静默的老路',
      );
    }
  });
}

/// 写入必失败的库：只让 `addToCollection` 抛（读成员照常成功），精确复现
/// 「查得到、写不进」这条真实故障面（DB 锁 / 磁盘满 / 约束冲突）。
class _FailingWriteDatabase extends HibikiDatabase {
  _FailingWriteDatabase() : super.forTesting(NativeDatabase.memory());

  @override
  Future<void> addToCollection(
    int collectionId,
    MediaKind mediaType,
    String entryKey,
  ) async {
    throw StateError('simulated collection write failure');
  }
}

/// 测试进程的工作目录是 `hibiki/`，故这里用仓内相对路径。
String _readSource(String relativePath) =>
    File(relativePath).readAsStringSync();
