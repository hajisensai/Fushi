/// RWKV 权重的按需下载与校验。
///
/// 只用小模型（int8 状态每卡 + 笔记约 4.5 KB；曾经的 int4 约 2.9 KB，超长历史上发散，BUG-5588）：SM40 在真实复习记录上已比上游大模型（2,762,884 参数，int8 状态
/// 每卡约 25.7 KB）还略准，大模型已移除（2026-10-21）；之后依次换成 SM56、无泄漏的 sm72e25，2026-11-15 换成
/// **Instant-Only 的 sm98**（同架构，按出示时刻的间隔训练、只训即时头：Fushi 只用 RWKV-Instant，同尺寸下
/// 即时头更准；它的曲线头没训练过，原生库对它拒绝 RWKV-Curve。见 native/fushi_rwkv/README.md「sm98」）。
/// 换权重后旧快照按权重指纹被拒、自动全量重放一次。
///
/// 设置里可改用省内存的 **Tiny Instant-Only sm101**（[SrsRwkvModelSize.tiny]）。
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

/// 省内存的 Tiny Instant-Only 小模型 sm101 的 int8 权重，与 fushi_rwkv `TINY_MODEL_INT8_SHA256` 一致。
/// card / note 流各 1 层：Fushi 的 int8 状态每卡 + 笔记约 3.1 KB（sm98 约 4.5 KB，约 −30%），即时头
/// LogLoss 0.27672（sm98 0.276191）。设置里选（[SrsRwkvModelSize.tiny]）。
const SrsRwkvModelFile kSrsRwkvTinyWeights = SrsRwkvModelFile(
  fileName: kSrsRwkvTinyWeightsName,
  urls: <String>[
    '$kSrsRwkvMirrorBase/77703dd2f2a21a1b-sm101-weights.int8.bin',
    '$kSrsRwkvUpstreamBase/sm101/weights.int8.bin',
  ],
  expectedBytes: kSrsRwkvTinyWeightsBytes,
  sha256: kSrsRwkvTinyWeightsSha256,
);

const String kSrsRwkvTinyWeightsName = 'sm101_weights.int8.bin';
const int kSrsRwkvTinyWeightsBytes = 409483;
const String kSrsRwkvTinyWeightsSha256 =
    '77703dd2f2a21a1bcadaedfed1cec93ee0fd6fd6d3c840be221e72b5e1c05066';

/// 用哪个 RWKV 小模型（整台设备一个设置，app 与无头服务端都从 `<support>/srs_rwkv/model_size` 读，见
/// srs_rwkv_attach.dart）。换了 = 换权重：按需下载新权重，旧快照按权重指纹被拒、全量重放一次。
enum SrsRwkvModelSize {
  /// Small Instant-Only（sm98），默认。
  small('small', kSrsRwkvSmallWeights),

  /// Tiny Instant-Only（sm101）：每卡状态约小 30%，即时头略差。
  tiny('tiny', kSrsRwkvTinyWeights);

  const SrsRwkvModelSize(this.persistedName, this.weights);

  /// 写进设置文件的值（持久化名，不随枚举名改）。
  final String persistedName;

  /// 这一档用的权重。
  final SrsRwkvModelFile weights;

  /// 设置文件内容 → 档位；缺失 / 认不出的值一律当默认的 [small]。
  static SrsRwkvModelSize fromPersisted(String? value) {
    final String? trimmed = value?.trim();
    for (final SrsRwkvModelSize size in values) {
      if (size.persistedName == trimmed) return size;
    }
    return small;
  }
}

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

/// [dir] 下的 RWKV 权重：是否就绪、下载、校验。[size] 选档（默认 [SrsRwkvModelSize.small]），[model] 缺省是
/// 这一档的权重（测试可以直接给一份）。
class SrsRwkvModels {
  SrsRwkvModels({
    required this.dir,
    this.size = SrsRwkvModelSize.small,
    SrsRwkvModelFile? model,
    HttpClient Function()? createClient,
  }) : model = model ?? size.weights,
       _createClient = createClient;

  final Directory dir;
  final SrsRwkvModelSize size;
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
  /// 目录里已有、但没有校验标记的权重（手动放进来的）先按同一标准验收：相符就写标记、不联网，不符才删掉去下载。
  /// 全部来源失败抛 [SrsRwkvModelException]，信息里逐个写明哪个来源、为什么失败。
  ///
  /// 取消（订阅 `cancel()`）是硬停：先停掉在途的连接，之后不再碰任何文件（不读权重、不写校验标记、不删残留），
  /// `cancel()` 返回的 future 等下载真的停下才完成——宿主关闭时 await 它，之后删目录也不会有收尾撞上来。
  /// 取消后才冒出来的文件错误（例如收尾那一刻目录被删）交给 `cancel()` 的 future，不落到 zone。
  Stream<ModelDownloadEvent> download() {
    final _DownloadCancel cancel = _DownloadCancel();
    late final StreamController<ModelDownloadEvent> out;
    Future<void>? body;
    out = StreamController<ModelDownloadEvent>(
      onListen: () {
        body = _download(out.add, cancel).then<void>(
          (_) {
            if (!cancel.requested) out.close();
          },
          onError: (Object error, StackTrace stack) {
            // 只有 cancel() 的调用方还在等：交给它的 future。
            if (cancel.requested) Error.throwWithStackTrace(error, stack);
            out
              ..addError(error, stack)
              ..close();
          },
        );
      },
      onPause: () => cancel.inner?.pause(),
      onResume: () => cancel.inner?.resume(),
      onCancel: () async {
        await cancel.stop();
        await body;
      },
    );
    return out.stream;
  }

  Future<void> _download(
    void Function(ModelDownloadEvent event) emit,
    _DownloadCancel cancel,
  ) async {
    if (isReady) return;
    dir.createSync(recursive: true);
    final SrsRwkvModelFile file = model;
    final File weights = weightsFile;
    final File part = File('${weights.path}.part');
    final List<String> failures = <String>[];
    // 没被验收过的权重 / 残留：下一个来源必须从头下（残留可能就是上一个来源失败的原因——内容不符）。
    void discard() {
      for (final File f in <File>[weights, part]) {
        if (f.existsSync()) f.deleteSync();
      }
    }

    // 目录里已有权重但没有标记（不能出网的机器手动放进来的，或上次下完、写标记前进程被杀）：先验收它，
    // 相符就用，不联网；不符才丢掉、去下载。
    if (weights.existsSync()) {
      final String? mismatch = await _accept(weights, cancel);
      if (cancel.requested || mismatch == null) return;
      discard();
    }
    for (final String url in file.urls) {
      if (cancel.requested) return;
      final Completer<void> done = Completer<void>();
      cancel.done = done;
      cancel.inner =
          ModelFileDownloader(
                // 连接由这里建、取消时由这里强关（见 [_DownloadCancel.stop]）。
                createClient: () =>
                    cancel.client = (_createClient ?? _client)(),
                urlCandidates: (DownloadableModelFile _) => <String>[url],
              )
              .downloadAll(
                files: <DownloadableModelFile>[file],
                targetDir: dir,
                isReady: (File f) =>
                    f.existsSync() && f.lengthSync() == file.expectedBytes,
              )
              .listen(
                emit,
                onError: (Object error, StackTrace stack) {
                  if (!done.isCompleted) done.completeError(error, stack);
                },
                onDone: () {
                  if (!done.isCompleted) done.complete();
                },
                cancelOnError: true,
              );
      try {
        await done.future;
      } on Object catch (error) {
        if (cancel.requested) return;
        failures.add('$url: $error');
        discard();
        continue;
      } finally {
        cancel
          ..inner = null
          ..done = null
          ..client = null;
      }
      if (cancel.requested) return;
      final String? mismatch = await _accept(weights, cancel);
      if (cancel.requested || mismatch == null) return;
      failures.add('$url: $mismatch');
      discard();
    }
    throw SrsRwkvModelException(
      '${file.fileName}: every source failed: ${failures.join('; ')}',
    );
  }

  /// 唯一的验收处：读 [weights]，字节数与 SHA-256 都与 [model] 相符就写校验标记、返回 null；不符返回
  /// 差在哪（不动文件，由调用方丢弃）。
  ///
  /// 遵守 [download] 的取消契约：读完发现已取消就不写标记、直接返回 null——调用方在 await 之后先查
  /// `cancel.requested`，再看返回值。
  Future<String?> _accept(File weights, _DownloadCancel cancel) async {
    final List<int> bytes = await weights.readAsBytes();
    if (cancel.requested) return null;
    final String actual = sha256.convert(bytes).toString();
    if (bytes.length != model.expectedBytes || actual != model.sha256) {
      return '${bytes.length} bytes, SHA-256 $actual '
          '(want ${model.expectedBytes} bytes, ${model.sha256})';
    }
    await _marker(weights).writeAsString(model.sha256, flush: true);
    return null;
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

/// [ModelFileDownloader] 不注入客户端时用的那一个（同它的缺省：统一代理装配 + 20 s 连接超时）。
HttpClient _client() =>
    createAsrHttpClient()..connectionTimeout = const Duration(seconds: 20);

/// [SrsRwkvModels.download] 一次下载的取消状态：取消标志、在途的来源订阅与它的完成信号。
class _DownloadCancel {
  bool requested = false;
  StreamSubscription<ModelDownloadEvent>? inner;
  Completer<void>? done;

  /// 在途来源用的 HTTP 客户端（[ModelFileDownloader] 每次下载建一个）。
  HttpClient? client;

  /// 取消：停掉在途的来源，再叫醒等它的循环（被取消的订阅不会再发 done），循环看到 [requested] 就退出。
  ///
  /// 先强关连接：[ModelFileDownloader] 是 async* 生成器，等下一块数据时（可长达它的卡死超时 30 s）对取消没有
  /// 反应，只有连接断了它才走到收尾。它收尾时报出的「连接断了 / 客户端已关」（[HttpException] /
  /// [SocketException] / `Client is closed` 的 [StateError]）正是这次强关的结果、也是取消要的结局，只认这三种；
  /// 没强关过连接、或冒出别的错，照常抛给 `cancel()` 的调用方。
  Future<void> stop() async {
    requested = true;
    final HttpClient? closing = client;
    closing?.close(force: true);
    try {
      await inner?.cancel();
    } on Object catch (error) {
      final bool causedByClose =
          closing != null &&
          (error is HttpException ||
              error is SocketException ||
              error is StateError);
      if (!causedByClose) rethrow;
    }
    final Completer<void>? waiting = done;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
  }
}
