/// admin API 的词典导入（`PUT /api/admin/dictionaries`，见 admin_dictionaries.dart）：
/// WebUI「词典」页上传一个词典包，在运行中的 serve 里导入并立即进引擎（不用重启）。
///
/// 协议：请求体是文件原始字节（不分块）。文件名可选，放在 `?filename=<名字>`（或
/// `X-Filename` 头，URL 编码），只用来认格式（扩展名）与交给原生导入器（MDX / DSL 按
/// 扩展名分派），不进任何库目录。不带文件名 = Yomitan zip（#3102 起的原始契约）。
///
/// 两种包，按内容判（扩展名只做初筛）：
/// - **app 导出的 `.fushidict`**：zip 根目录 `manifest.json` 的 `kind` 是 `dictionary`。
///   走 `LocalLibraryHostService.importDictionary`——与互联推送同一条路径（库互斥锁、
///   释放映射、收尾重载引擎）。
/// - **原始词典包**：Yomitan zip（根目录 `index.json`）、含 `.mdx` / `.ifo` 的 zip、
///   裸 `.mdx` / `.dsl`。走 `dict add` 同一个 [importDictionaryArchive]（记 index.json
///   来源元数据），装进库那一步走调用方给的 `installGuard`（库锁 + 释放映射 + 重载引擎）。
///
/// 字节先落 `<data_dir>/tmp/` 下的暂存目录（与资源目录同盘）。给了 [UploadStore] 时按
/// 上传配额边收边判（[UploadStore.receiveToFile]），导入成功才计入配额账本。暂存目录在
/// 所有出口都删。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/utils/misc/safe_file_name.dart';
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
    required DictInstallGuard installGuard,
    this.uploads,
    DictArchiveImporter? importer,
  }) : _installGuard = installGuard,
       _importer = importer;

  final AdminContext ctx;

  /// 上传配额账本；null = 不计配额（只有单测这样构造）。
  final UploadStore? uploads;

  /// 装进库那一步的包装（库锁 + 释放引擎映射 + 收尾重载引擎），由
  /// [AdminDictionaries] 给，与其它词典改动同一把锁。
  final DictInstallGuard _installGuard;

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
      final UploadStore? quota = uploads;
      final int bytes = quota != null
          ? await quota.receiveToFile(
              target: staged,
              body: request.read(),
              declaredLength: request.contentLength ?? 0,
            )
          : await _receive(staged, request.read());
      if (bytes == 0) {
        throw UploadRejected(400, tr('上传的文件是空的', 'empty upload'));
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
      await quota?.recordUsage(bytes);
      ctx.log.info(
        'dictionary import: "${outcome.name}" (${outcome.format}, '
        '${outcome.replaced ? 'replaced' : 'new'})',
      );
      return outcome;
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  /// 不计配额地把正文落到 [target]，返回字节数。
  static Future<int> _receive(File target, Stream<List<int>> body) async {
    await target.parent.create(recursive: true);
    final IOSink sink = target.openWrite();
    int written = 0;
    try {
      await for (final List<int> chunk in body) {
        sink.add(chunk);
        written += chunk.length;
      }
    } finally {
      await sink.close();
    }
    return written;
  }

  /// `?filename=` 优先，其次 `X-Filename` 头（URL 编码）。只取最后一段，替换掉
  /// Windows 文件名里不合法的字符。都没给 = `upload.zip`（#3102 的原始契约：正文是
  /// Yomitan zip）；给了却清洗成空名 400。
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
    if (raw.isEmpty) return 'upload.zip';
    final String base = p.posix
        .basename(raw.replaceAll('\\', '/'))
        .replaceAll(windowsUnsafeFileNameChars, '_')
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
      // 裸 MDX / DSL；`.zip` 却不是 zip 时也交给原生导入器，由它报 422（与 #3102 的
      // 原始契约一致：认不出的包是「导入失败」，不是「请求不对」）。
      if (ext != '.fushidict') {
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
    if (name is! String || !_isSafeDictionaryName(name)) {
      throw UploadRejected(
        400,
        tr('词典包里的词典名无效：$name', 'invalid dictionary name in the package: $name'),
      );
    }
    return name;
  }

  /// 词典名要当目录名用：只拒空 / `.` / `..`、含路径分隔符或 NUL 的名字；
  /// `Dict..v2` 这类合法名放行。
  static bool _isSafeDictionaryName(String name) {
    if (name.trim().isEmpty || name == '.' || name == '..') return false;
    if (name.contains('/') || name.contains(r'\') || name.contains('\x00')) {
      return false;
    }
    return p.posix.basename(name) == name && p.windows.basename(name) == name;
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
    await ctx.host.libraryService.importDictionary(package);
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

  /// 原始词典包：`dict add` 同一个导入函数，装进库那一步走 [_installGuard]。
  Future<AdminDictionaryImportOutcome> _importArchive(File archive) async {
    _ensureImporterAvailable();
    final DictImportOutcome r;
    try {
      r = await importDictionaryArchive(
        db: ctx.db,
        resourceRoot: ctx.paths.dictionaryResources,
        archive: archive,
        importer: _importer,
        stagingParent: ctx.paths.temp,
        installGuard: _installGuard,
      );
    } on DictImportException catch (e) {
      throw UploadRejected(422, e.message);
    }
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

  /// 原生导入器就是词典引擎的原生库：引擎没加载时导入必然失败，先说清原因（409），
  /// 免得交给导入器才报一句「找不到符号」。`.fushidict` 不经原生导入器，不受此限。
  void _ensureImporterAvailable() {
    if (_importer != null) return;
    final ServerDictionaryHost? engine = ctx.host.dictionaries;
    if (engine?.available ?? false) return;
    throw UploadRejected(
      409,
      'dictionary engine unavailable: '
      '${engine?.unavailableReason ?? 'the interconnect host is not running'}',
    );
  }
}
