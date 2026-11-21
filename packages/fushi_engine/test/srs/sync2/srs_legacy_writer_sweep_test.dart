// BUG-5017：v3.0.x 旧事件同步在位置目录 `fushi-srs/<dir>/` 下留的写入者目录 `<设备>#<化身号>/`（`batch-*` /
// `snapshot-*` / `cursor` / `probe` / `profile.json` / `media/`）迁移完也永远留着（用户 host 上一个就几百 MB）。
//
// 真内核 + 真 LocalDirectoryAssetStore（互联 host 的同步数据目录就是它），走生产入口 [srsRunLocationRound]：
// - 内核 `location_root` 认过根（新根 `v4/` 在用）：只有死文件 + 空 `media/` 的写入者目录整个删；`media/` 里还有
//   v3.3.0 没搬完的媒体、或有认不出的文件 → 只删死文件，目录与那些文件留着；别的目录、`v4/` 一个不碰；再跑一轮幂等。
// - 内核拒绝的位置（只有协议 1 旧根 `v2/`）：一个字节不动。
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
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
      trustedClock: SrsTrustedClock(
        wallClockMs: () => t,
        bootClockMs: () => t,
        bootId: 'boot-$id',
      ),
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
}
