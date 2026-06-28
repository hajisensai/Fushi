import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:path/path.dart' as path;

import 'package:hibiki/utils.dart';
import 'package:hibiki/src/models/dictionary_repository.dart';

class DictionaryImportManager {
  DictionaryImportManager({
    required DictionaryRepository dictRepo,
    required Directory resourceDirectory,
    required Map<String, DictionaryFormat> formats,
  })  : _dictRepo = dictRepo,
        _resourceDirectory = resourceDirectory,
        _formats = formats;

  final DictionaryRepository _dictRepo;
  final Directory _resourceDirectory;
  final Map<String, DictionaryFormat> _formats;

  DictionaryFormat detectFormat(File file) {
    final ext = path.extension(file.path).toLowerCase();
    if (ext == '.dsl') return _formats['abbyy_lingvo']!;
    if (ext == '.mdx') return _formats['mdict']!;
    if (ext == '.zip') {
      final fileNames = _readZipFileNames(file);

      if (fileNames.isEmpty) return _formats['yomichan']!;

      if (fileNames
          .any((f) => f == 'index.json' || f.endsWith('/index.json'))) {
        return _formats['yomichan']!;
      }
      if (fileNames.any((f) => f.endsWith('.mdx') || f.endsWith('.mdd'))) {
        return _formats['mdict']!;
      }
      if (fileNames.any((f) => f.endsWith('.json'))) {
        return _formats['migaku']!;
      }
      return _formats['yomichan']!;
    }
    throw Exception(t.import_unsupported_file_format(ext: ext));
  }

  DictionaryFormat detectFormatFromDirectory(Directory dir) {
    final indexFile = File(path.join(dir.path, 'index.json'));
    if (indexFile.existsSync()) return _formats['yomichan']!;
    final hasJson = dir
        .listSync()
        .whereType<File>()
        .any((f) => f.path.toLowerCase().endsWith('.json'));
    if (hasJson) return _formats['migaku']!;
    throw Exception(t.dictionary_unrecognized_format);
  }

  /// BUG-927：把一本词典的 native 导入结果摘要写进 [ErrorLogService]（错误日志页
  /// 可查）。成功但各类计数全为 0 通常意味着 native 端把所有 bank 解成空——这正是
  /// TODO-892 的 zip.cpp 压缩比守卫误杀合法 yomitan bank 时的症状——留下这条摘要后
  /// 「某本词典导入后没有词条」就能从日志直接定位，而不必逐本盲猜。
  void _logImportResultSummary(String source, HoshiImportResult result) {
    final int total = result.termCount +
        result.metaCount +
        result.freqCount +
        result.pitchCount +
        result.kanjiCount;
    ErrorLogService.instance.log(
      'DictImport.result',
      '$source success=${result.success} title="${result.title}" '
          'term=${result.termCount} meta=${result.metaCount} '
          'freq=${result.freqCount} pitch=${result.pitchCount} '
          'kanji=${result.kanjiCount} media=${result.mediaCount} '
          'total=$total'
          '${result.error.isNotEmpty ? ' error=${result.error}' : ''}'
          '${result.success && total == 0 ? ' [WARN:0 entries imported]' : ''}',
    );
  }

  Future<void> importFromDirectory({
    required Directory directory,
    required ValueNotifier<String> progressNotifier,
    required ValueNotifier<int?> countNotifier,
    required ValueNotifier<int?> totalNotifier,
    required Function() onImportSuccess,
    required bool lowMemoryMode,
    VoidCallback? onMemoryError,
  }) async {
    final entities = directory.listSync();
    final zipFiles = entities.whereType<File>().where((f) {
      final ext = path.extension(f.path).toLowerCase();
      return ext == '.zip' || ext == '.dsl' || ext == '.mdx';
    }).toList();

    if (zipFiles.isNotEmpty) {
      final cssFiles = entities
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.css'))
          .toList();
      final fontDirs = <Directory>[];
      for (final d in entities.whereType<Directory>()) {
        try {
          final hasFont = d.listSync().whereType<File>().any((f) {
            final ext = path.extension(f.path).toLowerCase();
            return ext == '.otf' ||
                ext == '.ttf' ||
                ext == '.woff' ||
                ext == '.woff2';
          });
          if (hasFont) fontDirs.add(d);
        } catch (e, stack) {
          ErrorLogService.instance.log('DictImport.scanFontDir', e, stack);
          debugPrint('[Hibiki] error scanning font dir ${d.path}: $e');
        }
      }

      totalNotifier.value = zipFiles.length;
      final List<String> failedNames = [];
      for (int i = 0; i < zipFiles.length; i++) {
        countNotifier.value = i + 1;
        try {
          await importFromFile(
            file: zipFiles[i],
            progressNotifier: progressNotifier,
            cssFiles: cssFiles,
            fontDirs: fontDirs,
            onImportSuccess: onImportSuccess,
            lowMemoryMode: lowMemoryMode,
            onMemoryError: onMemoryError,
          );
        } catch (e, stack) {
          ErrorLogService.instance.log('DictImport.importZip', e, stack);
          failedNames.add(path.basenameWithoutExtension(zipFiles[i].path));
        }
      }
      if (failedNames.isNotEmpty) {
        HibikiToast.show(
            msg: formatImportFailureSummary(failedNames),
            toastLength: Toast.LENGTH_LONG);
      }
      // TODO-082：成功导入数 = 总数 - 失败数；> 0 给一条明确成功提示，与失败汇总
      // 可同时出现（部分成功部分失败）。
      final int succeeded = zipFiles.length - failedNames.length;
      if (succeeded > 0) {
        HibikiToast.show(msg: t.dict_import_success_summary(n: succeeded));
      }
      return;
    }

    // TODO-379：到这里说明目录里没有 .zip/.dsl/.mdx 词典包，下面会把整个目录
    // 递归打包成一个 zip 喂给 native（yomichan 散文件 / migaku JSON 目录路径）。
    // 但用户可能选错目录——里头只有 QQ 下载的 `.conf` 等无关文件、没有任何词典
    // 主文件（index.json / *.json）。旧实现会无脑把无关文件打包后再让 native 报一句含糊的 import_failed。
    // 先做一次递归预检：目录里压根没有可识别的词典主文件时，直接抛明确的
    // 「无法识别的词典格式」，让用户知道是选错了目录而非 app 坏了。预检与 packDirectoryToZip
    // 同样递归，故子目录里的词典不会被误杀。
    if (!directoryContainsImportableDictionary(directory)) {
      throw Exception(t.dictionary_unrecognized_format);
    }

    _dictRepo.clearDictionaryResultsCache();

    try {
      progressNotifier.value = t.import_extract;

      final tempZipPath =
          path.join(_resourceDirectory.path, 'import_temp_dir.zip');
      final tempZip = File(tempZipPath);

      // 把整个目录读进内存再 zip 压缩是纯文件操作但很重（大词典目录可达数百
      // MB），若在主 isolate 同步跑会卡死 UI（TODO-082）。参数都是 String 路径，
      // 可安全丢进后台 isolate，让 UI 在打包期保持响应。native FFI 导入本就在
      // 自己的 isolate（HoshiDicts.importDictionary）。
      await Isolate.run(() => packDirectoryToZip(directory.path, tempZipPath));

      try {
        final tempOutputDir =
            Directory(path.join(_resourceDirectory.path, 'import_temp'));
        if (tempOutputDir.existsSync()) {
          tempOutputDir.deleteSync(recursive: true);
        }
        tempOutputDir.createSync(recursive: true);

        ErrorLogService.instance
            .markImportStart('native 词典导入(目录)未返回：${directory.path}');
        final HoshiImportResult result;
        try {
          result = await importDictionaryViaHoshidicts(
            zipPath: tempZipPath,
            outputDir: tempOutputDir.path,
            breadcrumbDir: ErrorLogService.instance.importStepBreadcrumbDir,
          );
        } finally {
          ErrorLogService.instance.markImportEnd();
        }
        // BUG-927：记每本导入的结果摘要（标题 + 各类计数）。零计数 + success
        // 说明 native 把 bank 解空了（曾被 zip.cpp 压缩比守卫误杀），这里留痕即可
        // 一眼定位「哪本被吞空」而不必猜。
        _logImportResultSummary('dir:${directory.path}', result);

        if (!result.success) {
          throw Exception(
              result.error.isNotEmpty ? result.error : t.import_failed);
        }

        final name = _sanitizeTitle(result.title);
        progressNotifier.value = t.import_name(name: name);

        final UpdateDecision decision = _decideUpdate(name, force: false);
        if (decision == UpdateDecision.alreadyUpToDate) {
          progressNotifier.value = t.import_duplicate(name: name);
          await Future.delayed(const Duration(seconds: 2));
          if (tempOutputDir.existsSync()) {
            tempOutputDir.deleteSync(recursive: true);
          }
          return;
        }

        final int order;
        Dictionary? preservedSettings;
        if (decision == UpdateDecision.replaceOldVersion ||
            decision == UpdateDecision.replaceExact) {
          final Dictionary existing = decision == UpdateDecision.replaceExact
              ? _dictRepo.dictionaries
                  .firstWhere((Dictionary d) => d.name == name)
              : _dictRepo.findUpdatable(name)!;
          order = existing.order;
          preservedSettings = existing;
          final oldDir =
              Directory(path.join(_resourceDirectory.path, existing.name));
          if (oldDir.existsSync()) oldDir.deleteSync(recursive: true);
          await _dictRepo.deleteDictionaryMeta(existing.name);
        } else {
          order = _nextOrder();
        }

        final innerDataDir = Directory(path.join(tempOutputDir.path, name));
        final finalDir = Directory(path.join(_resourceDirectory.path, name));
        _validatePath(finalDir);
        if (finalDir.existsSync()) finalDir.deleteSync(recursive: true);

        if (innerDataDir.existsSync()) {
          await _publishImportedDir(innerDataDir, finalDir.path);
        } else {
          await _publishImportedDir(tempOutputDir, finalDir.path);
        }
        if (tempOutputDir.existsSync()) {
          tempOutputDir.deleteSync(recursive: true);
        }

        final detectedType = _parseType(result.detectedType);
        _dictRepo.persistDictionary(Dictionary(
          order: order,
          name: name,
          formatKey: 'yomichan',
          type: detectedType,
          // TODO-609 来源 metadata + TODO-622 混合词典也进 kanji 桶(add_term+add_kanji)。
          metadata: <String, String>{
            ...readSourceMetadataFromIndex(finalDir),
            if (result.kanjiCount > 0) 'hasKanji': 'true',
          },
          hiddenLanguages: preservedSettings?.hiddenLanguages ?? const [],
          collapsedLanguages: preservedSettings?.collapsedLanguages ?? const [],
        ));

        progressNotifier.value = t.import_complete;
        onImportSuccess();
        // TODO-082：单目录导入成功，给一条明确成功提示（与文件/批量路径一致）。
        HibikiToast.show(msg: t.dict_import_success_summary(n: 1));
      } finally {
        if (tempZip.existsSync()) tempZip.deleteSync();
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('DictImport(dir)', e, stack);
      // BUG-082: do not block 3s per failure; signal the memory case once and
      // rethrow so the caller can report the failure.
      final bool mem = _isMemoryError(e) && !lowMemoryMode;
      if (mem) onMemoryError?.call();
      throw DictionaryImportException(e, isMemoryError: mem);
    }
  }

  Future<void> importFromFile({
    required File file,
    required ValueNotifier<String> progressNotifier,
    required Function() onImportSuccess,
    required bool lowMemoryMode,
    List<File> cssFiles = const [],
    List<Directory> fontDirs = const [],
    VoidCallback? onMemoryError,
    // TODO-609：强制重导（在线更新走这条）。true 时完全同名走 replaceExact 而非
    // alreadyUpToDate 跳过；默认 false，普通拖入/导入同名仍跳过（现有语义不破）。
    bool forceReplaceExisting = false,
    // TODO-609：在线下载来源回填（catalog 的 url 当 downloadUrl/indexUrl）。导入后
    // 与 readSourceMetadataFromIndex 合并落进 Dictionary.metadata；index.json 的
    // 真值优先覆盖，缺失字段由本 override 补上。默认 null（本地导入不带来源）。
    Map<String, String>? sourceOverride,
  }) async {
    _dictRepo.clearDictionaryResultsCache();

    try {
      progressNotifier.value = t.import_extract;
      await Future<void>.delayed(Duration.zero);

      final tempOutputDir =
          Directory(path.join(_resourceDirectory.path, 'import_temp'));
      if (tempOutputDir.existsSync()) {
        tempOutputDir.deleteSync(recursive: true);
      }
      tempOutputDir.createSync(recursive: true);

      ErrorLogService.instance.markImportStart('native 词典导入未返回：${file.path}');
      final HoshiImportResult result;
      try {
        result = await importDictionaryViaHoshidicts(
          zipPath: file.path,
          outputDir: tempOutputDir.path,
          breadcrumbDir: ErrorLogService.instance.importStepBreadcrumbDir,
        );
      } finally {
        ErrorLogService.instance.markImportEnd();
      }
      // BUG-927：记每本导入结果摘要（见上 dir 路径同名 helper 的说明）。
      _logImportResultSummary('file:${file.path}', result);

      if (!result.success) {
        throw Exception(
            result.error.isNotEmpty ? result.error : t.import_failed);
      }

      final name = _sanitizeTitle(result.title);
      progressNotifier.value = t.import_name(name: name);

      final UpdateDecision decision =
          _decideUpdate(name, force: forceReplaceExisting);
      if (decision == UpdateDecision.alreadyUpToDate) {
        progressNotifier.value = t.import_duplicate(name: name);
        await Future.delayed(const Duration(seconds: 2));
        if (tempOutputDir.existsSync()) {
          tempOutputDir.deleteSync(recursive: true);
        }
        return;
      }

      final int order;
      Dictionary? preservedSettings;
      if (decision == UpdateDecision.replaceOldVersion ||
          decision == UpdateDecision.replaceExact) {
        final Dictionary existing = decision == UpdateDecision.replaceExact
            ? _dictRepo.dictionaries
                .firstWhere((Dictionary d) => d.name == name)
            : _dictRepo.findUpdatable(name)!;
        order = existing.order;
        preservedSettings = existing;
        final oldDir =
            Directory(path.join(_resourceDirectory.path, existing.name));
        if (oldDir.existsSync()) oldDir.deleteSync(recursive: true);
        await _dictRepo.deleteDictionaryMeta(existing.name);
      } else {
        order = _nextOrder();
      }

      final innerDataDir = Directory(path.join(tempOutputDir.path, name));
      final finalDir = Directory(path.join(_resourceDirectory.path, name));
      _validatePath(finalDir);
      if (finalDir.existsSync()) finalDir.deleteSync(recursive: true);

      if (innerDataDir.existsSync()) {
        await _publishImportedDir(innerDataDir, finalDir.path);
      } else {
        await _publishImportedDir(tempOutputDir, finalDir.path);
      }
      if (tempOutputDir.existsSync()) {
        tempOutputDir.deleteSync(recursive: true);
      }

      for (final css in cssFiles) {
        if (css.existsSync()) {
          css.copySync(path.join(finalDir.path, path.basename(css.path)));
        }
      }
      for (final fontDir in fontDirs) {
        if (fontDir.existsSync()) {
          _copyDirectory(fontDir,
              Directory(path.join(finalDir.path, path.basename(fontDir.path))));
        }
      }

      final detectedType = _parseType(result.detectedType);
      // TODO-609：合并来源。revision **永远**取自本地导入包的 index.json（实际装的
      // 是哪个版本，才是后续比对的本地基准）；来源身份字段（isUpdatable/indexUrl/
      // downloadUrl）则优先用 [sourceOverride]——它是我们从在线 catalog / 更新链路
      // 拿到的权威来源，胜过包内 index.json 的字段。这修掉「包内 index.json 不声明
      // isUpdatable（很多 yomitan 包不带）→ 写回成 false → 更新一次后丢失可更新性、
      // 按钮消失无法二次更新」的缺口（W-2）：sourceOverride 带 isUpdatable:'true' 时
      // 它必须压过包内的 false。sourceOverride 不携带 revision（强制以本地包为准）。
      final Map<String, String> metadata = mergeSourceMetadata(
        readSourceMetadataFromIndex(finalDir),
        sourceOverride,
      );
      _dictRepo.persistDictionary(Dictionary(
        order: order,
        name: name,
        formatKey: 'yomichan',
        type: detectedType,
        // TODO-622: 混合词典也进 kanji 桶(叠加 609 的来源 metadata)。
        metadata: <String, String>{
          ...metadata,
          if (result.kanjiCount > 0) 'hasKanji': 'true',
        },
        hiddenLanguages: preservedSettings?.hiddenLanguages ?? const [],
        collapsedLanguages: preservedSettings?.collapsedLanguages ?? const [],
      ));

      progressNotifier.value = t.import_complete;
      onImportSuccess();
    } catch (e, stack) {
      ErrorLogService.instance.log('DictImport(file)', e, stack);
      // BUG-082: do not block 3s per failed dictionary. Signal the memory case
      // once and rethrow a typed exception so the batch caller can collect the
      // failure and show a single summary at the end.
      final bool mem = _isMemoryError(e) && !lowMemoryMode;
      if (mem) onMemoryError?.call();
      throw DictionaryImportException(e, isMemoryError: mem);
    }
  }

  // ── private helpers ──────────────────────────────────────────────────

  int _nextOrder() {
    final dicts = _dictRepo.dictionaries;
    if (dicts.isEmpty) return 1;
    return dicts.map((d) => d.order).reduce((a, b) => a > b ? a : b) + 1;
  }

  void _validatePath(Directory dir) {
    if (!path.isWithin(_resourceDirectory.path, dir.path)) {
      throw Exception('Invalid dictionary title: path traversal detected');
    }
  }

  List<String> _readZipFileNames(File file) {
    try {
      final input = InputFileStream(file.path);
      final dir = ZipDirectory.read(input);
      final names = dir.fileHeaders
          .map((h) => h.filename)
          .where((n) => n.isNotEmpty)
          .map((n) => n.toLowerCase())
          .toList();
      input.closeSync();
      return names;
    } catch (e, stack) {
      ErrorLogService.instance.log('DictImport.readZipNames', e, stack);
      return [];
    }
  }

  static String _sanitizeTitle(String raw) {
    final cleaned = path.basename(raw.trim()).replaceAll(RegExp(r'[/\\]'), '_');
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
      throw Exception('Dictionary title is empty');
    }
    return cleaned;
  }

  /// TODO-839：在**不导入**的前提下，从一个 yomitan zip 包里廉价探出 `index.json`
  /// 的 `title`，供「从文件重选覆盖更新」在导入前判断新旧包是否同名（异名时弹确认，
  /// 避免 [decideUpdate] 把异名包静默改判成新增导入、原词典原封不动留着的语义陷阱）。
  ///
  /// 只解压 zip 里**唯一一个** `index.json` entry 并解析 title，不解压全量、不落盘、
  /// 不改任何状态——纯函数（仅依赖入参 [File] 与磁盘只读）。
  ///
  /// 仅支持 yomitan zip：dsl/mdx 的 title 不在 index.json（要等 native 导入后才知道），
  /// 廉价 peek 拿不到 → 返回 null（调用方退化为纯 force 重导，不弹异名确认）。坏包 /
  /// 无 index.json / title 缺失也返回 null。
  static String? peekDictionaryTitle(File file) {
    if (path.extension(file.path).toLowerCase() != '.zip') return null;
    try {
      final InputFileStream input = InputFileStream(file.path);
      try {
        final ZipDirectory dir = ZipDirectory.read(input);
        ZipFileHeader? indexHeader;
        for (final ZipFileHeader header in dir.fileHeaders) {
          final String name = header.filename.toLowerCase();
          if (name == 'index.json' || name.endsWith('/index.json')) {
            indexHeader = header;
            break;
          }
        }
        final ZipFile? entry = indexHeader?.file;
        if (entry == null) return null;
        final dynamic decoded = jsonDecode(utf8.decode(entry.content));
        if (decoded is! Map) return null;
        final dynamic title = decoded['title'];
        if (title is! String) return null;
        final String trimmed = title.trim();
        return trimmed.isEmpty ? null : _sanitizeTitle(trimmed);
      } finally {
        input.closeSync();
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('DictImport.peekTitle', e, stack);
      return null;
    }
  }

  static DictionaryType _parseType(String type) {
    switch (type) {
      case 'frequency':
        return DictionaryType.frequency;
      case 'pitch':
        return DictionaryType.pitch;
      case 'kanji':
        return DictionaryType.kanji;
      default:
        return DictionaryType.term;
    }
  }

  /// 判断 [dir] 目录（含任意层子目录）里是否存在可被 native 导入的词典主文件。
  ///
  /// TODO-379：「导入文件夹词典」走整目录打包时，旧实现不做任何预检——哪怕目录里
  /// 只有 QQ 下载的随机名 `.conf` 等无关文件、没有任何词典，也照样打包丢给 native，
  /// 让用户看到一句含糊的「导入失败」。这里复用与 native yomichan / migaku 导入器
  /// 一致的判据（顶层或任意子目录里有 `index.json`，或存在任意 `.json` 文件即视为
  /// 词典 JSON 集合），把「目录里没有词典」变成一个可明确诊断的正常情况，而非交给
  /// native 去含糊报错。递归扫描，与 [packDirectoryToZip] 的 `recursive: true`
  /// 打包范围对齐，故子目录里的 yomitan/migaku 词典不会被误判为「无词典」。
  /// 扫描期单个目录不可读（权限等）按「该子树无词典」处理，不抛异常。
  @visibleForTesting
  static bool directoryContainsImportableDictionary(Directory dir) {
    final List<FileSystemEntity> entities;
    try {
      entities = dir.listSync(recursive: true);
    } on FileSystemException {
      return false;
    }
    for (final FileSystemEntity entity in entities) {
      if (entity is! File) continue;
      final String lower = path.basename(entity.path).toLowerCase();
      if (lower == 'index.json' || lower.endsWith('.json')) {
        return true;
      }
    }
    return false;
  }

  /// 把 [srcDirPath] 目录递归打包成 [zipPath] 处的 zip 文件。**纯路径输入/纯文件
  /// 输出**，不触碰任何实例状态，可安全在后台 isolate 经 [Isolate.run] 执行
  /// （TODO-082：避免大目录的同步读取+压缩卡死主 isolate）。暴露给测试以在 host
  /// 上验证打包正确性（无需 native FFI）。
  @visibleForTesting
  static void packDirectoryToZip(String srcDirPath, String zipPath) {
    final Directory directory = Directory(srcDirPath);
    final Archive archive = Archive();
    for (final FileSystemEntity entity in directory.listSync(recursive: true)) {
      if (entity is File) {
        final String relativePath =
            path.relative(entity.path, from: directory.path);
        archive.addFile(ArchiveFile(
            relativePath, entity.lengthSync(), entity.readAsBytesSync()));
      }
    }
    File(zipPath).writeAsBytesSync(ZipEncoder().encode(archive)!);
  }

  static void _copyDirectory(Directory source, Directory destination) {
    destination.createSync(recursive: true);
    for (final entity in source.listSync()) {
      final newPath = path.join(destination.path, path.basename(entity.path));
      if (entity is File) {
        entity.copySync(newPath);
      } else if (entity is Directory) {
        _copyDirectory(entity, Directory(newPath));
      }
    }
  }

  static Future<void> _copyDirectoryAsync(
      Directory source, Directory destination) async {
    await destination.create(recursive: true);
    await for (final entity in source.list()) {
      final newPath = path.join(destination.path, path.basename(entity.path));
      if (entity is File) {
        await entity.copy(newPath);
      } else if (entity is Directory) {
        await _copyDirectoryAsync(entity, Directory(newPath));
      }
    }
  }

  /// 把已导入的词典目录从暂存区 [source] 发布到最终路径 [destPath]。
  ///
  /// Windows Defender / 搜索索引器会在文件刚落盘后异步打开扫描、短暂持有句柄，
  /// 致紧接着的目录 rename（`MoveFileExW`）报 ERROR_ACCESS_DENIED(5) 或
  /// SHARING_VIOLATION(32)（BUG-050）。这是**不可控的外部平台行为**（无法阻止
  /// AV/索引器扫描刚写入的文件），故对 rename 做有界重试；用尽后回退「递归复制+删源」
  /// （copy 用共享读打开源文件，容忍扫描句柄）。POSIX 下 rename 一次即成功、不触发
  /// 重试分支。本进程自身的 native 句柄在 `import_` 返回时已关闭（RAII），故非同进程
  /// 句柄泄漏——间歇性失败(4/14)证实锁来自外部、可经重试规避。
  Future<void> _publishImportedDir(Directory source, String destPath) {
    return publishImportedDir(
      rename: () => source.rename(destPath),
      copyThenDelete: () async {
        await _copyDirectoryAsync(source, Directory(destPath));
        try {
          await source.delete(recursive: true);
        } catch (_) {
          // 删源失败留下的残留 temp 由下一轮 import 的 import_temp 清理覆盖。
        }
      },
      sleep: (ms) => Future<void>.delayed(Duration(milliseconds: ms)),
      isWindows: Platform.isWindows,
    );
  }

  /// [_publishImportedDir] 的纯逻辑核心，依赖项全部注入便于测试。
  /// 仅当 [isWindows] 且 OS 错误码为瞬时锁（5/32）时重试；用尽 [maxAttempts]
  /// 后调 [copyThenDelete] 回退。其余错误（非 Windows、或非瞬时码）原样抛出。
  @visibleForTesting
  static Future<DictPublishMethod> publishImportedDir({
    required Future<void> Function() rename,
    required Future<void> Function() copyThenDelete,
    required Future<void> Function(int delayMs) sleep,
    required bool isWindows,
    int maxAttempts = 10,
  }) async {
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await rename();
        return DictPublishMethod.renamed;
      } on FileSystemException catch (e) {
        final int? code = e.osError?.errorCode;
        final bool transient = isWindows && (code == 5 || code == 32);
        if (!transient) rethrow;
        if (attempt == maxAttempts) {
          await copyThenDelete();
          return DictPublishMethod.copied;
        }
        await sleep(50 * attempt); // 退避：50ms,100ms,… 给 AV 扫描窗口让路
      }
    }
    return DictPublishMethod.renamed; // 不可达：循环内必返回或抛出
  }

  UpdateDecision _decideUpdate(String newName, {required bool force}) {
    return decideUpdate(
      hasExactName: _dictRepo.hasDictionaryNamed(newName),
      hasUpdatableVersion: _dictRepo.findUpdatable(newName) != null,
      force: force,
    );
  }

  /// [_decideUpdate] 的纯逻辑核心（依赖全部入参注入，便于测试）。
  ///
  /// 完全同名优先：命中则按 [force] 区分 [UpdateDecision.replaceExact]（强制更新
  /// 重导）/ [UpdateDecision.alreadyUpToDate]（普通导入跳过，TODO-609 前的现有语义）。
  /// 否则若存在同 base 名的不同日期版本 → [UpdateDecision.replaceOldVersion]（与
  /// [force] 无关，旧行为）。都不命中 → [UpdateDecision.newDictionary]。
  @visibleForTesting
  static UpdateDecision decideUpdate({
    required bool hasExactName,
    required bool hasUpdatableVersion,
    required bool force,
  }) {
    if (hasExactName) {
      return force
          ? UpdateDecision.replaceExact
          : UpdateDecision.alreadyUpToDate;
    }
    if (hasUpdatableVersion) return UpdateDecision.replaceOldVersion;
    return UpdateDecision.newDictionary;
  }

  /// TODO-609 / W-2：合并词典来源元数据。[fromIndex] 是导入包内 index.json 提取的
  /// 真值（[readSourceMetadataFromIndex]），[sourceOverride] 是在线 catalog / 更新
  /// 链路提供的权威来源身份。
  ///
  /// 规则：
  /// - `revision` **永远**取 [fromIndex]（实际装的是哪个版本，才是本地比对基准）；
  ///   [sourceOverride] 携带的 revision 一律忽略。
  /// - 来源身份字段（`isUpdatable`/`indexUrl`/`downloadUrl`）优先 [sourceOverride]
  ///   （它压过包内字段），缺失时回退包内 [fromIndex]。
  ///
  /// 这修掉「包内 index.json 不声明 isUpdatable（很多 yomitan 包不带）→ glaze 写回
  /// 成 false → 更新一次后丢失可更新性、按钮消失无法二次更新」的缺口：更新链路传
  /// `isUpdatable:'true'` 的 override 必须压过包内的 false。
  @visibleForTesting
  static Map<String, String> mergeSourceMetadata(
    Map<String, String> fromIndex,
    Map<String, String>? sourceOverride,
  ) {
    final Map<String, String> override =
        Map<String, String>.from(sourceOverride ?? const <String, String>{})
          ..remove('revision');
    return <String, String>{...fromIndex, ...override};
  }

  static bool _isMemoryError(Object e) {
    final msg = e.toString().toLowerCase();
    return e is OutOfMemoryError || msg.contains('out of memory');
  }

  /// 批量导入结束后，把失败的词典名汇总成一条提示文案（单条/多条不同措辞）。
  /// 供文件批量与目录批量两条路径复用，统一在循环结束后一次性展示（BUG-082）。
  static String formatImportFailureSummary(List<String> failedNames) {
    if (failedNames.length == 1) {
      return '${t.srt_import_error}: ${failedNames.first}';
    }
    return '${t.dict_import_failed_summary(n: failedNames.length)}\n'
        '${failedNames.join(', ')}';
  }
}

/// TODO-609：导入时对「同名/同 base 名词典已存在」的决策。
/// - [newDictionary]：全新词典，正常追加。
/// - [alreadyUpToDate]：完全同名且非强制 → 跳过（普通拖入同名的现有语义，不破）。
/// - [replaceExact]：完全同名且强制更新 → 走 replaceOldVersion 链路重导带新 revision。
/// - [replaceOldVersion]：不同日期版本（base 名同、全名不同）→ 删旧版重导。
enum UpdateDecision {
  newDictionary,
  alreadyUpToDate,
  replaceExact,
  replaceOldVersion,
}

/// 单本词典导入失败时抛出的类型化异常，携带「是否内存不足」标志。
///
/// BUG-082：旧实现在每个失败项的 catch 里 `Future.delayed(3s)` 阻塞、且**不**
/// 重抛，导致批量导入逐个卡 3 秒、上层无法汇总。改为不阻塞、抛出本异常，由
/// 批量调用方收集失败项并在循环结束后统一展示，内存不足提示也只触发一次。
class DictionaryImportException implements Exception {
  DictionaryImportException(this.cause, {this.isMemoryError = false});

  final Object cause;
  final bool isMemoryError;

  @override
  String toString() => cause.toString();
}

/// [DictionaryImportManager.publishImportedDir] 的发布方式：直接 rename 成功，
/// 或重试用尽后回退到复制+删源。
enum DictPublishMethod { renamed, copied }
