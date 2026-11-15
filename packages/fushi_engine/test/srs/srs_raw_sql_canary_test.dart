// 金丝雀：测试宿主加载到的 fushi_fsrs 原生库带测试专用的原始 SQL 通道（cargo feature `raw_sql`，
// native/fushi_fsrs/Cargo.toml）。test/srs 里几十个文件靠 `SrsCore.debugExecRaw` 等直接改库造场景；库换成发布构建
// （不带它）时那些文件会成片红在 `kSrsRawSqlAbsent`，这一条先把原因说清楚。
import 'dart:io';

import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('测试用的原生库带原始 SQL 通道（raw_sql）', () {
    final Directory dir = Directory.systemTemp.createTempSync('srs_raw_sql_');
    final SrsCore core = SrsCore.open(p.join(dir.path, 'srs.db'));
    addTearDown(() {
      core.close();
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // 句柄晚释放。
      }
    });
    late final List<Map<String, Object?>> rows;
    try {
      rows = core.debugSelectRaw('SELECT 1 AS one');
    } on SrsCoreException catch (e) {
      fail(
        '测试库要带 cargo feature raw_sql（FUSHI_FSRS_FEATURES=raw_sql 编 '
        'native/fushi_fsrs）：$e',
      );
    }
    expect(rows, <Map<String, Object?>>[
      <String, Object?>{'one': 1},
    ]);
  });
}
