// ctl `library rm srt:<uid>` 只走一条删除路径（BUG-3101 同类，#3722 c37 遗留）。
//
// 以前 `_removeSrtBook` 对配对了 EPUB 的字幕书先 `deleteBook`、再按 uid 调一次
// `SrtBookRepository.delete`（行已随 deleteEpubBook 级联删掉），两边的失败都不看，
// 删不掉也回报成功。现在与书架字幕书卡删除同一个原语 `deleteSrtShelfBook`（行为由
// reader_fushi_delete_cleanup_test / reader_fushi_source_test 钉着），失败回 conflict。
// 处理器是私有类、要整套 AppModel + Riverpod 才能起，这里钉源码结构。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('_removeSrtBook 走 deleteSrtShelfBook，不再二次按 uid 删、失败不回报成功', () {
    final String src = File(
      p.join('lib', 'src', 'ops', 'ctl_library_routes.dart'),
    ).readAsStringSync();
    final int start = src.indexOf('Future<Object?> _removeSrtBook(');
    expect(start, isNonNegative);
    final String body = src.substring(start, src.indexOf('\n  }\n', start));
    expect(body, contains('.deleteSrtShelfBook('));
    expect(body, isNot(contains('.deleteBook(')));
    expect(body, isNot(contains('repo.delete(')));
    expect(body, contains('if (!result.deleted)'));
    expect(body, contains('CtlFailure.conflict('));
  });
}
