import 'package:flutter_test/flutter_test.dart';

import 'reader_history_source_corpus.dart';

/// BUG-439 source guard: the shelf batch-delete must count only books whose
/// rows were actually removed, never optimistically `deleted++` and then claim
/// "已删除 N 本". Previously the SRT branch incremented unconditionally after
/// `repo.delete(uid)` regardless of whether any row was deleted, so deleting an
/// orphan/absent entry still inflated the toast count.
void main() {
  group('reader history batch delete honesty (BUG-439)', () {
    test('SRT branch only counts genuine deletions, not optimistic success',
        () {
      final String source = readReaderHistorySource();

      final int start = source.indexOf('Future<void> _batchDeleteConfirm(');
      expect(start, isNonNegative,
          reason: '_batchDeleteConfirm must exist in the shelf history page');
      // 2026-10 体验优化：确认后的执行体拆进 `_runBatchDelete`（外层负责忙碌态
      // 进度弹窗），计数门控随之搬家；窗口延伸到执行体结尾，不变量不变。
      final int runner =
          source.indexOf('Future<void> _runBatchDelete(', start + 1);
      expect(runner, isNonNegative,
          reason: 'batch delete runner must follow _batchDeleteConfirm');
      final int end = source.indexOf('Future<void>', runner + 1);
      final String body =
          end > start ? source.substring(start, end) : source.substring(start);

      // BUG-3101 起 SRT 卡的删除收进 `ReaderFushiSource.deleteSrtShelfBook`（配对
      // EPUB 的走 deleteBook、纯字幕书走 repo，只走一条路径）；以前 deleteBook 后再
      // `repo.delete(uid…)` 一次，行已被级联删掉、回报 0 行，计数少算。
      expect(
        body.contains('deleteSrtShelfBook('),
        isTrue,
        reason: 'the SRT branch deletes via deleteSrtShelfBook (BUG-3101)',
      );
      expect(
        body.contains('await repo.delete(uid'),
        isFalse,
        reason: 'BUG-3101：不得在 deleteBook 之后再按 uid 删一次 srt 行',
      );
      // 不写死门控的字面形状：删除结果的类型会随需求扩展。BUG-439 的不变量是
      // **门控本身**——计数器只能由这次删除的返回值决定。
      expect(
        RegExp(r'if \(removed(\.\w+)?( > 0)?\) deleted\+\+').hasMatch(body),
        isTrue,
        reason: 'only real deletions may be counted (BUG-439).',
      );
      // 这一条正向匹配就足以钉住 BUG-439：它的原始形态是**删掉门控**、`repo.delete`
      // 之后无条件 `deleted++`；门控一没，上面的正则就不匹配 → 红。（变异实测过。）
    });
  });
}
