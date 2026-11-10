/// admin API 的词典端点（WebUI「词典」页）：
///
/// - `GET    /api/admin/dictionaries`               引擎状态（原生库 / 变形表）+ 词典清单；
/// - `PUT    /api/admin/dictionaries`               正文是 Yomitan zip，导入（同名视为更新）；
/// - `PUT    /api/admin/dictionaries/order`         `{"names": [...]}` 整份新顺序；
/// - `PATCH  /api/admin/dictionaries/<名>`          `{"hidden": bool}`；
/// - `DELETE /api/admin/dictionaries/<名>`          删除；
/// - `GET    /api/admin/dictionaries/lookup?q=词`   试查（与互联查词同一条路径）。
///
/// 改动与互联推送走同一把库锁，完成后按 DB 重载引擎，即时生效（离线 `dict` 命令要重启）。
/// 引擎没加载时导入 / 删除照样落 DB 与资源目录（与互联推送一致），只是试查不可用。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart';
import 'package:fushi_engine/dictionary/dictionary_engine_hooks.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/commands/dict_commands.dart';
import 'package:fushi_server/src/dictionary_host.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;

const String kAdminDictionariesPath = '/api/admin/dictionaries';

/// 服务端引擎只认「日语隐藏」这一个标记（见 [ServerDictionaryHost.refresh]）。
const String _kHiddenLanguage = 'ja';

/// 试查返回的最多词条数。
const int _kLookupMaxTerms = 10;

class AdminDictionaries {
  AdminDictionaries(this.ctx, {DictArchiveImporter? importer})
    : _importer = importer;

  final AdminContext ctx;

  /// 原生导入器（测试注入假的；生产为 null = [FushiDicts.importDictionary]）。
  final DictArchiveImporter? _importer;

  Future<shelf.Response?> route(
    String method,
    String path,
    shelf.Request request,
  ) async {
    switch ((method, path)) {
      case ('GET', kAdminDictionariesPath):
        return _json(await status());
      case ('PUT', kAdminDictionariesPath):
        return _import(request);
      case ('PUT', '$kAdminDictionariesPath/order'):
        return _reorder(await _body(request));
      case ('GET', '$kAdminDictionariesPath/lookup'):
        return _lookup(request.url.queryParameters['q'] ?? '');
    }
    if (!path.startsWith('$kAdminDictionariesPath/')) return null;
    final String name = Uri.decodeComponent(
      path.substring('$kAdminDictionariesPath/'.length),
    );
    switch (method) {
      case 'PATCH':
        return _patch(name, await _body(request));
      case 'DELETE':
        return _delete(name);
    }
    return null;
  }

  /// `GET /api/admin/dictionaries` 的回包。
  Future<Map<String, Object?>> status() async {
    final ServerDictionaryHost? engine = ctx.host.dictionaries;
    final List<DictionaryMetaRow> rows = await _sortedRows();
    return <String, Object?>{
      'engine': <String, Object?>{
        'available': engine?.available ?? false,
        'reason':
            engine?.unavailableReason ??
            (engine == null ? 'the interconnect host is not running' : null),
        'libraryPath': engine?.libraryPath,
        'transformsLoaded': engine?.transformsLoaded ?? false,
        'transformsPath': engine?.transformsPath,
        'loadedCount': engine?.loadedCount ?? 0,
      },
      'dictionaries': <Map<String, Object?>>[
        for (final DictionaryMetaRow r in rows)
          <String, Object?>{
            ...dictionaryRowJson(r, ctx.paths.dictionaryResources),
            'displayName': r.displayName,
          },
      ],
    };
  }

  Future<shelf.Response> _import(shelf.Request request) async {
    // 原生导入器和查词引擎是同一个原生库：引擎没加载时导入必然失败，先说清原因，
    // 免得收完整个上传才报一句「找不到符号」。
    final ServerDictionaryHost? engine = ctx.host.dictionaries;
    if (_importer == null && !(engine?.available ?? false)) {
      return _err(
        409,
        'dictionary engine unavailable: '
        '${engine?.unavailableReason ?? 'the interconnect host is not running'}',
      );
    }
    await ctx.paths.temp.create(recursive: true);
    final Directory dir = await ctx.paths.temp.createTemp('dict_upload_');
    try {
      final File archive = File(p.join(dir.path, 'upload.zip'));
      final IOSink sink = archive.openWrite();
      try {
        await sink.addStream(request.read());
      } finally {
        await sink.close();
      }
      if (await archive.length() == 0) {
        return _err(400, 'empty upload');
      }
      final DictImportOutcome r;
      try {
        r = await importDictionaryArchive(
          db: ctx.db,
          resourceRoot: ctx.paths.dictionaryResources,
          archive: archive,
          importer: _importer,
          installGuard: _installGuard,
        );
      } on DictImportException catch (e) {
        return _err(422, e.message);
      }
      ctx.log.info(
        'dictionary ${r.replaced ? 'updated' : 'imported'}: ${r.name} '
        '(${r.type}, ${r.termCount} terms)',
      );
      return _json(<String, Object?>{
        'name': r.name,
        'type': r.type,
        'termCount': r.termCount,
        'kanjiCount': r.kanjiCount,
        'replaced': r.replaced,
      });
    } finally {
      await dir.delete(recursive: true);
    }
  }

  /// 装进库那一步：拿库锁、释放引擎映射（Windows 不许覆盖被映射的文件，BUG-1756），
  /// 收尾按 DB 重载引擎——与互联推送的 `importDictionary` 同一口径。
  Future<void> _installGuard(Future<void> Function() install) =>
      _mutate(() => withDictionaryMappingsReleased<void>(install));

  Future<shelf.Response> _reorder(Map<String, dynamic> body) async {
    final Object? raw = body['names'];
    if (raw is! List || raw.any((Object? e) => e is! String)) {
      return _err(400, 'names must be a list of dictionary names');
    }
    final List<String> names = raw.cast<String>();
    String? error;
    await _mutate(() async {
      final List<DictionaryMetaRow> rows = await ctx.db
          .getAllDictionaryMetadata();
      final Set<String> existing = <String>{
        for (final DictionaryMetaRow r in rows) r.name,
      };
      if (names.length != existing.length ||
          !existing.containsAll(names) ||
          names.toSet().length != names.length) {
        error = 'names must list every dictionary exactly once';
        return;
      }
      final Map<String, DictionaryMetaRow> byName = <String, DictionaryMetaRow>{
        for (final DictionaryMetaRow r in rows) r.name: r,
      };
      await ctx.db.transaction(() async {
        for (int i = 0; i < names.length; i++) {
          final DictionaryMetaRow r = byName[names[i]]!;
          if (r.order == i) continue;
          await ctx.db.upsertDictionaryMeta(
            r.toCompanion(false).copyWith(order: Value<int>(i)),
          );
        }
      });
    });
    if (error != null) return _err(400, error!);
    return _json(await status());
  }

  Future<shelf.Response> _patch(String name, Map<String, dynamic> body) async {
    final Object? hidden = body['hidden'];
    if (hidden is! bool) return _err(400, 'hidden must be a boolean');
    bool found = false;
    await _mutate(() async {
      final DictionaryMetaRow? row = await _row(name);
      if (row == null) return;
      found = true;
      final List<String> langs = _decodeStringList(row.hiddenLanguagesJson)
        ..remove(_kHiddenLanguage);
      if (hidden) langs.add(_kHiddenLanguage);
      await ctx.db.upsertDictionaryMeta(
        row
            .toCompanion(false)
            .copyWith(hiddenLanguagesJson: Value<String>(jsonEncode(langs))),
      );
    });
    if (!found) return _err(404, 'no dictionary named "$name"');
    return _json(await status());
  }

  Future<shelf.Response> _delete(String name) async {
    if (await _row(name) == null) {
      return _err(404, 'no dictionary named "$name"');
    }
    // 互联推送的删除口径（先改 DB 并重载引擎释放映射，再删目录；BUG-1756）。
    await ctx.host.libraryService.deleteDictionary(name);
    ctx.log.info('dictionary deleted: $name');
    return _json(await status());
  }

  Future<shelf.Response> _lookup(String query) async {
    final ServerDictionaryHost? engine = ctx.host.dictionaries;
    if (engine == null || !engine.available) {
      return _err(409, 'dictionary engine unavailable');
    }
    if (query.trim().isEmpty) return _err(400, 'q is required');
    final DictionarySearchResult? result = engine.search(
      query,
      maximumTerms: _kLookupMaxTerms,
    );
    return _json(<String, Object?>{
      'query': query,
      'searchTerm': result?.searchTerm,
      'entries': <Map<String, Object?>>[
        for (final DictionaryEntry e
            in result?.entries ?? const <DictionaryEntry>[])
          <String, Object?>{
            'word': e.word,
            'reading': e.reading,
            'dictionary': e.dictionaryName,
            'meaning': e.plainMeaning,
          },
      ],
    });
  }

  /// 在库锁里改词典，收尾（成功或失败）都按 DB 重载引擎。
  Future<void> _mutate(Future<void> Function() body) =>
      ctx.host.runLibraryExclusive(() async {
        try {
          await body();
        } finally {
          await ctx.host.dictionaries?.refresh();
        }
      });

  Future<DictionaryMetaRow?> _row(String name) async {
    for (final DictionaryMetaRow r in await ctx.db.getAllDictionaryMetadata()) {
      if (r.name == name) return r;
    }
    return null;
  }

  Future<List<DictionaryMetaRow>> _sortedRows() async =>
      (await ctx.db.getAllDictionaryMetadata())..sort(
        (DictionaryMetaRow a, DictionaryMetaRow b) =>
            a.order.compareTo(b.order),
      );
}

List<String> _decodeStringList(String raw) {
  try {
    final Object? v = jsonDecode(raw);
    return v is List ? <String>[for (final Object? e in v) '$e'] : <String>[];
  } on FormatException {
    return <String>[];
  }
}

shelf.Response _json(Object body, {int status = 200}) => shelf.Response(
  status,
  body: jsonEncode(body),
  headers: const <String, String>{
    'Content-Type': 'application/json; charset=utf-8',
  },
);

shelf.Response _err(int status, String message) =>
    _json(<String, Object?>{'error': message}, status: status);

Future<Map<String, dynamic>> _body(shelf.Request request) async {
  final String text = await request.readAsString();
  if (text.isEmpty) return <String, dynamic>{};
  final Object? decoded = jsonDecode(text);
  if (decoded is! Map) throw const FormatException('JSON object body required');
  return Map<String, dynamic>.from(decoded);
}
