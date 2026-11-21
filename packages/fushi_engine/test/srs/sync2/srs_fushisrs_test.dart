// 手动导出 / 导入 `.fushisrs`（sync2/srs_fushisrs.dart；协议 4 第 2 版，G11-3）：导出到文件、在另一台设备导入后
// 笔记 / 复习 / 媒体都到齐；导入是并入（不覆盖本机）、幂等；另一个复习库的包要确认才合并；导入前自动打还原点；
// 清单 v 2 / gen 4、不带 magic（已发布版本在碰库之前拒收）；更新版本的包拒收；v2 同步之前的事件备份经冻结的协议 3
// 代码读入（G11-4，D34），另一个 profile 的 / 坏包拒收。
// 内核侧（导出再导入逐表相同、需确认 / 并入、第 1 版对拍、大文件、别名类）在 Rust 的 cmd/fushisrs_tests.rs。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_fushisrs.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/srs_fake_engine.dart';
import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000f1';
const String kOtherProfile = '01928c3e-0000-7000-8000-0000000000f2';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  int t = DateTime.utc(2026, 10, 25, 9).millisecondsSinceEpoch;

  setUp(() {
    t = DateTime.utc(2026, 10, 25, 9).millisecondsSinceEpoch;
    tmp = Directory.systemTemp.createTempSync('srs_fushisrs_');
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄滞后（Windows）：留给系统清理。
    }
  });

  Future<SrsDbStore> device(String id, {String profile = kProfile}) async {
    final SrsStorage st = await openTestSrsStorage();
    return SrsDbStore.open(
      core: st.core,
      profileUid: profile,
      deviceId: id,
      engine: const SrsFakeEngine(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => t,
        bootClockMs: () => t,
        bootId: 'boot-$id',
      ),
    );
  }

  Directory dir(String name) =>
      Directory(p.join(tmp.path, name))..createSync(recursive: true);

  String expr(SrsDbStore s) => srsLapisFieldId(s.profileUid, 'Expression');

  Future<String> addNote(SrsDbStore s, String text, {String picture = ''}) {
    t += 1000;
    return s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        expr(s): text,
        srsLapisFieldId(s.profileUid, 'Picture'): picture,
      },
    );
  }

  Future<int> noteCount(SrsDbStore s) async =>
      (await s.entityIds(SrsEntityKind.note)).length;

  test('导出 → 另一台设备导入：笔记、复习、媒体到齐；再导入一次什么也不变', () async {
    final SrsDbStore a = await device('a');
    final Directory mediaA = dir('media_a');
    File(p.join(mediaA.path, 'cat.png')).writeAsBytesSync(<int>[1, 2, 3]);
    final String n = await addNote(a, '猫', picture: '<img src="cat.png">');
    final String card = (await a.cardsOfNote(n)).single.id;
    t += 60 * 1000;
    await a.answer(card, 3);
    final File pkg = File(p.join(tmp.path, 'out', 'a.$kSrsFushiSrsExtension'));
    final SrsFushiSrsExport exp = await srsExportFushiSrs(
      a,
      pkg,
      mediaRoot: mediaA,
    );
    expect(pkg.existsSync(), isTrue);
    expect(exp.bytes, pkg.lengthSync());
    expect(exp.mediaFiles, 1);

    final SrsDbStore b = await device('b');
    final Directory mediaB = dir('media_b');
    final String own = await addNote(b, '犬');
    // 同一个复习库的包，但 b 还不认识 a 的设备公钥：先问（reason: identity），确认后才导入。
    SrsFushiSrsForeign? asked;
    final SrsFushiSrsImport imp = await srsImportFushiSrs(
      b,
      pkg,
      mediaRoot: mediaB,
      confirmForeign: (SrsFushiSrsForeign f) async {
        asked = f;
        return true;
      },
    );
    expect(asked?.reason, SrsFushiSrsConfirmReason.identity);
    expect(asked?.newPeers, isNotEmpty);
    expect(imp.applied, greaterThan(0));
    expect(imp.mediaFiles, 1);
    expect((await b.note(n))!.field(expr(b)), '猫');
    expect((await b.note(own))!.field(expr(b)), '犬', reason: '并入，不覆盖本机');
    expect((await b.history(card)).effective, hasLength(1));
    expect(
      srsCanonicalJson((await b.history(card)).state.toJson()),
      srsCanonicalJson((await a.history(card)).state.toJson()),
    );
    expect(File(p.join(mediaB.path, 'cat.png')).readAsBytesSync(), <int>[
      1,
      2,
      3,
    ]);
    expect(
      <String>[
        for (final Map<String, Object?> c in await b.sync2Checkpoints())
          '${c['reason']}',
      ],
      contains('import'),
      reason: '导入前自动打还原点',
    );

    // 幂等：同一个包再导一次，不并入任何操作、不补媒体、笔记数不变。
    final int notes = await noteCount(b);
    final SrsFushiSrsImport again = await srsImportFushiSrs(
      b,
      pkg,
      mediaRoot: mediaB,
    );
    expect(again.applied, 0);
    expect(again.mediaFiles, 0);
    expect(await noteCount(b), notes);
  });

  test('第 2 版清单：v 2 / gen 4、不带 magic、带内核给的集合与设备；ops.bin 不压缩存放', () async {
    final SrsDbStore a = await device('a');
    await addNote(a, '猫');
    final File pkg = File(p.join(tmp.path, 'm.$kSrsFushiSrsExtension'));
    await srsExportFushiSrs(a, pkg);
    final Archive zip = ZipDecoder().decodeBytes(pkg.readAsBytesSync());
    final Map<String, Object?> m =
        (jsonDecode(
                  utf8.decode(
                    zip.findFile('manifest.json')!.content as List<int>,
                  ),
                )
                as Map)
            .cast<String, Object?>();
    expect(m['v'], kSrsFushiSrsVersion);
    expect(m['v'], greaterThan(1), reason: '已发布版本的读者对 v > 1 一律拒收（碰库之前）');
    expect(m['gen'], 4);
    expect(m.containsKey('magic'), isFalse);
    expect(m['profile'], kProfile);
    expect(m['collection'], isA<String>());
    expect(m['dir'], kProfile);
    expect(m['salts'], contains(kProfile));
    expect(m['peers'], isA<List<Object?>>());
    final ArchiveFile ops = zip.findFile('ops.bin')!;
    expect(ops.compress, isFalse, reason: '流本身已是 zstd；不压缩才能流式交给内核');
    // FSRS4EXP 流是 zstd 帧（魔数 28 B5 2F FD）。
    expect((ops.content as List<int>).take(4), <int>[0x28, 0xb5, 0x2f, 0xfd]);
  });

  test('不带媒体导出：包里没有媒体，导入只并操作', () async {
    final SrsDbStore a = await device('a');
    final Directory mediaA = dir('media_a');
    File(p.join(mediaA.path, 'cat.png')).writeAsBytesSync(<int>[1]);
    final String n = await addNote(a, '猫', picture: '<img src="cat.png">');
    final File pkg = File(p.join(tmp.path, 'a.$kSrsFushiSrsExtension'));
    expect(
      (await srsExportFushiSrs(
        a,
        pkg,
        mediaRoot: mediaA,
        withMedia: false,
      )).mediaFiles,
      0,
    );
    final SrsDbStore b = await device('b');
    final Directory mediaB = dir('media_b');
    final SrsFushiSrsImport imp = await srsImportFushiSrs(
      b,
      pkg,
      mediaRoot: mediaB,
      confirmForeign: (_) async => true,
    );
    expect(imp.mediaFiles, 0);
    expect(await b.note(n), isNotNull);
    expect(File(p.join(mediaB.path, 'cat.png')).existsSync(), isFalse);
  });

  test(
    '另一个复习库的包：不确认就不导入、本机什么也不变（不写媒体、不打还原点）；确认后两库合并；不是 .fushisrs 的文件拒收',
    () async {
      final SrsDbStore other = await device('x', profile: kOtherProfile);
      final Directory mediaX = dir('media_x');
      File(p.join(mediaX.path, 'snow.png')).writeAsBytesSync(<int>[4, 5, 6]);
      final String snow = await addNote(
        other,
        '雪',
        picture: '<img src="snow.png">',
      );
      final File pkg = File(p.join(tmp.path, 'x.$kSrsFushiSrsExtension'));
      await srsExportFushiSrs(other, pkg, mediaRoot: mediaX);

      final SrsDbStore b = await device('b');
      final Directory mediaB = dir('media_b');
      final int notes = await noteCount(b);
      final Object? ops = (await b.sync2Status())['ops'];
      final int checkpoints = (await b.sync2Checkpoints()).length;
      final SrsFushiSrsImport no = await srsImportFushiSrs(
        b,
        pkg,
        mediaRoot: mediaB,
      );
      expect(no.declined, isTrue, reason: '没给确认回调 = 不合并');
      expect(no.applied, 0);
      expect(no.mediaFiles, 0);
      SrsFushiSrsForeign? asked;
      final SrsFushiSrsImport refused = await srsImportFushiSrs(
        b,
        pkg,
        mediaRoot: mediaB,
        confirmForeign: (SrsFushiSrsForeign f) async {
          asked = f;
          return false;
        },
      );
      expect(refused.declined, isTrue);
      expect(refused.mediaFiles, 0);
      expect(asked?.dir, kOtherProfile);
      expect(asked?.reason, SrsFushiSrsConfirmReason.join);
      expect(await noteCount(b), notes);
      expect((await b.sync2Status())['ops'], ops, reason: '确认之前内核什么都不写');
      expect(mediaB.listSync(), isEmpty, reason: '用户拒绝合并：媒体目录不能被写（复核：孤儿媒体）');
      expect(
        (await b.sync2Checkpoints()).length,
        checkpoints,
        reason: '用户拒绝合并：不打还原点',
      );

      final SrsFushiSrsImport merged = await srsImportFushiSrs(
        b,
        pkg,
        mediaRoot: mediaB,
        confirmForeign: (_) async => true,
      );
      expect(merged.declined, isFalse);
      expect(merged.applied, greaterThan(0));
      expect(merged.mediaFiles, 1);
      expect(File(p.join(mediaB.path, 'snow.png')).existsSync(), isTrue);
      expect(await b.note(snow), isNotNull);

      final File junk = File(p.join(tmp.path, 'junk.$kSrsFushiSrsExtension'))
        ..writeAsBytesSync(<int>[
          0x50,
          0x4b,
          0x05,
          0x06,
          ...List<int>.filled(18, 0),
        ]);
      await expectLater(srsImportFushiSrs(b, junk), throwsFormatException);
    },
  );

  test('来自更新版本的包（v 3 / 未知 gen）拒收，本机不变', () async {
    final SrsDbStore a = await device('a');
    await addNote(a, '猫');
    final File pkg = File(p.join(tmp.path, 'a.$kSrsFushiSrsExtension'));
    await srsExportFushiSrs(a, pkg);
    final Archive src = ZipDecoder().decodeBytes(pkg.readAsBytesSync());
    final Map<String, Object?> m =
        (jsonDecode(
                  utf8.decode(
                    src.findFile('manifest.json')!.content as List<int>,
                  ),
                )
                as Map)
            .cast<String, Object?>();
    final List<int> ops = src.findFile('ops.bin')!.content as List<int>;
    final SrsDbStore b = await device('b');
    final int notes = await noteCount(b);
    for (final Map<String, Object?> bad in <Map<String, Object?>>[
      <String, Object?>{...m, 'v': 3},
      <String, Object?>{...m, 'gen': 5},
    ]) {
      final Archive zip = Archive()
        ..addFile(ArchiveFile.string('manifest.json', jsonEncode(bad)))
        ..addFile(ArchiveFile('ops.bin', ops.length, ops));
      final File f = File(p.join(tmp.path, 'newer.$kSrsFushiSrsExtension'))
        ..writeAsBytesSync(ZipEncoder().encode(zip)!);
      await expectLater(srsImportFushiSrs(b, f), throwsFormatException);
    }
    expect(await noteCount(b), notes);
  });

  // ---------------------------------------------------------------- 旧格式（v2 之前的事件备份，同扩展名）

  /// 按旧备份层（develop f71b5aaa98 `srs_backup_store.dart`）的格式拼一份 `.fushisrs`：清单 + events.jsonl。
  Future<File> legacyBackup(SrsDbStore src, File out) async {
    final List<SrsEvent> events = await src.exportAll();
    final List<int> bodyBytes = utf8.encode(
      <String>[
        for (final SrsEvent e in events) srsCanonicalJson(e.toJson()),
      ].join('\n'),
    );
    final Archive zip = Archive()
      ..addFile(
        ArchiveFile.string(
          'manifest.json',
          jsonEncode(<String, Object?>{
            'magic': kSrsLegacyBackupMagic,
            'formatVersion': 1,
            'minReaderVersion': 1,
            'createdAt': t,
            'kind': 'manual',
            'profileUid': src.profileUid,
            'events': <String, Object?>{
              'count': events.length,
              'sha256': sha256.convert(bodyBytes).toString(),
            },
            'media': const <Object?>[],
            'mediaEmbedded': false,
          }),
        ),
      )
      ..addFile(ArchiveFile('events.jsonl', bodyBytes.length, bodyBytes));
    await out.parent.create(recursive: true);
    await out.writeAsBytes(ZipEncoder().encode(zip)!, flush: true);
    return out;
  }

  test('v2 同步之前的事件备份（D34）：经冻结的协议 3 代码读进新代库，笔记 / 复习条数对拍；再导一次不重复', () async {
    final SrsDbStore a = await device('a');
    final String n1 = await addNote(a, '猫');
    await addNote(a, '犬');
    final String card = (await a.cardsOfNote(n1)).single.id;
    t += 60 * 1000;
    await a.answer(card, 3);
    final int aLogs =
        ((await a.logsOfCards(<String>[card]))[card] ?? const <SrsReviewLog>[])
            .length;
    final File pkg = await legacyBackup(
      a,
      File(p.join(tmp.path, 'old.$kSrsFushiSrsExtension')),
    );
    final SrsDbStore b = await device('b');
    final int checkpoints = (await b.sync2Checkpoints()).length;
    // 用户不确认：什么都不写、不打还原点。
    final SrsFushiSrsImport no = await srsImportFushiSrs(
      b,
      pkg,
      confirmForeign: (_) async => false,
    );
    if (no.declined) {
      expect(await noteCount(b), 0);
      expect((await b.sync2Checkpoints()).length, checkpoints);
    }
    final SrsFushiSrsImport imp = await srsImportFushiSrs(
      b,
      pkg,
      confirmForeign: (_) async => true,
    );
    expect(imp.declined, isFalse);
    expect(await noteCount(b), await noteCount(a));
    expect(
      ((await b.logsOfCards(<String>[card]))[card] ?? const <SrsReviewLog>[])
          .length,
      aLogs,
    );
    final SrsFushiSrsImport again = await srsImportFushiSrs(
      b,
      pkg,
      confirmForeign: (_) async => true,
    );
    expect(again.applied, 0);
    expect(await noteCount(b), await noteCount(a));
    expect(
      ((await b.logsOfCards(<String>[card]))[card] ?? const <SrsReviewLog>[])
          .length,
      aLogs,
    );
  });

  test('v2 同步之前的事件备份：另一个 profile 的、摘要对不上的明确拒收，本机不变、不打还原点', () async {
    final SrsDbStore other = await device('o', profile: kOtherProfile);
    await addNote(other, '猫');
    final File foreign = await legacyBackup(
      other,
      File(p.join(tmp.path, 'foreign.$kSrsFushiSrsExtension')),
    );
    final SrsDbStore b = await device('b');
    final int notes = await noteCount(b);
    final int checkpoints = (await b.sync2Checkpoints()).length;
    await expectLater(
      srsImportFushiSrs(b, foreign, confirmForeign: (_) async => true),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains('another profile'),
        ),
      ),
    );
    // 摘要对不上（正文被改）：坏包。
    final Archive zip = ZipDecoder().decodeBytes(
      (await legacyBackup(
        b,
        File(p.join(tmp.path, 'mine.$kSrsFushiSrsExtension')),
      )).readAsBytesSync(),
    );
    final Archive bad = Archive();
    for (final ArchiveFile f in zip.files) {
      if (f.name == 'events.jsonl') {
        final List<int> body = <int>[...(f.content as List<int>), 10, 10];
        bad.addFile(ArchiveFile('events.jsonl', body.length, body));
      } else {
        bad.addFile(f);
      }
    }
    final File tampered = File(p.join(tmp.path, 'bad.$kSrsFushiSrsExtension'))
      ..writeAsBytesSync(ZipEncoder().encode(bad)!);
    await expectLater(
      srsImportFushiSrs(b, tampered, confirmForeign: (_) async => true),
      throwsFormatException,
    );
    expect(await noteCount(b), notes);
    expect((await b.sync2Checkpoints()).length, checkpoints);
  });
  // 读 / 写包的重活（读整个文件、解压、摘要、解析事件、组 zip）不许回到调用方 isolate：调用方是 UI isolate，
  // 大库导入 / 导出会卡帧。公开入口里只留碰数据库的几步，其余经 `_run*FushiSrs` → `Isolate.run`。
  test('读包 / 写包的解压、解析、压缩都在后台 isolate，公开入口只碰数据库', () {
    final String src = File(
      'lib/srs/sync2/srs_fushisrs.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    String topLevelBody(String signature) {
      final int start = src.indexOf(signature);
      expect(start, greaterThanOrEqualTo(0), reason: signature);
      final int end = src.indexOf('\n}\n', start);
      return src.substring(start, end);
    }

    const List<String> heavy = <String>[
      'ZipDecoder',
      'ZipEncoder',
      'ZipFileEncoder',
      'InputFileStream',
      'OutputFileStream',
      'readAsBytes',
      'jsonDecode',
      'LineSplitter',
      'sha256',
      'writeAsBytes',
    ];
    final String import = topLevelBody(
      'Future<SrsFushiSrsImport> srsImportFushiSrs(',
    );
    final String export = topLevelBody(
      'Future<SrsFushiSrsExport> srsExportFushiSrs(',
    );
    for (final String token in heavy) {
      expect(import, isNot(contains(token)), reason: 'import: $token');
      expect(export, isNot(contains(token)), reason: 'export: $token');
    }
    expect(import, contains('_runReadFushiSrs('));
    expect(import, contains('_runCopyFushiSrsMedia('));
    expect(export, contains('_runWriteFushiSrs('));
    expect(
      topLevelBody('Future<_FushiSrsRead> _runReadFushiSrs('),
      contains('Isolate.run('),
    );
    expect(
      topLevelBody('Future<List<String>> _runCopyFushiSrsMedia('),
      contains('Isolate.run('),
    );

    // 复核（孤儿媒体）：用户拒绝合并时本机一点不能动。读包那一步不碰媒体目录；内核预检在还原点与补媒体之前。
    final int pre = import.indexOf('preflight: true');
    expect(pre, greaterThan(0), reason: '导入先发内核预检');
    expect(import.indexOf('sync2Checkpoint('), greaterThan(pre));
    expect(import.indexOf('_runCopyFushiSrsMedia('), greaterThan(pre));
    expect(
      topLevelBody('Future<_FushiSrsRead> _readFushiSrs('),
      isNot(contains('media')),
    );
    // 旧事件备份同样：读包只写 JSONL，不碰媒体目录。
    expect(
      topLevelBody('_LegacyEventsRead _readLegacy('),
      isNot(contains('mediaRoot')),
    );
    expect(
      topLevelBody('Future<SrsFushiSrsExport> _runWriteFushiSrs('),
      contains('Isolate.run('),
    );
  });
}
