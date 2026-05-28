import 'dart:io';

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
        final String summary = failedNames.length == 1
            ? '${t.srt_import_error}: ${failedNames.first}'
            : '${t.dict_import_failed_summary(n: failedNames.length)}\n${failedNames.join(', ')}';
        HibikiToast.show(msg: summary, toastLength: Toast.LENGTH_LONG);
      }
      return;
    }

    _dictRepo.clearDictionaryResultsCache();

    try {
      progressNotifier.value = t.import_extract;

      final tempZipPath =
          path.join(_resourceDirectory.path, 'import_temp_dir.zip');
      final tempZip = File(tempZipPath);

      final archive = Archive();
      for (final entity in directory.listSync(recursive: true)) {
        if (entity is File) {
          final relativePath = path.relative(entity.path, from: directory.path);
          archive.addFile(ArchiveFile(
              relativePath, entity.lengthSync(), entity.readAsBytesSync()));
        }
      }
      tempZip.writeAsBytesSync(ZipEncoder().encode(archive)!);

      try {
        final tempOutputDir =
            Directory(path.join(_resourceDirectory.path, 'import_temp'));
        if (tempOutputDir.existsSync()) {
          tempOutputDir.deleteSync(recursive: true);
        }
        tempOutputDir.createSync(recursive: true);

        final result = await importDictionaryViaHoshidicts(
          zipPath: tempZipPath,
          outputDir: tempOutputDir.path,
        );

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
          innerDataDir.renameSync(finalDir.path);
        } else {
          tempOutputDir.renameSync(finalDir.path);
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
          hiddenLanguages: preservedSettings?.hiddenLanguages ?? const [],
          collapsedLanguages: preservedSettings?.collapsedLanguages ?? const [],
        ));

        progressNotifier.value = t.import_complete;
        onImportSuccess();
      } finally {
        if (tempZip.existsSync()) tempZip.deleteSync();
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('DictImport(dir)', e, stack);
      progressNotifier.value = '$e';
      await Future.delayed(const Duration(seconds: 3));
      if (_isMemoryError(e) && !lowMemoryMode) {
        progressNotifier.value = t.low_memory_mode_suggestion;
        await Future.delayed(const Duration(seconds: 3));
        onMemoryError?.call();
      }
      progressNotifier.value = t.import_failed;
      await Future.delayed(const Duration(seconds: 1));
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

      final result = await importDictionaryViaHoshidicts(
        zipPath: file.path,
        outputDir: tempOutputDir.path,
      );

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
        innerDataDir.renameSync(finalDir.path);
      } else {
        tempOutputDir.renameSync(finalDir.path);
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
        hiddenLanguages: preservedSettings?.hiddenLanguages ?? const [],
        collapsedLanguages: preservedSettings?.collapsedLanguages ?? const [],
      ));

      progressNotifier.value = t.import_complete;
      onImportSuccess();
    } catch (e, stack) {
      ErrorLogService.instance.log('DictImport(file)', e, stack);
      progressNotifier.value = '$e';
      await Future.delayed(const Duration(seconds: 3));
      if (_isMemoryError(e) && !lowMemoryMode) {
        progressNotifier.value = t.low_memory_mode_suggestion;
        await Future.delayed(const Duration(seconds: 3));
        onMemoryError?.call();
      }
      progressNotifier.value = t.import_failed;
      await Future.delayed(const Duration(seconds: 1));
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
}

enum _UpdateDecision { newDictionary, alreadyUpToDate, replaceOldVersion }
