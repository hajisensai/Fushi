/// `import epub|manga|text|auto` 与 `books backfill-isbn` 的端到端契约：临时数据目录 +
/// 真 FushiDatabase，命令跑完重新打开库核对落库行。
library;

import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_server/src/commands/import_commands.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'command_harness.dart';

void main() {
  late CommandHarness h;
  late ImportCommands module;

  setUp(() async {
    h = await CommandHarness.create();
    module = ImportCommands(io: h.io);
  });

  tearDown(() => h.dispose());

  Future<List<EpubBookRow>> books() async {
    final FushiDatabase db = h.openDb();
    try {
      return await db.getAllEpubBooks();
    } finally {
      await db.close();
    }
  }

  group('import epub', () {
    test('导入一本 EPUB：books 表多一行，--json 报 imported 与 bookKey', () async {
      final String epub = p.join(h.tmp.path, 'in', 'a.epub');
      writeTestEpub(epub, '吾輩は猫である');

      expect(await h.run(module, <String>['import', 'epub', epub, '--json']), 0, reason: '${h.err}');
      final Map<String, Object?> json = h.json();
      expect(json['imported'], 1);
      expect(json['skipped'], 0);
      expect(json['failed'], 0);
      final List<Object?> items = json['items']! as List<Object?>;
      final Map<Object?, Object?> item = items.single! as Map<Object?, Object?>;
      expect(item['status'], 'imported');
      expect(item['domain'], 'book');
      expect(item['path'], epub);

      final List<EpubBookRow> rows = await books();
      expect(rows, hasLength(1));
      expect(rows.single.title, '吾輩は猫である');
      expect((item['bookKeys']! as List<Object?>).single, rows.single.bookKey);
      expect(rows.single.format, BookFormat.epub.dbValue);
      // 命令行导入 = 手动导入：不属于任何库根，不会被库根对账回收。
      expect(rows.single.sourceId, isNull);
    });

    test('同名再导一次按 DuplicatePolicy.skip() 跳过：不报错、不出副本', () async {
      final String epub = p.join(h.tmp.path, 'a.epub');
      writeTestEpub(epub, 'Same');
      expect(await h.run(module, <String>['import', 'epub', epub]), 0);
      expect(await h.run(module, <String>['import', 'epub', epub, '--json']), 0);
      expect(h.json()['skipped'], 1);
      expect(h.json()['imported'], 0);
      expect(await books(), hasLength(1));
    });

    test('目录输入递归收全部 .epub', () async {
      final String dir = p.join(h.tmp.path, 'lib');
      writeTestEpub(p.join(dir, 'a.epub'), 'A');
      writeTestEpub(p.join(dir, 'sub', 'b.epub'), 'B');
      expect(await h.run(module, <String>['import', 'epub', dir, '--json']), 0);
      expect(h.json()['imported'], 2);
      expect((await books()).map((EpubBookRow b) => b.title).toSet(), <String>{'A', 'B'});
    });

    test('坏 EPUB 记 failed、退出码 1，不影响同批其它书', () async {
      final String good = p.join(h.tmp.path, 'good.epub');
      final String bad = p.join(h.tmp.path, 'bad.epub');
      writeTestEpub(good, 'Good');
      File(bad).writeAsStringSync('not a zip');
      expect(await h.run(module, <String>['import', 'epub', bad, good, '--json']), 1);
      expect(h.json()['imported'], 1);
      expect(h.json()['failed'], 1);
      expect((await books()).single.title, 'Good');
    });

    test('找不到输入 → 66，什么都不导', () async {
      final String good = p.join(h.tmp.path, 'good.epub');
      writeTestEpub(good, 'Good');
      expect(await h.run(module, <String>['import', 'epub', good, p.join(h.tmp.path, 'nope.epub')]), 66);
      expect(h.err.toString(), contains('nope.epub'));
      expect(Directory(h.dataDir).existsSync(), isFalse, reason: '输入校验在打开数据目录之前');
    });

    test('用法错误 → 64：缺子命令 / 缺路径 / 不是 .epub', () async {
      expect(await h.run(module, <String>['import']), 64);
      expect(await h.run(module, <String>['import', 'epub']), 64);
      final File txt = File(p.join(h.tmp.path, 'a.txt'))..writeAsStringSync('x');
      expect(await h.run(module, <String>['import', 'epub', txt.path]), 64);
    });

    test('缺配置文件 → 66', () async {
      final CommandHarness bare = await CommandHarness.create(withConfig: false);
      try {
        final String epub = p.join(bare.tmp.path, 'a.epub');
        writeTestEpub(epub, 'A');
        expect(await bare.run(ImportCommands(io: bare.io), <String>['import', 'epub', epub]), 66);
      } finally {
        await bare.dispose();
      }
    });
  });

  group('import text', () {
    test('--title 生效，入库为 EPUB', () async {
      final File txt = File(p.join(h.tmp.path, 'novel.txt'))..writeAsStringSync('第一章\n本文。\n');
      expect(
        await h.run(module, <String>['import', 'text', txt.path, '--title', '自定义书名', '--json']),
        0,
        reason: '${h.err}',
      );
      expect(h.json()['imported'], 1);
      final EpubBookRow row = (await books()).single;
      expect(row.title, '自定义书名');
    });

    test('缺省标题取文件名；--title 配多个输入 → 64；不支持的扩展名 → 64', () async {
      final File a = File(p.join(h.tmp.path, 'a.md'))..writeAsStringSync('# A');
      final File b = File(p.join(h.tmp.path, 'b.md'))..writeAsStringSync('# B');
      expect(await h.run(module, <String>['import', 'text', a.path, b.path, '--title', 'x']), 64);
      final File bin = File(p.join(h.tmp.path, 'x.bin'))..writeAsBytesSync(<int>[0]);
      expect(await h.run(module, <String>['import', 'text', bin.path]), 64);
      expect(await h.run(module, <String>['import', 'text', a.path]), 0);
      expect((await books()).single.title, 'a');
    });
  });

  group('import manga', () {
    test('mokuro 卷目录 → 一行漫画', () async {
      final String vol = p.join(h.tmp.path, 'manga', 'Vol1');
      writeTestMokuro(vol, 'Vol1');
      expect(await h.run(module, <String>['import', 'manga', p.dirname(vol), '--json']), 0, reason: '${h.err}');
      expect(h.json()['imported'], 1);
      final EpubBookRow row = (await books()).single;
      expect(row.format, BookFormat.manga.dbValue);
      expect(row.title, 'Vol1');
    });

    test('单个 .mokuro 文件 + --title', () async {
      final String vol = p.join(h.tmp.path, 'Vol2');
      writeTestMokuro(vol, 'Vol2');
      expect(await h.run(module, <String>['import', 'manga', p.join(vol, 'Vol2.mokuro'), '--title', '第二卷']), 0);
      expect((await books()).single.title, '第二卷');
    });

    test('不是漫画卷的文件记 failed → 1', () async {
      final File txt = File(p.join(h.tmp.path, 'a.txt'))..writeAsStringSync('x');
      expect(await h.run(module, <String>['import', 'manga', txt.path, '--json']), 1);
      expect(h.json()['failed'], 1);
    });
  });

  group('import auto', () {
    test('混合输入按域分派：EPUB 进书、mokuro 目录进漫画', () async {
      final String epub = p.join(h.tmp.path, 'a.epub');
      writeTestEpub(epub, 'Auto Book');
      final String vol = p.join(h.tmp.path, 'm', 'AutoVol');
      writeTestMokuro(vol, 'AutoVol');
      expect(await h.run(module, <String>['import', 'auto', epub, vol, '--json']), 0, reason: '${h.err}');
      final List<Object?> items = h.json()['items']! as List<Object?>;
      expect(
        <Object?>[for (final Object? i in items) (i! as Map<Object?, Object?>)['domain']],
        <Object?>['book', 'manga'],
      );
      final Map<String, String> formats = <String, String>{
        for (final EpubBookRow b in await books()) b.title: b.format,
      };
      expect(formats, <String, String>{'Auto Book': 'epub', 'AutoVol': 'manga'});
    });

    test('认不出的文件记 failed（unknown）', () async {
      final File f = File(p.join(h.tmp.path, 'x.bin'))..writeAsBytesSync(<int>[0]);
      expect(await h.run(module, <String>['import', 'auto', f.path, '--json']), 1);
      final Map<Object?, Object?> item = (h.json()['items']! as List<Object?>).single! as Map<Object?, Object?>;
      expect(item['domain'], 'unknown');
      expect(item['error'], contains('.bin'));
    });

    test('PDF 在服务端如实挡下（unsupportedOnThisHost），不假装导入', () async {
      final File pdf = File(p.join(h.tmp.path, 'a.pdf'))..writeAsStringSync('%PDF-1.4');
      expect(await h.run(module, <String>['import', 'auto', pdf.path, '--json']), 1);
      final Map<Object?, Object?> item = (h.json()['items']! as List<Object?>).single! as Map<Object?, Object?>;
      expect(item['error'], startsWith('unsupportedOnThisHost'));
    });
  });

  group('routeAutoImport', () {
    test('单文件按扩展名', () {
      File touch(String name) => File(p.join(h.tmp.path, name))..writeAsStringSync('x');
      expect(routeAutoImport(touch('a.txt').path).kind, AutoImportKind.novel);
      expect(routeAutoImport(touch('a.cbz').path).kind, AutoImportKind.mangaArchive);
      expect(routeAutoImport(touch('v.mokuro').path).kind, AutoImportKind.mangaLocal);
      expect(routeAutoImport(touch('a.mp3').path).kind, AutoImportKind.audiobook);
      expect(routeAutoImport(touch('a.xyz').path).kind, AutoImportKind.unsupported);
      final String epub = p.join(h.tmp.path, 'b.epub');
      writeTestEpub(epub, 'B');
      expect(routeAutoImport(epub).kind, AutoImportKind.novel);
    });

    test('目录按内容：音频 → 有声书；mokuro → 漫画；EPUB + 封面图 → 书；纯页图 → 漫画', () {
      Directory dir(String name, Map<String, List<int>> files) {
        final Directory d = Directory(p.join(h.tmp.path, name))..createSync(recursive: true);
        files.forEach((String rel, List<int> bytes) {
          File(p.join(d.path, rel))
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync(bytes);
        });
        return d;
      }

      final AutoImportRoute audio = routeAutoImport(
        dir('ab', <String, List<int>>{
          'b.txt': <int>[1],
          'b.srt': <int>[1],
          '01.mp3': <int>[1],
        }).path,
      );
      expect(audio.kind, AutoImportKind.audiobook);
      expect(audio.files, hasLength(3));
      final String vol = p.join(h.tmp.path, 'mk');
      writeTestMokuro(vol, 'V');
      expect(routeAutoImport(vol).kind, AutoImportKind.mangaLocal);
      expect(
        routeAutoImport(
          dir('nv', <String, List<int>>{
            'a.txt': <int>[1],
            'cover.jpg': <int>[1],
          }).path,
        ).kind,
        AutoImportKind.novel,
      );
      expect(
        routeAutoImport(
          dir('pg', <String, List<int>>{
            '001.jpg': <int>[1],
            '002.jpg': <int>[1],
          }).path,
        ).kind,
        AutoImportKind.mangaLocal,
      );
      expect(routeAutoImport(dir('empty', <String, List<int>>{}).path).kind, AutoImportKind.unsupported);
    });
  });

  test('books backfill-isbn --json', () async {
    expect(await h.run(module, <String>['books', 'backfill-isbn', '--json']), 0);
    expect(h.json(), <String, Object?>{'written': 0});
    expect(await h.run(module, <String>['books']), 64);
  });
}
