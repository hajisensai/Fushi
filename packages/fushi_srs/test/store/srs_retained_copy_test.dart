import 'dart:io';

import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

/// 保留副本的全局命令（`gen4_retained_state` / `gen4_retained_delete`，内核 retained.rs）经真实原生库：没有保留副本的
/// 目录报 absent、删除什么都不动；回包解析。到期规则、换墓碑、核对不过不删由 Rust 测试覆盖（retained_tests.rs）。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('srs_retained_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  const SrsNativeRetainedCopyBackend backend = SrsNativeRetainedCopyBackend();

  test(
    'a fresh library has no retained copy and deleting does nothing',
    () async {
      final SrsCore core = SrsCore.open(dir.path);
      core.close();
      final SrsRetainedCopyState s = await backend.state(dir.path, nowMs: 1);
      expect(s.kind, SrsRetainedCopyKind.absent);
      expect(s.present, isFalse);
      expect(s.dueAtMs, isNull);
      expect(s.error, isNull);
      final SrsRetainedCopyDeletion d = await backend.delete(dir.path);
      expect(d.deleted, isFalse);
      expect(d.reason, 'absent');
    },
  );

  test('the wire shapes parse', () {
    final SrsRetainedCopyState s =
        SrsRetainedCopyState.fromJson(const <String, Object?>{
          'copy': 'sealed',
          'bytes': 1234,
          'migratedAtMs': 10,
          'firstSyncAtMs': 20,
          'dueAtMs': 30,
          'due': true,
          'error': 'disk full',
        });
    expect(s.present, isTrue);
    expect(s.bytes, 1234);
    expect(s.migratedAtMs, 10);
    expect(s.firstSyncAtMs, 20);
    expect(s.dueAtMs, 30);
    expect(s.due, isTrue);
    expect(s.error, 'disk full');
    expect(
      () => SrsRetainedCopyState.fromJson(const <String, Object?>{'copy': '?'}),
      throwsA(isA<SrsCoreException>()),
    );
    final SrsRetainedCopyDeletion d = SrsRetainedCopyDeletion.fromJson(
      const <String, Object?>{'deleted': true, 'freedBytes': 99},
    );
    expect(d.deleted, isTrue);
    expect(d.freedBytes, 99);
  });
}
