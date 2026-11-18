// `.fushisrs` 导入时内核拒收的错误怎么换成界面认得的 [FormatException]（sync2/srs_fushisrs.dart
// `srsFushiSrsKernelError`）：一条改动超过 16 MiB（内核 `gen4/op.rs` `ERR_OP_TOO_LARGE`）要单独认出来，导入页给
// 「文件里有一条改动太大」的专门提示，而不是笼统的「不是 Fushi 导出文件」。内核侧的拒收与报错原文在 Rust
// `import_tests.rs` `an_op_over_the_payload_cap_is_refused_with_a_readable_reason_and_nothing_lands`。
import 'package:fushi_engine/srs/sync2/srs_fushisrs.dart';
import 'package:test/test.dart';

void main() {
  test('一条改动太大：消息以 kSrsOpTooLarge 开头、带内核原话（多大、上限）', () {
    final Object e = srsFushiSrsKernelError(
      StateError(
        'sync2 import: gen4 import: op too large: change 0a:2 is 16777217 bytes '
        '(16.0 MiB), over the 16 MiB limit for a single change; nothing was imported',
      ),
    );
    expect(e, isA<FormatException>());
    final String m = (e as FormatException).message;
    expect(m, startsWith(kSrsOpTooLarge));
    expect(m, contains('16 MiB limit'));
    expect(m, contains('nothing was imported'));
    expect(m, isNot(contains('corrupt')));
  });

  test('另一个集合、坏流照旧；认不出的原样交回', () {
    final Object other = srsFushiSrsKernelError(
      StateError('gen4 import: this file belongs to another collection (x)'),
    );
    expect((other as FormatException).message, contains('another profile'));
    final Object corrupt = srsFushiSrsKernelError(
      StateError('gen4 import: corrupt export (FSRS4EXP: trailing bytes)'),
    );
    expect((corrupt as FormatException).message, startsWith('corrupt'));
    final StateError unknown = StateError('disk full');
    expect(identical(srsFushiSrsKernelError(unknown), unknown), isTrue);
  });
}
