import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/pages/implementations/restore_point_notice.dart';

/// 更新前还原点没保存成功：启动后只提示一次（取出时就标成已提示）。
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('fushi_rp_notice_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('失败只取出一次；成功的状态不提示', () {
    final RestorePointStore store = RestorePointStore(tmp.path);
    expect(takeRestorePointFailureNotice(tmp.path), isNull);

    store.writeLastStatus(
      const RestorePointSnapshotStatus(
        database: RestorePointDatabase.fushi,
        ok: false,
        atMs: 1,
        fromSchema: 179,
        toSchema: 180,
        error: 'disk full',
      ),
    );
    final RestorePointSnapshotStatus? first = takeRestorePointFailureNotice(
      tmp.path,
    );
    expect(first?.error, 'disk full');
    expect(takeRestorePointFailureNotice(tmp.path), isNull);

    store.writeLastStatus(
      const RestorePointSnapshotStatus(
        database: RestorePointDatabase.srs,
        ok: true,
        atMs: 2,
        fromSchema: 40026,
        toSchema: 40027,
        pointId: 'x',
      ),
    );
    expect(takeRestorePointFailureNotice(tmp.path), isNull);
  });
}
