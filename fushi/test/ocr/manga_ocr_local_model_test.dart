import 'dart:io';

import 'package:test/test.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart'
    show PpOcrCharacterDictFormat;
import 'package:path/path.dart' as p;

void main() {
  test('all model caches include the shared pipeline revision', () {
    final List<String> signatures = <String>[
      for (final MangaOcrLocalModel model in MangaOcrLocalModel.values)
        model.cacheSignature,
    ];
    expect(signatures.toSet(), hasLength(MangaOcrLocalModel.values.length));
    for (final String signature in signatures) {
      expect(signature, endsWith('-$kMangaOcrPipelineRevision'));
    }
  });

  test('unknown values retain the default', () {
    expect(
      MangaOcrLocalModel.forPlatform('unknown', operatingSystem: 'windows'),
      kDefaultMangaOcrLocalModel,
    );
  });

  test('default local model is the per-column CTC', () {
    expect(kDefaultMangaOcrLocalModel, MangaOcrLocalModel.mangaCtc);
    expect(MangaOcrLocalModel.values, <MangaOcrLocalModel>[
      MangaOcrLocalModel.mangaCtc,
    ]);
  });

  test('removed model keys fall back to the default model', () {
    // 2026-10 删除了 kha-white manga-ocr（`manga_ocr`）、Windows 本地 Python +
    // torch CUDA 档（`manga_ocr_cuda`）与 Baberu（`baberu`）；旧偏好 / 备份 /
    // 互联对端可能还带着这些 key，必须落回默认模型而不是选到不存在的引擎。
    for (final String removed in <String>[
      'manga_ocr',
      'manga_ocr_cuda',
      'baberu',
    ]) {
      expect(
        MangaOcrLocalModel.values.map((MangaOcrLocalModel m) => m.key),
        isNot(contains(removed)),
      );
      expect(
        MangaOcrLocalModel.fromKey(removed),
        kDefaultMangaOcrLocalModel,
        reason: removed,
      );
      expect(
        MangaOcrLocalModel.forPlatform(removed, operatingSystem: 'windows'),
        kDefaultMangaOcrLocalModel,
        reason: removed,
      );
    }
    expect(
      MangaOcrLocalModel.fromKey('manga_ctc'),
      MangaOcrLocalModel.mangaCtc,
    );
  });

  test(
    'leftover manga-cuda / manga-baberu directories are deleted, CTC untouched',
    () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'ocr-removed-models',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final Directory cuda = Directory(p.join(root.path, 'manga-cuda'));
      Directory(p.join(cuda.path, 'python', 'Lib')).createSync(recursive: true);
      File(p.join(cuda.path, 'torch.whl')).writeAsBytesSync(<int>[1, 2, 3]);
      // Baberu 目录里也有一份同名检测器：删的是整个 manga-baberu，CTC 那份不动。
      final Directory baberu = Directory(p.join(root.path, 'manga-baberu'))
        ..createSync();
      for (final String name in <String>[
        'detector-v4-s_int8.onnx',
        'vision_fp16.onnx',
        'decoder_prefill_int8.onnx',
        'decoder_step_int8.onnx',
        'vocab.json',
        'vision_fp16.onnx.part',
      ]) {
        File(p.join(baberu.path, name)).writeAsBytesSync(<int>[1]);
      }
      final Directory ctc = Directory(p.join(root.path, 'manga-ctc'))
        ..createSync();
      final File ctcDetector = File(p.join(ctc.path, 'detector-v4-s_int8.onnx'))
        ..writeAsBytesSync(<int>[1]);

      expect(await deleteRemovedMangaOcrModelDirs(ocrModelsRoot: root), 2);
      expect(cuda.existsSync(), isFalse);
      expect(baberu.existsSync(), isFalse);
      expect(ctc.existsSync(), isTrue);
      expect(ctcDetector.existsSync(), isTrue);
      // 幂等：再调一次什么都不删。
      expect(await deleteRemovedMangaOcrModelDirs(ocrModelsRoot: root), 0);
    },
  );

  test(
    'legacy manga dir: manga-ocr files deleted, PP-OCRv6 files kept',
    () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'ocr-removed-legacy-files',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final Directory legacy = Directory(p.join(root.path, 'manga'))
        ..createSync();
      final List<String> removed = <String>[
        for (final String name in kRemovedMangaOcrLegacyFileNames) ...<String>[
          name,
          '$name.part',
        ],
      ];
      for (final String name in removed) {
        File(p.join(legacy.path, name)).writeAsBytesSync(<int>[1]);
      }
      // galgame 校准 OCR 复用这三份，绝不能被清理掉。
      const List<String> kept = <String>[
        kPpOcrDetFileName,
        kPpOcrRecFileName,
        kPpOcrRecDictFileName,
      ];
      for (final String name in kept) {
        File(p.join(legacy.path, name)).writeAsBytesSync(<int>[1]);
      }
      final File ctcDetector = File(
        p.join(root.path, 'manga-ctc', 'detector-v4-s_int8.onnx'),
      )..createSync(recursive: true);

      expect(
        await deleteRemovedMangaOcrModelDirs(ocrModelsRoot: root),
        removed.length,
      );
      for (final String name in removed) {
        expect(File(p.join(legacy.path, name)).existsSync(), isFalse);
      }
      for (final String name in kept) {
        expect(File(p.join(legacy.path, name)).existsSync(), isTrue);
      }
      expect(legacy.existsSync(), isTrue);
      // 同名检测器在活模型目录里不受影响。
      expect(ctcDetector.existsSync(), isTrue);
      expect(await deleteRemovedMangaOcrModelDirs(ocrModelsRoot: root), 0);
    },
  );

  test('legacy manga dir holding only manga-ocr files is removed', () async {
    final Directory root = Directory.systemTemp.createTempSync(
      'ocr-removed-legacy-dir',
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final Directory legacy = Directory(p.join(root.path, 'manga'))
      ..createSync();
    File(p.join(legacy.path, 'encoder_model.onnx')).writeAsBytesSync(<int>[1]);
    File(p.join(legacy.path, 'vocab.txt')).writeAsBytesSync(<int>[1]);

    // 两个文件 + 删空后的目录本身。
    expect(await deleteRemovedMangaOcrModelDirs(ocrModelsRoot: root), 3);
    expect(legacy.existsSync(), isFalse);
  });

  test(
    'manga-ctc dir: v0.2 rec and its PP-OCRv6 dictionary deleted, live files kept',
    () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'ocr-removed-ctc-files',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final Directory ctc = Directory(p.join(root.path, 'manga-ctc'))
        ..createSync();
      const List<String> removed = <String>[
        'kellenok_manga_rec_v0.2.onnx',
        'kellenok_manga_rec_v0.2.onnx.part',
        kPpOcrRecDictFileName,
      ];
      final List<String> kept = <String>[
        for (final MangaOcrModelFile file
            in MangaOcrLocalModel.mangaCtc.manifest)
          file.fileName,
        '$kMangaCtcRecFileName.part',
      ];
      for (final String name in <String>[...removed, ...kept]) {
        File(p.join(ctc.path, name)).writeAsBytesSync(<int>[1]);
      }
      // galgame 校准 OCR 在 manga/ 里复用的同名字典不归这条清理管。
      final File legacyDict = File(
        p.join(root.path, 'manga', kPpOcrRecDictFileName),
      )..createSync(recursive: true);

      expect(
        await deleteRemovedMangaOcrModelDirs(ocrModelsRoot: root),
        removed.length,
      );
      for (final String name in removed) {
        expect(
          File(p.join(ctc.path, name)).existsSync(),
          isFalse,
          reason: name,
        );
      }
      for (final String name in kept) {
        expect(File(p.join(ctc.path, name)).existsSync(), isTrue, reason: name);
      }
      expect(legacyDict.existsSync(), isTrue);
      expect(await deleteRemovedMangaOcrModelDirs(ocrModelsRoot: root), 0);
    },
  );

  test(
    'manga-ctc dir: v0.2 files are kept while v0.3 is not fully downloaded',
    () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'ocr-superseded-kept',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final Directory ctc = Directory(p.join(root.path, 'manga-ctc'))
        ..createSync();
      // 老用户更新 app 后的磁盘：只有上一代的四个文件，外加半截 v0.3 下载。
      final List<String> onDisk = <String>[
        for (final MangaOcrModelFile file
            in kMangaCtcSupersededGeneration.manifest)
          file.fileName,
        '$kMangaCtcRecFileName.part',
      ];
      for (final String name in onDisk) {
        File(p.join(ctc.path, name)).writeAsBytesSync(<int>[1]);
      }

      expect(await deleteRemovedMangaOcrModelDirs(ocrModelsRoot: root), 0);
      for (final String name in onDisk) {
        expect(File(p.join(ctc.path, name)).existsSync(), isTrue, reason: name);
      }
      expect(
        installedMangaOcrGeneration(
          ctc,
          current: kMangaCtcGeneration,
          superseded: kMangaCtcSupersededGeneration,
        ),
        same(kMangaCtcSupersededGeneration),
      );

      // v0.3 下齐：当前一代接手，上一代独有的两个文件被删。
      File(p.join(ctc.path, '$kMangaCtcRecFileName.part')).deleteSync();
      for (final String name in <String>[
        kMangaCtcRecFileName,
        kMangaCtcRecDictFileName,
      ]) {
        File(p.join(ctc.path, name)).writeAsBytesSync(<int>[1]);
      }
      expect(
        installedMangaOcrGeneration(
          ctc,
          current: kMangaCtcGeneration,
          superseded: kMangaCtcSupersededGeneration,
        ),
        same(kMangaCtcGeneration),
      );
      expect(await deleteRemovedMangaOcrModelDirs(ocrModelsRoot: root), 2);
      expect(
        File(p.join(ctc.path, kMangaCtcSupersededRecFileName)).existsSync(),
        isFalse,
      );
      expect(kMangaCtcGeneration.isCompleteIn(ctc), isTrue);
    },
  );

  test('superseded generation: the exact pre-upgrade v0.2 manifest', () {
    // 文件、顺序与签名基线都不能动：指纹按清单顺序折叠，变一处就落不到老用户
    // 原来那批逐页缓存目录上。
    const MangaOcrModelGeneration old = kMangaCtcSupersededGeneration;
    expect(
      <String>[
        for (final MangaOcrModelFile file in old.manifest) file.fileName,
      ],
      <String>[
        'detector-v4-s_int8.onnx',
        kPpOcrDetFileName,
        kPpOcrRecDictFileName,
        'kellenok_manga_rec_v0.2.onnx',
      ],
    );
    expect(old.cacheSignature, startsWith('local-onnx-ctc-kellenok-v0.2-'));
    expect(old.recFileName, 'kellenok_manga_rec_v0.2.onnx');
    expect(old.recDictFileName, kPpOcrRecDictFileName);
    expect(old.recDictFormat, PpOcrCharacterDictFormat.paddleYaml);
    expect(
      MangaOcrLocalModel.mangaCtc.supersededGeneration,
      same(kMangaCtcSupersededGeneration),
    );
    expect(
      kMangaCtcGeneration.cacheSignature,
      isNot(kMangaCtcSupersededGeneration.cacheSignature),
    );
  });

  test('manga-ctc cleanup never lists a file of the live manifest', () {
    for (final MangaOcrModelFile file in MangaOcrLocalModel.mangaCtc.manifest) {
      expect(kRemovedMangaCtcFileNames, isNot(contains(file.fileName)));
    }
  });

  test('legacy cleanup never lists a PP-OCRv6 file', () {
    for (final String name in <String>[
      kPpOcrDetFileName,
      kPpOcrRecFileName,
      kPpOcrRecDictFileName,
    ]) {
      expect(kRemovedMangaOcrLegacyFileNames, isNot(contains(name)));
    }
  });

  test('removed directory names never collide with a live model', () async {
    final EnginePaths previous = enginePaths;
    final Directory root = Directory(
      p.join(Directory.systemTemp.path, 'ocr-removed-models-collision'),
    );
    enginePaths = FixedEnginePaths(documents: root, support: root, temp: root);
    addTearDown(() => enginePaths = previous);
    for (final MangaOcrLocalModel model in MangaOcrLocalModel.values) {
      expect(
        kRemovedMangaOcrModelDirNames,
        isNot(contains(p.basename((await model.modelsDirectory()).path))),
        reason: model.key,
      );
    }
  });

  group('per-column CTC (manga_ctc)', () {
    test('selectable on every platform, own directory and signature', () async {
      final EnginePaths previous = enginePaths;
      final Directory root = Directory(
        p.join(Directory.systemTemp.path, 'ocr-model-resolution-ctc'),
      );
      enginePaths = FixedEnginePaths(
        documents: root,
        support: root,
        temp: root,
      );
      addTearDown(() => enginePaths = previous);

      for (final String os in <String>[
        'windows',
        'android',
        'ios',
        'macos',
        'linux',
      ]) {
        expect(
          MangaOcrLocalModel.forPlatform('manga_ctc', operatingSystem: os),
          MangaOcrLocalModel.mangaCtc,
          reason: os,
        );
      }
      const MangaOcrLocalModel ctc = MangaOcrLocalModel.mangaCtc;
      expect(ctc.availableOnAllPlatforms, isTrue);
      expect(
        (await ctc.modelsDirectory()).path,
        p.join(root.path, 'ocr_models', 'manga-ctc'),
      );
    });

    test(
      'manifest: detector + PP det + manga rec v0.3 + its own dictionary',
      () {
        final List<String> files = <String>[
          for (final MangaOcrModelFile file
              in MangaOcrLocalModel.mangaCtc.manifest)
            file.fileName,
        ];
        expect(files, <String>[
          'detector-v4-s_int8.onnx',
          kPpOcrDetFileName,
          kMangaCtcRecFileName,
          kMangaCtcRecDictFileName,
        ]);
        // 落盘名带版本：v0.2 的文件不会被当成 v0.3。
        expect(kMangaCtcRecFileName, 'kellenok_manga_rec_v0.3.onnx');
        expect(kMangaCtcRecDictFileName, 'kellenok_manga_rec_v0.3_dict.txt');
        final MangaOcrModelFile rec = MangaOcrLocalModel.mangaCtc.manifest[2];
        expect(
          rec.url,
          endsWith('/resolve/$kMangaCtcRecRevision/rec/manga_rec.onnx'),
        );
        expect(rec.expectedBytes, 21334702);
        // rec 与字典必须来自同一个 revision：字典错一版，词表长度就对不上。
        final MangaOcrModelFile dict = MangaOcrLocalModel.mangaCtc.manifest[3];
        expect(
          dict.url,
          endsWith('/resolve/$kMangaCtcRecRevision/ppocrv6_dict.txt'),
        );
        expect(dict.expectedBytes, 76327);
        expect(dict.role, MangaOcrModelRole.recognizer);
        // 换模型必须换缓存签名：v0.2 的逐页缓存不能当成 v0.3 的结果。
        expect(
          MangaOcrLocalModel.mangaCtc.cacheSignature,
          startsWith('local-onnx-ctc-kellenok-v0.3-'),
        );
        final int total = MangaOcrLocalModel.mangaCtc.manifest.fold<int>(
          0,
          (int sum, MangaOcrModelFile file) => sum + file.expectedBytes,
        );
        expect(total, lessThan(50 * 1024 * 1024));
      },
    );

    test('README credits the manga rec and its training data', () {
      // Manga109-s 的条款要求明确标注用到了它；AnimeText 是 CC BY-NC-SA 4.0，
      // 许可风险要让读者看得见（模型从作者的 HF 仓库直接下载，本仓不转发）。
      final String readme = File('../README.md').readAsStringSync();
      expect(readme, contains('Kellenok/PP-OCRv6_manga'));
      expect(readme, contains('AnimeText'));
      expect(readme, contains('CC BY-NC-SA 4.0'));
      expect(readme, contains('Manga109-s'));
    });

    test('cache signature can never adopt manga-ocr v4 caches as its own', () {
      final String signature =
          '${MangaOcrLocalModel.mangaCtc.cacheSignature}-36f475259340';
      expect(signature, isNot(startsWith(kLocalMangaOcrEngineSignature)));
      expect(relayoutableMangaOcrEngineSignatures(signature), isEmpty);
    });
  });

  for (final String os in <String>['android', 'ios', 'macos', 'linux']) {
    test(
      '$os restored removed Baberu preference imports into the default model',
      () async {
        final EnginePaths previous = enginePaths;
        final Directory root = Directory(
          p.join(Directory.systemTemp.path, 'ocr-model-resolution'),
        );
        enginePaths = FixedEnginePaths(
          documents: root,
          support: root,
          temp: root,
        );
        addTearDown(() => enginePaths = previous);

        final MangaOcrLocalModel model = MangaOcrLocalModel.forPlatform(
          'baberu',
          operatingSystem: os,
        );
        expect(model, kDefaultMangaOcrLocalModel);
        expect(
          MangaOcrLocalModel.forPlatform('manga_ocr_cuda', operatingSystem: os),
          kDefaultMangaOcrLocalModel,
        );
        expect(model.manifest, same(kMangaCtcOcrModelManifest));
        expect(
          (await model.modelsDirectory()).path,
          p.join(root.path, 'ocr_models', 'manga-ctc'),
        );
        expect(
          model.manifest.any(
            (MangaOcrModelFile file) => file.fileName == 'vision_fp16.onnx',
          ),
          isFalse,
        );
      },
    );
  }
}
