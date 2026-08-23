import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/texthooker_service.dart';

// BUG-1797：galgame 捕获工作台台词列表的「已制卡」徽章，此前是**单向内存 latch**
// （markLineMined 只能 false→true，永不复核 Anki）。用户在 Anki 里把那张卡删掉之后，
// 徽章仍然亮着——这就是「anki 扫描不是实时的」的真身。
//
// 修复把行模型从「制过卡这个事件」改成「制出的那张卡的身份」（minedNoteId），
// 徽章因此可以被 Anki 的真实状态推翻。这组测试守两件事：
//   ① 确认被删的卡 → 徽章必须消失；
//   ② 没被确认删除的一切情形（空集 = Anki 不可达 / 别人的 id / 没有 id 的行）
//      → 徽章必须**原样保留**。②比①更要害：误清会在 Anki 没开着时清空满屏徽章。

void main() {
  late TexthookerService service;

  setUp(() => service = TexthookerService.test());

  String appendLine(String text) {
    final TexthookerLineEntry? entry = service.appendLine(text);
    expect(entry, isNotNull);
    return entry!.id;
  }

  bool minedOf(String id) => service.entryById(id)!.mined;

  group('BUG-1797 制卡回写记下 note id', () {
    test('markLineMined 记下 note id，徽章点亮', () {
      final String id = appendLine('こんにちは');
      expect(service.markLineMined(id, noteId: 1700000000001), isTrue);
      final TexthookerLineEntry entry = service.entryById(id)!;
      expect(entry.mined, isTrue);
      expect(entry.minedNoteId, 1700000000001);
    });

    test('重复标记同一张卡是幂等的（不重复通知）', () {
      final String id = appendLine('こんにちは');
      expect(service.markLineMined(id, noteId: 42), isTrue);
      expect(service.markLineMined(id, noteId: 42), isFalse);
    });

    test('已 mined 的行拿到新 note id 仍要写进去（覆写卡后仍可复核）', () {
      final String id = appendLine('こんにちは');
      service.markLineMined(id, noteId: 42);
      expect(service.markLineMined(id, noteId: 99), isTrue,
          reason: '否则这行永远拿着过期 id、复核不到真正那张卡');
      expect(service.entryById(id)!.minedNoteId, 99);
    });

    test('minedNoteIds 只收「已制卡且有 id」的行', () {
      final String withId = appendLine('あ');
      final String withoutId = appendLine('い');
      final String notMined = appendLine('う');
      service.markLineMined(withId, noteId: 7);
      service.markLineMined(withoutId);
      expect(service.minedNoteIds, <int>{7});
      expect(minedOf(withoutId), isTrue, reason: '没有 id 不等于没制卡');
      expect(minedOf(notMined), isFalse);
    });
  });

  group('BUG-1797 卡被删则徽章消失', () {
    test('确认删除的 note 对应的行清回未制卡', () {
      final String id = appendLine('こんにちは');
      service.markLineMined(id, noteId: 42);

      expect(service.clearMinedForNotes(<int>{42}), 1);

      final TexthookerLineEntry entry = service.entryById(id)!;
      expect(entry.mined, isFalse, reason: '徽章必须消失');
      expect(entry.minedNoteId, isNull, reason: '陈旧 id 一并清掉，不留给下次复核');
    });

    test('同一张卡被多行引用时全部清掉', () {
      final String a = appendLine('あ');
      final String b = appendLine('い');
      service.markLineMined(a, noteId: 42);
      service.markLineMined(b, noteId: 42);
      expect(service.clearMinedForNotes(<int>{42}), 2);
      expect(minedOf(a), isFalse);
      expect(minedOf(b), isFalse);
    });

    test('清掉后可以重新制卡（不是一次性状态）', () {
      final String id = appendLine('こんにちは');
      service.markLineMined(id, noteId: 42);
      service.clearMinedForNotes(<int>{42});
      expect(service.markLineMined(id, noteId: 43), isTrue);
      expect(minedOf(id), isTrue);
      expect(service.entryById(id)!.minedNoteId, 43);
    });

    test('监听者只在真的清掉了东西时被通知', () {
      final String id = appendLine('こんにちは');
      service.markLineMined(id, noteId: 42);
      int notifications = 0;
      service.addListener(() => notifications++);

      expect(service.clearMinedForNotes(<int>{999}), 0);
      expect(notifications, 0, reason: '一行都没动就不该重绘');

      expect(service.clearMinedForNotes(<int>{42}), 1);
      expect(notifications, 1);
    });
  });

  group('BUG-1797 绝不误清（本组是核心不变式）', () {
    test('空集什么都不清 —— Anki 不可达时走的正是这条', () {
      final String id = appendLine('こんにちは');
      service.markLineMined(id, noteId: 42);

      expect(service.clearMinedForNotes(<int>{}), 0);

      expect(minedOf(id), isTrue,
          reason: 'findDeletedNotes 查询失败时返回空集，'
              '此时必须一张都不清，否则 Anki 没开着就会清空满屏徽章');
      expect(service.entryById(id)!.minedNoteId, 42);
    });

    test('别的 note id 不误伤本行', () {
      final String id = appendLine('こんにちは');
      service.markLineMined(id, noteId: 42);
      expect(service.clearMinedForNotes(<int>{41, 43}), 0);
      expect(minedOf(id), isTrue);
    });

    test('没有 note id 的行永不被清（无身份即无复核依据）', () {
      final String id = appendLine('こんにちは');
      service.markLineMined(id);
      expect(minedOf(id), isTrue);

      expect(service.clearMinedForNotes(<int>{42, 99}), 0);

      expect(minedOf(id), isTrue,
          reason: '拿不到 id 的后端保持旧 latch 行为，宁可陈旧不可误清');
    });

    test('未制卡的行不受影响', () {
      final String id = appendLine('こんにちは');
      expect(service.clearMinedForNotes(<int>{42}), 0);
      expect(minedOf(id), isFalse);
    });
  });
}
