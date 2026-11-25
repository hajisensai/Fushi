/// 视频模板错误码 → 当前界面语言的文案。模板页与 ctl / AI 通道
/// （`ctl_settings_body_anki.dart`）共用，所以不放在页面文件里。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 把视频模板操作抛出的错误变成给用户看的一句话。
///
/// [AnkiVideoTemplateException] 按错误码取当前界面语言的文案（服务与 `fushi_anki`
/// 只抛码，不带句子）；其余异常不是这条功能自己判出来的（后端 / 文件系统 / 网络），
/// 原样显示它的文本，不替它编一句话。
String describeAnkiVideoTemplateError(Object error) {
  if (error is! AnkiVideoTemplateException) return error.toString();
  return switch (error.code) {
    AnkiVideoTemplateErrorCode.invalidField =>
      t.anki_video_template_error_field_invalid,
    AnkiVideoTemplateErrorCode.markerIncomplete =>
      t.anki_video_template_error_marker_incomplete,
    AnkiVideoTemplateErrorCode.blockEdited =>
      t.anki_video_template_error_block_edited,
    AnkiVideoTemplateErrorCode.blockDamaged =>
      t.anki_video_template_error_block_damaged,
    AnkiVideoTemplateErrorCode.targetChanged =>
      t.anki_video_template_error_target_changed,
    AnkiVideoTemplateErrorCode.audioMappingRequired =>
      t.anki_video_template_audio_required,
    AnkiVideoTemplateErrorCode.fieldHasOtherContent =>
      t.anki_video_template_error_field_occupied,
    AnkiVideoTemplateErrorCode.applyBackupMissing =>
      t.anki_video_template_error_apply_backup_missing,
    AnkiVideoTemplateErrorCode.noVideoBlock =>
      t.anki_video_template_error_block_missing,
    AnkiVideoTemplateErrorCode.restoreBackupMissing =>
      t.anki_video_template_error_restore_backup_missing,
    AnkiVideoTemplateErrorCode.hostOnly =>
      t.anki_video_template_error_host_only,
    AnkiVideoTemplateErrorCode.rereadRequired =>
      t.anki_video_template_error_reread_required,
    AnkiVideoTemplateErrorCode.templateChanged =>
      t.anki_video_template_error_template_changed,
    AnkiVideoTemplateErrorCode.writeRejected =>
      t.anki_video_template_error_write_rejected,
    AnkiVideoTemplateErrorCode.writeVerificationFailed =>
      t.anki_video_template_error_write_unverified,
    AnkiVideoTemplateErrorCode.mappingsChanged =>
      t.anki_video_template_error_mappings_changed,
    AnkiVideoTemplateErrorCode.templateChangedDuringApply =>
      t.anki_video_template_error_template_changed_midway,
    AnkiVideoTemplateErrorCode.mappingVerificationFailed =>
      t.anki_video_template_error_mappings_unverified,
    // 两个内层错误各自再走一遍本函数：它们可能也是带码的（回滚被拒 / 回滚校验失败）。
    AnkiVideoTemplateErrorCode.rollbackIncomplete =>
      t.anki_video_template_error_rollback_incomplete(
        error: describeAnkiVideoTemplateError(error.cause ?? ''),
        rollbackError: describeAnkiVideoTemplateError(
          error.rollbackCause ?? '',
        ),
      ),
    AnkiVideoTemplateErrorCode.rollbackUnreadable =>
      t.anki_video_template_error_rollback_unreadable,
    AnkiVideoTemplateErrorCode.rollbackRejected =>
      t.anki_video_template_error_rollback_rejected,
    AnkiVideoTemplateErrorCode.rollbackVerificationFailed =>
      t.anki_video_template_error_rollback_unverified,
  };
}
