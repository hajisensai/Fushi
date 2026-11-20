// `.fushisrs` 导入时内核拒收的错误怎么交给界面（sync2/srs_fushisrs.dart `srsFushiSrsKernelError`）：一条改动超过
// 16 MiB（内核 `gen4/op.rs` `ERR_OP_TOO_LARGE`）在 FFI 边界已类型化成 [SrsOpTooLargeException]，原样交回（导入页按
// 类型给「文件里有一条改动太大」的专门提示），不再换成按英文开头认的 [FormatException]；另一个集合 / 坏流照旧换成
// [FormatException]。内核侧的拒收与报错原文在 Rust `import_tests.rs`
// `an_op_over_the_payload_cap_is_refused_with_a_readable_reason_and_nothing_lands`。
import 'package:fushi_engine/srs/sync2/srs_fushisrs.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

void main() {
  test('一条改动太大：FFI 边界类型化的错误原样交回，不换成坏文件', () {
    final SrsCoreException kernel = SrsCoreException.of(
      -1,
      'gen4 import: op too large: change 0a:2 is 16777217 bytes (16.0 MiB), '
      'over the 16 MiB limit for a single change; nothing was imported',
    );
    expect(kernel, isA<SrsOpTooLargeException>());
    expect(identical(srsFushiSrsKernelError(kernel), kernel), isTrue);
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
