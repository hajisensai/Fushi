/// `dict` 命令族（离线）：服务端词典库的列出 / 导入 / 删除。
///
/// 词典平常经互联推送进来（客户端「词典 · 传输」→ `/api/library/dictionaries`）；
/// 纯无头部署没有客户端可推时，用 `dict add <yomitan.zip>` 直接导入。导入走与 app
/// 同一个原生导入器（[FushiDicts.importDictionary]），落盘形状与 app / 互联推送一致：
/// `<dictionaryResources>/<词典名>/` + `dictionary_metadata` 一行。
///
/// 正在跑的 `serve` 不会自动看到离线改动：导入 / 删除后重启 serve 才进引擎
/// （经互联推送的词典则即时生效）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart';
import 'package:fushi_engine/models/dictionary_directory.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/dictionary_host.dart';
import 'package:fushi_server/src/server_runtime.dart';
import 'package:path/path.dart' as p;

/// 一次导入的结果（`dict add --json` 的输出形状）。
typedef DictImportOutcome = ({String name, String type, int termCount, int kanjiCount, bool replaced});

/// 词典导入失败（导入器报错 / 包里没有标题）。
class DictImportException implements Exception {
  const DictImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 原生导入器的签名（测试可注入）。
typedef DictArchiveImporter = Future<FushiImportResult> Function(String archivePath, String outputDir);

/// 把 [archive]（Yomitan zip 等原生导入器认的格式）导入服务端词典库。
///
/// 同名词典视为更新：替换资源目录，保留原有的排序与用户设置（隐藏 / 折叠 / 语言覆盖 /
/// 显示名），与 app 重导同名词典的继承口径一致；新词典排在最后。
Future<DictImportOutcome> importDictionaryArchive({
  required FushiDatabase db,
  required Directory resourceRoot,
  required File archive,
  DictArchiveImporter? importer,
}) async {
  final Directory staging = await Directory.systemTemp.createTemp('fushi_dict_import_');
  try {
    final FushiImportResult result = await (importer ?? FushiDicts.importDictionary)(archive.path, staging.path);
    if (!result.success) {
      throw DictImportException(result.error.isNotEmpty ? result.error : '导入失败');
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
    await deleteDictionaryDirectory(target, reloadEngine: () {});
    await _moveDirectory(source, target);
    final int order =
        previous?.order ??
        (rows.isEmpty ? 0 : rows.map((DictionaryMetaRow r) => r.order).reduce((int a, int b) => a > b ? a : b) + 1);
    final String type = switch (result.detectedType) {
      'frequency' || 'pitch' || 'kanji' => result.detectedType,
      _ => 'term',
    };
    await db.upsertDictionaryMeta(
      DictionaryMetadataCompanion.insert(
        name: name,
        formatKey: 'yomichan',
        order: order,
        type: Value<String>(type),
        metadataJson: Value<String>(
          jsonEncode(<String, String>{
            if (result.kanjiCount > 0) 'hasKanji': 'true',
            // 导入时原生侧已数过 term / kanji 记录，等于类型探测刚做完（与 app 同一标记）。
            'typeProbe': '1',
          }),
        ),
        hiddenLanguagesJson: Value<String>(previous?.hiddenLanguagesJson ?? '[]'),
        collapsedLanguagesJson: Value<String>(previous?.collapsedLanguagesJson ?? '[]'),
        expandedLanguagesJson: Value<String>(previous?.expandedLanguagesJson ?? '[]'),
        languageOverride: Value<String?>(previous?.languageOverride),
        displayName: Value<String?>(previous?.displayName),
      ),
    );
    return (
      name: name,
      type: type,
      termCount: result.termCount,
      kanjiCount: result.kanjiCount,
      replaced: previous != null,
    );
  } finally {
    if (staging.existsSync()) await staging.delete(recursive: true);
  }
}

/// 词典标题 → 目录名 / 主键（与 app `_sanitizeTitle` 同规则）。
String sanitizeDictionaryTitle(String raw) {
  final String cleaned = p.basename(raw.trim()).replaceAll(RegExp(r'[/\\]'), '_');
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
    throw const DictImportException('词典包里没有标题（index.json 的 title 为空）');
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
Map<String, Object?> dictionaryRowJson(DictionaryMetaRow r, Directory resourceRoot) => <String, Object?>{
  'name': r.name,
  'type': r.type,
  'order': r.order,
  'hidden': r.hiddenLanguagesJson.contains('"ja"'),
  'present': Directory(p.join(resourceRoot.path, r.name)).existsSync(),
};

class DictCliModule extends CliModule {
  const DictCliModule();

  @override
  List<String> get commands => const <String>['dict'];

  @override
  void register(ArgParser parser) {
    parser.addCommand('dict').addFlag('json', negatable: false, help: '机器可读输出');
  }

  @override
  String get usage => '''
词典（离线；改动在 serve 重启后进引擎）：
  dict ls [--json]                 列出服务端词典库
  dict add <词典包.zip> [--json]    导入一本词典（同名视为更新，保留排序与隐藏设置）
  dict rm <词典名> [--json]         删除一本词典（元数据 + 资源目录）''';

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
          stderr.writeln('找不到词典包 ${archive.path}');
          return 66;
        }
        return ctx.withRuntime((ServerRuntime rt) => _add(rt, archive, json: json));
      case 'rm':
        if (rest.length != 2) return _usageError();
        return ctx.withRuntime((ServerRuntime rt) => _remove(rt, rest[1], json: json));
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
      ..sort((DictionaryMetaRow a, DictionaryMetaRow b) => a.order.compareTo(b.order));
    if (json) {
      stdout.writeln(
        jsonEncode(<Map<String, Object?>>[
          for (final DictionaryMetaRow r in rows) dictionaryRowJson(r, rt.paths.dictionaryResources),
        ]),
      );
      return 0;
    }
    if (rows.isEmpty) {
      stdout.writeln('（没有词典）');
      return 0;
    }
    for (final DictionaryMetaRow r in rows) {
      final Map<String, Object?> row = dictionaryRowJson(r, rt.paths.dictionaryResources);
      stdout.writeln(
        '${r.order.toString().padLeft(3)}  ${r.type.padRight(9)} ${r.name}'
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
        '词典引擎原生库不可用（${lib ?? 'libfushidicts_ffi 裸名'}）：$e\n'
        '把 libfushidicts_ffi 放到 bin/../lib/，或设 $kFushiDictsLibEnv 指向它',
      );
      return 69;
    }
    stderr.writeln('导入 ${archive.path} …');
    final DictImportOutcome r;
    try {
      r = await importDictionaryArchive(db: rt.db, resourceRoot: rt.paths.dictionaryResources, archive: archive);
    } on DictImportException catch (e) {
      stderr.writeln('导入失败：${e.message}');
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
        }),
      );
    } else {
      stdout.writeln(
        '${r.replaced ? '已更新' : '已导入'}「${r.name}」（${r.type}，${r.termCount} 词条'
        '${r.kanjiCount > 0 ? '，${r.kanjiCount} 汉字' : ''}）；重启 serve 后生效',
      );
    }
    return 0;
  }

  Future<int> _remove(ServerRuntime rt, String name, {required bool json}) async {
    final List<DictionaryMetaRow> rows = await rt.db.getAllDictionaryMetadata();
    if (!rows.any((DictionaryMetaRow r) => r.name == name)) {
      stderr.writeln('没有名为「$name」的词典');
      return 1;
    }
    final String safe = p.basename(name);
    if (safe != name || name == '.' || name == '..') {
      stderr.writeln('非法词典名：$name');
      return 64;
    }
    await rt.db.deleteDictionaryMeta(name);
    final DictDirDeleteOutcome outcome = await deleteDictionaryDirectory(
      Directory(p.join(rt.paths.dictionaryResources.path, name)),
      reloadEngine: () {},
    );
    if (json) {
      stdout.writeln(jsonEncode(<String, Object?>{'name': name, 'files': outcome.name}));
    } else {
      stdout.writeln('已删除「$name」；重启 serve 后生效');
    }
    return 0;
  }
}
