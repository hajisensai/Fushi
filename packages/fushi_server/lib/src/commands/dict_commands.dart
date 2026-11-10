/// `dict` 命令族（离线）：服务端词典库的列出 / 导入 / 删除。
///
/// 词典平常经互联推送进来（客户端「词典 · 传输」→ `/api/library/dictionaries`）；
/// 纯无头部署没有客户端可推时，用 `dict add <yomitan.zip>` 直接导入。导入走与 app
/// 同一个原生导入器（[FushiDicts.importDictionary]），落盘形状与 app / 互联推送一致：
/// `<dictionaryResources>/<词典名>/` + `dictionary_metadata` 一行。
///
/// 正在跑的 `serve` 不会自动看到离线改动：导入 / 删除后重启 serve 才进引擎
/// （经互联推送、或在 WebUI「词典」页导入的词典则即时生效——后者在 serve 进程内跑
/// 同一个 [importDictionaryArchive]，带上 `reloadEngine`，见 admin_api.dart）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:args/args.dart';
import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart';
import 'package:fushi_engine/dictionary/dictionary_engine_hooks.dart';
import 'package:fushi_engine/models/dictionary_directory.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/dictionary_host.dart';
import 'package:fushi_server/src/server_language.dart';
import 'package:fushi_server/src/server_runtime.dart';
import 'package:path/path.dart' as p;

/// 一次导入的结果（`dict add --json` 的输出形状）。
typedef DictImportOutcome = ({
  String name,
  String type,
  int termCount,
  int kanjiCount,
  bool replaced,
  String? language,
});

/// 词典导入失败（导入器报错 / 包里没有标题）。
class DictImportException implements Exception {
  const DictImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 原生导入器的签名（测试可注入）。
typedef DictArchiveImporter =
    Future<FushiImportResult> Function(String archivePath, String outputDir);

/// 把 [archive]（Yomitan zip 等原生导入器认的格式）导入服务端词典库。
///
/// 同名词典视为更新：替换资源目录，保留原有的排序与用户设置（隐藏 / 折叠 / 语言覆盖 /
/// 显示名），与 app 重导同名词典的继承口径一致；新词典排在最后。
///
/// 两种调用方：
/// - 离线 CLI（`dict add`）：没有引擎在跑，[reloadEngine] 留空。
/// - serve 进程内（WebUI 导入）：调用方在库互斥锁里调用，并传 [reloadEngine]（按 DB
///   重载引擎）。原生导入写的是暂存目录，不碰引擎；「删旧目录 → 搬入 → 写 DB」整段
///   在 [withDictionaryMappingsReleased] 作用域里（同名覆盖时旧目录正被引擎映射，
///   BUG-1756），收尾无论成败都 [reloadEngine]，引擎不会停在释放后的空状态。
///
/// [stagingParent]：原生导入的输出暂存目录建在哪（默认系统临时目录）。serve 传数据目录
/// 的 `tmp/`，与资源目录同盘，搬入是一次改名而不是逐文件复制。
Future<DictImportOutcome> importDictionaryArchive({
  required FushiDatabase db,
  required Directory resourceRoot,
  required File archive,
  DictArchiveImporter? importer,
  Directory? stagingParent,
  Future<void> Function()? reloadEngine,
}) async {
  final Directory staging;
  if (stagingParent != null) {
    await stagingParent.create(recursive: true);
    staging = await stagingParent.createTemp('fushi_dict_import_');
  } else {
    staging = await Directory.systemTemp.createTemp('fushi_dict_import_');
  }
  try {
    final FushiImportResult result =
        await (importer ?? FushiDicts.importDictionary)(
          archive.path,
          staging.path,
        );
    if (!result.success) {
      throw DictImportException(
        result.error.isNotEmpty ? result.error : tr('导入失败', 'Import failed'),
      );
    }
    final String name = sanitizeDictionaryTitle(result.title);
    final List<DictionaryMetaRow> rows = await db.getAllDictionaryMetadata();
    DictionaryMetaRow? previous;
    for (final DictionaryMetaRow r in rows) {
      if (r.name == name) previous = r;
    }
    final Directory inner = Directory(p.join(staging.path, name));
    final Directory source = inner.existsSync() ? inner : staging;
    final Directory target = Directory(p.join(resourceRoot.path, name));
    await resourceRoot.create(recursive: true);
    final String type = switch (result.detectedType) {
      'frequency' || 'pitch' || 'kanji' => result.detectedType,
      _ => 'term',
    };
    Future<String?> publish() async {
      // 引擎在作用域结束后由调用方的 reloadEngine 统一装回（作用域内不装，免得把
      // 正要覆盖的目录又映射上）。
      await deleteDictionaryDirectory(target, reloadEngine: () {});
      await _moveDirectory(source, target);
      return _writeImportedMetadata(
        db: db,
        rows: rows,
        previous: previous,
        name: name,
        type: type,
        result: result,
        target: target,
        archive: archive,
      );
    }

    final String? language;
    if (reloadEngine == null) {
      language = await publish();
    } else {
      try {
        language = await withDictionaryMappingsReleased(publish);
      } finally {
        await reloadEngine();
      }
    }
    return (
      name: name,
      type: type,
      termCount: result.termCount,
      kanjiCount: result.kanjiCount,
      replaced: previous != null,
      language: language,
    );
  } finally {
    if (staging.existsSync()) await staging.delete(recursive: true);
  }
}

/// 写（或按同名更新）导入词典的 `dictionary_metadata` 行，返回生效的词头语言（手动
/// 指定优先，其次包内声明）。
Future<String?> _writeImportedMetadata({
  required FushiDatabase db,
  required List<DictionaryMetaRow> rows,
  required DictionaryMetaRow? previous,
  required String name,
  required String type,
  required FushiImportResult result,
  required Directory target,
  required File archive,
}) async {
  final int order =
      previous?.order ??
      (rows.isEmpty
          ? 0
          : rows
                    .map((DictionaryMetaRow r) => r.order)
                    .reduce((int a, int b) => a > b ? a : b) +
                1);
  final Map<String, String> source = await readImportedSourceMetadata(
    importedDir: target,
    archive: archive,
  );
  await db.upsertDictionaryMeta(
    DictionaryMetadataCompanion.insert(
      name: name,
      formatKey: 'yomichan',
      order: order,
      type: Value<String>(type),
      metadataJson: Value<String>(
        jsonEncode(<String, String>{
          // 来源与内容语言（revision / sourceLanguage / …），见该函数注释。
          ...source,
          if (result.kanjiCount > 0) kDictHasKanjiKey: 'true',
          // 混合词典汉字部分的开关 / 位置是用户设置，同名重导继承（与 app 同口径）。
          if (result.kanjiCount > 0 && previous != null)
            ...kanjiPartSettingsIn(_decodeMetadata(previous.metadataJson)),
          // 导入时原生侧已数过 term / kanji 记录，等于类型探测刚做完（与 app 同一标记）。
          'typeProbe': '1',
        }),
      ),
      hiddenLanguagesJson: Value<String>(previous?.hiddenLanguagesJson ?? '[]'),
      collapsedLanguagesJson: Value<String>(
        previous?.collapsedLanguagesJson ?? '[]',
      ),
      expandedLanguagesJson: Value<String>(
        previous?.expandedLanguagesJson ?? '[]',
      ),
      languageOverride: Value<String?>(previous?.languageOverride),
      displayName: Value<String?>(previous?.displayName),
    ),
  );
  final String? override = previous?.languageOverride?.trim();
  return (override != null && override.isNotEmpty)
      ? override
      : source['sourceLanguage'];
}

/// 这本词典来自 `index.json` 的来源与内容语言 metadata，键与取值规范和 app 导入一致
/// （`fushi_dictionary` 的 `parseSourceMetadataFromIndexJson`：字符串字段 trim 后
/// 非空才落；`isUpdatable` 是 bool 才落成 `'true'` / `'false'`）。
///
/// 两个来源，资源目录那份优先：
/// - [importedDir] 下原生导入器写回的 `index.json`（MDX / DSL 等也写一份）——与 app
///   读的是同一个文件，`revision` / `isUpdatable` / `indexUrl` / `downloadUrl` 取这里；
/// - [archive] 里的原始 `index.json`（只认 zip 根目录）——原生写回时用的结构体
///   （`native/fushidicts/fushidicts_src/json/yomitan_parser.hpp` 的 `Index`）不带
///   `sourceLanguage` / `targetLanguage`，写回的文件里这两个字段丢了，只能从原包补。
///
/// 解析函数在带 dio 的 `fushi_dictionary.dart` 库里，服务端只许 import 零 Flutter 的
/// `fushi_dictionary_core.dart`，所以这里按同一规范读，键集合见
/// [kImportedSourceMetadataKeys]。缺文件 / 坏 JSON / 不是 zip → 那一侧为空。
Future<Map<String, String>> readImportedSourceMetadata({
  required Directory importedDir,
  required File archive,
}) async {
  final File written = File(p.join(importedDir.path, 'index.json'));
  final Map<String, String> fromWritten = await written.exists()
      ? parseIndexSourceMetadata(await written.readAsString())
      : <String, String>{};
  return <String, String>{..._archiveIndexMetadata(archive), ...fromWritten};
}

Map<String, String> _archiveIndexMetadata(File archive) {
  if (!archive.existsSync()) return <String, String>{};
  InputFileStream? input;
  try {
    input = InputFileStream(archive.path);
    final ArchiveFile? entry = ZipDecoder()
        .decodeBuffer(input)
        .findFile('index.json');
    if (entry == null || !entry.isFile) return <String, String>{};
    return parseIndexSourceMetadata(
      utf8.decode(entry.content as List<int>, allowMalformed: true),
    );
  } on Object {
    // 不是 zip（裸 MDX / DSL 文件）或包损坏：原生导入已成功，元数据缺省即可。
    return <String, String>{};
  } finally {
    input?.closeSync();
  }
}

/// `index.json` 文本 → 来源 metadata（[kImportedSourceMetadataKeys]）。坏 JSON /
/// 顶层非对象 → 空 Map。
Map<String, String> parseIndexSourceMetadata(String text) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return <String, String>{};
  }
  if (decoded is! Map) return <String, String>{};
  final Map<String, String> out = <String, String>{};
  for (final String key in kImportedSourceMetadataKeys) {
    final Object? v = decoded[key];
    if (key == 'isUpdatable') {
      if (v is bool) out[key] = v ? 'true' : 'false';
    } else if (v is String && v.trim().isNotEmpty) {
      out[key] = v.trim();
    }
  }
  return out;
}

/// app 导入时从 `index.json` 落进 metadata 的键（与 `parseSourceMetadataFromIndexJson` 同集）。
const List<String> kImportedSourceMetadataKeys = <String>[
  'revision',
  'indexUrl',
  'downloadUrl',
  'sourceLanguage',
  'targetLanguage',
  'isUpdatable',
];

Map<String, String> _decodeMetadata(String json) {
  try {
    final Object? decoded = jsonDecode(json);
    if (decoded is! Map) return <String, String>{};
    return <String, String>{
      for (final MapEntry<Object?, Object?> e in decoded.entries)
        if (e.key is String && e.value is String)
          e.key! as String: e.value! as String,
    };
  } on FormatException {
    return <String, String>{};
  }
}

/// 词典标题 → 目录名 / 主键（与 app `_sanitizeTitle` 同规则）。
String sanitizeDictionaryTitle(String raw) {
  final String cleaned = p
      .basename(raw.trim())
      .replaceAll(RegExp(r'[/\\]'), '_');
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
    throw DictImportException(
      tr(
        '词典包里没有标题（index.json 的 title 为空）',
        'The dictionary package has no title (the title in index.json is empty)',
      ),
    );
  }
  return cleaned;
}

Future<void> _moveDirectory(Directory from, Directory to) async {
  try {
    await from.rename(to.path);
  } on FileSystemException {
    // 跨文件系统（临时目录在 tmpfs）改名失败：逐文件复制。
    await for (final FileSystemEntity e in from.list(recursive: true)) {
      final String rel = p.relative(e.path, from: from.path);
      if (e is Directory) {
        await Directory(p.join(to.path, rel)).create(recursive: true);
      } else if (e is File) {
        await File(p.join(to.path, rel)).parent.create(recursive: true);
        await e.copy(p.join(to.path, rel));
      }
    }
  }
}

/// 一条词典的列表行（`dict ls --json` 的形状）。
Map<String, Object?> dictionaryRowJson(
  DictionaryMetaRow r,
  Directory resourceRoot,
) => <String, Object?>{
  'name': r.name,
  'type': r.type,
  'order': r.order,
  'language':
      r.languageOverride ?? _decodeMetadata(r.metadataJson)['sourceLanguage'],
  'hidden': r.hiddenLanguagesJson.contains('"ja"'),
  'present': Directory(p.join(resourceRoot.path, r.name)).existsSync(),
};

class DictCliModule extends CliModule {
  const DictCliModule();

  @override
  List<String> get commands => const <String>['dict'];

  @override
  void register(ArgParser parser) {
    parser
        .addCommand('dict')
        .addFlag(
          'json',
          negatable: false,
          help: tr('机器可读输出', 'Machine-readable output'),
        );
  }

  @override
  String get usage => tr(
    '''
词典（离线；改动在 serve 重启后进引擎）：
  dict ls [--json]                 列出服务端词典库
  dict add <词典包.zip> [--json]    导入一本词典（同名视为更新，保留排序与隐藏设置）
  dict rm <词典名> [--json]         删除一本词典（元数据 + 资源目录）''',
    '''
Dictionaries (offline; changes reach the engine after serve restarts):
  dict ls [--json]                 list the server dictionary library
  dict add <package.zip> [--json]  import a dictionary (the same name counts as an update, keeping sort order and hidden settings)
  dict rm <name> [--json]          delete a dictionary (metadata + resource directory)''',
  );

  @override
  Future<int> run(String name, ArgResults command, CliContext ctx) async {
    final bool json = command['json'] as bool;
    final List<String> rest = command.rest;
    final String verb = rest.isEmpty ? '' : rest.first;
    switch (verb) {
      case 'ls':
        if (rest.length != 1) return _usageError();
        return ctx.withRuntime((ServerRuntime rt) => _list(rt, json: json));
      case 'add':
        if (rest.length != 2) return _usageError();
        final File archive = File(rest[1]);
        if (!await archive.exists()) {
          stderr.writeln(
            tr(
              '找不到词典包 ${archive.path}',
              'Dictionary package not found: ${archive.path}',
            ),
          );
          return 66;
        }
        return ctx.withRuntime(
          (ServerRuntime rt) => _add(rt, archive, json: json),
        );
      case 'rm':
        if (rest.length != 2) return _usageError();
        return ctx.withRuntime(
          (ServerRuntime rt) => _remove(rt, rest[1], json: json),
        );
      default:
        return _usageError();
    }
  }

  int _usageError() {
    stderr.writeln(usage);
    return 64;
  }

  Future<int> _list(ServerRuntime rt, {required bool json}) async {
    final List<DictionaryMetaRow> rows = await rt.db.getAllDictionaryMetadata()
      ..sort(
        (DictionaryMetaRow a, DictionaryMetaRow b) =>
            a.order.compareTo(b.order),
      );
    if (json) {
      stdout.writeln(
        jsonEncode(<Map<String, Object?>>[
          for (final DictionaryMetaRow r in rows)
            dictionaryRowJson(r, rt.paths.dictionaryResources),
        ]),
      );
      return 0;
    }
    if (rows.isEmpty) {
      stdout.writeln(tr('（没有词典）', '(No dictionaries)'));
      return 0;
    }
    for (final DictionaryMetaRow r in rows) {
      final Map<String, Object?> row = dictionaryRowJson(
        r,
        rt.paths.dictionaryResources,
      );
      stdout.writeln(
        '${r.order.toString().padLeft(3)}  ${r.type.padRight(9)} '
        '${((row['language'] as String?) ?? '-').padRight(5)} ${r.name}'
        '${row['hidden'] == true ? '  [hidden]' : ''}${row['present'] == true ? '' : '  [missing files]'}',
      );
    }
    return 0;
  }

  Future<int> _add(ServerRuntime rt, File archive, {required bool json}) async {
    // 导入器就是词典引擎的原生库：先确认能加载，缺库报 69 而不是导入半截。
    final String? lib = resolveFushiDictsLibraryPath();
    FushiDicts.nativeLibraryPath = lib;
    try {
      FushiDicts.probeDictContent(rt.paths.dictionaryResources.path);
    } catch (e) {
      stderr.writeln(
        tr(
          '词典引擎原生库不可用（${lib ?? 'libfushidicts_ffi 裸名'}）：$e\n'
              '把 libfushidicts_ffi 放到 bin/../lib/，或设 $kFushiDictsLibEnv 指向它',
          'The dictionary engine native library is unavailable (${lib ?? 'bare libfushidicts_ffi name'}): $e\n'
              'Put libfushidicts_ffi in bin/../lib/, or set $kFushiDictsLibEnv to point to it',
        ),
      );
      return 69;
    }
    stderr.writeln(tr('导入 ${archive.path} …', 'Importing ${archive.path} …'));
    final DictImportOutcome r;
    try {
      r = await importDictionaryArchive(
        db: rt.db,
        resourceRoot: rt.paths.dictionaryResources,
        archive: archive,
      );
    } on DictImportException catch (e) {
      stderr.writeln(tr('导入失败：${e.message}', 'Import failed: ${e.message}'));
      return 1;
    }
    if (json) {
      stdout.writeln(
        jsonEncode(<String, Object?>{
          'name': r.name,
          'type': r.type,
          'termCount': r.termCount,
          'kanjiCount': r.kanjiCount,
          'replaced': r.replaced,
          'language': r.language,
        }),
      );
    } else {
      stdout.writeln(
        tr(
          '${r.replaced ? '已更新' : '已导入'}「${r.name}」（${r.type}，${r.termCount} 词条'
              '${r.kanjiCount > 0 ? '，${r.kanjiCount} 汉字' : ''}）；重启 serve 后生效',
          '${r.replaced ? 'Updated' : 'Imported'} "${r.name}" (${r.type}, ${r.termCount} terms'
              '${r.kanjiCount > 0 ? ', ${r.kanjiCount} kanji' : ''}); takes effect after restarting serve',
        ),
      );
    }
    return 0;
  }

  Future<int> _remove(
    ServerRuntime rt,
    String name, {
    required bool json,
  }) async {
    final List<DictionaryMetaRow> rows = await rt.db.getAllDictionaryMetadata();
    if (!rows.any((DictionaryMetaRow r) => r.name == name)) {
      stderr.writeln(tr('没有名为「$name」的词典', 'No dictionary named "$name"'));
      return 1;
    }
    final String safe = p.basename(name);
    if (safe != name || name == '.' || name == '..') {
      stderr.writeln(tr('非法词典名：$name', 'Illegal dictionary name: $name'));
      return 64;
    }
    await rt.db.deleteDictionaryMeta(name);
    final DictDirDeleteOutcome outcome = await deleteDictionaryDirectory(
      Directory(p.join(rt.paths.dictionaryResources.path, name)),
      reloadEngine: () {},
    );
    if (json) {
      stdout.writeln(
        jsonEncode(<String, Object?>{'name': name, 'files': outcome.name}),
      );
    } else {
      stdout.writeln(
        tr(
          '已删除「$name」；重启 serve 后生效',
          'Deleted "$name"; takes effect after restarting serve',
        ),
      );
    }
    return 0;
  }
}
