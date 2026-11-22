import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_legacy_lapis_migration.dart';
import 'package:test/test.dart';

/// 预演逐条判出的「笔记 → 要补的字段 → 值」（[SrsLegacyLapisMigrationOps.previewLapisBackfill] 的 `onFill`；
/// 预演对象本身只留计数，HBK-AUDIT-209），顺带核对计数与逐条结果一致。
Future<Map<String, Map<String, String>>> previewFills(
  SrsDbStore s, {
  List<String>? noteIds,
  int? chunk,
}) async {
  final Map<String, Map<String, String>> out = <String, Map<String, String>>{};
  final Map<String, int> counts = <String, int>{};
  void collect(String id, Map<String, String> fill) {
    out[id] = fill;
    for (final String f in fill.keys) {
      counts[f] = (counts[f] ?? 0) + 1;
    }
  }

  final SrsLapisBackfillPreview p = chunk == null
      ? await s.previewLapisBackfill(noteIds: noteIds, onFill: collect)
      : await s.previewLapisBackfill(
          noteIds: noteIds,
          chunk: chunk,
          onFill: collect,
        );
  expect(p.notes, out.length);
  expect(p.fieldCounts, counts);
  return out;
}
