import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/srs/srs_action_error_text.dart';
import 'package:fushi_engine/srs/apkg/srs_anki_package.dart'
    show SrsImportException;
import 'package:fushi_srs/fushi_srs.dart'
    show SrsCoreException, SrsOpTooLargeException;

/// 复习库写入 / 导入失败的提示（srs_action_error_text.dart）：单条改动超过 16 MiB 时内核整笔回滚，FFI 边界
/// （`SrsCoreException.of`）把它类型化成 [SrsOpTooLargeException]；界面按**类型**给「太大、没存 / 导入停在那里」的
/// 专门提示，而不是笼统的「操作没有成功，请重试」（重试只会再失败一次）或内核英文原话，也不匹配英文字符串。
void main() {
  const String cap =
      'op too large: change 0a:2 is 16777217 bytes (16.0 MiB), over the 16 '
      'MiB limit for a single change (usually a field holding an embedded '
      'image or file; store it as a media file instead)';
  final SrsCoreException localWrite = SrsCoreException.of(
    -1,
    'gen4 store: $cap; nothing was saved',
  );
  final SrsCoreException streamImport = SrsCoreException.of(
    -1,
    'gen4 import: $cap; nothing was imported',
  );

  test('内核报错在 FFI 边界就是 SrsOpTooLargeException', () {
    expect(localWrite, isA<SrsOpTooLargeException>());
    expect(streamImport, isA<SrsOpTooLargeException>());
  });

  group('srsActionFailedText（本机写入）', () {
    test('超过上限：给「太大、没存」的专门提示', () {
      expect(srsActionFailedText(localWrite), t.srs_write_op_too_large);
      expect(t.srs_write_op_too_large, isNot(t.srs_action_failed));
    });

    test('别的失败仍是通用提示；只按类型认，不按英文原话认', () {
      expect(
        srsActionFailedText(const SrsCoreException(-1, 'gen4 store: no note')),
        t.srs_action_failed,
      );
      expect(srsActionFailedText(Exception('disk full')), t.srs_action_failed);
      expect(
        srsActionFailedText(
          StateError('SrsCoreException(-1): gen4 store: $cap'),
        ),
        t.srs_action_failed,
      );
    });
  });

  group('srsImportFailureMessage（.apkg / 文本导入、Anki 迁移）', () {
    test('落库那一批里有一条超过上限：专门提示，不是内核英文原话', () {
      final String m = srsImportFailureMessage(localWrite);
      expect(m, t.srs_import_op_too_large);
      expect(m, isNot(contains('op too large')));
    });

    test('需要内核、包里的原因、其他错误照旧', () {
      expect(
        srsImportFailureMessage(
          const SrsImportException(SrsImportException.needsKernel, 'zstd'),
        ),
        t.srs_import_needs_kernel,
      );
      expect(
        srsImportFailureMessage(
          const SrsImportException(SrsImportException.corrupt, 'not a zip'),
        ),
        t.srs_import_failed(error: 'not a zip'),
      );
      expect(
        srsImportFailureMessage(StateError('boom')),
        t.srs_import_failed(error: 'Bad state: boom'),
      );
    });
  });

  group('srsFushiSrsImportFailureText（时间线页导入 .fushisrs）', () {
    test('一条改动太大 / 另一个复习库 / 坏文件 / 其他各有各的提示', () {
      expect(
        srsFushiSrsImportFailureText(streamImport),
        t.srs_timeline_import_op_too_large,
      );
      expect(
        srsFushiSrsImportFailureText(
          const FormatException('this .fushisrs belongs to another profile'),
        ),
        t.srs_timeline_import_other_profile,
      );
      expect(
        srsFushiSrsImportFailureText(
          const FormatException('corrupt .fushisrs: x'),
        ),
        t.srs_timeline_import_invalid,
      );
      expect(
        srsFushiSrsImportFailureText(StateError('disk full')),
        t.srs_timeline_import_failed,
      );
      expect(<String>{
        t.srs_timeline_import_op_too_large,
        t.srs_timeline_import_other_profile,
        t.srs_timeline_import_invalid,
        t.srs_timeline_import_failed,
      }, hasLength(4));
    });
  });
}
