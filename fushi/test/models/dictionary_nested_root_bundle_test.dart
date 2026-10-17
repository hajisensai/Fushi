// BUG-2995（HBK-AUDIT-043）：整合包里父目录与嵌套目录各有一份 index.json 时，
// 给子词典打包的 skipPaths 带上了祖先根，`path.isWithin(祖先, 子文件)` 恒真，
// 子词典被重打包成空 zip。这里走真实 importFromFile → 拆包 → packDirectoryToZip，
// 只把末端逐本的 native 导入换成产物检查。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/dictionary_import_manager.dart';
import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:path/path.dart' as p;

class _InspectBundleManager extends DictionaryImportManager {
  _InspectBundleManager({
    required super.dictRepo,
    required super.resourceDirectory,
    required this.bundlePath,
  }) : super(formats: const <String, DictionaryFormat>{});

  final String bundlePath;

  /// 每本进入 native 导入的词典：文件名 → zip 内文件集合（非 zip 为空集）。
  final Map<String, Set<String>> nativeInputs = <String, Set<String>>{};

  @override
  Future<void> importFromFile({
    required File file,
    required ValueNotifier<String> progressNotifier,
    required Function() onImportSuccess,
    required bool lowMemoryMode,
    List<File> cssFiles = const <File>[],
    List<Directory> fontDirs = const <Directory>[],
    VoidCallback? onMemoryError,
    bool forceReplaceExisting = false,
    Map<String, String>? sourceOverride,
    Dictionary? replaceTarget,
  }) async {
    if (p.equals(file.path, bundlePath)) {
      await super.importFromFile(
        file: file,
        progressNotifier: progressNotifier,
        onImportSuccess: onImportSuccess,
        lowMemoryMode: lowMemoryMode,
      );
      return;
    }
    final String name = p.basename(file.path);
    if (p.extension(file.path).toLowerCase() != '.zip' ||
        !name.startsWith('_bundle_dict_')) {
      nativeInputs[name] = <String>{};
      return;
    }
    final Archive archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
    final Set<String> files = <String>{
      for (final ArchiveFile entry in archive)
        if (entry.isFile) entry.name.replaceAll(r'\', '/'),
    };
    final ArchiveFile? index = archive.findFile('index.json');
    final String title = index == null
        ? '<no index> $name'
        : (jsonDecode(utf8.decode(index.content as List<int>))
                  as Map<String, dynamic>)['title']
              as String;
    nativeInputs[title] = files;
  }
}

String _index(String title) => '{"title":"$title","revision":"1","format":3}';

String _bank(String term) => '[["$term","","","",0,["$term entry"],0,""]]';

Future<Map<String, Set<String>>> _runBundle(Map<String, String> entries) async {
  final Directory scratch = Directory.systemTemp.createTempSync(
    'fushi-bundle-nested-',
  );
  addTearDown(() => scratch.deleteSync(recursive: true));
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final DictionaryRepository repo = DictionaryRepository(db);
  addTearDown(repo.dispose);
  final Archive source = Archive();
  for (final MapEntry<String, String> entry in entries.entries) {
    final List<int> bytes = utf8.encode(entry.value);
    source.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  final File bundle = File(p.join(scratch.path, 'bundle.zip'))
    ..writeAsBytesSync(ZipEncoder().encode(source)!);
  final Directory resources = Directory(p.join(scratch.path, 'resources'))
    ..createSync();
  final _InspectBundleManager manager = _InspectBundleManager(
    dictRepo: repo,
    resourceDirectory: resources,
    bundlePath: bundle.path,
  );
  final ValueNotifier<String> progress = ValueNotifier<String>('');
  addTearDown(progress.dispose);
  await manager.importFromFile(
    file: bundle,
    progressNotifier: progress,
    onImportSuccess: () {},
    lowMemoryMode: false,
  );
  return manager.nativeInputs;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    const MethodChannel toast = MethodChannel('PonnamKarthik/fluttertoast');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(toast, (MethodCall _) async => true);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(toast, null),
    );
  });

  test('父根 + 嵌套根：两本各自带上自己的 index 与 bank，互不混入', () async {
    final Map<String, Set<String>> inputs = await _runBundle(<String, String>{
      'index.json': _index('Parent'),
      'term_bank_1.json': _bank('parent'),
      'nested/index.json': _index('Nested'),
      'nested/term_bank_1.json': _bank('nested'),
    });
    expect(inputs.keys.toSet(), <String>{'Parent', 'Nested'});
    expect(inputs['Nested'], <String>{'index.json', 'term_bank_1.json'});
    expect(inputs['Parent'], <String>{'index.json', 'term_bank_1.json'});
  });

  test('三层嵌套：中间根排除孙根、孙根不被祖先排空', () async {
    final Map<String, Set<String>> inputs = await _runBundle(<String, String>{
      'a/index.json': _index('A'),
      'a/term_bank_1.json': _bank('a'),
      'a/b/index.json': _index('B'),
      'a/b/term_bank_1.json': _bank('b'),
      'a/b/c/index.json': _index('C'),
      'a/b/c/term_bank_1.json': _bank('c'),
    });
    expect(inputs.keys.toSet(), <String>{'A', 'B', 'C'});
    for (final String title in <String>['A', 'B', 'C']) {
      expect(inputs[title], <String>{
        'index.json',
        'term_bank_1.json',
      }, reason: '$title 只应带自己目录下的文件：$inputs');
    }
  });

  test('同层兄弟根 + 嵌套根 + 内层 MDX 混合：各本完整、MDX 不进 Yomitan 包', () async {
    final Map<String, Set<String>> inputs = await _runBundle(<String, String>{
      'index.json': _index('Root'),
      'term_bank_1.json': _bank('root'),
      'extra.mdx': 'not-really-mdx',
      'left/index.json': _index('Left'),
      'left/term_bank_1.json': _bank('left'),
      'right/index.json': _index('Right'),
      'right/term_bank_1.json': _bank('right'),
      'right/inner/index.json': _index('Inner'),
      'right/inner/term_bank_1.json': _bank('inner'),
    });
    expect(inputs.keys.toSet(), <String>{
      'Root',
      'Left',
      'Right',
      'Inner',
      'extra.mdx',
    });
    for (final String title in <String>['Root', 'Left', 'Right', 'Inner']) {
      expect(inputs[title], <String>{
        'index.json',
        'term_bank_1.json',
      }, reason: '$title 只应带自己目录下的文件：$inputs');
    }
  });
}
