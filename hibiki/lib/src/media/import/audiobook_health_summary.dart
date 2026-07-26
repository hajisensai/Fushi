import 'package:hibiki/utils.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// 把 [AudiobookHealth] 压成一段 toast 尾巴；notApplicable/unrun/running 返回
/// null 省掉冗余提示。书/有声书两个导入对话框共用（原各持一份逐字相同副本，
/// 后寄生在 book_import_dialog.dart，迁出到共享目录——审计 §1-K）。
String? summarizeAudiobookHealth(AudiobookHealth h) {
  switch (h.kind) {
    case HealthKind.ok:
    case HealthKind.partial:
    case HealthKind.failed:
      final int pct = h.ratePct ?? 0;
      return t.health_match_summary(pct: pct);
    case HealthKind.notApplicable:
    case HealthKind.unrun:
    case HealthKind.running:
      return null;
  }
}
