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
          );
        } finally {
          ErrorLogService.instance.markImportEnd();
        }

        if (!result.success) {
          throw Exception(
              result.error.isNotEmpty ? result.error : t.import_failed);
        }

        final name = _sanitizeTitle(result.title);
        progressNotifier.value = t.import_name(name: name);

        final _UpdateDecision decision = _decideUpdate(name);
        if (decision == _UpdateDecision.alreadyUpToDate) {
          progressNotifier.value = t.import_duplicate(name: name);
          await Future.delayed(const Duration(seconds: 2));
          if (tempOutputDir.existsSync()) {
            tempOutputDir.deleteSync(recursive: true);
          }
          return;
        }

        final int order;
        Dictionary? preservedSettings;
        if (decision == _UpdateDecision.replaceOldVersion) {
          final Dictionary existing = _dictRepo.findUpdatable(name)!;
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
          // TODO-622: a mixed dictionary classifies as term (word lookup is
          // primary) but still carries kanji records. Record that so the bucket
          // router also registers it as a kanji dict (add_term + add_kanji).
          metadata:
              result.kanjiCount > 0 ? const {'hasKanji': 'true'} : const {},
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
        );
      } finally {
        ErrorLogService.instance.markImportEnd();
      }

      if (!result.success) {
        throw Exception(
            result.error.isNotEmpty ? result.error : t.import_failed);
      }

      final name = _sanitizeTitle(result.title);
      progressNotifier.value = t.import_name(name: name);

      final _UpdateDecision decision = _decideUpdate(name);
      if (decision == _UpdateDecision.alreadyUpToDate) {
        progressNotifier.value = t.import_duplicate(name: name);
        await Future.delayed(const Duration(seconds: 2));
        if (tempOutputDir.existsSync()) {
          tempOutputDir.deleteSync(recursive: true);
        }
        return;
      }

      final int order;
      Dictionary? preservedSettings;
      if (decision == _UpdateDecision.replaceOldVersion) {
        final Dictionary existing = _dictRepo.findUpdatable(name)!;
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
      _dictRepo.persistDictionary(Dictionary(
        order: order,
        name: name,
        formatKey: 'yomichan',
        type: detectedType,
        // TODO-622: a mixed dictionary classifies as term (word lookup is
        // primary) but still carries kanji records. Record that so the bucket
        // router also registers it as a kanji dict (add_term + add_kanji).
        metadata: result.kanjiCount > 0 ? const {'hasKanji': 'true'} : const {},
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

  _UpdateDecision _decideUpdate(String newName) {
    if (_dictRepo.hasDictionaryNamed(newName)) {
      return _UpdateDecision.alreadyUpToDate;
    }
    if (_dictRepo.findUpdatable(newName) != null) {
      return _UpdateDecision.replaceOldVersion;
    }
    return _UpdateDecision.newDictionary;
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

enum _UpdateDecision { newDictionary, alreadyUpToDate, replaceOldVersion }

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
