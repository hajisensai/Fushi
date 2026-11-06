/// 专名表的 Drift 实现（app 与无头服务端共用）：表 `video_subtitle_glossaries`
/// （schema v119），一部作品一行。
library;

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';

/// 当前时刻（毫秒）；测试注入。
typedef SubtitleGlossaryClock = int Function();

int _systemNowMs() => DateTime.now().millisecondsSinceEpoch;

/// [SubtitleGlossaryStore] 落在 [FushiDatabase] 上。
///
/// `glossary_json` 是 [SubtitleGlossary.encode] 的整份快照（读回只认它）；
/// `source_fingerprint` / `user_edited_at` 是从同一份快照上提的列，供不解 JSON 的
/// 查询用，写入时与 JSON 同源，不会分叉。`updated_at` 记本机写入时刻。
class SubtitleGlossaryDriftStore implements SubtitleGlossaryStore {
  SubtitleGlossaryDriftStore(this.database, {SubtitleGlossaryClock? now})
    : _now = now ?? _systemNowMs;

  final FushiDatabase database;
  final SubtitleGlossaryClock _now;

  /// 读出一部作品的专名表；没有返回 null。
  ///
  /// JSON 只由 [save] 经 [SubtitleGlossary.encode] 写入，解析失败说明库被外部改坏，
  /// 异常原样抛出——吞成 null 会让调用方当「从未生成」重新生成并覆盖用户手编的条目。
  @override
  Future<SubtitleGlossary?> load(String workKey) async {
    final VideoSubtitleGlossaryRow? row = await database
        .getVideoSubtitleGlossary(workKey);
    if (row == null) return null;
    return SubtitleGlossary.decode(row.glossaryJson);
  }

  @override
  Future<void> save(String workKey, SubtitleGlossary glossary) =>
      database.upsertVideoSubtitleGlossary(
        VideoSubtitleGlossariesCompanion.insert(
          workKey: workKey,
          glossaryJson: glossary.encode(),
          sourceFingerprint: Value<String>(glossary.sourceFingerprint),
          userEditedAt: Value<int?>(glossary.userEditedAt),
          updatedAt: _now(),
        ),
      );
}
