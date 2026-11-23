// BUG-5017：v3.0.x 旧事件同步在位置目录 `fushi-srs/<dir>/` 下留的写入者目录 `<设备>#<化身号>/`（`batch-*` /
// `snapshot-*` / `cursor` / `probe` / `profile.json` / `media/`）迁移完也永远留着（用户 host 上一个就几百 MB）。
//
// 真内核 + 真 LocalDirectoryAssetStore（互联 host 的同步数据目录就是它），走生产入口 [srsRunLocationRound]：
// - 内核 `location_root` 认过根（新根 `v4/` 在用）：只有死文件 + 空 `media/` 的写入者目录整个删；`media/` 里还有
//   v3.3.0 没搬完的媒体、或有认不出的文件 → 只删死文件，目录与那些文件留着；别的目录、`v4/` 一个不碰；再跑一轮幂等。
// - 内核拒绝的位置（只有协议 1 旧根 `v2/`）：一个字节不动。
// - 完整的一趟媒体对账（生产入口 [srsRunLocationMedia]，拍板台 bug-5017-legacy-writer-media）把写入者目录里
//   v3.3.0 没搬完的媒体收尾：集合引用、本机没有的搬进本机媒体目录（同一趟传上位置）；不引用的、本机已有同名的删；
//   之后写入者目录整个删。名字已有别处的绑定时不抢：媒体同步照常换回绑定的内容。
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_runner.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart'
    show kSrsSync2Namespace;
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/srs_fake_engine.dart';
import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000f5';

/// v3.0.x 写入者目录名（44 字符设备 ID + `#` + 化身号，与用户 host 上的同形）。
const String kWriter1 = 'pzzCeD9XhMUjc8aHC58YYX__FAOfI8wmmSA-Azn_Ctg=#1';
const String kWriter2 = 'pzzCeD9XhMUjc8aHC58YYX__FAOfI8wmmSA-Azn_Ctg=#2';
const String kWriter3 = '2RIr94DPav6kxb5RWSGciWgE4LNKvGBCRtT4wT2iGSc=#1';

const List<String> kDeadFiles = <String>[
  'batch-0000000129',
  'batch-0000000130',
  'snapshot-0000000128',
  'cursor',
  'probe',
  'profile.json',
];

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  late LocalDirectoryAssetStore assets;
  final int t = DateTime.utc(2026, 11, 22, 9).millisecondsSinceEpoch;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('srs_legacy_writers_');
    assets = LocalDirectoryAssetStore(tmp);
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄滞后（Windows）：留给系统清理。
    }
  });

  Future<SrsDbStore> device(String id) async {
    final SrsStorage st = await openTestSrsStorage();
    st.core.sync2(<String, Object?>{
      'op': 'identity',
      'profile': kProfile,
      'now': t,
    });
    return SrsDbStore.open(
      core: st.core,
      profileUid: kProfile,
      deviceId: id,
      engine: const SrsFakeEngine(),
      trustedClock: SrsTrustedClock(wallClockMs: () => t, bootClockMs: () => t),
    );
  }

  /// 位置目录 `fushi-srs/<dir>/` 在磁盘上的路径。
  String locationPath(String dir) => p.join(tmp.path, kSrsSync2Namespace, dir);

  void write(String path, [String content = 'x']) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  /// [root] 下全部文件的相对路径（`/` 分隔、排好序）。
  List<String> filesUnder(String root) {
    final Directory d = Directory(root);
    if (!d.existsSync()) return const <String>[];
    return <String>[
      for (final FileSystemEntity e in d.listSync(recursive: true))
        if (e is File) p.relative(e.path, from: root).replaceAll(r'\', '/'),
    ]..sort();
  }

  /// 种一个 v3.0.x 写入者目录：死文件全套 + `media/`（[media] 里的文件名，空 = 空目录）+ [extra] 文件。
  void plantWriter(
    String loc,
    String writer, {
    List<String> media = const <String>[],
    List<String> extra = const <String>[],
  }) {
    final String w = p.join(loc, writer);
    for (final String f in kDeadFiles) {
      write(p.join(w, f));
    }
    Directory(p.join(w, 'media')).createSync(recursive: true);
    for (final String m in media) {
      write(p.join(w, 'media', m), 'image');
    }
    for (final String f in extra) {
      write(p.join(w, f));
    }
  }

  test('根认过（新根 v4 在用）：死文件整删，没搬完的媒体与认不出的文件留着，别的不碰，幂等', () async {
    final SrsDbStore s = await device('dev-a');
    await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(s.profileUid, 'Expression'): '猫',
      },
    );
    final String dir = await srsLocationDir(s);
    final String loc = locationPath(dir);
    plantWriter(loc, kWriter1);
    plantWriter(loc, kWriter2, media: <String>['cat.png']);
    plantWriter(loc, kWriter3, extra: <String>['notes.txt']);
    // 不是 `<设备>#<化身号>` 形状的目录：不是 v3.0.x 写入者目录，里面同名的文件也不碰。
    write(p.join(loc, 'misc', 'batch-0000000001'));
    write(p.join(loc, 'misc#x', 'cursor'));

    final SrsSync2Report r = await srsRunLocationRound(
      SrsLocationBackend(assets),
      s,
      'interconnect:host',
    );
    expect(r.error, isNull);
    expect(r.legacyWriterErrors, isEmpty);
    expect(r.legacyWritersRemoved, <String>[kWriter1]);
    final List<String> v4 = filesUnder(p.join(loc, kSrs4Root));
    expect(v4, contains('meta.json'));
    expect(
      v4.where((String f) => f.contains('/seg-')),
      isNotEmpty,
      reason: '这一轮照常发了段',
    );

    expect(Directory(p.join(loc, kWriter1)).existsSync(), isFalse);
    expect(filesUnder(p.join(loc, kWriter2)), <String>['media/cat.png']);
    expect(filesUnder(p.join(loc, kWriter3)), <String>['notes.txt']);
    expect(Directory(p.join(loc, kWriter3, 'media')).existsSync(), isTrue);
    expect(filesUnder(p.join(loc, 'misc')), <String>['batch-0000000001']);
    expect(filesUnder(p.join(loc, 'misc#x')), <String>['cursor']);

    // 幂等：再跑一轮什么都不删、不报错，v4 不变（只多出这一轮自己的东西）。
    final SrsSync2Report again = await srsRunLocationRound(
      SrsLocationBackend(assets),
      s,
      'interconnect:host',
    );
    expect(again.error, isNull);
    expect(again.legacyWritersRemoved, isEmpty);
    expect(again.legacyWriterErrors, isEmpty);
    expect(filesUnder(p.join(loc, kWriter2)), <String>['media/cat.png']);
    expect(filesUnder(p.join(loc, kSrs4Root)), containsAll(v4));
  });

  test('内核拒绝的位置（只有协议 1 旧根 v2/）：写入者目录一个字节不动', () async {
    final SrsDbStore s = await device('dev-b');
    final String dir = await srsLocationDir(s);
    final String loc = locationPath(dir);
    write(p.join(loc, 'v2', 'meta.json'), '{"v":1,"minReader":1}');
    plantWriter(loc, kWriter1);
    final List<String> before = filesUnder(loc);

    final SrsSync2Report r = await srsRunLocationRound(
      SrsLocationBackend(assets),
      s,
      'interconnect:host',
    );
    expect(r.error, kSrsLocationProtocol1Root);
    expect(r.legacyWritersRemoved, isEmpty);
    expect(filesUnder(loc), before);
    expect(Directory(p.join(loc, kWriter1, 'media')).existsSync(), isTrue);
  });

  /// 集合里加一条笔记，图片字段引用 [picture]。
  Future<void> addPicture(SrsDbStore s, String expr, String picture) =>
      s.createNote(
        noteTypeId: s.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(s.profileUid, 'Expression'): expr,
          srsLapisFieldId(s.profileUid, 'Picture'): '<img src="$picture">',
        },
      );

  /// [loc] 下内容寻址目录里有没有内容 [sha]（`<根>/media/<前2>/<sha>`）。
  bool remoteHas(String loc, String sha) => filesUnder(
    loc,
  ).any((String f) => f.endsWith('/media/${sha.substring(0, 2)}/$sha'));

  test('媒体对账：没搬完的媒体引用到的搬进本机并传上位置，不引用 / 本机已有的删，之后写入者目录整删', () async {
    final SrsDbStore s = await device('dev-c');
    await addPicture(s, '猫', 'cat.png');
    await addPicture(s, '犬', 'dog.png');
    final String dir = await srsLocationDir(s);
    final String loc = locationPath(dir);
    final Directory mediaRoot = Directory(p.join(tmp.path, 'local-media'))
      ..createSync(recursive: true);
    // 本机已有 dog.png（之后改过的版本）：写入者目录那份是旧副本。
    write(p.join(mediaRoot.path, 'dog.png'), 'dog-new');
    plantWriter(loc, kWriter2);
    write(p.join(loc, kWriter2, 'media', 'cat.png'), 'cat-v30');
    write(p.join(loc, kWriter2, 'media', 'dog.png'), 'dog-v30');
    write(p.join(loc, kWriter2, 'media', 'orphan.png'), 'orphan');
    // 有认不出的文件的写入者目录：媒体照样收尾，目录与那个文件留着。
    plantWriter(loc, kWriter3, extra: <String>['notes.txt']);
    write(p.join(loc, kWriter3, 'media', 'cat.png'), 'cat-v30');

    final SrsSync2Report r = await srsRunLocationRound(
      SrsLocationBackend(assets),
      s,
      'interconnect:host',
    );
    expect(r.error, isNull);
    expect(r.legacyWritersRemoved, isEmpty, reason: '一轮同步本身不碰没搬完的媒体');
    expect(filesUnder(p.join(loc, kWriter2)), <String>[
      'media/cat.png',
      'media/dog.png',
      'media/orphan.png',
    ]);

    final SrsMediaSyncReport m = await srsRunLocationMedia(
      SrsLocationBackend(assets),
      s,
      mediaRoot,
      locationId: 'interconnect:host',
    );
    expect(m.completed, isTrue);
    expect(m.legacyWriterErrors, isEmpty);
    // writer2 的 cat.png 搬进来；writer3 的 cat.png 到时本机已有 → 删；dog / orphan 删。
    expect(m.legacyMediaImported, 1);
    expect(m.legacyMediaDropped, 3);
    expect(m.legacyWritersRemoved, <String>[kWriter2]);
    expect(
      File(p.join(mediaRoot.path, 'cat.png')).readAsStringSync(),
      'cat-v30',
    );
    expect(
      File(p.join(mediaRoot.path, 'dog.png')).readAsStringSync(),
      'dog-new',
    );
    expect(File(p.join(mediaRoot.path, 'orphan.png')).existsSync(), isFalse);
    expect(
      mediaRoot.listSync().map((FileSystemEntity e) => p.basename(e.path)),
      unorderedEquals(<String>['cat.png', 'dog.png']),
      reason: '临时文件不留',
    );
    expect(
      remoteHas(loc, srsMediaSha256('cat-v30'.codeUnits)),
      isTrue,
      reason: '搬进来的同一趟就按内容传上位置',
    );
    expect(Directory(p.join(loc, kWriter2)).existsSync(), isFalse);
    expect(filesUnder(p.join(loc, kWriter3)), <String>['notes.txt']);

    // 幂等：再来一趟什么都不搬、不删、不报错。
    final SrsMediaSyncReport again = await srsRunLocationMedia(
      SrsLocationBackend(assets),
      s,
      mediaRoot,
      locationId: 'interconnect:host',
    );
    expect(again.legacyMediaImported, 0);
    expect(again.legacyMediaDropped, 0);
    expect(again.legacyWriterErrors, isEmpty);
    expect(
      File(p.join(mediaRoot.path, 'cat.png')).readAsStringSync(),
      'cat-v30',
    );
  });

  // HBK-AUDIT-202：v3.0.x 写入者多在不分大小写的文件系统上，笔记引用 cat.png、写入者目录里那份叫 CAT.png。
  // 修前按精确文件名判存活，唯一的副本被当成没人引用直接删掉；媒体同步清理本来就按大小写折叠算存活。
  test('媒体对账：只差大小写的副本按引用名搬进本机，多份只留一份；归属认不出的留着；没人引用的照删', () async {
    final SrsDbStore s = await device('dev-f');
    await addPicture(s, '猫', 'cat.png');
    await addPicture(s, '犬', 'dog.png');
    await addPicture(s, '狗', 'Dog.png');
    final String dir = await srsLocationDir(s);
    final String loc = locationPath(dir);
    final Directory mediaRoot = Directory(p.join(tmp.path, 'local-media'))
      ..createSync(recursive: true);
    expect(
      (await srsRunLocationRound(
        SrsLocationBackend(assets),
        s,
        'interconnect:host',
      )).error,
      isNull,
    );
    // 同一张图在两个写入者目录里各一份，大小写都和引用名不同。
    plantWriter(loc, kWriter2);
    write(p.join(loc, kWriter2, 'media', 'CAT.png'), 'cat-v30');
    plantWriter(loc, kWriter3);
    write(p.join(loc, kWriter3, 'media', 'Cat.PNG'), 'cat-v30');
    // dog.png 与 Dog.png 都有人引用：DOG.png 归谁认不出。bird.png 大小写不论都没人引用。
    plantWriter(loc, kWriter1);
    write(p.join(loc, kWriter1, 'media', 'DOG.png'), 'dog-v30');
    write(p.join(loc, kWriter1, 'media', 'BIRD.png'), 'bird');

    final SrsMediaSyncReport m = await srsRunLocationMedia(
      SrsLocationBackend(assets),
      s,
      mediaRoot,
      locationId: 'interconnect:host',
    );
    expect(m.completed, isTrue);
    expect(m.legacyWriterErrors, isEmpty);
    expect(m.legacyMediaImported, 1, reason: '两份副本只搬一份，按引用名 cat.png 落地');
    expect(m.legacyMediaDropped, 2, reason: '另一份副本与 BIRD.png');
    expect(
      mediaRoot.listSync().map((FileSystemEntity e) => p.basename(e.path)),
      <String>['cat.png'],
    );
    expect(
      File(p.join(mediaRoot.path, 'cat.png')).readAsStringSync(),
      'cat-v30',
    );
    expect(
      remoteHas(loc, srsMediaSha256('cat-v30'.codeUnits)),
      isTrue,
      reason: '按引用名记账，同一趟按内容传上位置',
    );
    expect(
      m.legacyWritersRemoved,
      unorderedEquals(<String>[kWriter2, kWriter3]),
    );
    expect(filesUnder(p.join(loc, kWriter1)), <String>[
      'media/DOG.png',
    ], reason: '归属认不出的不搬也不删');
  });

  test('媒体对账：名字已绑到别的内容时搬来的旧副本不抢绑定，换回绑定的内容', () async {
    final SrsDbStore s = await device('dev-d');
    await addPicture(s, '猫', 'cat.png');
    final String dir = await srsLocationDir(s);
    final String loc = locationPath(dir);
    final Directory mediaRoot = Directory(p.join(tmp.path, 'local-media'))
      ..createSync(recursive: true);
    write(p.join(mediaRoot.path, 'cat.png'), 'cat-bound');
    expect(
      (await srsRunLocationRound(
        SrsLocationBackend(assets),
        s,
        'interconnect:host',
      )).error,
      isNull,
    );
    // 绑定 cat.png → 'cat-bound' 并传上位置；之后本机那份没了（本机媒体目录被清过）。
    await srsRunLocationMedia(
      SrsLocationBackend(assets),
      s,
      mediaRoot,
      locationId: 'interconnect:host',
    );
    expect(remoteHas(loc, srsMediaSha256('cat-bound'.codeUnits)), isTrue);
    File(p.join(mediaRoot.path, 'cat.png')).deleteSync();
    plantWriter(loc, kWriter1);
    write(p.join(loc, kWriter1, 'media', 'cat.png'), 'cat-v30');

    final SrsMediaSyncReport m = await srsRunLocationMedia(
      SrsLocationBackend(assets),
      s,
      mediaRoot,
      locationId: 'interconnect:host',
    );
    expect(m.legacyWriterErrors, isEmpty);
    expect(m.legacyMediaImported, 1);
    expect(m.legacyWritersRemoved, <String>[kWriter1]);
    expect(
      File(p.join(mediaRoot.path, 'cat.png')).readAsStringSync(),
      'cat-bound',
      reason: '绑定没被旧副本抢走，媒体同步换回绑定的内容',
    );
    // 旧副本被换掉之前，媒体同步按既有的保全规则先把它按内容传上位置（「那份内容此刻可能只有这台设备有」）：
    // 字节不丢，但没有名字指向它。
    expect(remoteHas(loc, srsMediaSha256('cat-v30'.codeUnits)), isTrue);
    expect(Directory(p.join(loc, kWriter1)).existsSync(), isFalse);
  });

  test('媒体对账：到点收手时没收完的写入者媒体记成 deferred（不记已对账），文件一个不动', () async {
    final SrsDbStore s = await device('dev-e');
    await addPicture(s, '猫', 'cat.png');
    await addPicture(s, '犬', 'dog.png');
    final String dir = await srsLocationDir(s);
    final String loc = locationPath(dir);
    final Directory mediaRoot = Directory(p.join(tmp.path, 'local-media'))
      ..createSync(recursive: true);
    expect(
      (await srsRunLocationRound(
        SrsLocationBackend(assets),
        s,
        'interconnect:host',
      )).error,
      isNull,
    );
    plantWriter(loc, kWriter1);
    write(p.join(loc, kWriter1, 'media', 'cat.png'), 'cat-v30');
    write(p.join(loc, kWriter1, 'media', 'dog.png'), 'dog-v30');
    final List<String> before = filesUnder(p.join(loc, kWriter1));

    final SrsMediaSyncReport m = await srsRunLocationMedia(
      SrsLocationBackend(assets),
      s,
      mediaRoot,
      locationId: 'interconnect:host',
      deferRemaining: () => true,
    );
    expect(m.legacyMediaImported, 0);
    expect(m.legacyMediaDropped, 0);
    expect(m.deferred, greaterThanOrEqualTo(2), reason: '没收完的两个文件算没做');
    expect(filesUnder(p.join(loc, kWriter1)), before);
    expect(File(p.join(mediaRoot.path, 'cat.png')).existsSync(), isFalse);
  });
}
