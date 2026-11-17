import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fushi_engine/ocr/manga_ocr_custom_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/ocr/manga_ocr_service_impl.dart';
import 'package:fushi_engine/ocr/ocr_host_bindings.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const String _yamlDict = '''
PostProcess:
  name: CTCLabelDecode
  character_dict:
  - a
  - b
  - c
''';

const String _textDict = 'x\ny\nz\nw\n';

/// Probe stub: reports `[1, 40, classes]` and records what it was handed.
class _Probe {
  _Probe(this.classes);

  int classes;
  MangaOcrCustomModelImportException? error;
  final List<String> paths = <String>[];

  Future<List<int>> call(String modelPath) async {
    paths.add(modelPath);
    final MangaOcrCustomModelImportException? failure = error;
    if (failure != null) throw failure;
    return <int>[1, 40, classes];
  }
}

class _PageSession implements MangaOcrPageSession {
  @override
  Future<String> ocrPage(String relativeUrl) async => '';

  @override
  Future<void> close() async {}
}

class _RecordingPageRunner implements MangaOcrPageSessionRunner {
  final List<MangaOcrPageSessionRequest> requests =
      <MangaOcrPageSessionRequest>[];

  @override
  MangaOcrPageSession open(
    MangaOcrPageSessionRequest request, {
    void Function(MangaOcrAcceleration acceleration)? onAcceleration,
  }) {
    requests.add(request);
    return _PageSession();
  }
}

// ── Probe isolate fakes (top-level: they cross the isolate boundary) ────────

class _ShapeSession implements OcrSession {
  _ShapeSession(this.outputShape, {this.failRun = false});

  final List<int> outputShape;
  final bool failRun;

  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) async {
    final OcrTensor x = inputs['x']!;
    if (failRun ||
        x.shape.length != 4 ||
        x.shape[1] != 3 ||
        x.shape[2] != kPpRecHeight) {
      throw StateError('input rejected: ${x.shape}');
    }
    final int n = outputShape.fold<int>(1, (int a, int b) => a * b);
    return <String, OcrTensor>{
      'out': OcrTensor.float32(Float32List(n), outputShape),
    };
  }

  @override
  Future<void> close() async {}
}

class _ShapeFactory implements OcrSessionFactory {
  _ShapeFactory(this.create);

  final OcrSession Function(String path) create;

  @override
  Future<OcrSession> createSession(
    String modelPath, {
    required List<OcrExecutionProvider> providers,
    void Function(OcrProviderResolution resolution)? onProviderResolved,
    int? intraOpNumThreads,
    Map<String, int>? freeDimensionOverrides,
  }) async => create(modelPath);

  @override
  Future<Set<OcrExecutionProvider>> availableAcceleratedProviders() async =>
      const <OcrExecutionProvider>{};

  @override
  Future<int?> deviceMemoryBudgetBytes() async => null;
}

OcrSessionFactory _recognizerFactory() =>
    _ShapeFactory((String _) => _ShapeSession(const <int>[1, 80, 5]));
OcrSessionFactory _detectorLikeFactory() =>
    _ShapeFactory((String _) => _ShapeSession(const <int>[1, 1, 48, 320]));
OcrSessionFactory _wrongInputFactory() => _ShapeFactory(
  (String _) => _ShapeSession(const <int>[1, 80, 5], failRun: true),
);
OcrSessionFactory _unloadableFactory() =>
    _ShapeFactory((String path) => throw StateError('protobuf parse failed'));

void main() {
  late Directory root;
  late Directory slot;
  late File model;
  late File yamlDict;
  late File textDict;
  late _Probe probe;
  late MangaOcrCustomModelStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_custom_ocr_');
    slot = Directory(p.join(root.path, 'ocr_models', 'custom'));
    final Directory downloads = Directory(p.join(root.path, 'downloads'))
      ..createSync();
    model = File(p.join(downloads.path, 'inference.onnx'))
      ..writeAsBytesSync(List<int>.generate(64, (int i) => i));
    yamlDict = File(p.join(downloads.path, 'inference.yml'))
      ..writeAsStringSync(_yamlDict);
    textDict = File(p.join(downloads.path, 'dict.txt'))
      ..writeAsStringSync(_textDict);
    probe = _Probe(5);
    store = MangaOcrCustomModelStore(
      slotDirProvider: () async => slot,
      probe: probe.call,
    );
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  MangaOcrServiceImpl serviceFor({_RecordingPageRunner? runner}) =>
      MangaOcrServiceImpl(
        localModel: MangaOcrLocalModel.custom,
        modelsDirProvider: () async => slot,
        pageSessionRunner: runner,
        platformSupport: () => true,
      );

  /// Exact-size detector files in an installed built-in model folder.
  void installBuiltInDetectors() {
    final Directory ctc = Directory(
      p.join(slot.parent.path, kMangaCtcModelDirName),
    )..createSync(recursive: true);
    for (final MangaOcrModelFile file
        in kCustomMangaOcrSlotGeneration.manifest) {
      final RandomAccessFile raf = File(
        p.join(ctc.path, file.fileName),
      ).openSync(mode: FileMode.write);
      raf.truncateSync(file.expectedBytes);
      raf.closeSync();
    }
  }

  Future<MangaOcrCustomModelImportException> importError({
    String? modelPath,
    String? dictPath,
  }) async {
    try {
      await store.importModel(
        modelPath: modelPath ?? model.path,
        dictPath: dictPath ?? yamlDict.path,
      );
    } on MangaOcrCustomModelImportException catch (error) {
      return error;
    }
    fail('import was accepted');
  }

  group('import', () {
    test('YAML dictionary: copies by content and writes metadata', () async {
      final MangaOcrCustomModelInfo info = await store.importModel(
        modelPath: model.path,
        dictPath: yamlDict.path,
      );
      expect(info.dictFormat, PpOcrCharacterDictFormat.paddleYaml);
      expect(info.dictEntries, 3);
      expect(info.outputClasses, 5);
      expect(info.displayName, 'downloads', reason: 'generic stem → folder');
      expect(info.sourceModelFileName, 'inference.onnx');
      expect(
        info.modelSha256,
        sha256Hex(model.readAsBytesSync()),
        reason: 'hash of the content, not of the path',
      );
      expect(
        File(p.join(slot.path, kCustomMangaOcrRecFileName)).readAsBytesSync(),
        model.readAsBytesSync(),
      );
      expect(
        File(
          p.join(slot.path, kCustomMangaOcrDictYamlFileName),
        ).readAsStringSync(),
        _yamlDict,
      );
      // The probe ran on Fushi's copy, never on the user's download.
      expect(probe.paths.single, startsWith(slot.parent.path));
      expect(probe.paths.single, isNot(model.path));
      final MangaOcrCustomModelInfo? read = await store.readInfo();
      expect(read?.toJson(), info.toJson());
      final String json = File(
        p.join(slot.path, kCustomMangaOcrInfoFileName),
      ).readAsStringSync();
      expect(json, isNot(contains(root.path.replaceAll(r'\', r'\\'))));
    });

    test('text dictionary', () async {
      probe.classes = 6;
      final MangaOcrCustomModelInfo info = await store.importModel(
        modelPath: model.path,
        dictPath: textDict.path,
      );
      expect(info.dictFormat, PpOcrCharacterDictFormat.plainText);
      expect(info.dictEntries, 4);
      expect(
        File(p.join(slot.path, kCustomMangaOcrDictTextFileName)).existsSync(),
        isTrue,
      );
    });

    test('.yaml is YAML; contents are never sniffed', () async {
      final File yaml = File(p.join(root.path, 'dict.yaml'))
        ..writeAsStringSync(_yamlDict);
      expect(
        customMangaOcrDictFormatForPath(yaml.path),
        PpOcrCharacterDictFormat.paddleYaml,
      );
      // A YAML file named .txt is read as plain text (one entry per line).
      final File misnamed = File(p.join(root.path, 'dict.txt'))
        ..writeAsStringSync(_yamlDict);
      probe.classes = 3 + 2;
      final MangaOcrCustomModelImportException error = await importError(
        dictPath: misnamed.path,
      );
      expect(error.error, MangaOcrCustomModelImportError.classCountMismatch);
      expect(error.dictEntries, 6);
    });

    test('copies the shared detectors from an installed model', () async {
      installBuiltInDetectors();
      await store.importModel(modelPath: model.path, dictPath: yamlDict.path);
      final MangaOcrModelStatus status = await serviceFor().modelStatus();
      expect(status.detectorReady, isTrue);
      expect(status.recognizerReady, isTrue);
      expect(status.allReady, isTrue);
    });
  });

  group('validation', () {
    test('model must be .onnx', () async {
      final File bin = File(p.join(root.path, 'model.bin'))
        ..writeAsBytesSync(<int>[1]);
      final MangaOcrCustomModelImportException error = await importError(
        modelPath: bin.path,
      );
      expect(error.error, MangaOcrCustomModelImportError.modelFileType);
      expect(probe.paths, isEmpty);
    });

    test('dictionary must be .yml / .yaml / .txt', () async {
      final File json = File(p.join(root.path, 'vocab.json'))
        ..writeAsStringSync('{}');
      final MangaOcrCustomModelImportException error = await importError(
        dictPath: json.path,
      );
      expect(error.error, MangaOcrCustomModelImportError.dictFileType);
    });

    test('missing or empty file', () async {
      expect(
        (await importError(modelPath: p.join(root.path, 'gone.onnx'))).error,
        MangaOcrCustomModelImportError.fileUnreadable,
      );
      final File empty = File(p.join(root.path, 'empty.txt'))..createSync();
      expect(
        (await importError(dictPath: empty.path)).error,
        MangaOcrCustomModelImportError.fileUnreadable,
      );
    });

    test('dictionary over the size cap is not read', () async {
      final File big = File(p.join(root.path, 'big.txt'));
      final RandomAccessFile raf = big.openSync(mode: FileMode.write);
      raf.truncateSync(kCustomMangaOcrMaxDictBytes + 1);
      raf.closeSync();
      final MangaOcrCustomModelImportException error = await importError(
        dictPath: big.path,
      );
      expect(error.error, MangaOcrCustomModelImportError.dictTooLarge);
      expect(probe.paths, isEmpty);
    });

    test('dictionary that is not UTF-8 or has no entries', () async {
      final File latin1 = File(p.join(root.path, 'latin1.txt'))
        ..writeAsBytesSync(<int>[0xff, 0xfe, 0x0a]);
      expect(
        (await importError(dictPath: latin1.path)).error,
        MangaOcrCustomModelImportError.dictInvalid,
      );
      final File noDict = File(p.join(root.path, 'inference_no_dict.yml'))
        ..writeAsStringSync('PostProcess:\n  name: CTCLabelDecode\n');
      final MangaOcrCustomModelImportException error = await importError(
        dictPath: noDict.path,
      );
      expect(error.error, MangaOcrCustomModelImportError.dictInvalid);
      expect(error.detail, contains('character_dict'));
      expect(probe.paths, isEmpty, reason: 'dictionary is checked first');
    });

    test('model that ONNX Runtime cannot load', () async {
      probe.error = const MangaOcrCustomModelImportException(
        MangaOcrCustomModelImportError.modelLoadFailed,
      );
      expect(
        (await importError()).error,
        MangaOcrCustomModelImportError.modelLoadFailed,
      );
    });

    test('model that is not a CTC recogniser', () async {
      probe.error = const MangaOcrCustomModelImportException(
        MangaOcrCustomModelImportError.notRecognizer,
      );
      expect(
        (await importError()).error,
        MangaOcrCustomModelImportError.notRecognizer,
      );
    });

    test('class count must be dictionary length + 2', () async {
      probe.classes = 11947;
      final MangaOcrCustomModelImportException error = await importError();
      expect(error.error, MangaOcrCustomModelImportError.classCountMismatch);
      expect(error.modelClasses, 11947);
      expect(error.expectedDictEntries, 11945);
      expect(error.dictEntries, 3);
      expect(slot.existsSync(), isFalse);
      expect(
        slot.parent.listSync(),
        isEmpty,
        reason: 'a rejected import leaves no staging folder behind',
      );
    });
  });

  group('probe (real isolate, fake session factory)', () {
    tearDown(() => ocrSessionFactoryBuilder = null);

    final File onnx = File(p.join(Directory.systemTemp.path, 'unused.onnx'));

    test('reads the class count from a dummy run', () async {
      ocrSessionFactoryBuilder = _recognizerFactory;
      expect(await probeCustomMangaOcrRecognizer(onnx.path), <int>[1, 80, 5]);
    });

    test('load failure', () async {
      ocrSessionFactoryBuilder = _unloadableFactory;
      await expectLater(
        probeCustomMangaOcrRecognizer(onnx.path),
        throwsA(
          isA<MangaOcrCustomModelImportException>().having(
            (MangaOcrCustomModelImportException e) => e.error,
            'error',
            MangaOcrCustomModelImportError.modelLoadFailed,
          ),
        ),
      );
    });

    for (final (String name, OcrSessionFactory Function() builder)
        in <(String, OcrSessionFactory Function())>[
          ('4-D output (a detector)', _detectorLikeFactory),
          ('input that is not [1, 3, 48, W]', _wrongInputFactory),
        ]) {
      test('rejects $name', () async {
        ocrSessionFactoryBuilder = builder;
        await expectLater(
          probeCustomMangaOcrRecognizer(onnx.path),
          throwsA(
            isA<MangaOcrCustomModelImportException>().having(
              (MangaOcrCustomModelImportException e) => e.error,
              'error',
              MangaOcrCustomModelImportError.notRecognizer,
            ),
          ),
        );
      });
    }
  });

  group('replace and delete', () {
    test('failed replace keeps the previous model intact', () async {
      final MangaOcrCustomModelInfo first = await store.importModel(
        modelPath: model.path,
        dictPath: yamlDict.path,
      );
      final List<int> firstBytes = File(
        p.join(slot.path, kCustomMangaOcrRecFileName),
      ).readAsBytesSync();
      final File other = File(p.join(root.path, 'other.onnx'))
        ..writeAsBytesSync(<int>[9, 9, 9]);
      probe.classes = 99;
      await expectLater(
        store.importModel(modelPath: other.path, dictPath: textDict.path),
        throwsA(isA<MangaOcrCustomModelImportException>()),
      );
      expect((await store.readInfo())?.toJson(), first.toJson());
      expect(
        File(p.join(slot.path, kCustomMangaOcrRecFileName)).readAsBytesSync(),
        firstBytes,
      );
      expect(
        slot.parent.listSync().map((FileSystemEntity e) => p.basename(e.path)),
        <String>['custom'],
      );
    });

    test('successful replace swaps everything and keeps detectors', () async {
      installBuiltInDetectors();
      await store.importModel(modelPath: model.path, dictPath: yamlDict.path);
      // Detectors now only in the slot: the replace carries them over.
      Directory(
        p.join(slot.parent.path, kMangaCtcModelDirName),
      ).deleteSync(recursive: true);
      final File other = File(p.join(root.path, 'other_rec.onnx'))
        ..writeAsBytesSync(<int>[7, 7, 7, 7]);
      probe.classes = 6;
      final MangaOcrCustomModelInfo second = await store.importModel(
        modelPath: other.path,
        dictPath: textDict.path,
      );
      expect(second.displayName, 'other_rec');
      expect((await store.readInfo())?.modelSha256, second.modelSha256);
      expect(
        File(p.join(slot.path, kCustomMangaOcrDictYamlFileName)).existsSync(),
        isFalse,
        reason: 'the old dictionary does not linger',
      );
      expect((await serviceFor().modelStatus()).allReady, isTrue);
      expect(
        slot.parent.listSync().map((FileSystemEntity e) => p.basename(e.path)),
        <String>['custom'],
      );
    });

    test('delete empties the slot', () async {
      await store.importModel(modelPath: model.path, dictPath: yamlDict.path);
      final MangaOcrServiceImpl service = serviceFor();
      expect(await service.deleteModels(), greaterThan(0));
      expect(await store.readInfo(), isNull);
      final MangaOcrModelStatus status = await service.modelStatus();
      expect(status.recognizerReady, isFalse);
      expect(status.canRun, isFalse);
      expect(status.hasAnyFiles, isFalse);
    });

    test('both renames failing keeps the previous model', () async {
      installBuiltInDetectors();
      final MangaOcrCustomModelInfo first = await store.importModel(
        modelPath: model.path,
        dictPath: yamlDict.path,
      );
      final List<int> firstBytes = File(
        p.join(slot.path, kCustomMangaOcrRecFileName),
      ).readAsBytesSync();
      // The slot can be set aside, but nothing can be renamed onto it: the
      // new folder does not go in and the old one does not go back.
      final MangaOcrCustomModelStore stuck = MangaOcrCustomModelStore(
        slotDirProvider: () async => slot,
        probe: probe.call,
        renameDirectory: (Directory from, String toPath) async {
          if (toPath == slot.path) {
            throw FileSystemException('rename refused', toPath);
          }
          await from.rename(toPath);
        },
      );
      final File other = File(p.join(root.path, 'other_rec.onnx'))
        ..writeAsBytesSync(<int>[7, 7, 7, 7]);
      probe.classes = 6;
      MangaOcrCustomModelImportException? failure;
      try {
        await stuck.importModel(modelPath: other.path, dictPath: textDict.path);
      } on MangaOcrCustomModelImportException catch (error) {
        failure = error;
      }
      expect(failure?.error, MangaOcrCustomModelImportError.storageFailed);
      expect(slot.existsSync(), isFalse, reason: 'set aside, not put back');

      // Every reader puts it back: the service first, then the store.
      expect((await serviceFor().modelStatus()).allReady, isTrue);
      expect((await store.readInfo())?.toJson(), first.toJson());
      expect(
        File(p.join(slot.path, kCustomMangaOcrRecFileName)).readAsBytesSync(),
        firstBytes,
      );
      expect(
        slot.parent.listSync().map((FileSystemEntity e) => p.basename(e.path)),
        unorderedEquals(<String>['custom', kMangaCtcModelDirName]),
      );
    });

    test(
      'an import after a stuck replace does not sweep the old model',
      () async {
        final MangaOcrCustomModelInfo first = await store.importModel(
          modelPath: model.path,
          dictPath: yamlDict.path,
        );
        // As left by a replace that died between its two renames.
        slot.renameSync(p.join(slot.parent.path, 'custom.old-456'));
        probe.classes = 99;
        await expectLater(
          store.importModel(modelPath: model.path, dictPath: textDict.path),
          throwsA(isA<MangaOcrCustomModelImportException>()),
        );
        expect((await store.readInfo())?.toJson(), first.toJson());
        expect(
          slot.parent.listSync().map(
            (FileSystemEntity e) => p.basename(e.path),
          ),
          <String>['custom'],
        );
      },
    );

    test(
      'the newest retired model wins; a slot in place is left alone',
      () async {
        final MangaOcrCustomModelInfo first = await store.importModel(
          modelPath: model.path,
          dictPath: yamlDict.path,
        );
        slot.renameSync(p.join(slot.parent.path, 'custom.old-100'));
        final File other = File(p.join(root.path, 'other_rec.onnx'))
          ..writeAsBytesSync(<int>[7, 7, 7, 7]);
        probe.classes = 6;
        // The first model is restored and then replaced by the second.
        final MangaOcrCustomModelInfo second = await store.importModel(
          modelPath: other.path,
          dictPath: textDict.path,
        );
        expect(second.modelSha256, isNot(first.modelSha256));
        slot.renameSync(p.join(slot.parent.path, 'custom.old-200'));
        Directory(p.join(slot.parent.path, 'custom.old-150')).createSync();
        expect(await restoreRetiredCustomMangaOcrSlot(slot), isTrue);
        expect((await store.readInfo())?.modelSha256, second.modelSha256);
        expect(await restoreRetiredCustomMangaOcrSlot(slot), isFalse);
      },
    );

    test('leftovers of an interrupted import are swept', () async {
      final Directory stale = Directory(
        p.join(slot.parent.path, 'custom.import-123'),
      )..createSync(recursive: true);
      final Directory retired = Directory(
        p.join(slot.parent.path, 'custom.old-456'),
      )..createSync(recursive: true);
      await store.importModel(modelPath: model.path, dictPath: yamlDict.path);
      expect(stale.existsSync(), isFalse);
      expect(retired.existsSync(), isFalse);
    });
  });

  group('status and running', () {
    test('empty slot: no recogniser, nothing to run', () async {
      final MangaOcrServiceImpl service = serviceFor(
        runner: _RecordingPageRunner(),
      );
      final MangaOcrModelStatus status = await service.modelStatus();
      expect(status.recognizerReady, isFalse);
      expect(status.canRun, isFalse);
      expect(
        status.totalBytes,
        kCustomMangaOcrSlotGeneration.manifest.fold<int>(
          0,
          (int sum, MangaOcrModelFile f) => sum + f.expectedBytes,
        ),
      );
      await expectLater(
        service.openPageSession(imageDirPath: root.path),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('not downloaded'),
          ),
        ),
      );
    });

    test(
      'imported without detectors: recogniser ready, detector missing',
      () async {
        final MangaOcrCustomModelInfo info = await store.importModel(
          modelPath: model.path,
          dictPath: yamlDict.path,
        );
        final MangaOcrModelStatus status = await serviceFor().modelStatus();
        // The PP-OCRv6 line detector counts as a recogniser-side file (as for
        // the built-ins), so both flags are down until the download.
        expect(status.detectorReady, isFalse);
        expect(status.canRun, isFalse);
        expect(status.obtainedBytes, info.modelBytes + info.dictBytes);
        expect(
          status.totalBytes,
          info.modelBytes +
              info.dictBytes +
              kCustomMangaOcrSlotGeneration.manifest.fold<int>(
                0,
                (int sum, MangaOcrModelFile f) => sum + f.expectedBytes,
              ),
        );
      },
    );

    test('metadata gone (files left over) reads as empty', () async {
      installBuiltInDetectors();
      await store.importModel(modelPath: model.path, dictPath: yamlDict.path);
      File(p.join(slot.path, kCustomMangaOcrInfoFileName)).deleteSync();
      final MangaOcrModelStatus status = await serviceFor().modelStatus();
      expect(status.recognizerReady, isFalse);
      expect(status.hasAnyFiles, isTrue, reason: 'still deletable');
    });

    test(
      'runs through the CTC column pipeline with its own dictionary',
      () async {
        installBuiltInDetectors();
        probe.classes = 6;
        await store.importModel(modelPath: model.path, dictPath: textDict.path);
        final _RecordingPageRunner runner = _RecordingPageRunner();
        final MangaOcrServiceImpl service = MangaOcrServiceImpl(
          localModel: MangaOcrLocalModel.custom,
          modelsDirProvider: () async => slot,
          pageSessionRunner: runner,
          platformSupport: () => true,
          ignoreFurigana: () => true,
        );
        final MangaOcrPageSession session = await service.openPageSession(
          imageDirPath: root.path,
        );
        await session.close();
        final MangaOcrModelPaths paths = runner.requests.single.modelPaths;
        expect(paths.ctcRecPath, p.join(slot.path, kCustomMangaOcrRecFileName));
        expect(paths.ppRecPath, paths.ctcRecPath);
        expect(
          paths.ppRecDictPath,
          p.join(slot.path, kCustomMangaOcrDictTextFileName),
        );
        expect(paths.ppRecDictFormat, PpOcrCharacterDictFormat.plainText);
        expect(paths.charspot, isNull);
        expect(
          paths.ignoreFurigana,
          isTrue,
          reason: 'PaddleOCR-format models honour "ignore furigana"',
        );
        expect(runner.requests.single.engineSignature, endsWith('_noruby'));
      },
    );

    test('paths and cache signature come from one read of the slot', () async {
      installBuiltInDetectors();
      final MangaOcrCustomModelInfo first = await store.importModel(
        modelPath: model.path,
        dictPath: yamlDict.path,
      );
      final File other = File(p.join(root.path, 'other_rec.onnx'))
        ..writeAsBytesSync(<int>[7, 7, 7, 7]);
      // The model is replaced right after the run resolved its folder: a
      // second look at the slot would see the other model.
      int resolved = 0;
      final _RecordingPageRunner runner = _RecordingPageRunner();
      final MangaOcrServiceImpl service = MangaOcrServiceImpl(
        localModel: MangaOcrLocalModel.custom,
        modelsDirProvider: () async {
          if (resolved++ == 1) {
            probe.classes = 6;
            await store.importModel(
              modelPath: other.path,
              dictPath: textDict.path,
            );
          }
          return slot;
        },
        pageSessionRunner: runner,
        platformSupport: () => true,
      );
      final MangaOcrPageSession session = await service.openPageSession(
        imageDirPath: root.path,
      );
      await session.close();
      expect(resolved, 1, reason: 'the slot folder is resolved once per run');
      final MangaOcrPageSessionRequest request = runner.requests.single;
      expect(
        request.modelPaths.ppRecDictPath,
        p.join(slot.path, kCustomMangaOcrDictYamlFileName),
      );
      expect(
        request.engineSignature,
        contains(first.modelSha256.substring(0, 12)),
      );
    });
  });

  group('cache signature', () {
    test('follows the content of the imported files', () async {
      installBuiltInDetectors();
      await store.importModel(modelPath: model.path, dictPath: yamlDict.path);
      final String first = await resolveCustomMangaOcrEngineSignature(slot);
      final String firstDir = await serviceFor().resolvePageCacheDirPath(
        imageDirPath: root.path,
      );
      expect(first, startsWith('local-onnx-ctc-custom-'));
      expect(first, isNot(kCustomMangaOcrSlotGeneration.cacheSignature));
      expect(p.basename(firstDir), first);

      // Same files again: same signature (same results).
      await store.importModel(modelPath: model.path, dictPath: yamlDict.path);
      expect(await resolveCustomMangaOcrEngineSignature(slot), first);

      // Different weights, same file name and dictionary: new signature.
      model.writeAsBytesSync(List<int>.generate(64, (int i) => 255 - i));
      await store.importModel(modelPath: model.path, dictPath: yamlDict.path);
      final String second = await resolveCustomMangaOcrEngineSignature(slot);
      expect(second, isNot(first));
      expect(
        await serviceFor().resolvePageCacheDirPath(imageDirPath: root.path),
        isNot(firstDir),
      );

      // Different dictionary only: new signature too.
      File(
        p.join(root.path, 'downloads', 'inference.yml'),
      ).writeAsStringSync(_yamlDict.replaceFirst('  - c', '  - d'));
      await store.importModel(modelPath: model.path, dictPath: yamlDict.path);
      expect(
        await resolveCustomMangaOcrEngineSignature(slot),
        allOf(isNot(first), isNot(second)),
      );
    });

    test('never shared with a built-in model by recogniser name', () {
      expect(mangaOcrGenerationForRecFile(kCustomMangaOcrRecFileName), isNull);
    });
  });

  group('preference', () {
    test('custom key resolves to the slot on every platform', () {
      expect(MangaOcrLocalModel.fromKey('custom'), MangaOcrLocalModel.custom);
      for (final String os in <String>['windows', 'android', 'ios', 'linux']) {
        expect(
          MangaOcrLocalModel.forPlatform('custom', operatingSystem: os),
          MangaOcrLocalModel.custom,
        );
      }
      expect(
        MangaOcrLocalModel.fromKey('no_such_model'),
        kDefaultMangaOcrLocalModel,
      );
    });

    test('hosts and the server list only built-in models', () {
      expect(
        MangaOcrLocalModel.builtInValues,
        isNot(contains(MangaOcrLocalModel.custom)),
      );
      expect(
        MangaOcrLocalModel.builtInValues.length,
        MangaOcrLocalModel.values.length - 1,
      );
    });

    test('unreadable metadata reads as an empty slot', () async {
      slot.createSync(recursive: true);
      File(
        p.join(slot.path, kCustomMangaOcrInfoFileName),
      ).writeAsStringSync(jsonEncode(<String, Object?>{'display_name': 1}));
      expect(await readCustomMangaOcrModelInfo(slot), isNull);
    });
  });
}

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();
