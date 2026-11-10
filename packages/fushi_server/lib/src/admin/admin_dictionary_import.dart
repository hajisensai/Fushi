/// admin API 的词典导入（`POST /api/admin/dictionaries/import`）：WebUI「词典」页上传
/// 一个词典包，在运行中的 serve 里导入并立即进引擎（不用重启）。
///
/// 协议：请求体是文件原始字节（`Content-Type: application/octet-stream`，不分块），
/// 文件名放在 `?filename=<名字>`（或 `X-Filename` 头，URL 编码）。文件名只用来认格式
/// （扩展名）与交给原生导入器（MDX / DSL 按扩展名分派），不进任何库目录。
///
/// 两种包，按内容判（扩展名只做初筛）：
/// - **app 导出的 `.fushidict`**：zip 根目录 `manifest.json` 的 `kind` 是 `dictionary`。
///   走 `LocalLibraryHostService.importDictionary`——与互联推送同一条路径（库互斥锁、
///   释放映射、收尾重载引擎）。
/// - **原始词典包**：Yomitan zip（根目录 `index.json`）、含 `.mdx` / `.ifo` 的 zip、
///   裸 `.mdx` / `.dsl`。走 `dict add` 同一个 [importDictionaryArchive]（记 index.json
///   来源元数据），在库互斥锁里跑、传 `reloadEngine`，导入完引擎即看到。
///
/// 字节先落 `<data_dir>/tmp/` 下的暂存目录（与资源目录同盘），按上传配额边收边判
/// （[UploadStore.receiveToFile]）；导入成功才计入配额账本。暂存目录在所有出口都删。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/admin/upload_store.dart';
import 'package:fushi_server/src/commands/dict_commands.dart';
import 'package:fushi_server/src/dictionary_host.dart';
import 'package:fushi_server/src/server_language.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;

/// 导入接受的扩展名（WebUI 文件选择器的 `accept` 同一组）。
const List<String> kDictionaryImportExtensions = <String>[
  '.zip',
  '.fushidict',
  '.mdx',
  '.dsl',
];

/// 一次 WebUI 导入的结果。`.fushidict` 包不带词条数，[termCount] / [kanjiCount] 为 null。
typedef AdminDictionaryImportOutcome = ({
  String name,
  String format,
  String type,
  int? termCount,
  int? kanjiCount,
  bool replaced,
  String? language,
});

/// 内容判出来的包格式。
enum _DictPackageKind { fushidict, archive }

class AdminDictionaryImport {
  AdminDictionaryImport({
    required this.ctx,
    required this.uploads,
    DictArchiveImporter? importer,
  }) : _importer = importer;

  final AdminContext ctx;
  final UploadStore uploads;

  /// 原始词典包的原生导入器；null = 真原生库（`FushiDicts.importDictionary`）。测试注入。
  final DictArchiveImporter? _importer;

  Future<AdminDictionaryImportOutcome> run(shelf.Request request) async {
    final String fileName = _fileNameOf(request);
    final String ext = p.extension(fileName).toLowerCase();
    if (!kDictionaryImportExtensions.contains(ext)) {
      throw UploadRejected(
        415,
        tr(
          '不支持的文件类型「$fileName」：只收 .zip、.fushidict、.mdx、.dsl',
          'unsupported file type "$fileName": only .zip, .fushidict, .mdx and .dsl are accepted',
        ),
      );
    }
    await ctx.paths.temp.create(recursive: true);
    final Directory staging = await ctx.paths.temp.createTemp('dict_upload_');
    try {
      File staged = File(p.join(staging.path, fileName));
      final int bytes = await uploads.receiveToFile(
        target: staged,
        body: request.read(),
        declaredLength: request.contentLength ?? 0,
      );
      if (bytes == 0) {
        throw UploadRejected(400, tr('上传的文件是空的', 'the uploaded file is empty'));
      }
      final ({_DictPackageKind kind, String? name}) detected = _detect(
        staged,
        ext,
      );
      final AdminDictionaryImportOutcome outcome;
      switch (detected.kind) {
        case _DictPackageKind.fushidict:
          outcome = await _importPackage(staged, detected.name!);
        case _DictPackageKind.archive:
          // 原生导入器按扩展名分派：zip 内容一律以 .zip 交给它（改了扩展名的 zip
          // 否则会被当成 MDX / DSL 去解析）。
          if (_isZip(staged) && ext != '.zip') {
            staged = await staged.rename(
              p.join(
                staging.path,
                '${p.basenameWithoutExtension(fileName)}.zip',
              ),
            );
          }
          outcome = await _importArchive(staged);
      }
      await uploads.recordUsage(bytes);
      ctx.log.info(
        'dictionary import: "${outcome.name}" (${outcome.format}, '
        '${outcome.replaced ? 'replaced' : 'new'})',
      );
      return outcome;
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  /// `?filename=` 优先，其次 `X-Filename` 头（URL 编码）。只取最后一段，替换掉
  /// Windows 文件名里不合法的字符；空名 400。
  static String _fileNameOf(shelf.Request request) {
    String raw = request.url.queryParameters['filename'] ?? '';
    if (raw.isEmpty) {
      final String header = request.headers['x-filename'] ?? '';
      try {
        raw = Uri.decodeComponent(header);
      } on ArgumentError {
        raw = header;
      }
    }
    final String base = p.posix
        .basename(raw.replaceAll('\\', '/'))
        .replaceAll(RegExp(r'[<>:"|?*\x00-\x1f]'), '_')
        .trim();
    if (base.isEmpty || base == '.' || base == '..') {
      throw UploadRejected(
        400,
        tr(
          '缺少文件名（?filename= 或 X-Filename 头）',
          'missing file name (?filename= or the X-Filename header)',
        ),
      );
    }
    if (base.length > 200) {
      final String e = p.extension(base);
      return '${base.substring(0, 200 - e.length)}$e';
    }
    return base;
  }

  static bool _isZip(File file) {
    final RandomAccessFile raf = file.openSync();
    try {
      final List<int> head = raf.readSync(4);
      return head.length == 4 &&
          head[0] == 0x50 &&
          head[1] == 0x4B &&
          ((head[2] == 0x03 && head[3] == 0x04) ||
              (head[2] == 0x05 && head[3] == 0x06));
    } finally {
      raf.closeSync();
    }
  }

  /// 按内容判包格式；判不出来 400。`.fushidict` 同时带回 manifest 里的词典名。
  static ({_DictPackageKind kind, String? name}) _detect(
    File file,
    String ext,
  ) {
    if (!_isZip(file)) {
      if (ext == '.mdx' || ext == '.dsl') {
        return (kind: _DictPackageKind.archive, name: null);
      }
      throw UploadRejected(
        400,
        tr(
          '不是 zip 文件：$ext 应当是 zip 压缩包',
          'not a zip file: a $ext upload must be a zip archive',
        ),
      );
    }
    final InputFileStream input = InputFileStream(file.path);
    try {
      final Archive archive;
      try {
        archive = ZipDecoder().decodeBuffer(input);
      } on Object {
        throw UploadRejected(
          400,
          tr('zip 压缩包已损坏，读不出目录', 'the zip archive is corrupt'),
        );
      }
      final ArchiveFile? manifest = archive.findFile('manifest.json');
      if (manifest != null && manifest.isFile) {
        final String? name = _fushidictName(manifest);
        if (name != null) return (kind: _DictPackageKind.fushidict, name: name);
      }
      if (ext == '.fushidict') {
        throw UploadRejected(
          400,
          tr(
            '不是 Fushi 词典包：manifest.json 缺失或不是词典',
            'not a Fushi dictionary package: manifest.json is missing or is not a dictionary',
          ),
        );
      }
      final bool hasDictionary =
          archive.findFile('index.json') != null ||
          archive.files.any((ArchiveFile f) {
            final String n = f.name.toLowerCase();
            return f.isFile && (n.endsWith('.mdx') || n.endsWith('.ifo'));
          });
      if (!hasDictionary) {
        throw UploadRejected(
          400,
          tr(
            'zip 里没有词典（找不到 index.json、.mdx 或 .ifo）',
            'the zip contains no dictionary (no index.json, .mdx or .ifo)',
          ),
        );
      }
      return (kind: _DictPackageKind.archive, name: null);
    } finally {
      input.closeSync();
    }
  }

  /// `manifest.json` 是词典包时返回词典名（单段路径），否则 null。名字不安全 400。
  static String? _fushidictName(ArchiveFile manifest) {
    final Object? decoded;
    try {
      decoded = jsonDecode(
        utf8.decode(manifest.content as List<int>, allowMalformed: true),
      );
    } on FormatException {
      return null;
    }
    if (decoded is! Map || decoded['kind'] != 'dictionary') return null;
    final Object? dict = decoded['dictionary'];
    final Object? name = dict is Map ? dict['name'] : null;
    if (name is! String ||
        name.trim().isEmpty ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains('..')) {
      throw UploadRejected(
        400,
        tr('词典包里的词典名无效：$name', 'invalid dictionary name in the package: $name'),
      );
    }
    return name;
  }

  Future<DictionaryMetaRow?> _row(String name) async {
    for (final DictionaryMetaRow r in await ctx.db.getAllDictionaryMetadata()) {
      if (r.name == name) return r;
    }
    return null;
  }

  static String? _effectiveLanguage(DictionaryMetaRow row) {
    final String override = row.languageOverride?.trim() ?? '';
    if (override.isNotEmpty) return override;
    try {
      final Object? meta = jsonDecode(row.metadataJson);
      final Object? lang = meta is Map ? meta['sourceLanguage'] : null;
      if (lang is String && lang.trim().isNotEmpty) return lang.trim();
    } on FormatException {
      // 畸形 metadataJson：当没声明。
    }
    return null;
  }

  /// app 导出的 `.fushidict`：与互联推送同一条路径（库锁 + 释放映射 + 重载引擎）。
  Future<AdminDictionaryImportOutcome> _importPackage(
    File package,
    String name,
  ) async {
    final bool replaced = await _row(name) != null;
    await ctx.host.buildLibraryService().importDictionary(package);
    final DictionaryMetaRow? row = await _row(name);
    if (row == null) {
      throw StateError('dictionary "$name" missing after import');
    }
    return (
      name: name,
      format: 'fushidict',
      type: row.type,
      termCount: null,
      kanjiCount: null,
      replaced: replaced,
      language: _effectiveLanguage(row),
    );
  }

  /// 原始词典包：`dict add` 同一个导入函数，在库锁里跑、导入完重载引擎。
  Future<AdminDictionaryImportOutcome> _importArchive(File archive) async {
    _ensureImporterAvailable();
    DictImportOutcome? result;
    try {
      await ctx.host.runLibraryExclusive(() async {
        result = await importDictionaryArchive(
          db: ctx.db,
          resourceRoot: ctx.paths.dictionaryResources,
          archive: archive,
          importer: _importer,
          stagingParent: ctx.paths.temp,
          reloadEngine: () async => ctx.host.dictionaries?.refresh(),
        );
      });
    } on DictImportException catch (e) {
      throw UploadRejected(
        422,
        tr('导入失败：${e.message}', 'import failed: ${e.message}'),
      );
    }
    final DictImportOutcome r = result!;
    return (
      name: r.name,
      format: 'archive',
      type: r.type,
      termCount: r.termCount,
      kanjiCount: r.kanjiCount,
      replaced: r.replaced,
      language: r.language,
    );
  }

  /// 原生导入器就是词典引擎的原生库：引擎没起来就别收（503 带原因）。host 还没 start
  /// （只有测试会这样）时按 `dict add` 的办法现探一次。
  void _ensureImporterAvailable() {
    if (_importer != null) return;
    final ServerDictionaryHost? host = ctx.host.dictionaries;
    if (host != null) {
      if (host.available) return;
      throw UploadRejected(
        503,
        host.unavailableReason ??
            tr('词典引擎没有运行', 'the dictionary engine is not running'),
      );
    }
    final String? lib = resolveFushiDictsLibraryPath();
    FushiDicts.nativeLibraryPath = lib;
    try {
      FushiDicts.probeDictContent(ctx.paths.dictionaryResources.path);
    } catch (e) {
      throw UploadRejected(
        503,
        tr(
          '词典引擎原生库不可用（${lib ?? 'libfushidicts_ffi 裸名'}）：$e',
          'the dictionary engine native library is unavailable '
              '(${lib ?? 'bare libfushidicts_ffi name'}): $e',
        ),
      );
    }
  }
}
