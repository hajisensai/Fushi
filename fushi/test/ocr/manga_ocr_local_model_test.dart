import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';
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
    expect(
      MangaOcrLocalModel.baberu.cacheSignature,
      isNot('local-onnx-baberu-v1-bicubic'),
    );
  });

  test('Windows supports Baberu and unknown values retain the default', () {
    expect(
      MangaOcrLocalModel.forPlatform('baberu', operatingSystem: 'windows'),
      MangaOcrLocalModel.baberu,
    );
    expect(
      MangaOcrLocalModel.forPlatform('unknown', operatingSystem: 'windows'),
      kDefaultMangaOcrLocalModel,
    );
  });

  test('default local model is the per-column CTC', () {
    expect(kDefaultMangaOcrLocalModel, MangaOcrLocalModel.mangaCtc);
    expect(MangaOcrLocalModel.values, <MangaOcrLocalModel>[
      MangaOcrLocalModel.baberu,
      MangaOcrLocalModel.mangaCtc,
    ]);
  });

  test('removed model keys fall back to the default model', () {
    // 2026-10 删除了 kha-white manga-ocr（`manga_ocr`）与 Windows 本地 Python +
    // torch CUDA 档（`manga_ocr_cuda`）；旧偏好 / 备份 / 互联对端可能还带着这些
    // key，必须落回默认模型而不是选到不存在的引擎。
    for (final String removed in <String>['manga_ocr', 'manga_ocr_cuda']) {
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
    'leftover manga-cuda directory is deleted, live models untouched',
    () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'ocr-removed-models',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final Directory cuda = Directory(p.join(root.path, 'manga-cuda'));
      Directory(p.join(cuda.path, 'python', 'Lib')).createSync(recursive: true);
      File(p.join(cuda.path, 'torch.whl')).writeAsBytesSync(<int>[1, 2, 3]);
      final List<Directory> live = <Directory>[
        for (final String name in <String>['manga-ctc', 'manga-baberu'])
          Directory(p.join(root.path, name))..createSync(),
      ];

      expect(await deleteRemovedMangaOcrModelDirs(ocrModelsRoot: root), 1);
      expect(cuda.existsSync(), isFalse);
      for (final Directory dir in live) {
        expect(dir.existsSync(), isTrue, reason: dir.path);
      }
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
      expect(MangaOcrLocalModel.baberu.availableOnAllPlatforms, isFalse);
      expect(
        (await ctc.modelsDirectory()).path,
        p.join(root.path, 'ocr_models', 'manga-ctc'),
      );
    });

    test(
      'manifest: detector + PP det + dictionary + manga rec, no manga-ocr',
      () {
        final List<String> files = <String>[
          for (final MangaOcrModelFile file
              in MangaOcrLocalModel.mangaCtc.manifest)
            file.fileName,
        ];
        expect(files, <String>[
          'detector-v4-s_int8.onnx',
          kPpOcrDetFileName,
          kPpOcrRecDictFileName,
          kMangaCtcRecFileName,
        ]);
        final MangaOcrModelFile rec = MangaOcrLocalModel.mangaCtc.manifest.last;
        expect(rec.url, contains('/resolve/$kMangaCtcRecRevision/'));
        expect(rec.expectedBytes, 21167540);
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
      '$os restored Baberu preference imports into the default model',
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
