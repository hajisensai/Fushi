import 'dart:convert';
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
      MangaOcrLocalModel.ppOcrV6Medium,
      MangaOcrLocalModel.ppOcrV5Korean,
      MangaOcrLocalModel.charspotSmall,
      MangaOcrLocalModel.charspotNano,
      MangaOcrLocalModel.narSmall,
      MangaOcrLocalModel.custom,
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
    // 这一代不再下载；URL 仍指向还解析得到的 Release v0.2 提交（BUG-4492）。
    expect(
      old.manifest.last.url,
      'https://huggingface.co/Kellenok/PP-OCRv6_manga/resolve/'
      'd090c421598eadd2e179ad62c29ff0767492072c/rec/manga_rec_v0.2.onnx',
    );
    expect(old.manifest.last.expectedBytes, 21167540);
    expect(old.recFileName, 'kellenok_manga_rec_v0.2.onnx');
    expect(old.recDictFileName, kPpOcrRecDictFileName);
    expect(
      (old.recognizer as MangaOcrCtcColumnSpec).dictFormat,
      PpOcrCharacterDictFormat.paddleYaml,
    );
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
        // BUG-4492：上游改写历史后最早钉的 revision ba1d479e 整个 404。钉的必须是
        // 完整 commit SHA，不能是可变的分支名。
        expect(kMangaCtcRecRevision, matches(RegExp(r'^[0-9a-f]{40}$')));
        expect(kMangaCtcRecRevision, isNot(startsWith('ba1d479e')));
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

  group('general PaddleOCR recognisers (ppocrv6_medium, ppocrv5_korean)', () {
    const Map<MangaOcrLocalModel, ({String dir, String rec, String dict})>
    expected = <MangaOcrLocalModel, ({String dir, String rec, String dict})>{
      MangaOcrLocalModel.ppOcrV6Medium: (
        dir: 'ppocrv6-medium',
        rec: 'ppocrv6_medium_rec.onnx',
        dict: 'ppocrv6_medium_rec.yml',
      ),
      MangaOcrLocalModel.ppOcrV5Korean: (
        dir: 'ppocrv5-korean',
        rec: 'ppocrv5_korean_rec.onnx',
        dict: 'ppocrv5_korean_rec.yml',
      ),
    };

    test('selectable on every platform, each in its own directory', () async {
      final EnginePaths previous = enginePaths;
      final Directory root = Directory(
        p.join(Directory.systemTemp.path, 'ocr-model-resolution-general'),
      );
      enginePaths = FixedEnginePaths(
        documents: root,
        support: root,
        temp: root,
      );
      addTearDown(() => enginePaths = previous);

      for (final MapEntry<
            MangaOcrLocalModel,
            ({String dir, String rec, String dict})
          >
          entry
          in expected.entries) {
        final MangaOcrLocalModel model = entry.key;
        for (final String os in <String>[
          'windows',
          'android',
          'ios',
          'macos',
          'linux',
        ]) {
          expect(
            MangaOcrLocalModel.forPlatform(model.key, operatingSystem: os),
            model,
            reason: '${model.key} on $os',
          );
        }
        expect(model.availableOnAllPlatforms, isTrue);
        expect(MangaOcrLocalModel.fromKey(model.key), model);
        expect(
          (await model.modelsDirectory()).path,
          p.join(root.path, 'ocr_models', entry.value.dir),
        );
      }
    });

    test(
      'manifest: shared detectors + own recogniser + own YAML dictionary',
      () {
        for (final MapEntry<
              MangaOcrLocalModel,
              ({String dir, String rec, String dict})
            >
            entry
            in expected.entries) {
          final MangaOcrLocalModel model = entry.key;
          final MangaOcrModelGeneration generation = model.generation;
          expect(
            <String>[
              for (final MangaOcrModelFile file in model.manifest)
                file.fileName,
            ],
            <String>[
              'detector-v4-s_int8.onnx',
              kPpOcrDetFileName,
              entry.value.rec,
              entry.value.dict,
            ],
            reason: model.key,
          );
          expect(generation.recFileName, entry.value.rec);
          expect(generation.recDictFileName, entry.value.dict);
          expect(
            (generation.recognizer as MangaOcrCtcColumnSpec).dictFormat,
            PpOcrCharacterDictFormat.paddleYaml,
          );
          // 没有上一代：这两个模型从未换过 rec。
          expect(model.supersededGeneration, isNull);
          // 离线导入按字节数认文件：同一份清单里不能有两个文件一样大。
          final List<int> sizes = <int>[
            for (final MangaOcrModelFile file in model.manifest)
              file.expectedBytes,
          ];
          expect(sizes.toSet(), hasLength(sizes.length), reason: model.key);
        }
      },
    );

    test('recogniser and dictionary are pinned to a commit, not a branch', () {
      final RegExp pinned = RegExp(r'/resolve/[0-9a-f]{40}/');
      for (final MangaOcrLocalModel model in expected.keys) {
        final MangaOcrModelGeneration generation = model.generation;
        for (final MangaOcrModelFile file in model.manifest) {
          if (file.fileName != generation.recFileName &&
              file.fileName != generation.recDictFileName) {
            continue;
          }
          expect(
            pinned.hasMatch(file.url),
            isTrue,
            reason: '${model.key}: ${file.url}',
          );
        }
      }
      MangaOcrModelFile rec(MangaOcrLocalModel model) =>
          model.manifest.firstWhere(
            (MangaOcrModelFile f) => f.fileName == model.generation.recFileName,
          );
      expect(rec(MangaOcrLocalModel.ppOcrV6Medium).expectedBytes, 76554979);
      expect(
        rec(MangaOcrLocalModel.ppOcrV6Medium).url,
        contains('PaddlePaddle/PP-OCRv6_medium_rec_onnx/'),
      );
      expect(rec(MangaOcrLocalModel.ppOcrV5Korean).expectedBytes, 13418787);
      expect(
        rec(MangaOcrLocalModel.ppOcrV5Korean).url,
        contains('PaddlePaddle/korean_PP-OCRv5_mobile_rec_onnx/'),
      );
    });
  });

  group('muscgab manga-ocr-nar-small (nar_small)', () {
    const MangaOcrLocalModel model = MangaOcrLocalModel.narSmall;

    test('key, every platform, own directory', () async {
      final EnginePaths previous = enginePaths;
      final Directory root = Directory(
        p.join(Directory.systemTemp.path, 'ocr-model-resolution-nar'),
      );
      enginePaths = FixedEnginePaths(
        documents: root,
        support: root,
        temp: root,
      );
      addTearDown(() => enginePaths = previous);

      expect(model.key, 'nar_small');
      for (final String os in <String>[
        'windows',
        'android',
        'ios',
        'macos',
        'linux',
      ]) {
        expect(
          MangaOcrLocalModel.forPlatform(model.key, operatingSystem: os),
          model,
          reason: os,
        );
      }
      expect(model.isUserImported, isFalse);
      expect(MangaOcrLocalModel.builtInValues, contains(model));
      expect(
        (await model.modelsDirectory()).path,
        p.join(root.path, 'ocr_models', 'nar-small'),
      );
    });

    test('manifest: shared detectors + weights + vocab, no PP rec', () {
      final MangaOcrModelGeneration generation = model.generation;
      expect(
        <String>[
          for (final MangaOcrModelFile file in model.manifest) file.fileName,
        ],
        <String>[
          'detector-v4-s_int8.onnx',
          kPpOcrDetFileName,
          'nar_small.onnx',
          'nar_small_vocab.json',
        ],
      );
      expect(generation.recFileName, 'nar_small.onnx');
      expect(generation.recDictFileName, 'nar_small_vocab.json');
      expect(generation.recognizer, isA<MangaOcrNarSpec>());
      // 模型按「文字块 → 正文」训练，不读振假名：开关对它不起额外作用。
      expect(generation.recognizer.honoursIgnoreFurigana, isFalse);
      expect(model.supersededGeneration, isNull);
      expect(
        model.cacheSignature,
        allOf(contains('nar-small'), endsWith(kMangaOcrPipelineRevision)),
      );
      expect(mangaOcrGenerationForRecFile('nar_small.onnx'), same(generation));
      // 离线导入按字节数认文件：同一份清单里不能有两个文件一样大。
      final List<int> sizes = <int>[
        for (final MangaOcrModelFile file in model.manifest) file.expectedBytes,
      ];
      expect(sizes.toSet(), hasLength(sizes.length));
    });

    test('weights and vocab are pinned to a commit and a sha256', () {
      const String base =
          'https://huggingface.co/muscgab/manga-ocr-nar-small/resolve/'
          '81ff4f3313263d1da349946a9dd20d14e0fb0e66';
      final MangaOcrModelFile rec = model.manifest[2];
      final MangaOcrModelFile vocab = model.manifest[3];
      expect(rec.url, '$base/onnx/mangaocr_nar_small_fp32.onnx');
      expect(vocab.url, '$base/nar_vocabulary_6817.json');
      expect(rec.expectedBytes, 213095336);
      expect(vocab.expectedBytes, 48538);
      // 与上游 HF LFS 指纹逐字一致（下载后按它校验）。
      expect(
        rec.sha256,
        '5ee628dfd40c59c522022d87c31f8f903104198877b9ba4cf795603dc540dcf5',
      );
      expect(
        vocab.sha256,
        '9f1059427b54216c869dbf1244157f86bef74b1a0061c46a6001402c6f0c1dbf',
      );
      for (final MangaOcrModelFile file in <MangaOcrModelFile>[rec, vocab]) {
        expect(file.role, MangaOcrModelRole.recognizer);
      }
    });

    test('README credits the model and states the non-commercial licence', () {
      for (final String readme in <String>[
        File('../README.md').readAsStringSync(),
        File('../README.zh-CN.md').readAsStringSync(),
      ]) {
        expect(readme, contains('muscgab/manga-ocr-nar-small'));
        expect(readme, contains('CC BY-NC-SA 4.0'));
      }
    });
  });

  group('muscgab charspot (charspot_small, charspot_nano)', () {
    const Map<
      MangaOcrLocalModel,
      ({
        String dir,
        String rec,
        String vocab,
        String repo,
        String revision,
        int recBytes,
        int vocabBytes,
        int budget,
      })
    >
    expected =
        <
          MangaOcrLocalModel,
          ({
            String dir,
            String rec,
            String vocab,
            String repo,
            String revision,
            int recBytes,
            int vocabBytes,
            int budget,
          })
        >{
          MangaOcrLocalModel.charspotSmall: (
            dir: 'charspot-small',
            rec: 'charspot_small.onnx',
            vocab: 'charspot_small_vocab.json',
            repo: 'muscgab/manga-ocr-charspot-small',
            revision: '72ca29202673880ca9c67b1c02c107535be4472b',
            recBytes: 43992111,
            vocabBytes: 62244,
            budget: 256,
          ),
          MangaOcrLocalModel.charspotNano: (
            dir: 'charspot-nano',
            rec: 'charspot_nano.onnx',
            vocab: 'charspot_nano_vocab.json',
            repo: 'muscgab/manga-ocr-charspot-nano',
            revision: '978dc91bde3bcb36eed3cf2de679d607d1d0f30b',
            recBytes: 6926056,
            vocabBytes: 48538,
            budget: 196,
          ),
        };

    test('keys, every platform, own directory', () async {
      final EnginePaths previous = enginePaths;
      final Directory root = Directory(
        p.join(Directory.systemTemp.path, 'ocr-model-resolution-charspot'),
      );
      enginePaths = FixedEnginePaths(
        documents: root,
        support: root,
        temp: root,
      );
      addTearDown(() => enginePaths = previous);

      expect(MangaOcrLocalModel.charspotSmall.key, 'charspot_small');
      expect(MangaOcrLocalModel.charspotNano.key, 'charspot_nano');
      for (final MangaOcrLocalModel model in expected.keys) {
        for (final String os in <String>[
          'windows',
          'android',
          'ios',
          'macos',
          'linux',
        ]) {
          expect(
            MangaOcrLocalModel.forPlatform(model.key, operatingSystem: os),
            model,
            reason: '${model.key} on $os',
          );
        }
        expect(MangaOcrLocalModel.fromKey(model.key), model);
        expect(
          (await model.modelsDirectory()).path,
          p.join(root.path, 'ocr_models', expected[model]!.dir),
        );
      }
    });

    test(
      'manifest: shared detectors + charspot weights + vocab, no PP rec',
      () {
        for (final MangaOcrLocalModel model in expected.keys) {
          final MangaOcrModelGeneration generation = model.generation;
          final String rec = expected[model]!.rec;
          final String vocab = expected[model]!.vocab;
          expect(
            <String>[
              for (final MangaOcrModelFile file in model.manifest)
                file.fileName,
            ],
            <String>['detector-v4-s_int8.onnx', kPpOcrDetFileName, rec, vocab],
            reason: model.key,
          );
          expect(generation.recFileName, rec);
          expect(generation.recDictFileName, vocab);
          final MangaOcrRecognizerSpec spec = generation.recognizer;
          expect(spec, isA<MangaOcrCharspotSpec>());
          expect(
            (spec as MangaOcrCharspotSpec).cellBudget,
            expected[model]!.budget,
          );
          // 振假名在模型里就去掉了：「忽略振假名」对它不起额外作用。
          expect(spec.honoursIgnoreFurigana, isFalse);
          expect(model.supersededGeneration, isNull);
          expect(
            model.cacheSignature,
            allOf(
              contains(
                model == MangaOcrLocalModel.charspotSmall ? 'small' : 'nano',
              ),
              contains('charspot'),
              endsWith(kMangaOcrPipelineRevision),
            ),
          );
          final List<int> sizes = <int>[
            for (final MangaOcrModelFile file in model.manifest)
              file.expectedBytes,
          ];
          expect(sizes.toSet(), hasLength(sizes.length), reason: model.key);
        }
        expect(
          MangaOcrLocalModel
              .mangaCtc
              .generation
              .recognizer
              .honoursIgnoreFurigana,
          isTrue,
        );
      },
    );

    test('weights and vocab are pinned to a commit and a sha256', () {
      for (final MangaOcrLocalModel model in expected.keys) {
        final ({
          String dir,
          String rec,
          String vocab,
          String repo,
          String revision,
          int recBytes,
          int vocabBytes,
          int budget,
        })
        e = expected[model]!;
        MangaOcrModelFile file(String name) => model.manifest.firstWhere(
          (MangaOcrModelFile f) => f.fileName == name,
        );
        expect(
          file(e.rec).url,
          'https://huggingface.co/${e.repo}/resolve/${e.revision}/model.onnx',
        );
        expect(
          file(e.vocab).url,
          'https://huggingface.co/${e.repo}/resolve/${e.revision}/vocab.json',
        );
        expect(file(e.rec).expectedBytes, e.recBytes);
        expect(file(e.vocab).expectedBytes, e.vocabBytes);
        for (final String name in <String>[e.rec, e.vocab]) {
          expect(file(name).sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
          expect(file(name).role, MangaOcrModelRole.recognizer);
        }
      }
      // 与上游 HF LFS 指纹逐字一致（下载后按它校验）。
      expect(
        kCharspotSmallGeneration.manifest[2].sha256,
        '05fb79760f8e3dbc989b61f23a34c46b511818a2166573ce7e41d994f4403843',
      );
      expect(
        kCharspotNanoGeneration.manifest[2].sha256,
        'f4fc3f4d59f982f050dd4f57bde0e8d7335041a224c3813a5dfbc20c34b0e28c',
      );
    });

    test('README credits muscgab and states the non-commercial licence', () {
      for (final String readme in <String>[
        File('../README.md').readAsStringSync(),
        File('../README.zh-CN.md').readAsStringSync(),
      ]) {
        expect(readme, contains('muscgab'));
        expect(readme, contains('manga-ocr-charspot'));
        expect(readme, contains('CC BY-NC-SA 4.0'));
      }
    });

    test('model descriptions name the model and the licence', () {
      final Map<String, Object?> en =
          jsonDecode(File('lib/i18n/strings.i18n.json').readAsStringSync())
              as Map<String, Object?>;
      for (final String size in <String>['small', 'nano']) {
        final String desc = en['manga_ocr_charspot_${size}_desc']! as String;
        expect(desc, contains('Japanese only'));
        expect(desc, contains('Non-commercial licence'));
        expect(desc, contains('muscgab/manga-ocr-charspot-$size'));
        expect(en['manga_ocr_charspot_${size}_model'], isA<String>());
      }
    });
  });

  group('mangaOcrGenerationForRecFile', () {
    test('every generation has a recogniser file name of its own', () {
      final List<String> names = <String>[
        for (final MangaOcrLocalModel model in MangaOcrLocalModel.values) ...[
          model.generation.recFileName,
          ?model.supersededGeneration?.recFileName,
        ],
      ];
      expect(names.toSet(), hasLength(names.length));
    });

    test('maps a recogniser file back to the generation that owns it', () {
      // The user-imported slot's generation comes from its import metadata;
      // the synchronous lookup never claims its recogniser file.
      expect(
        mangaOcrGenerationForRecFile(
          MangaOcrLocalModel.custom.generation.recFileName,
        ),
        isNull,
      );
      for (final MangaOcrLocalModel model in MangaOcrLocalModel.builtInValues) {
        expect(
          mangaOcrGenerationForRecFile(model.generation.recFileName),
          same(model.generation),
          reason: model.key,
        );
      }
      // 上一代（v0.2 还在替 v0.3 读）要查回上一代，签名才落在老用户原来的缓存上。
      expect(
        mangaOcrGenerationForRecFile(kMangaCtcSupersededRecFileName),
        same(kMangaCtcSupersededGeneration),
      );
      expect(mangaOcrGenerationForRecFile('rec.onnx'), isNull);
    });
  });
}
