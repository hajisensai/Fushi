/// The user-imported OCR model slot ([MangaOcrLocalModel.custom]).
///
/// The user downloads a PaddleOCR-format CTC text recogniser themselves (an
/// `.onnx` file plus its dictionary, PaddleX `inference.yml` or plain text one
/// character per line) and imports it here. It then runs through the same
/// per-column pipeline as the built-in PaddleOCR models (Manga CTC, PP-OCRv6
/// medium, PP-OCRv5 Korean); only the weights and the dictionary differ.
///
/// Layout of the slot folder (`<support>/ocr_models/custom/`):
///
/// - `custom_rec.onnx`: the imported recogniser, copied by content;
/// - `custom_rec_dict.yml` or `custom_rec_dict.txt`: the dictionary, copied
///   byte for byte, extension from the format the user picked;
/// - `custom_model.json`: metadata written last at import (display name,
///   dictionary format, original file names, sizes, sha256, class count,
///   import date). Its presence is what "a model is imported" means, so
///   readiness never re-parses the dictionary;
/// - the two shared detector files, copied at import from an installed
///   built-in model folder when one has them, otherwise downloaded through the
///   normal downloader (`MangaOcrServiceImpl.downloadModels`).
///
/// Import is atomic: everything is assembled and validated in a staging folder
/// next to the slot, which then replaces the slot folder by rename. A failed
/// import leaves the previously imported model untouched.
///
/// The files come from the internet and are treated as untrusted data: nothing
/// in them is executed (an ONNX graph is data for ONNX Runtime; custom-op
/// libraries are never registered), the dictionary read is capped at
/// [kCustomMangaOcrMaxDictBytes], the model at [kCustomMangaOcrMaxModelBytes],
/// and no path to the user's download is kept.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart'
    show kMangaOcrPipelineRevision;
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_fingerprint.dart' as model_fp;
import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi_engine/ocr/ocr_host_bindings.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart'
    show
        PpOcrCharacterDictFormat,
        kPpRecHeight,
        kPpRecMinWidth,
        parseCharacterDict;

/// Metadata file name inside the slot folder.
const String kCustomMangaOcrInfoFileName = 'custom_model.json';

/// Stored dictionary names, one per format.
const String kCustomMangaOcrDictYamlFileName = 'custom_rec_dict.yml';
const String kCustomMangaOcrDictTextFileName = 'custom_rec_dict.txt';

/// Largest dictionary read at import. Real ones are 50 to 160 KB; 4 MiB leaves
/// room for very large character sets without reading arbitrary blobs.
const int kCustomMangaOcrMaxDictBytes = 4 * 1024 * 1024;

/// Largest recogniser accepted. Real PaddleOCR recognisers are 7 to 80 MB.
const int kCustomMangaOcrMaxModelBytes = 1024 * 1024 * 1024;

/// Largest metadata file read back (it is a few hundred bytes).
const int _kMaxInfoBytes = 64 * 1024;

const int _kInfoSchemaVersion = 1;

/// Prefixes of the temporary sibling folders an import uses; leftovers from an
/// interrupted import are removed by the next one.
const String _kStagingPrefix = '$kCustomMangaOcrModelDirName.import-';
const String _kRetiredPrefix = '$kCustomMangaOcrModelDirName.old-';

/// Dictionary format from the extension of the file the user picked
/// (`.yml` / `.yaml` → PaddleX YAML, `.txt` → plain text); null for anything
/// else. Contents are never sniffed.
PpOcrCharacterDictFormat? customMangaOcrDictFormatForPath(String path) =>
    switch (p.extension(path).toLowerCase()) {
      '.yml' || '.yaml' => PpOcrCharacterDictFormat.paddleYaml,
      '.txt' => PpOcrCharacterDictFormat.plainText,
      _ => null,
    };

/// Stored dictionary file name for [format].
String customMangaOcrDictFileName(PpOcrCharacterDictFormat format) =>
    switch (format) {
      PpOcrCharacterDictFormat.paddleYaml => kCustomMangaOcrDictYamlFileName,
      PpOcrCharacterDictFormat.plainText => kCustomMangaOcrDictTextFileName,
    };

/// What is imported in the slot (`custom_model.json`).
class MangaOcrCustomModelInfo {
  const MangaOcrCustomModelInfo({
    required this.displayName,
    required this.dictFormat,
    required this.sourceModelFileName,
    required this.sourceDictFileName,
    required this.modelSha256,
    required this.dictSha256,
    required this.modelBytes,
    required this.dictBytes,
    required this.dictEntries,
    required this.outputClasses,
    required this.importedAt,
  });

  /// Name shown in settings (derived from the picked file names).
  final String displayName;
  final PpOcrCharacterDictFormat dictFormat;

  /// Base names of the files the user picked (shown only; never opened again).
  final String sourceModelFileName;
  final String sourceDictFileName;
  final String modelSha256;
  final String dictSha256;
  final int modelBytes;
  final int dictBytes;

  /// Dictionary length and the model's class count (= [dictEntries] + 2).
  final int dictEntries;
  final int outputClasses;
  final DateTime importedAt;

  /// Dictionary file name inside the slot folder.
  String get storedDictFileName => customMangaOcrDictFileName(dictFormat);

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': _kInfoSchemaVersion,
    'display_name': displayName,
    'dict_format': dictFormat.name,
    'source_model_file': sourceModelFileName,
    'source_dict_file': sourceDictFileName,
    'model_sha256': modelSha256,
    'dict_sha256': dictSha256,
    'model_bytes': modelBytes,
    'dict_bytes': dictBytes,
    'dict_entries': dictEntries,
    'output_classes': outputClasses,
    'imported_at': importedAt.toUtc().toIso8601String(),
  };

  /// Throws [FormatException] on anything malformed.
  static MangaOcrCustomModelInfo fromJson(Map<String, Object?> json) {
    T field<T>(String key) {
      final Object? value = json[key];
      if (value is! T) {
        throw FormatException('custom OCR model metadata: bad "$key"');
      }
      return value;
    }

    final String formatName = field<String>('dict_format');
    final PpOcrCharacterDictFormat format = PpOcrCharacterDictFormat.values
        .firstWhere(
          (PpOcrCharacterDictFormat f) => f.name == formatName,
          orElse: () => throw FormatException(
            'custom OCR model metadata: unknown dict format "$formatName"',
          ),
        );
    final RegExp hex = RegExp(r'^[0-9a-f]{64}$');
    final String modelSha = field<String>('model_sha256');
    final String dictSha = field<String>('dict_sha256');
    if (!hex.hasMatch(modelSha) || !hex.hasMatch(dictSha)) {
      throw const FormatException('custom OCR model metadata: bad sha256');
    }
    return MangaOcrCustomModelInfo(
      displayName: field<String>('display_name'),
      dictFormat: format,
      sourceModelFileName: field<String>('source_model_file'),
      sourceDictFileName: field<String>('source_dict_file'),
      modelSha256: modelSha,
      dictSha256: dictSha,
      modelBytes: field<int>('model_bytes'),
      dictBytes: field<int>('dict_bytes'),
      dictEntries: field<int>('dict_entries'),
      outputClasses: field<int>('output_classes'),
      importedAt: DateTime.parse(field<String>('imported_at')),
    );
  }
}

/// The imported model in [slotDir], or null when the slot is empty or its
/// metadata is unreadable (treated as empty: the user re-imports).
///
/// One small file read; it does not check the recogniser or the dictionary
/// (status does that by stat, like the built-ins). A model that a failed or
/// interrupted replace left set aside is put back first
/// ([restoreRetiredCustomMangaOcrSlot]), so every reader sees it again.
Future<MangaOcrCustomModelInfo?> readCustomMangaOcrModelInfo(
  Directory slotDir,
) async {
  await restoreRetiredCustomMangaOcrSlot(slotDir);
  final File file = File(p.join(slotDir.path, kCustomMangaOcrInfoFileName));
  try {
    final FileStat stat = await file.stat();
    if (stat.type != FileSystemEntityType.file ||
        stat.size <= 0 ||
        stat.size > _kMaxInfoBytes) {
      return null;
    }
    final Object? decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?>) return null;
    return MangaOcrCustomModelInfo.fromJson(decoded);
  } on FormatException catch (error, stack) {
    engineLog.log('readCustomMangaOcrModelInfo', error, stack);
    return null;
  } on FileSystemException catch (error, stack) {
    engineLog.log('readCustomMangaOcrModelInfo', error, stack);
    return null;
  }
}

/// Slots whose replace is between its two renames in this isolate. While a
/// slot is listed, its missing folder is the replace in progress, not an
/// interrupted one, and [restoreRetiredCustomMangaOcrSlot] leaves it alone.
final Set<String> _swappingSlots = <String>{};

/// Stamp of a retired folder name (`custom.old-<stamp>`); 0 when unreadable.
int _retiredStamp(String name) =>
    int.tryParse(name.substring(_kRetiredPrefix.length)) ?? 0;

/// The folders a replace set aside next to [slot], newest first.
Future<List<Directory>> _retiredSlots(Directory slot) async {
  final Directory root = slot.parent;
  if (!await root.exists()) return const <Directory>[];
  final List<Directory> retired = <Directory>[
    await for (final FileSystemEntity entity in root.list())
      if (entity is Directory &&
          p.basename(entity.path).startsWith(_kRetiredPrefix))
        entity,
  ];
  retired.sort(
    (Directory a, Directory b) => _retiredStamp(
      p.basename(b.path),
    ).compareTo(_retiredStamp(p.basename(a.path))),
  );
  return retired;
}

bool _holdsModel(Directory dir) =>
    File(p.join(dir.path, kCustomMangaOcrInfoFileName)).existsSync();

/// Puts back the model a replace set aside when the replace never finished.
///
/// A replace renames the slot to `custom.old-<stamp>` and then renames the new
/// folder in. If the second rename fails and the rename back fails too (or the
/// process dies in between), the only copy of the user's model sits in the
/// retired folder and the slot is gone. Such a folder is the live model, not a
/// leftover: when [slot] does not exist, the newest retired folder that holds
/// a model is renamed back. Returns whether a model was restored.
///
/// Does nothing while a replace of [slot] is running in this isolate, and
/// nothing when the slot exists (the common case: one `stat`).
Future<bool> restoreRetiredCustomMangaOcrSlot(Directory slot) async {
  if (_swappingSlots.contains(slot.path)) return false;
  try {
    if (await slot.exists()) return false;
    for (final Directory retired in await _retiredSlots(slot)) {
      if (!_holdsModel(retired)) continue;
      await retired.rename(slot.path);
      return true;
    }
  } on FileSystemException catch (error, stack) {
    // Still set aside; the next read tries again.
    engineLog.log('restoreRetiredCustomMangaOcrSlot', error, stack);
  }
  return false;
}

/// The generation that runs for an imported model: the slot's shared detector
/// files plus the imported recogniser and dictionary.
///
/// The cache signature is derived from the content of the imported files (their
/// sha256 from the metadata), so replacing the model with a different one moves
/// page results to another cache folder; re-importing the same files keeps it.
/// The fingerprint layer appends the installed files' own content hash on top
/// ([resolveCustomMangaOcrEngineSignature]).
MangaOcrModelGeneration customMangaOcrGeneration(MangaOcrCustomModelInfo info) {
  return MangaOcrModelGeneration(
    manifest: <MangaOcrModelFile>[
      ...kCustomMangaOcrSlotGeneration.manifest,
      MangaOcrModelFile(
        fileName: kCustomMangaOcrRecFileName,
        url: '',
        expectedBytes: info.modelBytes,
        role: MangaOcrModelRole.recognizer,
        sha256: info.modelSha256,
      ),
      MangaOcrModelFile(
        fileName: info.storedDictFileName,
        url: '',
        expectedBytes: info.dictBytes,
        role: MangaOcrModelRole.recognizer,
        sha256: info.dictSha256,
      ),
    ],
    cacheSignature:
        'local-onnx-ctc-custom-${info.modelSha256.substring(0, 12)}'
        '${info.dictSha256.substring(0, 12)}-$kMangaOcrPipelineRevision',
    recFileName: kCustomMangaOcrRecFileName,
    recDictFileName: info.storedDictFileName,
    recognizer: MangaOcrCtcColumnSpec(dictFormat: info.dictFormat),
  );
}

/// Page cache signature of whatever is imported in [slotDir] (the slot's empty
/// signature when nothing is).
Future<String> resolveCustomMangaOcrEngineSignature(Directory slotDir) async {
  final MangaOcrCustomModelInfo? info = await readCustomMangaOcrModelInfo(
    slotDir,
  );
  if (info == null) return kCustomMangaOcrSlotGeneration.cacheSignature;
  final MangaOcrModelGeneration generation = customMangaOcrGeneration(info);
  return model_fp.resolveLocalMangaOcrEngineSignature(
    slotDir,
    manifest: generation.manifest,
    baseSignature: generation.cacheSignature,
  );
}

/// Why an import was refused. Each has its own translated message in the app.
enum MangaOcrCustomModelImportError {
  /// The model file is not an `.onnx` file.
  modelFileType,

  /// The dictionary is not `.yml` / `.yaml` / `.txt`.
  dictFileType,

  /// A picked file is missing or cannot be read.
  fileUnreadable,

  /// Over [kCustomMangaOcrMaxModelBytes] / [kCustomMangaOcrMaxDictBytes].
  modelTooLarge,
  dictTooLarge,

  /// The dictionary is not UTF-8 text, or has no entries / a malformed entry
  /// for the chosen format.
  dictInvalid,

  /// ONNX Runtime could not load the model.
  modelLoadFailed,

  /// The model loads but is not a PaddleOCR CTC recogniser of the supported
  /// kind: it does not take float32 `[1, 3, 48, W]` or does not return a
  /// single float `[1, T, classes]` output.
  notRecognizer,

  /// The model's class count is not dictionary length + 2.
  classCountMismatch,

  /// Copying into Fushi's folder or swapping the slot failed.
  storageFailed,
}

class MangaOcrCustomModelImportException implements Exception {
  const MangaOcrCustomModelImportException(
    this.error, {
    this.detail,
    this.modelClasses,
    this.dictEntries,
  });

  final MangaOcrCustomModelImportError error;

  /// Underlying error text (for logs and the "details" line).
  final String? detail;

  /// For [MangaOcrCustomModelImportError.classCountMismatch]: the model's class
  /// count and the dictionary length (the model expects `modelClasses - 2`).
  final int? modelClasses;
  final int? dictEntries;

  /// Dictionary entries the model expects.
  int? get expectedDictEntries =>
      modelClasses == null ? null : modelClasses! - 2;

  @override
  String toString() =>
      'MangaOcrCustomModelImportException(${error.name}'
      '${modelClasses == null ? '' : ', model classes $modelClasses, '
                'dictionary entries $dictEntries'}'
      '${detail == null ? '' : ': $detail'})';
}

/// Runs one dummy inference on a candidate recogniser and returns the shape of
/// its single output. Throws [MangaOcrCustomModelImportException] with
/// [MangaOcrCustomModelImportError.modelLoadFailed] or
/// [MangaOcrCustomModelImportError.notRecognizer].
typedef MangaOcrCustomModelProbe = Future<List<int>> Function(String modelPath);

/// Width of the probe input: the pipeline's minimum line width.
const int kCustomMangaOcrProbeWidth = kPpRecMinWidth;

/// Default probe: a background isolate set up exactly like the OCR page
/// sessions (`ocr_host_bindings`: the app's plugin factory with its isolate
/// bootstrap, or the server's FFI factory), CPU only, one thread.
///
/// The session abstraction exposes no input / output metadata, so the input
/// contract is checked by running it: a model whose input is not 4-D float with
/// 3 channels and height 48 (or dynamic) rejects the `[1, 3, 48, 320]` probe.
/// The class count is read from the output of that same run, which also covers
/// models whose output dimension is dynamic.
Future<List<int>> probeCustomMangaOcrRecognizer(String modelPath) async {
  final OcrSessionFactory Function()? builder = ocrSessionFactoryBuilder;
  if (builder == null) {
    throw StateError(
      'ocrSessionFactoryBuilder not installed: the host must assign '
      'ocr_host_bindings before importing a custom OCR model',
    );
  }
  final OcrIsolateBootstrap? bootstrap = ocrIsolateBootstrap;
  final Object? bootstrapArg = ocrIsolateBootstrapArg;
  final _ProbeOutcome outcome = await Isolate.run<_ProbeOutcome>(
    () => _probeInIsolate(modelPath, builder, bootstrap, bootstrapArg),
    debugName: 'manga_ocr_custom_model_probe',
  );
  final List<int>? shape = outcome.shape;
  if (shape != null) return shape;
  throw MangaOcrCustomModelImportException(
    outcome.loadFailed
        ? MangaOcrCustomModelImportError.modelLoadFailed
        : MangaOcrCustomModelImportError.notRecognizer,
    detail: outcome.detail,
  );
}

class _ProbeOutcome {
  const _ProbeOutcome.shape(List<int> this.shape)
    : loadFailed = false,
      detail = null;
  const _ProbeOutcome.failed({required this.loadFailed, required this.detail})
    : shape = null;

  final List<int>? shape;
  final bool loadFailed;
  final String? detail;
}

Future<_ProbeOutcome> _probeInIsolate(
  String modelPath,
  OcrSessionFactory Function() builder,
  OcrIsolateBootstrap? bootstrap,
  Object? bootstrapArg,
) async {
  bootstrap?.call(bootstrapArg);
  final OcrSessionFactory factory = builder();
  final OcrSession session;
  try {
    session = await factory.createSession(
      modelPath,
      providers: const <OcrExecutionProvider>[OcrExecutionProvider.cpu],
      intraOpNumThreads: 1,
    );
  } catch (error) {
    return _ProbeOutcome.failed(loadFailed: true, detail: '$error');
  }
  try {
    const int width = kCustomMangaOcrProbeWidth;
    final Map<String, OcrTensor> outputs = await session.run(
      <String, OcrTensor>{
        'x': OcrTensor.float32(
          Float32List(3 * kPpRecHeight * width),
          const <int>[1, 3, kPpRecHeight, width],
        ),
      },
    );
    if (outputs.length != 1) {
      return _ProbeOutcome.failed(
        loadFailed: false,
        detail: 'expected one output, got ${outputs.length}',
      );
    }
    final OcrTensor output = outputs.values.single;
    if (output.type != OcrTensorType.float32 ||
        output.shape.length != 3 ||
        output.shape[0] != 1 ||
        output.shape[1] <= 0 ||
        output.shape[2] <= 2) {
      return _ProbeOutcome.failed(
        loadFailed: false,
        detail: 'output ${output.type.name} ${output.shape}',
      );
    }
    return _ProbeOutcome.shape(List<int>.of(output.shape));
  } catch (error) {
    return _ProbeOutcome.failed(loadFailed: false, detail: '$error');
  } finally {
    try {
      await session.close();
    } catch (_) {
      // Closing a probe session cannot change the verdict.
    }
  }
}

/// The slot the settings page talks to (interface so widget tests can fake it).
abstract interface class MangaOcrCustomModelSlot {
  /// What is imported, or null when the slot is empty.
  Future<MangaOcrCustomModelInfo?> readInfo();

  /// Validates and imports [modelPath] + [dictPath], replacing any previous
  /// model only once the new one has passed. Throws
  /// [MangaOcrCustomModelImportException].
  Future<MangaOcrCustomModelInfo> importModel({
    required String modelPath,
    required String dictPath,
  });
}

/// Real slot: imports into [MangaOcrLocalModel.custom]'s folder.
class MangaOcrCustomModelStore implements MangaOcrCustomModelSlot {
  MangaOcrCustomModelStore({
    Future<Directory> Function()? slotDirProvider,
    MangaOcrCustomModelProbe? probe,
    DateTime Function()? clock,
    Future<void> Function(Directory from, String toPath)? renameDirectory,
  }) : _slotDirProvider =
           slotDirProvider ?? MangaOcrLocalModel.custom.modelsDirectory,
       _probe = probe ?? probeCustomMangaOcrRecognizer,
       _clock = clock ?? DateTime.now,
       _rename = renameDirectory ?? _renameDirectory;

  final Future<Directory> Function() _slotDirProvider;
  final MangaOcrCustomModelProbe _probe;
  final DateTime Function() _clock;

  /// Directory rename (tests inject one that fails).
  final Future<void> Function(Directory from, String toPath) _rename;

  static Future<void> _renameDirectory(Directory from, String toPath) async {
    await from.rename(toPath);
  }

  /// Built-in model folders the shared detector files can be copied from.
  static const List<String> _detectorSourceDirNames = <String>[
    kMangaCtcModelDirName,
    kPpOcrV6MediumModelDirName,
    kPpOcrV5KoreanModelDirName,
    kCharspotSmallModelDirName,
    kCharspotNanoModelDirName,
    kNarSmallModelDirName,
  ];

  @override
  Future<MangaOcrCustomModelInfo?> readInfo() async =>
      readCustomMangaOcrModelInfo(await _slotDirProvider());

  @override
  Future<MangaOcrCustomModelInfo> importModel({
    required String modelPath,
    required String dictPath,
  }) async {
    if (p.extension(modelPath).toLowerCase() != '.onnx') {
      throw MangaOcrCustomModelImportException(
        MangaOcrCustomModelImportError.modelFileType,
        detail: p.basename(modelPath),
      );
    }
    final PpOcrCharacterDictFormat? format = customMangaOcrDictFormatForPath(
      dictPath,
    );
    if (format == null) {
      throw MangaOcrCustomModelImportException(
        MangaOcrCustomModelImportError.dictFileType,
        detail: p.basename(dictPath),
      );
    }
    await _checkSource(
      modelPath,
      maxBytes: kCustomMangaOcrMaxModelBytes,
      tooLarge: MangaOcrCustomModelImportError.modelTooLarge,
    );
    await _checkSource(
      dictPath,
      maxBytes: kCustomMangaOcrMaxDictBytes,
      tooLarge: MangaOcrCustomModelImportError.dictTooLarge,
    );

    final Directory slot = await _slotDirProvider();
    final Directory root = slot.parent;
    // A model an earlier replace left set aside goes back first: the sweep
    // below must never see the only copy of it as a leftover.
    await restoreRetiredCustomMangaOcrSlot(slot);
    await _removeLeftovers(slot);
    final String stamp = '${_clock().microsecondsSinceEpoch}';
    final Directory staging = Directory(
      p.join(root.path, '$_kStagingPrefix$stamp'),
    );
    try {
      await staging.create(recursive: true);
      // Everything below reads the copies in Fushi's folder, never the user's
      // files again: what was validated is exactly what will run.
      final _Copied model = await _copyHashed(
        File(modelPath),
        File(p.join(staging.path, kCustomMangaOcrRecFileName)),
        maxBytes: kCustomMangaOcrMaxModelBytes,
        tooLarge: MangaOcrCustomModelImportError.modelTooLarge,
      );
      final String storedDictName = customMangaOcrDictFileName(format);
      final _Copied dict = await _copyHashed(
        File(dictPath),
        File(p.join(staging.path, storedDictName)),
        maxBytes: kCustomMangaOcrMaxDictBytes,
        tooLarge: MangaOcrCustomModelImportError.dictTooLarge,
      );
      final List<String> entries = await _parseDict(
        File(p.join(staging.path, storedDictName)),
        format,
      );
      final List<int> shape = await _probe(
        p.join(staging.path, kCustomMangaOcrRecFileName),
      );
      if (shape.length != 3) {
        throw MangaOcrCustomModelImportException(
          MangaOcrCustomModelImportError.notRecognizer,
          detail: 'output $shape',
        );
      }
      final int classes = shape[2];
      if (classes != entries.length + 2) {
        throw MangaOcrCustomModelImportException(
          MangaOcrCustomModelImportError.classCountMismatch,
          modelClasses: classes,
          dictEntries: entries.length,
        );
      }
      await _carryDetectors(slot, root, staging);
      final MangaOcrCustomModelInfo info = MangaOcrCustomModelInfo(
        displayName: _displayNameFor(modelPath),
        dictFormat: format,
        sourceModelFileName: p.basename(modelPath),
        sourceDictFileName: p.basename(dictPath),
        modelSha256: model.sha256,
        dictSha256: dict.sha256,
        modelBytes: model.bytes,
        dictBytes: dict.bytes,
        dictEntries: entries.length,
        outputClasses: classes,
        importedAt: _clock(),
      );
      // Metadata last: a staging folder without it is never a valid slot.
      await File(
        p.join(staging.path, kCustomMangaOcrInfoFileName),
      ).writeAsString(jsonEncode(info.toJson()), flush: true);
      await _swapIn(staging, slot, root, stamp);
      return info;
    } on MangaOcrCustomModelImportException {
      await _deleteQuietly(staging);
      rethrow;
    } on FileSystemException catch (error) {
      await _deleteQuietly(staging);
      throw MangaOcrCustomModelImportException(
        MangaOcrCustomModelImportError.storageFailed,
        detail: '$error',
      );
    } catch (_) {
      await _deleteQuietly(staging);
      rethrow;
    }
  }

  static Future<void> _checkSource(
    String path, {
    required int maxBytes,
    required MangaOcrCustomModelImportError tooLarge,
  }) async {
    final FileStat stat;
    try {
      stat = await File(path).stat();
    } on FileSystemException catch (error) {
      throw MangaOcrCustomModelImportException(
        MangaOcrCustomModelImportError.fileUnreadable,
        detail: '$error',
      );
    }
    if (stat.type != FileSystemEntityType.file || stat.size <= 0) {
      throw MangaOcrCustomModelImportException(
        MangaOcrCustomModelImportError.fileUnreadable,
        detail: p.basename(path),
      );
    }
    if (stat.size > maxBytes) {
      throw MangaOcrCustomModelImportException(
        tooLarge,
        detail: '${stat.size}',
      );
    }
  }

  /// Streams [source] into [target] while hashing it, stopping past [maxBytes]
  /// (the file may have grown since it was stat'ed).
  static Future<_Copied> _copyHashed(
    File source,
    File target, {
    required int maxBytes,
    required MangaOcrCustomModelImportError tooLarge,
  }) async {
    final _DigestSink digest = _DigestSink();
    final ByteConversionSink hasher = sha256.startChunkedConversion(digest);
    final IOSink sink = target.openWrite();
    int bytes = 0;
    try {
      await for (final List<int> chunk in source.openRead()) {
        bytes += chunk.length;
        if (bytes > maxBytes) {
          throw MangaOcrCustomModelImportException(tooLarge, detail: '$bytes');
        }
        hasher.add(chunk);
        sink.add(chunk);
      }
    } on FileSystemException catch (error) {
      throw MangaOcrCustomModelImportException(
        MangaOcrCustomModelImportError.fileUnreadable,
        detail: '$error',
      );
    } finally {
      await sink.flush();
      await sink.close();
    }
    hasher.close();
    if (bytes <= 0) {
      throw MangaOcrCustomModelImportException(
        MangaOcrCustomModelImportError.fileUnreadable,
        detail: p.basename(source.path),
      );
    }
    return _Copied(bytes: bytes, sha256: digest.value.toString());
  }

  /// Parses the stored dictionary exactly as the pipeline will at run time
  /// (strict UTF-8 like `File.readAsString`, then [parseCharacterDict]).
  static Future<List<String>> _parseDict(
    File file,
    PpOcrCharacterDictFormat format,
  ) async {
    final String content;
    try {
      content = utf8.decode(await file.readAsBytes());
    } on FormatException catch (error) {
      throw MangaOcrCustomModelImportException(
        MangaOcrCustomModelImportError.dictInvalid,
        detail: 'not UTF-8 text: ${error.message}',
      );
    }
    try {
      return parseCharacterDict(content, format);
    } on FormatException catch (error) {
      throw MangaOcrCustomModelImportException(
        MangaOcrCustomModelImportError.dictInvalid,
        detail: error.message,
      );
    }
  }

  /// Copies the shared detector files into [staging] from the current slot or
  /// an installed built-in model folder (exact expected size only). Files not
  /// found anywhere are left for the normal downloader; status then reports the
  /// detector as missing and the settings card offers the download.
  static Future<void> _carryDetectors(
    Directory slot,
    Directory root,
    Directory staging,
  ) async {
    final List<Directory> sources = <Directory>[
      slot,
      for (final String name in _detectorSourceDirNames)
        Directory(p.join(root.path, name)),
    ];
    for (final MangaOcrModelFile file
        in kCustomMangaOcrSlotGeneration.manifest) {
      for (final Directory dir in sources) {
        final File candidate = File(p.join(dir.path, file.fileName));
        try {
          final FileStat stat = await candidate.stat();
          if (stat.type != FileSystemEntityType.file ||
              stat.size != file.expectedBytes) {
            continue;
          }
          await candidate.copy(p.join(staging.path, file.fileName));
          break;
        } on FileSystemException catch (error, stack) {
          // Another source may still have it; failing that it is downloaded.
          engineLog.log(
            'MangaOcrCustomModelStore.carryDetectors',
            error,
            stack,
          );
        }
      }
    }
  }

  /// Replaces [slot] with [staging]: the old slot is renamed aside first and
  /// put back if the new one cannot be moved in.
  ///
  /// When putting it back fails as well, the old model stays in its retired
  /// folder and the import fails with
  /// [MangaOcrCustomModelImportError.storageFailed]; the next read or import
  /// restores it ([restoreRetiredCustomMangaOcrSlot]). It is never deleted
  /// while the slot is missing ([_removeLeftovers]).
  Future<void> _swapIn(
    Directory staging,
    Directory slot,
    Directory root,
    String stamp,
  ) async {
    _swappingSlots.add(slot.path);
    try {
      Directory? retired;
      if (await slot.exists()) {
        final String retiredPath = p.join(root.path, '$_kRetiredPrefix$stamp');
        await _rename(slot, retiredPath);
        retired = Directory(retiredPath);
      }
      try {
        await _rename(staging, slot.path);
      } on FileSystemException catch (swapError) {
        if (retired != null) {
          try {
            await _rename(retired, slot.path);
          } on FileSystemException catch (restoreError, stack) {
            engineLog.log(
              'MangaOcrCustomModelStore.swapIn.restore',
              restoreError,
              stack,
            );
            throw MangaOcrCustomModelImportException(
              MangaOcrCustomModelImportError.storageFailed,
              detail:
                  '$swapError; the previous model is kept in '
                  '${p.basename(retired.path)}: $restoreError',
            );
          }
        }
        rethrow;
      }
      if (retired != null) await _deleteQuietly(retired);
    } finally {
      _swappingSlots.remove(slot.path);
    }
  }

  /// Removes what earlier imports left next to [slot]: staging folders always;
  /// retired folders only when they cannot be the live model (the slot exists,
  /// or the folder holds no model).
  static Future<void> _removeLeftovers(Directory slot) async {
    final Directory root = slot.parent;
    if (!await root.exists()) return;
    try {
      final bool slotExists = await slot.exists();
      await for (final FileSystemEntity entity in root.list()) {
        if (entity is! Directory) continue;
        final String name = p.basename(entity.path);
        if (name.startsWith(_kStagingPrefix) ||
            (name.startsWith(_kRetiredPrefix) &&
                (slotExists || !_holdsModel(entity)))) {
          await _deleteQuietly(entity);
        }
      }
    } on FileSystemException catch (error, stack) {
      engineLog.log('MangaOcrCustomModelStore.removeLeftovers', error, stack);
    }
  }

  static Future<void> _deleteQuietly(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException catch (error, stack) {
      // Removed by the next import's leftover sweep.
      engineLog.log('MangaOcrCustomModelStore.delete', error, stack);
    }
  }

  /// `inference.onnx` / `model.onnx` say nothing; the folder they came in
  /// (`korean_PP-OCRv5_mobile_rec_onnx`) usually does.
  static String _displayNameFor(String modelPath) {
    final String stem = p.basenameWithoutExtension(modelPath);
    const Set<String> generic = <String>{'inference', 'model', 'rec'};
    if (generic.contains(stem.toLowerCase())) {
      final String folder = p.basename(p.dirname(p.absolute(modelPath)));
      if (folder.isNotEmpty && folder != '.' && folder != p.separator) {
        return folder;
      }
    }
    return stem;
  }
}

class _Copied {
  const _Copied({required this.bytes, required this.sha256});
  final int bytes;
  final String sha256;
}

class _DigestSink implements Sink<Digest> {
  Digest? _value;
  Digest get value => _value!;

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}
