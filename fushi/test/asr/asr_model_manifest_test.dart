import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_model_manifest.dart';
import 'package:fushi/src/onnx/model_file_downloader.dart';
import 'package:path/path.dart' as p;

const String _kJaPrimary =
    'https://huggingface.co/reazon-research/reazonspeech-k2-v2/resolve/main/';
const String _kJaSecondary =
    'https://huggingface.co/DeL-TaiseiOzaki/'
    'sherpa-onnx-zipformer-ja-reazonspeech-2024-08-01/resolve/main/';
const String _kEnPrimary =
    'https://huggingface.co/csukuangfj/'
    'sherpa-onnx-zipformer-en-libriheavy-20230830-large-punct-case/'
    'resolve/main/';
const String _kVadUrl =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
    'asr-models/silero_vad.onnx';

void main() {
  group('模型包总表', () {
    test('与 AsrLanguage.values 同序、id 互不相同且冻结', () {
      expect(
        kAsrModelPacks.map((AsrModelPack pack) => pack.language).toList(),
        AsrLanguage.values,
      );
      expect(
        kAsrModelPacks.map((AsrModelPack pack) => pack.id).toSet(),
        hasLength(kAsrModelPacks.length),
      );
      // id 是磁盘目录名与任务目录哈希的一部分：改了等于让用户已下载的模型与
      // 进行中的任务全部失联，这里钉死。
      expect(kAsrJapanesePack.id, 'reazonspeech-k2-v2');
      expect(kAsrEnglishPack.id, 'zipformer-en-libriheavy-punct-case');
      expect(kAsrJapanesePack.language, AsrLanguage.japanese);
      expect(kAsrEnglishPack.language, AsrLanguage.english);
    });

    test('asrModelPackFor 每种语言都能取到自己的包', () {
      expect(asrModelPackFor(AsrLanguage.japanese), same(kAsrJapanesePack));
      expect(asrModelPackFor(AsrLanguage.english), same(kAsrEnglishPack));
      for (final AsrLanguage language in AsrLanguage.values) {
        expect(asrModelPackFor(language).language, language);
      }
    });

    test('AsrLanguage.fromTag 往返；未知标签返回 null', () {
      for (final AsrLanguage language in AsrLanguage.values) {
        expect(AsrLanguage.fromTag(language.tag), language);
      }
      expect(AsrLanguage.japanese.tag, 'ja');
      expect(AsrLanguage.english.tag, 'en');
      expect(AsrLanguage.fromTag('zz'), isNull);
      expect(AsrLanguage.fromTag(''), isNull);
      expect(AsrLanguage.fromTag(null), isNull);
    });
  });

  group('每个包的清单构成', () {
    for (final AsrModelPack pack in kAsrModelPacks) {
      group(pack.id, () {
        test('八个角色各一、每个变体内文件名唯一，且每个角色都能按角色取到', () {
          expect(pack.files, hasLength(AsrModelRole.values.length));
          expect(
            pack.files.map((AsrModelFile f) => f.role).toSet(),
            AsrModelRole.values.toSet(),
          );
          // 上游没给 int8 decoder 的包两变体共用同一个 decoder 文件，所以只要求
          // 「每个变体内」文件名唯一（同名条目必须指向同一 URL、同一字节数）。
          for (final AsrEncoderVariant variant in AsrEncoderVariant.values) {
            final List<AsrModelFile> files = pack.filesFor(variant);
            expect(
              files.map((AsrModelFile f) => f.fileName).toSet(),
              hasLength(files.length),
              reason: variant.name,
            );
          }
          final Map<String, AsrModelFile> byName = <String, AsrModelFile>{};
          for (final AsrModelFile f in pack.files) {
            final AsrModelFile? seen = byName[f.fileName];
            if (seen != null) {
              expect(f.url, seen.url, reason: f.fileName);
              expect(f.expectedBytes, seen.expectedBytes, reason: f.fileName);
            }
            byName[f.fileName] = f;
          }
          for (final AsrModelRole role in AsrModelRole.values) {
            expect(pack.fileForRole(role).role, role);
          }
        });

        test('每个变体恰好五个文件：同精度 encoder/decoder/joiner + tokens/vad', () {
          for (final AsrEncoderVariant variant in AsrEncoderVariant.values) {
            final List<AsrModelFile> files = pack.filesFor(variant);
            expect(files, hasLength(5), reason: variant.name);
            final bool fp32 = variant == AsrEncoderVariant.fp32;
            expect(
              files.map((AsrModelFile f) => f.role).toSet(),
              <AsrModelRole>{
                fp32 ? AsrModelRole.encoderFp32 : AsrModelRole.encoderInt8,
                fp32 ? AsrModelRole.decoderFp32 : AsrModelRole.decoderInt8,
                fp32 ? AsrModelRole.joinerFp32 : AsrModelRole.joinerInt8,
                AsrModelRole.tokens,
                AsrModelRole.vad,
              },
            );
            // 编码器排第一：下载进度条与「先下最大的」都依赖这个顺序。
            expect(
              files.first.role,
              fp32 ? AsrModelRole.encoderFp32 : AsrModelRole.encoderInt8,
            );
            expect(
              pack.totalBytes(variant),
              files.fold<int>(
                0,
                (int acc, AsrModelFile f) => acc + f.expectedBytes,
              ),
            );
          }
        });

        test('文件名与远端 basename 一致（Range 续传复用同 URL 的前提）', () {
          for (final AsrModelFile f in pack.files) {
            expect(Uri.parse(f.url).pathSegments.last, f.fileName);
            for (final String mirror in f.mirrorUrls) {
              expect(Uri.parse(mirror).pathSegments.last, f.fileName);
            }
          }
        });

        test('VAD 是共用的 k2-fsa release 文件', () {
          expect(pack.fileForRole(AsrModelRole.vad), same(kAsrVadFile));
          expect(kAsrVadFile.url, _kVadUrl);
          expect(kAsrVadFile.mirrorUrls, isEmpty);
        });

        test('候选 URL 派生规则与共享层一致', () {
          for (final AsrModelFile f in pack.files) {
            expect(asrModelUrlCandidates(f), <String>[
              for (final String s in <String>[f.url, ...f.mirrorUrls])
                ...defaultHuggingFaceUrlCandidates(s),
            ]);
          }
        });
      });
    }
  });

  group('日语 ReazonSpeech k2-v2', () {
    test('精确字节数（2026-09-05 HF API ?blobs=true / GitHub release 核实）', () {
      expect(
        <AsrModelRole, int>{
          for (final AsrModelFile f in kAsrJapanesePack.files)
            f.role: f.expectedBytes,
        },
        <AsrModelRole, int>{
          AsrModelRole.encoderFp32: 592347848,
          AsrModelRole.encoderInt8: 154670139,
          AsrModelRole.decoderFp32: 11767836,
          AsrModelRole.decoderInt8: 2959337,
          AsrModelRole.joinerFp32: 10720115,
          AsrModelRole.joinerInt8: 2696970,
          AsrModelRole.tokens: 45754,
          AsrModelRole.vad: 643854,
        },
      );
      expect(
        kAsrJapanesePack.totalBytes(AsrEncoderVariant.fp32),
        592347848 + 11767836 + 10720115 + 45754 + 643854,
      );
      expect(
        kAsrJapanesePack.totalBytes(AsrEncoderVariant.int8),
        154670139 + 2959337 + 2696970 + 45754 + 643854,
      );
    });

    test('文件名：epoch-99-avg-1 系列', () {
      expect(
        kAsrJapanesePack.fileForRole(AsrModelRole.encoderFp32).fileName,
        'encoder-epoch-99-avg-1.onnx',
      );
      expect(
        kAsrJapanesePack.fileForRole(AsrModelRole.encoderInt8).fileName,
        'encoder-epoch-99-avg-1.int8.onnx',
      );
      expect(
        kAsrJapanesePack.fileForRole(AsrModelRole.tokens).fileName,
        'tokens.txt',
      );
    });

    test('主源：七个 HF 文件在 reazon-research/reazonspeech-k2-v2', () {
      for (final AsrModelFile f in kAsrJapanesePack.files) {
        if (f.role == AsrModelRole.vad) continue;
        expect(f.url, startsWith(_kJaPrimary), reason: f.fileName);
      }
      expect(
        kAsrJapanesePack.sourceUrl,
        'https://huggingface.co/reazon-research/reazonspeech-k2-v2',
      );
    });

    test('第二源只挂在它真有的四个文件上：int8 编码器、fp32 decoder/joiner、tokens', () {
      final Set<AsrModelRole> withMirror = <AsrModelRole>{
        for (final AsrModelFile f in kAsrJapanesePack.files)
          if (f.mirrorUrls.isNotEmpty) f.role,
      };
      expect(withMirror, <AsrModelRole>{
        AsrModelRole.encoderInt8,
        AsrModelRole.decoderFp32,
        AsrModelRole.joinerFp32,
        AsrModelRole.tokens,
      });
      for (final AsrModelFile f in kAsrJapanesePack.files) {
        for (final String mirror in f.mirrorUrls) {
          expect(mirror, startsWith(_kJaSecondary));
        }
      }
    });
  });

  group('英语 LibriHeavy zipformer', () {
    test('精确字节数（2026-09-05 HF API ?blobs=true / GitHub release 核实）', () {
      expect(
        <AsrModelRole, int>{
          for (final AsrModelFile f in kAsrEnglishPack.files)
            f.role: f.expectedBytes,
        },
        <AsrModelRole, int>{
          AsrModelRole.encoderFp32: 259807148,
          AsrModelRole.encoderInt8: 68780141,
          AsrModelRole.decoderFp32: 2616855,
          AsrModelRole.decoderInt8: 670318,
          AsrModelRole.joinerFp32: 1551717,
          AsrModelRole.joinerInt8: 391431,
          AsrModelRole.tokens: 7368,
          AsrModelRole.vad: 643854,
        },
      );
      expect(
        kAsrEnglishPack.totalBytes(AsrEncoderVariant.fp32),
        259807148 + 2616855 + 1551717 + 7368 + 643854,
      );
      expect(
        kAsrEnglishPack.totalBytes(AsrEncoderVariant.int8),
        68780141 + 670318 + 391431 + 7368 + 643854,
      );
    });

    test('文件名：epoch-16-avg-2 系列', () {
      expect(
        kAsrEnglishPack.fileForRole(AsrModelRole.encoderFp32).fileName,
        'encoder-epoch-16-avg-2.onnx',
      );
      expect(
        kAsrEnglishPack.fileForRole(AsrModelRole.encoderInt8).fileName,
        'encoder-epoch-16-avg-2.int8.onnx',
      );
      expect(
        kAsrEnglishPack.fileForRole(AsrModelRole.decoderInt8).fileName,
        'decoder-epoch-16-avg-2.int8.onnx',
      );
      expect(
        kAsrEnglishPack.fileForRole(AsrModelRole.joinerFp32).fileName,
        'joiner-epoch-16-avg-2.onnx',
      );
      expect(
        kAsrEnglishPack.fileForRole(AsrModelRole.tokens).fileName,
        'tokens.txt',
      );
    });

    test('主源：七个 HF 文件在 csukuangfj 的 libriheavy punct-case 仓库，没有第二源', () {
      for (final AsrModelFile f in kAsrEnglishPack.files) {
        if (f.role == AsrModelRole.vad) continue;
        expect(f.url, startsWith(_kEnPrimary), reason: f.fileName);
        expect(f.mirrorUrls, isEmpty, reason: f.fileName);
      }
      expect(
        kAsrEnglishPack.sourceUrl,
        'https://huggingface.co/csukuangfj/'
        'sherpa-onnx-zipformer-en-libriheavy-20230830-large-punct-case',
      );
    });
  });

  group('候选 URL 序列', () {
    test('主源 → 主源 hf-mirror → 第二源 → 第二源 hf-mirror', () {
      final AsrModelFile file = kAsrJapanesePack.fileForRole(
        AsrModelRole.encoderInt8,
      );
      expect(asrModelUrlCandidates(file), <String>[
        file.url,
        file.url.replaceFirst('huggingface.co', 'hf-mirror.com'),
        file.mirrorUrls.single,
        file.mirrorUrls.single.replaceFirst('huggingface.co', 'hf-mirror.com'),
      ]);
    });

    test('只有主源的 HF 文件派生两个候选（日语 int8 decoder / 英语全部）', () {
      for (final AsrModelFile file in <AsrModelFile>[
        kAsrJapanesePack.fileForRole(AsrModelRole.decoderInt8),
        kAsrEnglishPack.fileForRole(AsrModelRole.encoderFp32),
        kAsrEnglishPack.fileForRole(AsrModelRole.tokens),
      ]) {
        expect(asrModelUrlCandidates(file), <String>[
          file.url,
          file.url.replaceFirst('huggingface.co', 'hf-mirror.com'),
        ]);
      }
    });

    test('GitHub release 的 VAD 不派生 hf-mirror', () {
      expect(asrModelUrlCandidates(kAsrVadFile), <String>[kAsrVadFile.url]);
    });
  });

  group('就绪判定', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('asr_manifest_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('不存在 / 空文件不就绪，非空就绪（不校验长度==expected）', () {
      final File file = File(p.join(tempDir.path, 'tokens.txt'));
      expect(isAsrModelFileReady(file), isFalse);
      file.writeAsBytesSync(<int>[]);
      expect(isAsrModelFileReady(file), isFalse);
      file.writeAsBytesSync(<int>[1, 2, 3]);
      expect(
        isAsrModelFileReady(file),
        isTrue,
        reason: '清单 expected 过期时不能把用户已可用的旧模型判成缺失',
      );
    });
  });
}
