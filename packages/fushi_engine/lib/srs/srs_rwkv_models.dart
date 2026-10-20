/// RWKV 权重的按需下载与校验。
///
/// 权重不随包：大模型 ~11 MB（AGPL-3.0-or-later，随上游仓库发布）；小模型（SM40）的许可作者还没
/// 声明，Fushi 不再分发它，只在用户启用时从作者的 GitHub release 下载。两份都钉 URL + 字节数 +
/// SHA-256（作者可以替换同名资产，所以只认哈希），与 native/fushi_rwkv/fetch_model.* 同源。
library;

import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:fushi_asr_core/asr_core.dart';
import 'package:path/path.dart' as p;

/// 用哪个 RWKV 网络。
enum SrsRwkvModelChoice {
  /// SM40 小模型（331,511 参数），int4 状态：每卡约 2.9 KB，298 个留出用户上 LogLoss 比大模型
  /// 高约 1%。默认。
  small('small'),

  /// 上游大模型（2,762,884 参数），int8 状态：每卡约 25.7 KB。质量优先。
  large('large');

  const SrsRwkvModelChoice(this.wire);

  /// 偏好里的持久化名（冻结）。
  final String wire;

  static SrsRwkvModelChoice parse(String? wire) => values.firstWhere(
    (SrsRwkvModelChoice c) => c.wire == wire,
    orElse: () => small,
  );
}

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

/// 大模型权重（kuma3-anki-core @ c639bcec，与 fushi_rwkv `MODEL_SHA256` 一致）。
const SrsRwkvModelFile kSrsRwkvLargeWeights = SrsRwkvModelFile(
  fileName: 'RWKV_trained_on_5000_10000.bin',
  url:
      'https://raw.githubusercontent.com/Pedrubik2000/kuma3-anki-core/c639bcec696f2317f9bb9a736d433b9d6c0d9c56/qt/aqt/rwkv_inference/RWKV_trained_on_5000_10000.bin',
  expectedBytes: 11082637,
  sha256: '749ad1ad18d5b6ef8c4185802fa0c1e4a14e67cd7874f3efeaae355fffb1b9ec',
);

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
  File weightsFile(SrsRwkvModelChoice choice) => File(
    p.join(
      dir.path,
      choice == SrsRwkvModelChoice.small
          ? kSrsRwkvSmallWeightsName
          : kSrsRwkvLargeWeights.fileName,
    ),
  );

  /// 校验过的标记：`<权重>.verified` 里写着它的 SHA-256。哈希只在下载完成时算一次。
  File _marker(File weights) => File('${weights.path}.verified');

  bool isReady(SrsRwkvModelChoice choice) {
    final File weights = weightsFile(choice);
    final File marker = _marker(weights);
    if (!weights.existsSync() || !marker.existsSync()) return false;
    final int bytes = choice == SrsRwkvModelChoice.small
        ? kSrsRwkvSmallWeightsBytes
        : kSrsRwkvLargeWeights.expectedBytes;
    final String sha = choice == SrsRwkvModelChoice.small
        ? kSrsRwkvSmallWeightsSha256
        : kSrsRwkvLargeWeights.sha256;
    return weights.lengthSync() == bytes &&
        marker.readAsStringSync().trim() == sha;
  }

  /// 下载（断点续传 / 代理 / 换源见 [ModelFileDownloader]）并校验 SHA-256；小模型再从包里解出
  /// int8 权重并校验。已就绪时立即结束。哈希不符删掉文件抛 [SrsRwkvModelException]。
  Stream<ModelDownloadEvent> download(SrsRwkvModelChoice choice) async* {
    if (isReady(choice)) return;
    dir.createSync(recursive: true);
    final SrsRwkvModelFile file = choice == SrsRwkvModelChoice.small
        ? kSrsRwkvSmallPackage
        : kSrsRwkvLargeWeights;
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
    final File weights = weightsFile(choice);
    if (choice == SrsRwkvModelChoice.small) {
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
      await weights.writeAsBytes(content, flush: true);
      // 包里还有测试向量与 PyTorch 检查点，运行时用不到。
      await downloaded.delete();
    }
    await _marker(weights).writeAsString(
      choice == SrsRwkvModelChoice.small
          ? kSrsRwkvSmallWeightsSha256
          : file.sha256,
      flush: true,
    );
  }

  /// 删掉某个模型的权重（设置里「删除已下载的模型」）。
  Future<void> delete(SrsRwkvModelChoice choice) async {
    final File weights = weightsFile(choice);
    for (final File f in <File>[weights, _marker(weights)]) {
      if (await f.exists()) await f.delete();
    }
  }
}
