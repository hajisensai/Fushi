/// RWKV 权重的按需下载与校验。
///
/// 只用小模型（331,511 参数，int4 状态每卡约 2.9 KB）：SM40 在真实复习记录上已比上游大模型
/// （2,762,884 参数，int8 状态每卡约 25.7 KB）还略准，大模型已移除（2026-10-21）；2026-10-27
/// 换成同架构重训的 SM56，2026-11-07 换成无泄漏的 sm72e25（SM72 第 25 轮起降温；部署路径 295 个
/// 封存用户上 LogLoss 比 SM56 低 0.39%，见 native/fushi_rwkv/README.md「sm72e25」）。换权重后旧快照
/// 按权重指纹被拒、自动全量重放一次。权重不随包，用户启用时下载；钉 URL（上游提交）+ 字节数 +
/// SHA-256，与 native/fushi_rwkv/fetch_model.* 同源。
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

/// 小模型 int8 权重（JSchoreels/anki @ 986963d2 的 `qt/aqt/rwkv_inference/sm72e25/weights.int8.bin`，
/// 与 fushi_rwkv `SMALL_MODEL_INT8_SHA256` 一致）。
const SrsRwkvModelFile kSrsRwkvSmallWeights = SrsRwkvModelFile(
  fileName: kSrsRwkvSmallWeightsName,
  url:
      'https://raw.githubusercontent.com/JSchoreels/anki/986963d23e7ec9f22771c38998ef9042214c2b98/qt/aqt/rwkv_inference/sm72e25/weights.int8.bin',
  expectedBytes: kSrsRwkvSmallWeightsBytes,
  sha256: kSrsRwkvSmallWeightsSha256,
);

const String kSrsRwkvSmallWeightsName = 'sm72e25_weights.int8.bin';
const int kSrsRwkvSmallWeightsBytes = 436391;
const String kSrsRwkvSmallWeightsSha256 =
    'ff626af2e974346ed282615d190500148b22cfe05cbfd081b1e70d5a1dfa3cd9';

/// 以前下载过、现在不再用的文件名（[SrsRwkvModels.deleteRetired] 清理用）：已移除的大模型
/// （约 11 MB），被取代的 SM40 / SM56 小模型权重，以及 SM56 发布包（解压后本应已删，下载中断时
/// 可能残留）。
const List<String> kSrsRwkvRetiredWeightsNames = <String>[
  'RWKV_trained_on_5000_10000.bin',
  'sm40_weights.int8.bin',
  'sm56_weights.int8.bin',
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

  /// 下载（断点续传 / 代理 / 换源见 [ModelFileDownloader]）并校验 SHA-256。已就绪时立即结束。
  /// 哈希不符删掉文件抛 [SrsRwkvModelException]。
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
    final List<int> bytes = await weights.readAsBytes();
    if (sha256.convert(bytes).toString() != file.sha256) {
      await weights.delete();
      throw SrsRwkvModelException(
        '${file.fileName}: SHA-256 mismatch (download corrupted or replaced)',
      );
    }
    await _marker(weights).writeAsString(file.sha256, flush: true);
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
