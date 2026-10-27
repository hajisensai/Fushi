/// RWKV 权重的按需下载与校验。
///
/// 只用小模型（331,511 参数，int4 状态每卡约 2.9 KB）：SM40 在真实复习记录上已比上游大模型
/// （2,762,884 参数，int8 状态每卡约 25.7 KB）还略准，大模型已移除（2026-10-21）；2026-10-27
/// 换成同架构重训的 SM56（新权重，旧快照按权重指纹被拒、自动全量重放一次）。权重不随包，
/// 用户启用时从作者的 GitHub release 下载；钉 URL + 字节数 + SHA-256（作者可以替换同名资产，所以
/// 只认哈希），与 native/fushi_rwkv/fetch_model.* 同源。
library;

import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:fushi_asr_core/asr_core.dart';
import 'package:path/path.dart' as p;

/// 一个钉死的下载文件。
class SrsRwkvModelFile implements DownloadableModelFile {
  const SrsRwkvModelFile({
    required this.fileName,
    required this.url,
    required this.expectedBytes,
    required this.sha256,
  });

  @override
  final String fileName;
  @override
  final String url;
  @override
  final int expectedBytes;
  final String sha256;
}

/// 小模型发布包（JSchoreels/anki-rwkv release small-model-sm56-2026-10-24，与 fushi_rwkv
/// `SMALL_MODEL_PACKAGE_SHA256` 一致）。
const SrsRwkvModelFile kSrsRwkvSmallPackage = SrsRwkvModelFile(
  fileName: 'sm56-package.zip',
  url:
      'https://github.com/JSchoreels/anki-rwkv/releases/download/small-model-sm56-2026-10-24/sm56-package.zip',
  expectedBytes: 5581795,
  sha256: '7b1790f49fdabf1279510247cc9bc3bf3ac461b67cf0135ab8e51589b5efe71a',
);

/// 从小模型包里解出来用的 int8 权重（包内 `manifest.json` 记的哈希）。
const String kSrsRwkvSmallWeightsEntry = 'sm56/weights.int8.bin';
const String kSrsRwkvSmallWeightsName = 'sm56_weights.int8.bin';
const int kSrsRwkvSmallWeightsBytes = 436391;
const String kSrsRwkvSmallWeightsSha256 =
    '479b3e2bc6a1c900ba8a4a45d629965c6df2a20cc8ff294583f5aeaeea3b4fdd';

/// 以前下载过、现在不再用的权重文件名（[SrsRwkvModels.deleteRetired] 清理用）：已移除的大模型
/// （约 11 MB），以及被 SM56 取代的 SM40 小模型权重。
const List<String> kSrsRwkvRetiredWeightsNames = <String>[
  'RWKV_trained_on_5000_10000.bin',
  'sm40_weights.int8.bin',
];

/// 下载或校验失败。
class SrsRwkvModelException implements Exception {
  const SrsRwkvModelException(this.message);
  final String message;

  @override
  String toString() => 'SrsRwkvModelException: $message';
}

/// [dir] 下的 RWKV 权重：是否就绪、下载、校验。
class SrsRwkvModels {
  SrsRwkvModels({required this.dir, HttpClient Function()? createClient})
    : _createClient = createClient;

  final Directory dir;
  final HttpClient Function()? _createClient;

  /// 运行时加载的权重文件（就绪前不存在）。
  File get weightsFile => File(p.join(dir.path, kSrsRwkvSmallWeightsName));

  /// 校验过的标记：`<权重>.verified` 里写着它的 SHA-256。哈希只在下载完成时算一次。
  File _marker(File weights) => File('${weights.path}.verified');

  bool get isReady {
    final File weights = weightsFile;
    final File marker = _marker(weights);
    if (!weights.existsSync() || !marker.existsSync()) return false;
    return weights.lengthSync() == kSrsRwkvSmallWeightsBytes &&
        marker.readAsStringSync().trim() == kSrsRwkvSmallWeightsSha256;
  }

  /// 下载（断点续传 / 代理 / 换源见 [ModelFileDownloader]）并校验 SHA-256，再从包里解出 int8
  /// 权重并校验。已就绪时立即结束。哈希不符删掉文件抛 [SrsRwkvModelException]。
  Stream<ModelDownloadEvent> download() async* {
    if (isReady) return;
    dir.createSync(recursive: true);
    const SrsRwkvModelFile file = kSrsRwkvSmallPackage;
    final File downloaded = File(p.join(dir.path, file.fileName));
    yield* ModelFileDownloader(createClient: _createClient).downloadAll(
      files: <DownloadableModelFile>[file],
      targetDir: dir,
      isReady: (File f) =>
          f.existsSync() && f.lengthSync() == file.expectedBytes,
    );
    final List<int> bytes = await downloaded.readAsBytes();
    if (sha256.convert(bytes).toString() != file.sha256) {
      await downloaded.delete();
      throw SrsRwkvModelException(
        '${file.fileName}: SHA-256 mismatch (download corrupted or replaced)',
      );
    }
    final ArchiveFile? entry = ZipDecoder()
        .decodeBytes(bytes)
        .findFile(kSrsRwkvSmallWeightsEntry);
    if (entry == null) {
      throw const SrsRwkvModelException(
        'small model package lacks $kSrsRwkvSmallWeightsEntry',
      );
    }
    final List<int> content = entry.content as List<int>;
    if (sha256.convert(content).toString() != kSrsRwkvSmallWeightsSha256) {
      throw const SrsRwkvModelException(
        '$kSrsRwkvSmallWeightsName: SHA-256 mismatch',
      );
    }
    final File weights = weightsFile;
    await weights.writeAsBytes(content, flush: true);
    // 包里还有测试向量与 PyTorch 检查点，运行时用不到。
    await downloaded.delete();
    await _marker(
      weights,
    ).writeAsString(kSrsRwkvSmallWeightsSha256, flush: true);
  }

  /// 删掉 [kSrsRwkvRetiredWeightsNames] 里以前下载的权重与校验标记；没有就什么也不做。
  Future<void> deleteRetired() async {
    for (final String name in kSrsRwkvRetiredWeightsNames) {
      final File weights = File(p.join(dir.path, name));
      for (final File f in <File>[weights, _marker(weights)]) {
        if (await f.exists()) await f.delete();
      }
    }
  }
}
