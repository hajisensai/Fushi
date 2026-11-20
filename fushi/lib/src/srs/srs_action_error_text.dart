import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_engine/srs/sync2/srs_fushisrs.dart' show kSrsOpTooLarge;

/// 本机写复习库（加 / 改笔记、改牌组、改笔记类型、复习等）失败时给用户看的提示。
///
/// 内核拒收单条超过载荷上限（16 MiB，`native/fushi_fsrs/src/gen4/op.rs` `ERR_OP_TOO_LARGE`）的改动时整笔回滚、什么
/// 都没存；它的报错可能裹在 `SrsCoreException` / 后台 isolate 转交的 `StateError` 里，所以按错误文本认（与导入页的
/// `srsFushiSrsKernelError` 同一个标记）。认出来给专门的说明（多半是字段里直接粘贴了图片或文件、什么都没存、
/// 大文件改用媒体附件），其余仍是通用的「操作没有成功」。
String srsActionFailedText(Object error) =>
    error.toString().contains(kSrsOpTooLarge)
    ? t.srs_write_op_too_large
    : t.srs_action_failed;
