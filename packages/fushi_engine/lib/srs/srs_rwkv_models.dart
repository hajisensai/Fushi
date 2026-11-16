/// RWKV 权重的按需下载与校验。
///
/// 只用小模型（331,511 参数，int4 状态每卡约 2.9 KB）：SM40 在真实复习记录上已比上游大模型
/// （2,762,884 参数，int8 状态每卡约 25.7 KB）还略准，大模型已移除（2026-10-21）；2026-10-27
/// 换成同架构重训的 SM56（新权重，旧快照按权重指纹被拒、自动全量重放一次）。权重不随包，
/// 用户启用时从 Fushi 自家镜像（hajisensai/Fushi release `rwkv-models`）直接下载 int8 权重；
/// 钉 URL + 字节数 + SHA-256，只认哈希。
///
/// 3.3.x 热修：以前下载作者 release 里的 `sm56-package.zip` 再解压，作者重新打包了同名资产
/// （字节数 5581795 → 4136639，里面的 `sm56/weights.int8.bin` 哈希没变），钉死的包大小 / 哈希
/// 对不上，所有用户启用 RWKV 都失败。镜像上的权重与包内那份逐字节相同。
library;

import 'dart:async';
import 'dart:io';

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

/// 小模型 SM56 的 int8 权重（作者 release small-model-sm56-2026-10-24 包内
/// `sm56/weights.int8.bin`，与 fushi_rwkv 加载的权重同一份）。
const String kSrsRwkvSmallWeightsName = 'sm56_weights.int8.bin';
const int kSrsRwkvSmallWeightsBytes = 436391;
const String kSrsRwkvSmallWeightsSha256 =
    '479b3e2bc6a1c900ba8a4a45d629965c6df2a20cc8ff294583f5aeaeea3b4fdd';

/// 权重在 Fushi 镜像上的下载地址（资产名前缀是 SHA-256 的前 16 位）。
const SrsRwkvModelFile kSrsRwkvSmallWeights = SrsRwkvModelFile(
  fileName: kSrsRwkvSmallWeightsName,
  url:
      'https://github.com/hajisensai/Fushi/releases/download/rwkv-models/479b3e2bc6a1c900-sm56-weights.int8.bin',
  expectedBytes: kSrsRwkvSmallWeightsBytes,
  sha256: kSrsRwkvSmallWeightsSha256,
);

/// 以前下载过、现在不再用的文件（[SrsRwkvModels.deleteRetired] 清理用）：已移除的大模型
/// （约 11 MB）、被 SM56 取代的 SM40 小模型权重，以及旧下载路径留下的 SM56 发布包。
const List<String> kSrsRwkvRetiredWeightsNames = <String>[
  'RWKV_trained_on_5000_10000.bin',
  'sm40_weights.int8.bin',
  'sm56-package.zip',
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

  /// 下载（断点续传 / 代理 / 换源见 [ModelFileDownloader]）int8 权重并校验 SHA-256。已就绪时
  /// 立即结束。哈希不符删掉文件抛 [SrsRwkvModelException]。
  Stream<ModelDownloadEvent> download() async* {
    if (isReady) return;
    dir.createSync(recursive: true);
    const SrsRwkvModelFile file = kSrsRwkvSmallWeights;
    final File weights = weightsFile;
    yield* ModelFileDownloader(createClient: _createClient).downloadAll(
      files: <DownloadableModelFile>[file],
      targetDir: dir,
      isReady: (File f) =>
          f.existsSync() && f.lengthSync() == file.expectedBytes,
    );
    await verifyDownloadedWeights(weights);
  }

  /// 校验下载落地的 [weights]：哈希对得上写校验标记；对不上删掉文件（下次重下）并抛
  /// [SrsRwkvModelException]。
  static Future<void> verifyDownloadedWeights(File weights) async {
    final List<int> bytes = await weights.readAsBytes();
    if (sha256.convert(bytes).toString() != kSrsRwkvSmallWeightsSha256) {
      await weights.delete();
      throw const SrsRwkvModelException(
        '$kSrsRwkvSmallWeightsName: SHA-256 mismatch (download corrupted or replaced)',
      );
    }
    await File(
      '${weights.path}.verified',
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
