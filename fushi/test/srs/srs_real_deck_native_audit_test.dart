// 真实牌组原生渲染审计（手动跑，默认跳过）：
//   FUSHI_SRS_AUDIT_DB=<srs.db 副本> FUSHI_SRS_AUDIT_SUPPORT=<应用支持目录> \
//   FUSHI_SRS_AUDIT_PROFILE=<profile uid> [FUSHI_SRS_AUDIT_OUT=<报告文件>] \
//   flutter test test/srs/srs_real_deck_native_audit_test.dart
// 逐张卡走复习页同一判据（srsCardFaceRoute：Fushi 卡片带引擎回退原因，其余 → 原生 HTML 子集原因），
// 按笔记类型 × 模板统计原生 / 回退、回退原因与渲染异常。只读：库请先复制一份。
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:fushi/src/srs/srs_card_face_route.dart';
import 'package:fushi_core/fushi_core.dart' show srsIdType;
import 'package:fushi_engine/srs/srs_builtin.dart' show kSrsBuiltinFushiCardKey;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/srs_style_store.dart';
import 'package:test/test.dart';

class _Bucket {
  int total = 0;
  int native = 0;
  int empty = 0;
  final Map<String, int> reasons = <String, int>{};
  final Map<String, String> sampleCard = <String, String>{};
  final List<String> errors = <String>[];
}

void main() {
  final String? dbPath = Platform.environment['FUSHI_SRS_AUDIT_DB'];
  final String? support = Platform.environment['FUSHI_SRS_AUDIT_SUPPORT'];
  final String? uid = Platform.environment['FUSHI_SRS_AUDIT_PROFILE'];
  final String out =
      Platform.environment['FUSHI_SRS_AUDIT_OUT'] ?? 'srs_native_audit.txt';
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test(
    '真实牌组原生渲染审计',
    () async {
      final SrsStorage storage = await SrsStorage.open(path: dbPath!);
      addTearDown(storage.close);
      final SrsDbStore store = await SrsDbStore.open(
        db: storage.db,
        core: storage.core,
        profileUid: uid!,
        deviceId: 'audit',
        engine: null,
        fallbackRolloverHour: () => 4,
        styles: SrsStyleStore(
          SrsStyleStore.directoryFor(Directory(support!), uid),
        ),
      );
      final List<QueryRow> rows = await storage.db
          .customSelect(
            'SELECT c.id AS id FROM srs_cards_cache c '
            'JOIN srs_notes_cache n ON c.note_id = n.id '
            'WHERE n.profile_uid = ? AND n.deleted_at IS NULL '
            'AND c.hidden = 0',
            variables: <Variable<Object>>[Variable<String>(uid, srsIdType)],
          )
          .get();
      final String? dump = Platform.environment['FUSHI_SRS_AUDIT_DUMP'];
      if (dump != null) {
        for (final String id in dump.split(',')) {
          final SrsRenderedCard? r = await store.renderCard(id);
          final SrsCardDetail? d = await store.cardDetail(id);
          File('$out.$id.html').writeAsStringSync(
            '<!-- ${d?.noteType.name} / ${d?.template?.name} -->\n'
            '<!-- ===== CSS ===== -->\n<style>${r?.css}</style>\n'
            '<!-- ===== QUESTION ===== -->\n${r?.question}\n'
            '<!-- ===== ANSWER ===== -->\n${r?.answer}\n'
            '<!-- ===== FIELDS ===== -->\n${r?.fields}\n',
          );
        }
        return;
      }
      final Map<String, _Bucket> buckets = <String, _Bucket>{};
      final Stopwatch sw = Stopwatch()..start();
      for (final QueryRow row in rows) {
        final String id = row.read<String>('id');
        final SrsCardDetail? d = await store.cardDetail(id);
        if (d == null) continue;
        final String key =
            '${d.noteType.name} [${d.noteType.builtinKey ?? '-'}] / '
            '${d.template?.name ?? '?'} | ${d.deckName.split('::').first}';
        final _Bucket b = buckets.putIfAbsent(key, _Bucket.new);
        b.total++;
        try {
          final SrsRenderedCard? r = await store.renderCard(id, detail: d);
          if (r == null) {
            b.reasons.update(
              'renderCard=null',
              (int v) => v + 1,
              ifAbsent: () => 1,
            );
            continue;
          }
          if (r.isEmpty) b.empty++;
          final SrsCardFaceRoute route = srsCardFaceRoute(
            r,
            fushiCard: d.noteType.builtinKey == kSrsBuiltinFushiCardKey,
            languageCode: 'ja',
          );
          final String? reason = route is SrsCardFaceWeb
              ? route.fallback.toString()
              : null;
          if (reason == null) {
            b.native++;
          } else {
            b.reasons.update(reason, (int v) => v + 1, ifAbsent: () => 1);
            b.sampleCard.putIfAbsent(reason, () => id);
          }
        } on Object catch (e, st) {
          if (b.errors.length < 5) {
            b.errors.add(
              '$id: $e\n${st.toString().split('\n').take(6).join('\n')}',
            );
          }
          b.reasons.update(
            'EXCEPTION ${e.runtimeType}',
            (int v) => v + 1,
            ifAbsent: () => 1,
          );
        }
      }
      final StringBuffer sb = StringBuffer()
        ..writeln('cards=${rows.length} elapsed=${sw.elapsedMilliseconds}ms');
      final List<String> keys = buckets.keys.toList()..sort();
      for (final String k in keys) {
        final _Bucket b = buckets[k]!;
        sb.writeln(
          '\n## $k  total=${b.total} native=${b.native} '
          'fallback=${b.total - b.native} empty=${b.empty}',
        );
        for (final MapEntry<String, int> e in b.reasons.entries) {
          sb.writeln('  - ${e.value}× ${e.key}  (e.g. ${b.sampleCard[e.key]})');
        }
        for (final String e in b.errors) {
          sb.writeln('  ! $e');
        }
      }
      File(out).writeAsStringSync(sb.toString());
      // ignore: avoid_print
      print(sb.toString());
    },
    skip: dbPath == null ? 'set FUSHI_SRS_AUDIT_DB' : false,
    timeout: const Timeout(Duration(hours: 1)),
  );
}
