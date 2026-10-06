import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart';
import 'package:fushi_server/src/cli.dart';
import 'package:fushi_server/src/commands/dict_commands.dart';
import 'package:fushi_server/src/dictionary_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `dict ls / add / rm`：参数解析与退出码、`--json` 形状、导入落盘形状（假导入器），
/// 有 libfushidicts_ffi 时再用真导入器端到端跑一遍。
void main() {
  late Directory tmp;
  late File config;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_dict_cli_');
    config = File(p.join(tmp.path, 'fushi_server.yaml'));
    expect(
      await _quiet(
        () => runFushiServerCli(<String>['-c', config.path, 'init', '--data-dir', p.join(tmp.path, 'data')]),
      ),
      0,
    );
  });

  tearDown(() => tmp.delete(recursive: true));

  group('用法与退出码', () {
    test('缺动词 / 未知动词 / 参数个数不对 → 64', () async {
      expect(await _quiet(() => runFushiServerCli(<String>['-c', config.path, 'dict'])), 64);
      expect(await _quiet(() => runFushiServerCli(<String>['-c', config.path, 'dict', 'bogus'])), 64);
      expect(await _quiet(() => runFushiServerCli(<String>['-c', config.path, 'dict', 'add'])), 64);
      expect(await _quiet(() => runFushiServerCli(<String>['-c', config.path, 'dict', 'ls', 'extra'])), 64);
    });

    test('词典包不存在 → 66；配置不存在 → 66', () async {
      expect(
        await _quiet(() => runFushiServerCli(<String>['-c', config.path, 'dict', 'add', p.join(tmp.path, 'no.zip')])),
        66,
      );
      expect(await _quiet(() => runFushiServerCli(<String>['-c', p.join(tmp.path, 'nope.yaml'), 'dict', 'ls'])), 66);
    });

    test('dict ls --json：空库输出 []；dict rm 不存在的词典 → 1', () async {
      final _Captured out = await _capture(
        () => runFushiServerCli(<String>['-c', config.path, 'dict', 'ls', '--json']),
      );
      expect(out.code, 0);
      expect(jsonDecode(out.stdout.trim()), <Object>[]);
      expect(await _quiet(() => runFushiServerCli(<String>['-c', config.path, 'dict', 'rm', 'Nope'])), 1);
    });
  });

  group('importDictionaryArchive（假导入器）', () {
    late FushiDatabase db;
    late Directory resources;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      resources = Directory(p.join(tmp.path, 'res'));
    });
    tearDown(() => db.close());

    Future<FushiImportResult> fakeImporter(String archive, String outDir, {String title = 'Fake Dict'}) async {
      final Directory d = Directory(p.join(outDir, title))..createSync(recursive: true);
      File(p.join(d.path, 'index.json')).writeAsStringSync('{"title":"$title"}');
      File(p.join(d.path, 'blobs.bin')).writeAsStringSync('x');
      return FushiImportResult(
        success: true,
        title: title,
        termCount: 3,
        metaCount: 0,
        freqCount: 0,
        pitchCount: 0,
        mediaCount: 0,
        kanjiCount: 1,
        detectedType: 'term',
        error: '',
      );
    }

    test('新词典排最后、落资源目录、metadata 记 hasKanji', () async {
      await db.upsertDictionaryMeta(DictionaryMetadataCompanion.insert(name: 'Old', formatKey: 'yomichan', order: 4));
      final DictImportOutcome r = await importDictionaryArchive(
        db: db,
        resourceRoot: resources,
        archive: File('unused.zip'),
        importer: fakeImporter,
      );
      expect(r.name, 'Fake Dict');
      expect(r.replaced, isFalse);
      expect(File(p.join(resources.path, 'Fake Dict', 'blobs.bin')).existsSync(), isTrue);
      final DictionaryMetaRow row = (await db.getAllDictionaryMetadata()).firstWhere(
        (DictionaryMetaRow x) => x.name == 'Fake Dict',
      );
      expect(row.order, 5);
      expect(row.type, 'term');
      expect(jsonDecode(row.metadataJson), containsPair('hasKanji', 'true'));
    });

    test('同名重导 = 更新：保留排序与隐藏设置', () async {
      await importDictionaryArchive(db: db, resourceRoot: resources, archive: File('a.zip'), importer: fakeImporter);
      final DictionaryMetaRow first = (await db.getAllDictionaryMetadata()).single;
      await db.upsertDictionaryMeta(
        first
            .toCompanion(true)
            .copyWith(order: const Value<int>(7), hiddenLanguagesJson: const Value<String>('["ja"]')),
      );
      final DictImportOutcome again = await importDictionaryArchive(
        db: db,
        resourceRoot: resources,
        archive: File('a.zip'),
        importer: fakeImporter,
      );
      expect(again.replaced, isTrue);
      final DictionaryMetaRow row = (await db.getAllDictionaryMetadata()).single;
      expect(row.order, 7);
      expect(row.hiddenLanguagesJson, '["ja"]');
    });

    test('导入器报错 → DictImportException；标题为空 → DictImportException', () async {
      Future<FushiImportResult> failing(String a, String o) async => const FushiImportResult(
        success: false,
        title: '',
        termCount: 0,
        metaCount: 0,
        freqCount: 0,
        pitchCount: 0,
        mediaCount: 0,
        kanjiCount: 0,
        detectedType: '',
        error: 'bad zip',
      );
      await expectLater(
        importDictionaryArchive(db: db, resourceRoot: resources, archive: File('a.zip'), importer: failing),
        throwsA(isA<DictImportException>().having((DictImportException e) => e.message, 'message', 'bad zip')),
      );
      expect(() => sanitizeDictionaryTitle('  '), throwsA(isA<DictImportException>()));
      expect(sanitizeDictionaryTitle('a/b'), 'b');
    });
  });

  final String? libPath = resolveFushiDictsLibraryPath();
  final bool haveLib = libPath != null && File(libPath).existsSync();
  test('端到端：dict add 真导入 → dict ls 列出 → dict rm 删除', () async {
    final File zip = File(p.join(tmp.path, 'cli.zip'));
    final Archive archive = Archive();
    void add(String name, Object json) {
      final List<int> bytes = utf8.encode(jsonEncode(json));
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    add('index.json', <String, Object>{'title': 'CliDict', 'revision': '1', 'format': 3});
    add('term_bank_1.json', <Object>[
      <Object>[
        '食べる',
        'たべる',
        'v1',
        'v1',
        100,
        <String>['to eat'],
        1,
        '',
      ],
    ]);
    zip.writeAsBytesSync(ZipEncoder().encode(archive)!);

    final _Captured added = await _capture(
      () => runFushiServerCli(<String>['-c', config.path, 'dict', 'add', zip.path, '--json']),
    );
    expect(added.code, 0, reason: added.stderr);
    final Map<String, dynamic> outcome = Map<String, dynamic>.from(jsonDecode(added.stdout.trim()) as Map);
    expect(outcome['name'], 'CliDict');
    expect(outcome['termCount'], 1);

    final _Captured listed = await _capture(
      () => runFushiServerCli(<String>['-c', config.path, 'dict', 'ls', '--json']),
    );
    final List<dynamic> rows = jsonDecode(listed.stdout.trim()) as List<dynamic>;
    expect(rows.single, containsPair('name', 'CliDict'));
    expect(rows.single, containsPair('present', true));

    expect(await _quiet(() => runFushiServerCli(<String>['-c', config.path, 'dict', 'rm', 'CliDict'])), 0);
    final _Captured after = await _capture(
      () => runFushiServerCli(<String>['-c', config.path, 'dict', 'ls', '--json']),
    );
    expect(jsonDecode(after.stdout.trim()), <Object>[]);
    FushiDicts.nativeLibraryPath = null;
  }, skip: haveLib ? false : '没有 libfushidicts_ffi（设 $kFushiDictsLibEnv）');
}

class _Captured {
  _Captured(this.code, this.stdout, this.stderr);
  final int code;
  final String stdout;
  final String stderr;
}

Future<int> _quiet(Future<int> Function() body) async => (await _capture(body)).code;

/// 把 stdout / stderr 截进内存（CLI 命令直接写 `stdout`）。
Future<_Captured> _capture(Future<int> Function() body) async {
  final _Sink out = _Sink();
  final _Sink err = _Sink();
  final int code = await IOOverrides.runZoned(body, stdout: () => out, stderr: () => err);
  return _Captured(code, out.buffer.toString(), err.buffer.toString());
}

class _Sink implements Stdout {
  final StringBuffer buffer = StringBuffer();

  @override
  void write(Object? object) => buffer.write(object);

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) => buffer.writeAll(objects, separator);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
