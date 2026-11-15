/// admin API 的词典端点（WebUI「词典」页）。服务端 admin 词典契约只有这一套：
///
/// - `GET    /api/admin/dictionaries`               引擎状态（原生库 / 变形表）+ 词典清单
///   （每行见 [AdminDictionaries.dictionaryEntry]）；
/// - `PUT    /api/admin/dictionaries`               正文是词典包，导入（同名视为更新）。不带
///   文件名 = Yomitan zip；`?filename=`（或 `X-Filename` 头）带扩展名时另收 app 导出的
///   `.fushidict`、MDX、DSL（见 admin_dictionary_import.dart）；
/// - `PUT    /api/admin/dictionaries/order`         `{"names": [...]}` 整份新顺序；
/// - `PATCH  /api/admin/dictionaries/<名>`          任意几项（至少一项）：`hidden` /
///   `defaultEnabled`（bool，互为反义）、`languageOverride` / `displayName`（string|null）；
/// - `DELETE /api/admin/dictionaries/<名>`          删除；
/// - `POST   /api/admin/dictionaries/reload`        按 DB 重载引擎（手工改过资源目录后用）；
/// - `GET    /api/admin/dictionaries/lookup?q=词`   试查（与互联查词同一条路径）。
///
/// 改动类端点（排序 / PATCH / 删除 / 重载）回整份 `GET` 回包；导入回导入结果。
/// 改动与互联推送走同一把库锁，完成后按 DB 重载引擎，即时生效（离线 `dict` 命令要重启）。
/// 引擎没加载时 `.fushidict` 导入 / 删除照样落 DB 与资源目录（与互联推送一致），原始
/// 词典包导入、试查与重载报 409。
///
/// 已配对设备按自己的配置（Profile）在查词请求里带词典选择；这里的 `hidden` /
/// `defaultEnabled` 只是**没带选择**的请求（浏览器扩展 / 旧客户端）的默认开关，落在
/// 服务端行的 `hiddenLanguagesJson`（含 `ja` = 默认关，与 app 推送写入同一口径）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart';
import 'package:fushi_engine/dictionary/dictionary_engine_hooks.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteDictionaryInfo;
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/admin/admin_dictionary_import.dart';
import 'package:fushi_server/src/admin/upload_store.dart';
import 'package:fushi_server/src/commands/dict_commands.dart';
import 'package:fushi_server/src/dictionary_host.dart';
import 'package:fushi_server/src/server_language.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;

const String kAdminDictionariesPath = '/api/admin/dictionaries';

/// 试查返回的最多词条数。
const int _kLookupMaxTerms = 10;

/// 词头语言手动指定的宽松校验：BCP-47 形状（字母 / 数字 / 连字符，2–35 字符）。
final RegExp _languageTagPattern = RegExp(r'^[A-Za-z0-9-]{2,35}$');

/// 显示名上限（字符）：只是给人看的覆盖名，防误粘一大段。
const int _maxDisplayNameLength = 200;

class AdminDictionaries {
  AdminDictionaries(
    this.ctx, {
    DictArchiveImporter? importer,
    UploadStore? uploads,
  }) : _importer = importer,
       _uploads = uploads;

  final AdminContext ctx;

  /// 原生导入器（测试注入假的；生产为 null = [FushiDicts.importDictionary]）。
  final DictArchiveImporter? _importer;

  /// 上传配额账本（导入的字节计入配额）；null = 不计（单测）。
  final UploadStore? _uploads;

  late final AdminDictionaryImport _imports = AdminDictionaryImport(
    ctx: ctx,
    installGuard: _installGuard,
    uploads: _uploads,
    importer: _importer,
  );

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
      case ('POST', '$kAdminDictionariesPath/reload'):
        return _reload();
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
        for (final DictionaryMetaRow r in rows) await dictionaryEntry(r),
      ],
    };
  }

  /// 清单里的一条。`dict ls --json` 的形状（`name` / `type` / `order` / `hidden` /
  /// `present`）加 `displayName`（原始列，没起名为 null），再加：
  ///
  /// - 互联目录 `/api/library/dictionaries` 同源的字段（[RemoteDictionaryInfo.fromMetadataRow]）：
  ///   `formatKey` / `revision` / `sourceLanguage`（生效值，手动指定优先）/
  ///   `defaultEnabled`（= `!hidden`）；
  /// - 管理页要分辨「自动 / 手动」的原始列：`languageOverride`（没指定为 null）、
  ///   `packageLanguage`（包内 index.json 声明的词头语言，没声明为 null）；
  /// - `sizeBytes`：资源目录占用（目录不在为 0）。
  Future<Map<String, Object?>> dictionaryEntry(DictionaryMetaRow r) async {
    final Directory dir = Directory(
      p.join(ctx.paths.dictionaryResources.path, r.name),
    );
    final bool present = await dir.exists();
    return <String, Object?>{
      ...RemoteDictionaryInfo.fromMetadataRow(r).toJson(),
      ...dictionaryRowJson(r, ctx.paths.dictionaryResources),
      'displayName': r.displayName,
      'languageOverride': _blankToNull(r.languageOverride),
      'packageLanguage': _packageLanguageOf(r.metadataJson),
      'sizeBytes': present ? await _directorySize(dir) : 0,
    };
  }

  /// 导入：协议见 [AdminDictionaryImport]。回 `{name, format, type, termCount,
  /// kanjiCount, replaced, language, dictionary}`（`format` 是 `fushidict` / `archive`；
  /// `.fushidict` 不带词条数，两个 count 为 null；`dictionary` 是 [dictionaryEntry]）。
  /// 拒收：400 空文件 / 认不出的包，409 词典引擎不可用，413 超上传配额，415 扩展名
  /// 不收，422 原生导入器报错。
  Future<shelf.Response> _import(shelf.Request request) async {
    final AdminDictionaryImportOutcome r;
    try {
      r = await _imports.run(request);
    } on UploadRejected catch (e) {
      return _err(e.status, e.message);
    }
    final DictionaryMetaRow? row = await _row(r.name);
    return _json(<String, Object?>{
      'name': r.name,
      'format': r.format,
      'type': r.type,
      'termCount': r.termCount,
      'kanjiCount': r.kanjiCount,
      'replaced': r.replaced,
      'language': r.language,
      'dictionary': row == null ? null : await dictionaryEntry(row),
    });
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

  /// `PATCH /api/admin/dictionaries/<名>`，请求体可带下面任意几项（至少一项）：
  ///
  /// - `hidden: bool` / `defaultEnabled: bool`（互为反义，同时给且矛盾时 400）：服务端
  ///   默认开关，`hiddenLanguagesJson` 里只增删 `ja`，其余语言保留；
  /// - `languageOverride: string|null`：词头语言手动指定（同 app 的每词典语言设置）；
  ///   trim 后空串 / null = 清掉、回到包内声明；
  /// - `displayName: string|null`：显示名覆盖（真名不动），语义同上。
  ///
  /// 读-改-写与引擎重载都在库锁里。客户端下次刷新目录就看到新值：互联词典目录读的是
  /// 同一行。
  Future<shelf.Response> _patch(String name, Map<String, dynamic> body) async {
    bool? hidden;
    for (final (String key, bool invert) in <(String, bool)>[
      ('hidden', false),
      ('defaultEnabled', true),
    ]) {
      if (!body.containsKey(key)) continue;
      final Object? raw = body[key];
      if (raw is! bool) return _err(400, '$key must be a boolean');
      final bool value = invert ? !raw : raw;
      if (hidden != null && hidden != value) {
        return _err(400, 'hidden and defaultEnabled contradict each other');
      }
      hidden = value;
    }
    final Value<String?>? language;
    final Value<String?>? displayName;
    try {
      language = _clearableString(body, 'languageOverride');
      displayName = _clearableString(body, 'displayName');
    } on FormatException catch (e) {
      return _err(400, e.message);
    }
    final String? tag = language?.value;
    if (tag != null && !_languageTagPattern.hasMatch(tag)) {
      return _err(
        400,
        tr(
          '语言标签无效：「$tag」（应为 BCP-47 标签，如 ja、zh-Hant）',
          'invalid language tag "$tag" (expected a BCP-47 tag such as ja or zh-Hant)',
        ),
      );
    }
    final String? shown = displayName?.value;
    if (shown != null && shown.length > _maxDisplayNameLength) {
      return _err(
        400,
        tr(
          '显示名太长（最多 $_maxDisplayNameLength 个字符）',
          'display name is too long (at most $_maxDisplayNameLength characters)',
        ),
      );
    }
    if (hidden == null && language == null && displayName == null) {
      return _err(
        400,
        'body must contain hidden, defaultEnabled, languageOverride or '
        'displayName',
      );
    }
    final bool? hide = hidden;
    bool found = false;
    await _mutate(() async {
      final DictionaryMetaRow? row = await _row(name);
      if (row == null) return;
      found = true;
      await ctx.db.upsertDictionaryMeta(
        row
            .toCompanion(false)
            .copyWith(
              hiddenLanguagesJson: hide == null
                  ? const Value<String>.absent()
                  : Value<String>(
                      RemoteDictionaryInfo.withHiddenByDefault(
                        row.hiddenLanguagesJson,
                        hide,
                      ),
                    ),
              languageOverride: language ?? const Value<String?>.absent(),
              displayName: displayName ?? const Value<String?>.absent(),
            ),
      );
    });
    if (!found) return _err(404, 'no dictionary named "$name"');
    return _json(await status());
  }

  /// `POST /api/admin/dictionaries/reload`：按 DB 重载引擎（手工改过资源目录后用），
  /// 在库锁里跑，不与导入 / 删除交错。引擎没加载时 409。
  Future<shelf.Response> _reload() async {
    final ServerDictionaryHost? engine = ctx.host.dictionaries;
    if (engine == null || !engine.available) {
      return _err(
        409,
        'dictionary engine unavailable: '
        '${engine?.unavailableReason ?? 'the interconnect host is not running'}',
      );
    }
    await _mutate(() async {});
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

String? _blankToNull(String? raw) {
  final String trimmed = raw?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

String? _packageLanguageOf(String metadataJson) {
  try {
    final Object? decoded = jsonDecode(metadataJson);
    if (decoded is Map) {
      final Object? lang = decoded['sourceLanguage'];
      if (lang is String) return _blankToNull(lang);
    }
  } on FormatException {
    // 畸形 metadataJson：当包内没声明。
  }
  return null;
}

/// 可清空的字符串字段：缺键 = 不改（返回 `null`）；`null` / 空串 / 纯空白 = 清掉
/// （`Value(null)`）；否则 trim 后写入。非字符串抛 [FormatException]（admin API 回 400）。
Value<String?>? _clearableString(Map<String, dynamic> body, String key) {
  if (!body.containsKey(key)) return null;
  final Object? raw = body[key];
  if (raw != null && raw is! String) {
    throw FormatException(
      tr('$key 必须是字符串或 null', '$key must be a string or null'),
    );
  }
  return Value<String?>(_blankToNull(raw as String?));
}

Future<int> _directorySize(Directory dir) async {
  int total = 0;
  await for (final FileSystemEntity e in dir.list(
    recursive: true,
    followLinks: false,
  )) {
    if (e is File) total += await e.length();
  }
  return total;
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
