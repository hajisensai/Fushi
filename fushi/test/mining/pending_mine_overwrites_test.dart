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
    PendingMineOverwrites<String> book, {
    required bool landed,
    int? noteId,
    int? foundNoteId,
  }) => book.settle(
    key,
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
    book.addStarted(key);
    expect(book.queue(key, 'with-context'), isTrue);

    await settle(book, landed: true, noteId: 1700000000000);

    expect(overwritten, <(int, String)>[(1700000000000, 'with-context')]);
    expect(cancelled, isEmpty);
    expect(lookups, 0, reason: '后端回了 note id 就不必反查');
    expect(book.isAddPending(key), isFalse);
  });

  test('后端不回 note id（AnkiDroid）：按词反查到的笔记作为覆盖目标', () async {
    final PendingMineOverwrites<String> book = PendingMineOverwrites<String>();
    book.addStarted(key);
    book.queue(key, 'req');

    await settle(book, landed: true, foundNoteId: 99);

    expect(lookups, 1);
    expect(overwritten, <(int, String)>[(99, 'req')]);
  });

  test('写入失败：不覆盖，按「前一张没写进去」取消', () async {
    final PendingMineOverwrites<String> book = PendingMineOverwrites<String>();
    book.addStarted(key);
    book.queue(key, 'req');

    await settle(book, landed: false, foundNoteId: 99);

    expect(overwritten, isEmpty, reason: '写入失败绝不能去覆盖任何笔记');
    expect(lookups, 0, reason: '写入失败不该反查出一张旧卡来覆盖');
    expect(cancelled, <(String, PendingOverwriteCancel)>[
      ('req', PendingOverwriteCancel.addFailed),
    ]);
  });

  test('写入报成功但找不到那张笔记：不覆盖，说明原因', () async {
    final PendingMineOverwrites<String> book = PendingMineOverwrites<String>();
    book.addStarted(key);
    book.queue(key, 'req');

    await settle(book, landed: true);

    expect(overwritten, isEmpty);
    expect(cancelled.single.$2, PendingOverwriteCancel.noTargetNote);
  });

  test('同一个词连续排多次只保留最后一次', () async {
    final PendingMineOverwrites<String> book = PendingMineOverwrites<String>();
    book.addStarted(key);
    book.queue(key, 'first');
    book.queue(key, 'second');
    book.queue(key, 'last');
    expect(book.queuedFor(key), 'last');

    await settle(book, landed: true, noteId: 7);

    expect(overwritten, <(int, String)>[(7, 'last')], reason: '只覆盖一次，用最后一次的选择');
  });

  test('别的词的排队互不影响', () async {
    final PendingMineOverwrites<String> book = PendingMineOverwrites<String>();
    final String other = mineEntryKeyOf('離縁', 'りえん');
    book.addStarted(key);
    book.addStarted(other);
    book.queue(key, 'a');
    book.queue(other, 'b');

    await settle(book, landed: true, noteId: 1);

    expect(overwritten, <(int, String)>[(1, 'a')]);
    expect(book.queuedFor(other), 'b');
    expect(book.isAddPending(other), isTrue);
  });

  test('没有在途写入时不收覆盖请求；落地之后也不再收', () async {
    final PendingMineOverwrites<String> book = PendingMineOverwrites<String>();
    expect(book.queue(key, 'req'), isFalse, reason: '不是后台写入路径上的卡，排了也等不到落地');

    book.addStarted(key);
    await settle(book, landed: true, noteId: 1);
    expect(overwritten, isEmpty, reason: '没有排队请求时落地什么也不做');
    expect(book.queue(key, 'late'), isFalse, reason: '已落地：该走正常的已制卡覆盖路径');
  });
}
