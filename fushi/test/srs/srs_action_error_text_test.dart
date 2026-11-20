import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/srs/srs_action_error_text.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsCoreException;

/// 本机写复习库失败的提示（[srsActionFailedText]）：单条改动超过 16 MiB 时内核整笔回滚、报
/// `gen4 store: op too large: …; nothing was saved`（`native/fushi_fsrs/src/store/gen4/truth.rs` 的写入闸），
/// 用户要看到「太大、什么都没存、改用媒体附件」，而不是笼统的「操作没有成功，请重试」——重试只会再失败一次。
void main() {
  const String kernel =
      'gen4 store: op too large: change 0a:2 is 16777217 bytes (16.0 MiB), '
      'over the 16 MiB limit for a single change (usually a field holding an '
      'embedded image or file; store it as a media file instead); nothing was saved';

  test('内核写入闸拒收：给「太大、没存」的专门提示', () {
    expect(
      srsActionFailedText(const SrsCoreException(-1, kernel)),
      t.srs_write_op_too_large,
    );
  });

  test('经后台 isolate 转交（StateError 裹着原话）也认得出', () {
    expect(
      srsActionFailedText(StateError('SrsCoreException(-1): $kernel')),
      t.srs_write_op_too_large,
    );
  });

  test('别的失败仍是通用提示', () {
    expect(
      srsActionFailedText(const SrsCoreException(-1, 'gen4 store: no note n1')),
      t.srs_action_failed,
    );
    expect(srsActionFailedText(Exception('disk full')), t.srs_action_failed);
    expect(t.srs_write_op_too_large, isNot(t.srs_action_failed));
  });
}
