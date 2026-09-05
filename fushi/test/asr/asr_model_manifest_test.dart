import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_model_manifest.dart';
import 'package:fushi/src/onnx/model_file_downloader.dart';
import 'package:path/path.dart' as p;

void main() {
  group('清单构成', () {
    test('每个变体恰好五个文件：编码器 + decoder/joiner/tokens/vad', () {
      for (final AsrEncoderVariant variant in AsrEncoderVariant.values) {
        final List<AsrModelFile> files = asrModelFilesFor(variant);
        expect(files, hasLength(5), reason: variant.name);
        expect(files.map((AsrModelFile f) => f.role).toSet(), <AsrModelRole>{
          variant == AsrEncoderVariant.fp32
              ? AsrModelRole.encoderFp32
              : AsrModelRole.encoderInt8,
          AsrModelRole.decoder,
          AsrModelRole.joiner,
          AsrModelRole.tokens,
          AsrModelRole.vad,
        });
        // 编码器排第一：下载进度条与「先下最大的」都依赖这个顺序。
        expect(
          files.first.role,
          anyOf(AsrModelRole.encoderFp32, AsrModelRole.encoderInt8),
        );
      }
    });

    test('全表按角色唯一、文件名唯一，且每个角色都能按角色取到', () {
      expect(
        kAsrModelFiles.map((AsrModelFile f) => f.role).toSet(),
        AsrModelRole.values.toSet(),
      );
      expect(
        kAsrModelFiles.map((AsrModelFile f) => f.fileName).toSet(),
        hasLength(kAsrModelFiles.length),
      );
      for (final AsrModelRole role in AsrModelRole.values) {
        expect(asrModelFileForRole(role).role, role);
      }
    });

    test('精确字节数（2026-09-05 HF API ?blobs=true / GitHub release 核实）', () {
      expect(
        <AsrModelRole, int>{
          for (final AsrModelFile f in kAsrModelFiles) f.role: f.expectedBytes,
        },
        <AsrModelRole, int>{
          AsrModelRole.encoderFp32: 592347848,
          AsrModelRole.encoderInt8: 154670139,
          AsrModelRole.decoder: 2959337,
          AsrModelRole.joiner: 2696970,
          AsrModelRole.tokens: 45754,
          AsrModelRole.vad: 643854,
        },
      );
      expect(
        asrModelTotalBytes(AsrEncoderVariant.fp32),
        592347848 + 2959337 + 2696970 + 45754 + 643854,
      );
      expect(
        asrModelTotalBytes(AsrEncoderVariant.int8),
        154670139 + 2959337 + 2696970 + 45754 + 643854,
      );
    });

    test('文件名与远端 basename 一致（Range 续传复用同 URL 的前提）', () {
      for (final AsrModelFile f in kAsrModelFiles) {
        expect(Uri.parse(f.url).pathSegments.last, f.fileName);
        for (final String mirror in f.mirrorUrls) {
          expect(Uri.parse(mirror).pathSegments.last, f.fileName);
        }
      }
    });

    test(
      '主源：五个 HF 文件在 reazon-research/reazonspeech-k2-v2，VAD 在 k2-fsa release',
      () {
        for (final AsrModelFile f in kAsrModelFiles) {
          if (f.role == AsrModelRole.vad) {
            expect(
              f.url,
              'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
              'asr-models/silero_vad.onnx',
            );
            continue;
          }
          expect(
            f.url,
            startsWith(
              'https://huggingface.co/reazon-research/reazonspeech-k2-v2/'
              'resolve/main/',
            ),
          );
        }
      },
    );

    test('第二源只挂在 int8 编码器与 tokens 上', () {
      final Set<AsrModelRole> withMirror = <AsrModelRole>{
        for (final AsrModelFile f in kAsrModelFiles)
          if (f.mirrorUrls.isNotEmpty) f.role,
      };
      expect(withMirror, <AsrModelRole>{
        AsrModelRole.encoderInt8,
        AsrModelRole.tokens,
      });
      for (final AsrModelFile f in kAsrModelFiles) {
        for (final String mirror in f.mirrorUrls) {
          expect(
            mirror,
            startsWith(
              'https://huggingface.co/DeL-TaiseiOzaki/'
              'sherpa-onnx-zipformer-ja-reazonspeech-2024-08-01/resolve/main/',
            ),
          );
        }
      }
    });
  });

  group('候选 URL 序列', () {
    test('主源 → 主源 hf-mirror → 第二源 → 第二源 hf-mirror', () {
      final List<String> candidates = asrModelUrlCandidates(
        kAsrEncoderInt8File,
      );
      expect(candidates, <String>[
        kAsrEncoderInt8File.url,
        kAsrEncoderInt8File.url.replaceFirst('huggingface.co', 'hf-mirror.com'),
        kAsrEncoderInt8File.mirrorUrls.single,
        kAsrEncoderInt8File.mirrorUrls.single.replaceFirst(
          'huggingface.co',
          'hf-mirror.com',
        ),
      ]);
    });

    test('只有主源的 HF 文件派生两个候选', () {
      expect(asrModelUrlCandidates(kAsrDecoderFile), <String>[
        kAsrDecoderFile.url,
        kAsrDecoderFile.url.replaceFirst('huggingface.co', 'hf-mirror.com'),
      ]);
    });

    test('GitHub release 的 VAD 不派生 hf-mirror', () {
      expect(asrModelUrlCandidates(kAsrVadFile), <String>[kAsrVadFile.url]);
    });

    test('派生规则与共享层一致', () {
      for (final AsrModelFile f in kAsrModelFiles) {
        expect(asrModelUrlCandidates(f), <String>[
          for (final String s in <String>[f.url, ...f.mirrorUrls])
            ...defaultHuggingFaceUrlCandidates(s),
        ]);
      }
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
