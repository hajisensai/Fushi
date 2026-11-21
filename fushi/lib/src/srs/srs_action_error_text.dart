import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_engine/srs/apkg/srs_anki_package.dart'
    show SrsImportException;
import 'package:fushi_srs/fushi_srs.dart' show SrsOpTooLargeException;

// 复习库写入 / 导入失败 → 给人看的一句话。错误按**类型**认（FFI 边界的 `SrsCoreException.of` 已把内核报错类型化，
// 后台 isolate 原样转交），不在界面里匹配内核的英文原话；调用方把拿到的错误对象原样交进来。

/// 本机写复习库（加 / 改笔记、改牌组、改笔记类型、复习、设备改名 / 停用等）失败时的提示。
///
/// 内核拒收单条超过载荷上限（16 MiB，`native/fushi_fsrs/src/gen4/op.rs` `ERR_OP_TOO_LARGE`）的改动时整笔回滚、什么
/// 都没存（[SrsOpTooLargeException]）：给专门的说明（多半是字段里直接粘贴了图片或文件、什么都没存、大文件改用媒体
/// 附件）。其余仍是通用的「操作没有成功」。
String srsActionFailedText(Object error) => error is SrsOpTooLargeException
    ? t.srs_write_op_too_large
    : t.srs_action_failed;

/// 时间线页导入 `.fushisrs`（`srsImportFushiSrs`）失败的提示：一条改动超过载荷上限（[SrsOpTooLargeException]，文件
/// 没坏、什么都没导入）、另一个复习库的文件、坏文件（`srsFushiSrsKernelError` 换成的 [FormatException]），其余笼统的
/// 「导入失败」。
String srsFushiSrsImportFailureText(Object error) => switch (error) {
  SrsOpTooLargeException() => t.srs_timeline_import_op_too_large,
  FormatException(:final String message)
      when message.contains('another profile') =>
    t.srs_timeline_import_other_profile,
  FormatException() => t.srs_timeline_import_invalid,
  _ => t.srs_timeline_import_failed,
};

/// .apkg / .colpkg / 文本导入、Anki 一键迁移失败的提示。
///
/// - 排程内核不可用、新格式包解不开 → 「需要内核」；
/// - 落库的那一批里有一条超过载荷上限（[SrsOpTooLargeException]）→ 说清楚是哪类内容太大、导入停在那里、此前已落库的
///   批保留（每批只含完整笔记，导入幂等，改小后重新导入会补齐）；
/// - 其余带上原因。
String srsImportFailureMessage(Object failure) => switch (failure) {
  SrsImportException(code: SrsImportException.needsKernel) =>
    t.srs_import_needs_kernel,
  SrsOpTooLargeException() => t.srs_import_op_too_large,
  SrsImportException(:final String message) => t.srs_import_failed(
    error: message,
  ),
  _ => t.srs_import_failed(error: '$failure'),
};
