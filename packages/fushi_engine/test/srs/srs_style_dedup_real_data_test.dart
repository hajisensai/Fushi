/// 释义样式去重的真实数据体积对比（手动跑，不进 CI）。
///
/// 需要一份开发版库的**只读副本**（别直接指向在用的库）：
///
/// ```
/// FUSHI_SRS_STYLE_BENCH_DB=D:/hibiki-tmp/srs-style-dedup/fushi.db dart test test/srs/srs_style_dedup_real_data_test.dart
/// ```
///
/// 从 `mined_sentences`（制卡历史）取最近 N 条，按「从制卡历史导入」的形状建成 Fushi 卡片笔记，
/// 分别落进不去重 / 去重两个内存库，比较修改记录总字节、共享样式文件、渲染结果。
library;

import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_style_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'support/srs_test_storage.dart';
import 'package:fushi_engine/srs/srs_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000be';

void main() {
  final String? source = Platform.environment['FUSHI_SRS_STYLE_BENCH_DB'];
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<void> bench(int limit) async {
    final Database src = sqlite3.open(source!, mode: OpenMode.readOnly);
    final List<Row> rows = src.select(
      'SELECT expression, reading, glossary, sentence FROM mined_sentences '
      'ORDER BY id DESC LIMIT ?',
      <Object?>[limit],
    );
    src.dispose();
    final Directory tmp = Directory.systemTemp.createTempSync('srs_bench_');
    final SrsStorage plainDb = await openTestSrsStorage();
    final SrsStorage dedupDb = await openTestSrsStorage();
    try {
      final SrsDbStore plain = await SrsDbStore.open(
        db: plainDb.db,
        core: plainDb.core,
        profileUid: kProfile,
        deviceId: 'plain',
      );
      final Directory styleDir = Directory(p.join(tmp.path, 'media'));
      final SrsDbStore dedup = await SrsDbStore.open(
        db: dedupDb.db,
        core: dedupDb.core,
        profileUid: kProfile,
        deviceId: 'dedup',
        styles: SrsStyleStore(styleDir),
      );
      String fid(String k) => srsFushiCardFieldId(kProfile, k);
      final List<(String, String)> ids = <(String, String)>[];
      final Set<String> distinct = <String>{};
      int glossaryBytes = 0;
      int styleBytes = 0;
      for (final Row r in rows) {
        final String gloss = r['glossary'] as String;
        glossaryBytes += gloss.length;
        final SrsStyleDedup d = srsDedupStyles(gloss);
        for (final MapEntry<String, String> e in d.styles.entries) {
          distinct.add(e.key);
        }
        styleBytes += gloss.length - d.html.length;
        final Map<String, String> fields = <String, String>{
          fid('Expression'): r['expression'] as String,
          fid('ExpressionReading'): r['reading'] as String,
          fid('Sentence'): r['sentence'] as String,
          fid('Glossary'): gloss,
        };
        ids.add((
          await plain.createNote(
            noteTypeId: plain.fushiCardNoteTypeId,
            fieldsById: fields,
          ),
          await dedup.createNote(
            noteTypeId: dedup.fushiCardNoteTypeId,
            fieldsById: fields,
          ),
        ));
      }
      Future<int> bytes(SrsStorage s) async =>
          (await s.db
                  .customSelect(
                    'SELECT COALESCE(SUM(LENGTH(CAST(json AS BLOB))), 0) AS n '
                    'FROM srs_field_edits',
                  )
                  .getSingle())
              .read<int>('n');
      final int before = await bytes(plainDb);
      final int after = await bytes(dedupDb);
      int files = 0;
      int fileBytes = 0;
      for (final FileSystemEntity f in styleDir.listSync()) {
        if (f is File) {
          files++;
          fileBytes += f.lengthSync();
        }
      }
      // 渲染逐张对拍。
      Future<(String, String)> render(SrsDbStore s, String noteId) async {
        final SrsCardCacheRow c = (await s.cardsOfNote(
          noteId,
        )).firstWhere((SrsCardCacheRow c) => !c.hidden);
        final SrsRenderedCard rc = (await s.renderCard(c.id))!;
        return (rc.question, rc.answer);
      }

      for (final (String a, String b) in ids) {
        expect(await render(dedup, b), await render(plain, a));
      }
      expect(files, distinct.length);
      // ignore: avoid_print
      print(
        '[${rows.length} 张] 释义字段 ${glossaryBytes ~/ rows.length} 字符/卡'
        '（其中样式 ${styleBytes ~/ rows.length}）；'
        '修改记录 ${before ~/ 1024} KB → ${after ~/ 1024} KB'
        '（${(after * 100 / before).toStringAsFixed(1)}%）；'
        '共享样式文件 $files 个 / ${fileBytes ~/ 1024} KB；'
        '合计 ${(after + fileBytes) ~/ 1024} KB',
      );
    } finally {
      await plainDb.close();
      await dedupDb.close();
      tmp.deleteSync(recursive: true);
    }
  }

  test(
    '开发版制卡历史：最近 50 条 / 全部',
    () async {
      await bench(50);
      await bench(100000);
    },
    skip: source == null ? '设 FUSHI_SRS_STYLE_BENCH_DB 指向开发版库的只读副本' : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
