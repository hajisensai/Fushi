import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/ocr/manga_ocr_folder_job.dart';
import 'package:hibiki/src/ocr/manga_ocr_model_fingerprint.dart';
import 'package:hibiki/src/ocr/manga_ocr_model_manifest.dart';
import 'package:path/path.dart' as p;

/// 两个文件的迷你清单（真清单是 470MB，测试只需要同样的结构）。
const List<MangaOcrModelFile> _manifest = <MangaOcrModelFile>[
  MangaOcrModelFile(
    fileName: 'detector.onnx',
    url: 'https://example.invalid/detector.onnx',
    expectedBytes: 4,
    role: MangaOcrModelRole.detector,
  ),
  MangaOcrModelFile(
    fileName: 'encoder.onnx',
    url: 'https://example.invalid/encoder.onnx',
    expectedBytes: 4,
    role: MangaOcrModelRole.recognizer,
  ),
];

/// 把 [name] 的修改时间推后一秒，模拟真实重新下载（记忆化按 (size, mtime) 判定
/// 是否需要重算 sha256；模型是 100MB+ 的下载，不可能同尺寸同毫秒换内容）。
void _touch(Directory root, String name) {
  final File file = File(p.join(root.path, name));
  file.setLastModifiedSync(
    file.lastModifiedSync().add(const Duration(seconds: 1)),
  );
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('manga_ocr_fp_');
  });

  tearDown(() async {
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  Future<void> writeModels(String detector, String encoder) async {
    await File(p.join(root.path, 'detector.onnx')).writeAsString(detector);
    await File(p.join(root.path, 'encoder.onnx')).writeAsString(encoder);
  }

  test('模型文件缺失时没有可识别身份，退回基线签名', () async {
    expect(
      await resolveMangaOcrModelFingerprint(root, manifest: _manifest),
      isNull,
    );
    expect(
      await resolveLocalMangaOcrEngineSignature(root, manifest: _manifest),
      kLocalMangaOcrEngineSignature,
    );
  });

  // BUG-1173：manifest 无 sha256、下载 URL 指向 HuggingFace 的可变 ref `main`，
  // 上游换模型后手维护常量纹丝不动。指纹必须由**文件内容**派生。
  test('指纹由模型内容派生：同名同长度但内容不同 → 指纹不同', () async {
    await writeModels('detector-v4', 'encoder-a');
    final String? a =
        await resolveMangaOcrModelFingerprint(root, manifest: _manifest);
    expect(a, isNotNull);
    expect(a, hasLength(kMangaOcrModelFingerprintLength));

    // 另一台机器 / 另一次安装：同样的文件名与长度，不同的权重。
    final Directory other =
        await Directory.systemTemp.createTemp('manga_ocr_fp_other_');
    addTearDown(() => other.deleteSync(recursive: true));
    await File(p.join(other.path, 'detector.onnx'))
        .writeAsString('detector-v4');
    await File(p.join(other.path, 'encoder.onnx')).writeAsString('encoder-b');
    final String? b =
        await resolveMangaOcrModelFingerprint(other, manifest: _manifest);

    expect(b, isNotNull);
    expect(
      b,
      isNot(a),
      reason: '换了模型权重却复用同一个缓存目录，全库结果会陈旧且无人察觉',
    );
    expect(
      await resolveLocalMangaOcrEngineSignature(other, manifest: _manifest),
      isNot(
        await resolveLocalMangaOcrEngineSignature(root, manifest: _manifest),
      ),
    );
  });

  test('上游换模型后重下（内容变、mtime 变）→ 缓存签名变', () async {
    await writeModels('detector-v4', 'encoder-a');
    final String signatureBefore =
        await resolveLocalMangaOcrEngineSignature(root, manifest: _manifest);

    await writeModels('detector-v4', 'encoder-b');
    _touch(root, 'encoder.onnx');

    expect(
      await resolveLocalMangaOcrEngineSignature(root, manifest: _manifest),
      isNot(signatureBefore),
    );
  });

  test('重下同一份模型（内容不变、mtime 变）不误伤缓存', () async {
    await writeModels('detector-v4', 'encoder-a');
    final String signatureBefore =
        await resolveLocalMangaOcrEngineSignature(root, manifest: _manifest);

    // 用户删模型后重下同一份：mtime 变了，但内容一致，整卷缓存不该作废。
    await writeModels('detector-v4', 'encoder-a');
    _touch(root, 'encoder.onnx');
    _touch(root, 'detector.onnx');

    expect(
      await resolveLocalMangaOcrEngineSignature(root, manifest: _manifest),
      signatureBefore,
      reason: '指纹只看内容；mtime 只是记忆化的键，不能自己造成整卷重跑',
    );
  });

  test('内容不变时指纹稳定，且哈希被 (size, mtime) 记忆化', () async {
    await writeModels('detector-v4', 'encoder-a');
    final String? first =
        await resolveMangaOcrModelFingerprint(root, manifest: _manifest);
    final File sidecar =
        File(p.join(root.path, kMangaOcrModelFingerprintFileName));
    expect(sidecar.existsSync(), isTrue);

    final Map<String, dynamic> memo =
        jsonDecode(await sidecar.readAsString()) as Map<String, dynamic>;
    expect((memo['files'] as Map<String, dynamic>).keys,
        containsAll(<String>['detector.onnx', 'encoder.onnx']));

    // 第二次解析必须给出同一指纹（记忆化命中，不重算 470MB）。
    expect(
      await resolveMangaOcrModelFingerprint(root, manifest: _manifest),
      first,
    );
  });

  test('损坏的记忆化文件不影响指纹正确性', () async {
    await writeModels('detector-v4', 'encoder-a');
    final String? expected =
        await resolveMangaOcrModelFingerprint(root, manifest: _manifest);
    await File(p.join(root.path, kMangaOcrModelFingerprintFileName))
        .writeAsString('{ not json');
    expect(
      await resolveMangaOcrModelFingerprint(root, manifest: _manifest),
      expected,
    );
  });
}
