// 释义样式去重在 app 侧的接线：共享样式文件与卡片媒体同目录（随媒体同步 / 备份走）；
// 制卡回读（出处卡片的乐观并发检查）拿到与写入逐字节相同的内容。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_mining.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_style_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'srs_test_support.dart';

String _css(String dict) => List<String>.generate(
  40,
  (int i) => '[data-dictionary="$dict"] .g$i{padding:${i}px}',
).join('\n');

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('fushi_srs_style_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('共享样式文件落在卡片媒体目录里', () {
    expect(
      SrsStyleStore.directoryFor(tmp, kSrsTestProfile).path,
      SrsMediaStore.directoryFor(tmp, kSrsTestProfile).path,
    );
  });

  test('制卡回读按字段名展开引用行：写入什么读回什么', () async {
    final Directory dir = SrsMediaStore.directoryFor(tmp, kSrsTestProfile);
    final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore(
      styles: SrsStyleStore(dir),
    );
    try {
      final SrsMiner miner = SrsMiner(store: store, media: SrsMediaStore(dir));
      final String gloss =
          '<ol><li>snow<style>${_css('JMdict')}</style></li></ol>';
      final String noteId = await store.createNote(
        noteTypeId: store.fushiCardNoteTypeId,
        fieldsById: <String, String>{
          srsFushiCardFieldId(kSrsTestProfile, 'Expression'): '雪',
          srsFushiCardFieldId(kSrsTestProfile, 'Glossary'): gloss,
        },
      );
      expect(
        (await store.note(
          noteId,
        ))!.field(srsFushiCardFieldId(kSrsTestProfile, 'Glossary')),
        isNot(contains('<style>')),
      );
      expect((await miner.fieldsByName(noteId))!['Glossary'], gloss);

      final String gloss2 =
          '<ol><li>yuki<style>${_css('大辞林')}</style></li></ol>';
      await miner.writeFieldsByName(noteId, <String, String>{
        'Glossary': gloss2,
      });
      expect((await miner.fieldsByName(noteId))!['Glossary'], gloss2);
      expect(
        dir.listSync().map((FileSystemEntity f) => f.uri.pathSegments.last),
        containsAll(<String>[
          srsStyleMediaName(_css('JMdict')),
          srsStyleMediaName(_css('大辞林')),
        ]),
      );
    } finally {
      await db.close();
    }
  });
}
