import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/pending_mine_overwrites.dart';

/// BUG-3492（所有者拍板的方案 B）：卡还在后台写入 Anki 时发起的覆盖先排队，写入落地后
/// 自动执行；写入失败不覆盖并说明；同一个词连续排多次只保留最后一次。
void main() {
  final String key = mineEntryKeyOf('離婚', 'りこん');

  late List<(int, String)> overwritten;
  late List<(String, PendingOverwriteCancel)> cancelled;
  late int lookups;

  setUp(() {
    overwritten = <(int, String)>[];
    cancelled = <(String, PendingOverwriteCancel)>[];
    lookups = 0;
  });

  Future<void> settle(
    PendingMineOverwrites<String> book,
    int addId, {
    required bool landed,
    int? noteId,
    int? foundNoteId,
    String? forKey,
  }) => book.settle(
    forKey ?? key,
    addId,
    landed: landed,
    noteId: noteId,
    findNoteId: (String _) async {
      lookups++;
      return foundNoteId;
    },
    overwrite: (int id, String request) async => overwritten.add((id, request)),
    onCancelled: (String request, PendingOverwriteCancel reason) =>
        cancelled.add((request, reason)),
  );

  test('排队后写入完成：自动覆盖刚写下的那张笔记', () async {
    final PendingMineOverwrites<String> book = PendingMineOverwrites<String>();
    final int add = book.addStarted(key);
    expect(book.queue(key, 'with-context'), isTrue);

    await settle(book, add, landed: true, noteId: 1700000000000);

    expect(overwritten, <(int, String)>[(1700000000000, 'with-context')]);
    expect(cancelled, isEmpty);
    expect(lookups, 0, reason: '后端回了 note id 就不必反查');
    expect(book.isAddPending(key), isFalse);
  });

  test('后端不回 note id（AnkiDroid）：按词反查到的笔记作为覆盖目标', () async {
    final PendingMineOverwrites<String> book = PendingMineOverwrites<String>();
    final int add = book.addStarted(key);
    book.queue(key, 'req');

    await settle(book, add, landed: true, foundNoteId: 99);

    expect(lookups, 1);
    expect(overwritten, <(int, String)>[(99, 'req')]);
  });

  test('写入失败：不覆盖，按「前一张没写进去」取消', () async {
    final PendingMineOverwrites<String> book = PendingMineOverwrites<String>();
    final int add = book.addStarted(key);
    book.queue(key, 'req');

    await settle(book, add, landed: false, foundNoteId: 99);

    expect(overwritten, isEmpty, reason: '写入失败绝不能去覆盖任何笔记');
    expect(lookups, 0, reason: '写入失败不该反查出一张旧卡来覆盖');
    expect(cancelled, <(String, PendingOverwriteCancel)>[
      ('req', PendingOverwriteCancel.addFailed),
    ]);
  });

  test('写入报成功但找不到那张笔记：不覆盖，说明原因', () async {
    final PendingMineOverwrites<String> book = PendingMineOverwrites<String>();
    final int add = book.addStarted(key);
    book.queue(key, 'req');

    await settle(book, add, landed: true);

    expect(overwritten, isEmpty);
    expect(cancelled.single.$2, PendingOverwriteCancel.noTargetNote);
  });

  test('同一个词连续排多次只保留最后一次', () async {
    final PendingMineOverwrites<String> book = PendingMineOverwrites<String>();
    final int add = book.addStarted(key);
    book.queue(key, 'first');
    book.queue(key, 'second');
    book.queue(key, 'last');
    expect(book.queuedFor(key), 'last');

    await settle(book, add, landed: true, noteId: 7);

    expect(overwritten, <(int, String)>[(7, 'last')], reason: '只覆盖一次，用最后一次的选择');
  });

  test('别的词的排队互不影响', () async {
    final PendingMineOverwrites<String> book = PendingMineOverwrites<String>();
    final String other = mineEntryKeyOf('離縁', 'りえん');
    final int add = book.addStarted(key);
    book.addStarted(other);
    book.queue(key, 'a');
    book.queue(other, 'b');

    await settle(book, add, landed: true, noteId: 1);

    expect(overwritten, <(int, String)>[(1, 'a')]);
    expect(book.queuedFor(other), 'b');
    expect(book.isAddPending(other), isTrue);
  });

  test('没有在途写入时不收覆盖请求；落地之后也不再收', () async {
    final PendingMineOverwrites<String> book = PendingMineOverwrites<String>();
    expect(book.queue(key, 'req'), isFalse, reason: '不是后台写入路径上的卡，排了也等不到落地');

    final int add = book.addStarted(key);
    await settle(book, add, landed: true, noteId: 1);
    expect(overwritten, isEmpty, reason: '没有排队请求时落地什么也不做');
    expect(book.queue(key, 'late'), isFalse, reason: '已落地：该走正常的已制卡覆盖路径');
  });

  group('同一个词同时有两次后台写入在途（两个弹窗各点了一次「+」）', () {
    test('先落地的那次不清在途标记，也不吃掉绑在后一次上的覆盖', () async {
      final PendingMineOverwrites<String> book =
          PendingMineOverwrites<String>();
      final int first = book.addStarted(key);
      final int second = book.addStarted(key);
      expect(book.queue(key, 'for-second'), isTrue);

      await settle(book, first, landed: true, noteId: 100);

      expect(overwritten, isEmpty, reason: '覆盖绑在排队时最新的那次写入上，不能套到第一张卡');
      expect(book.isAddPending(key), isTrue, reason: '第二次写入还没落地');
      expect(book.queuedFor(key), 'for-second');
      expect(book.queue(key, 'later'), isTrue, reason: '仍有写入在途，照样能排');

      await settle(book, second, landed: true, noteId: 200);

      expect(overwritten, <(int, String)>[(200, 'later')]);
      expect(book.isAddPending(key), isFalse);
    });

    test('绑定的那次先落地：照常覆盖，另一次落地什么也不做', () async {
      final PendingMineOverwrites<String> book =
          PendingMineOverwrites<String>();
      final int first = book.addStarted(key);
      final int second = book.addStarted(key);
      book.queue(key, 'req');

      await settle(book, second, landed: true, noteId: 200);
      expect(overwritten, <(int, String)>[(200, 'req')]);
      expect(book.isAddPending(key), isTrue);

      await settle(book, first, landed: true, noteId: 100);
      expect(overwritten, hasLength(1));
      expect(cancelled, isEmpty);
    });
  });

  test('同一次写入重复结算、或结算一个不认识的代号：什么也不做', () async {
    final PendingMineOverwrites<String> book = PendingMineOverwrites<String>();
    final int add = book.addStarted(key);
    book.queue(key, 'req');

    await settle(book, add + 1000, landed: true, noteId: 1);
    expect(overwritten, isEmpty);
    expect(book.isAddPending(key), isTrue);

    await settle(book, add, landed: true, noteId: 1);
    await settle(book, add, landed: false);
    expect(overwritten, <(int, String)>[(1, 'req')]);
    expect(cancelled, isEmpty);
    expect(book.lastLanded(key), isTrue, reason: '重复结算不得改写结局');
  });

  group('lastLanded：在途写入全部结束之后的结局（给赛跑窗口里迟到的覆盖请求）', () {
    test('没走过后台写入 → null（看完再制卡的暂存等不在这条路上的卡）', () {
      expect(PendingMineOverwrites<String>().lastLanded(key), isNull);
    });

    test('写入在途 → null；落地 → true；失败 → false；再开一次写入 → 清空', () async {
      final PendingMineOverwrites<String> book =
          PendingMineOverwrites<String>();
      final int add = book.addStarted(key);
      expect(book.lastLanded(key), isNull);
      await settle(book, add, landed: true, noteId: 1);
      expect(book.lastLanded(key), isTrue);

      final int retry = book.addStarted(key);
      expect(book.lastLanded(key), isNull, reason: '新写入在途时旧结局作废');
      await settle(book, retry, landed: false);
      expect(book.lastLanded(key), isFalse);
    });

    test('两次在途只落地了一次：仍算在途，不报结局', () async {
      final PendingMineOverwrites<String> book =
          PendingMineOverwrites<String>();
      final int first = book.addStarted(key);
      book.addStarted(key);
      await settle(book, first, landed: false);
      expect(book.lastLanded(key), isNull);
      expect(book.isAddPending(key), isTrue);
    });
  });
}
