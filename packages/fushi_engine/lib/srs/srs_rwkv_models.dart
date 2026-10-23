/// RWKV 权重的按需下载与校验。
///
/// 只用 SM40 小模型（331,511 参数，int4 状态每卡约 2.9 KB）：在真实复习记录上比上游大模型
/// （2,762,884 参数，int8 状态每卡约 25.7 KB）还略准，大模型已移除（2026-10-21）。权重不随包，
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

/// 小模型发布包（JSchoreels/anki-rwkv release small-model-sm40-2026-10-19，与 fushi_rwkv
/// `SMALL_MODEL_PACKAGE_SHA256` 一致）。
const SrsRwkvModelFile kSrsRwkvSmallPackage = SrsRwkvModelFile(
  fileName: 'sm40v2-package.zip',
  url:
      'https://github.com/JSchoreels/anki-rwkv/releases/download/small-model-sm40-2026-10-19/sm40v2-package.zip',
  expectedBytes: 5582672,
  sha256: '9bc1e3e4040ce9693f230e905abb5c925b1102f787424b9059543ae900f1e2a2',
);

/// 从小模型包里解出来用的 int8 权重（包内 `manifest.json` 记的哈希）。
const String kSrsRwkvSmallWeightsEntry = 'sm40v2/weights.int8.bin';
const String kSrsRwkvSmallWeightsName = 'sm40_weights.int8.bin';
const int kSrsRwkvSmallWeightsBytes = 436391;
const String kSrsRwkvSmallWeightsSha256 =
    '6196c5fadd611827123102563639393fdcea99bfca83e3fb336fae1cd4bfc7c8';

/// 已移除的大模型以前下载到的文件名（[SrsRwkvModels.deleteRetired] 清理用）。
const String kSrsRwkvRetiredLargeWeightsName = 'RWKV_trained_on_5000_10000.bin';

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

  /// 删掉以前选过大模型时下载的权重（约 11 MB）；没有就什么也不做。
  Future<void> deleteRetired() async {
    final File weights = File(
      p.join(dir.path, kSrsRwkvRetiredLargeWeightsName),
    );
    for (final File f in <File>[weights, _marker(weights)]) {
      if (await f.exists()) await f.delete();
    }
  }
}
