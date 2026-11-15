/// RWKV 权重的按需下载与校验。
///
/// 只用小模型（int4 状态每卡约 2.9 KB）：SM40 在真实复习记录上已比上游大模型（2,762,884 参数，int8 状态
/// 每卡约 25.7 KB）还略准，大模型已移除（2026-10-21）；之后依次换成 SM56、无泄漏的 sm72e25，2026-11-15 换成
/// **Instant-Only 的 sm98**（同架构，按出示时刻的间隔训练、只训即时头：Fushi 只用 RWKV-Instant，同尺寸下
/// 即时头更准；它的曲线头没训练过，原生库对它拒绝 RWKV-Curve。见 native/fushi_rwkv/README.md「sm98」）。
/// 换权重后旧快照按权重指纹被拒、自动全量重放一次。
///
/// 权重不随包，用户启用时下载：首选 Fushi 自己的镜像 release（`hajisensai/Fushi` tag `rwkv-models`，文件名带
/// 内容哈希前缀、永不覆盖），失败再用上游 JSchoreels/anki 钉死提交的 raw URL；校验只认字节数 + SHA-256，与
/// native/fushi_rwkv/fetch_model.* 同源。
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fushi_asr_core/asr_core.dart';
import 'package:path/path.dart' as p;

/// 一个钉死的下载文件：本地文件名、按顺序尝试的来源、字节数与 SHA-256。
class SrsRwkvModelFile implements DownloadableModelFile {
  const SrsRwkvModelFile({
    required this.fileName,
    required this.urls,
    required this.expectedBytes,
    required this.sha256,
  });

  @override
  final String fileName;

  /// 来源，首选在前（镜像 → 上游），至少一个。前一个下载失败或校验不符才用下一个。
  final List<String> urls;

  /// 首选来源（[DownloadableModelFile] 契约）。
  @override
  String get url => urls.first;

  @override
  final int expectedBytes;
  final String sha256;
}

/// Fushi 的 RWKV 权重镜像 release（内容寻址：资产名 = SHA-256 前 16 位 + 原名，已发布的资产永不覆盖）。
const String kSrsRwkvMirrorBase =
    'https://github.com/hajisensai/Fushi/releases/download/rwkv-models';

/// 上游权重所在的 JSchoreels/anki 提交（`qt/aqt/rwkv_inference/<模型>/`；release `rwkv-family-2026-11-13`
/// 说明与它逐字节相同）。只钉提交，不钉 release zip（上游会原地替换 zip）。
const String kSrsRwkvUpstreamBase =
    'https://raw.githubusercontent.com/JSchoreels/anki/001440b03395f24ffc1714b18ad3d9d4d89d2067/qt/aqt/rwkv_inference';

/// 小模型 sm98（Instant-Only）的 int8 权重，与 fushi_rwkv `SMALL_MODEL_INT8_SHA256` 一致。
const SrsRwkvModelFile kSrsRwkvSmallWeights = SrsRwkvModelFile(
  fileName: kSrsRwkvSmallWeightsName,
  urls: <String>[
    '$kSrsRwkvMirrorBase/b2f335bd712b9d60-sm98-weights.int8.bin',
    '$kSrsRwkvUpstreamBase/sm98/weights.int8.bin',
  ],
  expectedBytes: kSrsRwkvSmallWeightsBytes,
  sha256: kSrsRwkvSmallWeightsSha256,
);

const String kSrsRwkvSmallWeightsName = 'sm98_weights.int8.bin';
const int kSrsRwkvSmallWeightsBytes = 436391;
const String kSrsRwkvSmallWeightsSha256 =
    'b2f335bd712b9d602150201de41ab5a0f0a4c291644705e2aa1ed2a1bf1592c3';

/// 以前下载过、现在不再用的文件名（[SrsRwkvModels.deleteRetired] 清理用）：已移除的大模型
/// （约 11 MB），被取代的 SM40 / SM56 / sm72e25 小模型权重，以及 SM56 发布包（解压后本应已删，下载中断时
/// 可能残留）。
const List<String> kSrsRwkvRetiredWeightsNames = <String>[
  'RWKV_trained_on_5000_10000.bin',
  'sm40_weights.int8.bin',
  'sm56_weights.int8.bin',
  'sm56-package.zip',
  'sm72e25_weights.int8.bin',
];

/// 下载或校验失败。
class SrsRwkvModelException implements Exception {
  const SrsRwkvModelException(this.message);
  final String message;

  @override
  String toString() => 'SrsRwkvModelException: $message';
}

/// [dir] 下的 RWKV 权重：是否就绪、下载、校验。[model] 是要用的那份权重（默认 [kSrsRwkvSmallWeights]）。
class SrsRwkvModels {
  SrsRwkvModels({
    required this.dir,
    this.model = kSrsRwkvSmallWeights,
    HttpClient Function()? createClient,
  }) : _createClient = createClient;

  final Directory dir;
  final SrsRwkvModelFile model;
  final HttpClient Function()? _createClient;

  /// 运行时加载的权重文件（就绪前不存在）。
  File get weightsFile => File(p.join(dir.path, model.fileName));

  /// 校验过的标记：`<权重>.verified` 里写着它的 SHA-256。哈希只在下载完成时算一次。
  File _marker(File weights) => File('${weights.path}.verified');

  bool get isReady {
    final File weights = weightsFile;
    final File marker = _marker(weights);
    if (!weights.existsSync() || !marker.existsSync()) return false;
    return weights.lengthSync() == model.expectedBytes &&
        marker.readAsStringSync().trim() == model.sha256;
  }

  /// 按 [SrsRwkvModelFile.urls] 的顺序下载（每个来源内的断点续传 / 代理 / 重连见 [ModelFileDownloader]），
  /// 每个来源下完都校验字节数 + SHA-256，不符或下载失败就删掉残留、换下一个来源。已就绪时立即结束。
  /// 全部来源失败抛 [SrsRwkvModelException]，信息里逐个写明哪个来源、为什么失败。
  Stream<ModelDownloadEvent> download() async* {
    if (isReady) return;
    dir.createSync(recursive: true);
    final SrsRwkvModelFile file = model;
    final File weights = weightsFile;
    final File part = File('${weights.path}.part');
    final List<String> failures = <String>[];
    for (final String url in file.urls) {
      // 每个来源从头下：上一个来源的残留可能就是它失败的原因（内容不符）。
      for (final File f in <File>[weights, part]) {
        if (f.existsSync()) f.deleteSync();
      }
      try {
        await for (final ModelDownloadEvent event
            in ModelFileDownloader(
              createClient: _createClient,
              urlCandidates: (DownloadableModelFile _) => <String>[url],
            ).downloadAll(
              files: <DownloadableModelFile>[file],
              targetDir: dir,
              isReady: (File f) =>
                  f.existsSync() && f.lengthSync() == file.expectedBytes,
            )) {
          yield event;
        }
      } on Object catch (error) {
        failures.add('$url: $error');
        continue;
      }
      final List<int> bytes = await weights.readAsBytes();
      final String actual = sha256.convert(bytes).toString();
      if (bytes.length == file.expectedBytes && actual == file.sha256) {
        await _marker(weights).writeAsString(file.sha256, flush: true);
        return;
      }
      failures.add(
        '$url: ${bytes.length} bytes, SHA-256 $actual '
        '(want ${file.expectedBytes} bytes, ${file.sha256})',
      );
    }
    for (final File f in <File>[weights, part]) {
      if (f.existsSync()) f.deleteSync();
    }
    throw SrsRwkvModelException(
      '${file.fileName}: every source failed: ${failures.join('; ')}',
    );
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
