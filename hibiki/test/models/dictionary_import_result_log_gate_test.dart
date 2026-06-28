import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/dictionary_import_manager.dart';

/// TODO-943：词典导入**成功且有词条**的结果摘要不应再写进「错误日志」页
/// （`ErrorLogService` 是单通道无级别日志器）。只有真正需要排查的情况——
/// 导入失败、或成功但 0 词条（native 把 bank 解空，BUG-927/TODO-892 症状）——
/// 才写入。这里直接断言 [DictionaryImportManager.shouldLogImportResult] 这个
/// 决策门的三种情况，它是 `_logImportResultSummary` 是否调 `ErrorLogService.log`
/// 的唯一闸门。
void main() {
  group('DictionaryImportManager.shouldLogImportResult (TODO-943)', () {
    test('success with imported entries does NOT log to error log', () {
      // 用例 1：success==true 且 total>0（正常成功，93091 词条）→ 不写错误日志。
      expect(
        DictionaryImportManager.shouldLogImportResult(
          success: true,
          totalEntries: 93091,
        ),
        isFalse,
        reason: '正常成功导入不应出现在错误日志页',
      );
    });

    test('failed import still logs to error log', () {
      // 用例 2：success==false（导入失败）→ 仍写错误日志（保留 BUG-927 诊断）。
      expect(
        DictionaryImportManager.shouldLogImportResult(
          success: false,
          totalEntries: 0,
        ),
        isTrue,
        reason: '导入失败必须可在错误日志查到',
      );
      // 失败但计数非零（部分失败语义）也应记录。
      expect(
        DictionaryImportManager.shouldLogImportResult(
          success: false,
          totalEntries: 42,
        ),
        isTrue,
      );
    });

    test('success with zero entries still logs (swallowed-empty case)', () {
      // 用例 3：success==true 且 total==0（被吞空）→ 仍写错误日志，含 0 词条警告。
      expect(
        DictionaryImportManager.shouldLogImportResult(
          success: true,
          totalEntries: 0,
        ),
        isTrue,
        reason: 'success+0 词条是 BUG-927 真正想报警的情况，必须留痕',
      );
    });
  });
}
