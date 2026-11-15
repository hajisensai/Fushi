/// RWKV 权重的按需下载与校验。
///
/// 只用小模型（331,511 参数，int4 状态每卡约 2.9 KB）：SM40 在真实复习记录上已比上游大模型
/// （2,762,884 参数，int8 状态每卡约 25.7 KB）还略准，大模型已移除（2026-10-21）；2026-10-27
/// 换成同架构重训的 SM56（新权重，旧快照按权重指纹被拒、自动全量重放一次）。权重不随包，
/// 用户启用时下载 int8 权重文件本身：首选本仓库 release `rwkv-models` 上的镜像（内容寻址、永不
/// 覆盖），备用上游 fork 钉死提交的 raw 文件；只认字节数 + SHA-256。
///
/// 以前下的是作者 release 里的发布包 `sm56-package.zip` 再解出权重。作者 2026-11-13 原地替换了
/// 所有旧 release 的 zip（换掉里面的测试向量，权重没变），钉死的包字节数 / 哈希从此对不上，
/// 下载必然失败（BUG：`sm56-package.zip size mismatch: got 4136639, expected 5581795`）。
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
    this.fallbackUrls = const <String>[],
  });

  @override
  final String fileName;
  @override
  final String url;
  @override
  final int expectedBytes;
  final String sha256;

  /// [url] 连不上或返回错误时按序再试的源（同一份字节）。
  final List<String> fallbackUrls;
}

/// 小模型 SM56 的 int8 权重（JSchoreels/anki-rwkv release small-model-sm56-2026-10-24 包内的
/// `sm56/weights.int8.bin`，哈希即包内 `manifest.json` 所记；同一文件也在 JSchoreels/anki 的
/// `qt/aqt/rwkv_inference/sm56/`）。
const SrsRwkvModelFile kSrsRwkvSmallWeights = SrsRwkvModelFile(
  fileName: kSrsRwkvSmallWeightsName,
  url:
      'https://github.com/hajisensai/Fushi/releases/download/rwkv-models/479b3e2bc6a1c900-sm56-weights.int8.bin',
  expectedBytes: kSrsRwkvSmallWeightsBytes,
  sha256: kSrsRwkvSmallWeightsSha256,
  fallbackUrls: <String>[
    'https://raw.githubusercontent.com/JSchoreels/anki/001440b03395f24ffc1714b18ad3d9d4d89d2067/qt/aqt/rwkv_inference/sm56/weights.int8.bin',
  ],
);

const String kSrsRwkvSmallWeightsName = 'sm56_weights.int8.bin';
const int kSrsRwkvSmallWeightsBytes = 436391;
const String kSrsRwkvSmallWeightsSha256 =
    '479b3e2bc6a1c900ba8a4a45d629965c6df2a20cc8ff294583f5aeaeea3b4fdd';

/// 以前下载过、现在不再用的权重文件名（[SrsRwkvModels.deleteRetired] 清理用）：已移除的大模型
/// （约 11 MB），被 SM56 取代的 SM40 小模型权重，以及旧版下载的 SM56 发布包（解压后本应已删，
/// 下载中断或校验失败时会残留，含 `.part`）。
const List<String> kSrsRwkvRetiredWeightsNames = <String>[
  'RWKV_trained_on_5000_10000.bin',
  'sm40_weights.int8.bin',
  'sm56-package.zip',
  'sm56-package.zip.part',
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
  SrsRwkvModels({
    required this.dir,
    HttpClient Function()? createClient,
    this.file = kSrsRwkvSmallWeights,
  }) : _createClient = createClient;

  final Directory dir;

  /// 要下载的权重文件（测试里换成指向本地 HttpServer 的 URL）。
  final SrsRwkvModelFile file;
  final HttpClient Function()? _createClient;

  /// 运行时加载的权重文件（就绪前不存在）。
  File get weightsFile => File(p.join(dir.path, file.fileName));

  /// 校验过的标记：`<权重>.verified` 里写着它的 SHA-256。哈希只在下载完成时算一次。
  File _marker(File weights) => File('${weights.path}.verified');

  bool get isReady {
    final File weights = weightsFile;
    final File marker = _marker(weights);
    if (!weights.existsSync() || !marker.existsSync()) return false;
    return weights.lengthSync() == file.expectedBytes &&
        marker.readAsStringSync().trim() == file.sha256;
  }

  /// 下载（断点续传 / 代理见 [ModelFileDownloader]；首选源失败按 [SrsRwkvModelFile.fallbackUrls]
  /// 换源）并校验 SHA-256。已就绪时立即结束。哈希不符删掉文件抛 [SrsRwkvModelException]。
  Stream<ModelDownloadEvent> download() async* {
    if (isReady) return;
    dir.createSync(recursive: true);
    final SrsRwkvModelFile file = this.file;
    final File weights = weightsFile;
    yield* ModelFileDownloader(
      createClient: _createClient,
      urlCandidates: (DownloadableModelFile _) => <String>[
        file.url,
        ...file.fallbackUrls,
      ],
    ).downloadAll(
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
