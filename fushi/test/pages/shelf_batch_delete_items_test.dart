import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// gap-novelmisc-7 批删兜底：书架批删某一本抛错时，异常以前直接冲出循环——后面的
/// 书一本都没删、书架不刷新、多选态不退出、没有提示。逐项执行器每项单独兜住。
void main() {
  test('一项抛错：记日志、计入 failed，后面的照删；进度每项都推进', () async {
    await ErrorLogService.instance.clear();
    final List<String> attempted = <String>[];
    int progress = 0;

    final ({int done, int failed}) outcome =
        await runShelfBatchDeleteItems<String>(
          <String>['a', 'boom', 'c', 'gone'],
          (String key) async {
            attempted.add(key);
            if (key == 'boom') throw StateError('database is locked');
            return key != 'gone';
          },
          onItemDone: () => progress++,
          logSource: 'test.batchDelete',
        );

    expect(attempted, <String>['a', 'boom', 'c', 'gone']);
    expect(outcome.done, 2, reason: '只数真删掉的（BUG-439 口径）');
    expect(outcome.failed, 1);
    expect(progress, 4);
    expect(
      ErrorLogService.instance.entries.map((ErrorLogEntry e) => e.source),
      contains('test.batchDelete'),
    );
  });
}
