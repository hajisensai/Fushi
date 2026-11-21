// 笔记引用的媒体（srs.db schema v4 的 srs_notes_cache.media_refs，缓存修订号 3）：
// srsReferencedMedia 读这一列而不再解析全部字段值；新建 / 改字段 / 删除 / 存量样式去重改写字段后
// 都随笔记缓存刷新；派生列被改坏后整层重建按真相复原。
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/srs_style_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000de';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  late SrsStorage st;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('fushi_srs_media_refs_');
    st = await openTestSrsStorage();
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄晚释放。
    }
  });

  Future<SrsDbStore> open({String? styleDir}) => SrsDbStore.open(
    core: st.core,
    profileUid: kProfile,
    deviceId: 'dev',
    styles: styleDir == null
        ? null
        : SrsStyleStore(Directory(p.join(tmp.path, styleDir))),
  );

  String lapis(String key) => srsLapisFieldId(kProfile, key);

  test('字段里的 <img> 与 [sound:] 进引用集；改字段去掉、删笔记后都不再算', () async {
    final SrsDbStore s = await open();
    final String n = await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        lapis('Expression'): '猫',
        lapis('Picture'): '<img src="a.png">',
        lapis('ExpressionAudio'): '[sound:b.mp3]',
      },
    );
    final String keep = await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        lapis('Expression'): '犬',
        lapis('Picture'): '<img src="c.png">',
      },
    );
    expect(
      await srsReferencedMedia(s),
      containsAll(<String>['a.png', 'b.mp3']),
    );
    expect(await srsReferencedMedia(s), contains('c.png'));

    await s.updateNote(
      n,
      fieldsById: <String, String>{
        lapis('Picture'): '',
        lapis('ExpressionAudio'): '[sound:b.mp3]',
      },
    );
    Set<String> refs = await srsReferencedMedia(s);
    expect(refs, isNot(contains('a.png')));
    expect(refs, contains('b.mp3'));

    await s.deleteNote(n);
    refs = await srsReferencedMedia(s);
    expect(refs, isNot(contains('b.mp3')), reason: '已删除的笔记不算当前引用');
    expect(refs, contains('c.png'), reason: '别的笔记不受影响');
    expect((await s.note(keep))!.deletedAt, isNull);
  });

  // 协议 3 的「老库（缓存修订号 2）打开时补齐」改成整层重建：新代没有 `cacheRev`，派生层是真相的纯函数。
  // 先经原始通道把 `notes.media_refs` 改坏，重建必须按笔记字段重算回来（只比重建前后同值测不出重建坏掉）。
  test('媒体引用列改坏后整层重建复原，引用集不变', () async {
    final SrsDbStore s = await open();
    await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        lapis('Expression'): '猫',
        lapis('Picture'): '<img src="a.png">',
        lapis('ExpressionAudio'): '[sound:b.mp3]',
      },
    );
    final Set<String> want = await srsReferencedMedia(s);
    expect(want, containsAll(<String>['a.png', 'b.mp3']));
    await expectRebuildRestores(
      s,
      'notes',
      "UPDATE notes SET media_refs = 'damaged.png'",
    );
    expect(await srsReferencedMedia(s), want);
    expect(await srsReferencedMedia(await open()), want);
  });
}
