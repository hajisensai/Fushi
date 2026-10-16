/// Windows GPU 推理环境：**按需下载、不随包**，在转录模型的下模型阶段按显卡自动
/// 挑一种一起下。只有语音转录用得上它：OCR（漫画整卷 / 直读、gal 校准、分格检测）
/// 在 Windows 上有意只走 CPU（`acceleratedProviderPreference` 对 Windows 返回
/// 空表，BUG-2050 实测拍板），装不装 GPU 环境对它没有任何影响，所以 OCR 模型的
/// 下载入口不接 `withGpuRuntimeDownload`、老用户补下判据也不看 OCR 模型。哪天 OCR
/// 重新要 GPU，要先改那张偏好表，再把这两处一起接上。
///
/// 随包的只有最新 ORT **CPU** core（`flutter_onnxruntime` 插件，见其 PATCHES.md
/// 第 13 条）。两种环境：
/// - [GpuRuntimeKind.cuda]：ORT 官方 CUDA plugin EP（与随包 core 同一 revision）+
///   cuBLAS + cuDNN，约 0.9 GB 下载。插件 `registerCudaRuntime` 在运行时注册，
///   随包 core 不换。N 卡（驱动 ≥ R580、sm_75+）上比 DirectML 快约 3 倍。
/// - [GpuRuntimeKind.directml]：`Microsoft.ML.OnnxRuntime.DirectML` 的
///   onnxruntime.dll（DirectML 只在这个包里，最后一版 1.24.4）+ DirectML.dll，约
///   15 MB 下载。它**替换**本进程的 core：启动时、任何 ORT 调用之前
///   `selectOrtRuntime` 选中它（一个进程只能有一份 onnxruntime.dll）。
///
/// 来源全是官方发行物（GitHub release / PyPI wheel / NuGet nupkg，都是 zip）。
/// **不下整包**：先用 HTTP Range 读 zip 的中央目录，再只取需要的成员的压缩数据
/// （CUDA 的 wheel 里大半用不到），落成 `.deflate.part`（可 Range 续传）后本地
/// 解压。每个成员钉解压后字节数与 sha256——下来的是要塞进本进程执行的机器码，
/// 长度校验不够。
///
/// 目录：`<数据根>/gpu_runtime/<kind>/<version>/`，装完写 [_kMarker]；换版本就是
/// 换目录，旧目录由 [GpuRuntimeStore.removeStale] 清。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:path/path.dart' as p;

const String _kMarker = '.complete';

/// 下载进度事件的字节间隔。
const int _kProgressInterval = 512 * 1024;

/// 两种 GPU 环境。
enum GpuRuntimeKind { cuda, directml }

/// zip 里要取的一个成员。
class GpuRuntimeMember {
  const GpuRuntimeMember({
    required this.path,
    required this.bytes,
    required this.compressedBytes,
    required this.sha256,
  });

  /// zip 内路径；落盘取 basename。
  final String path;

  /// 解压后字节数。
  final int bytes;

  /// 压缩后字节数（即下载量；与中央目录不符视为来源被换过）。
  final int compressedBytes;

  /// 解压后内容的 sha256（小写十六进制）。
  final String sha256;

  String get fileName => p.posix.basename(path);
}

/// 一个远端 zip 发行物及要从里面取的成员。
class GpuRuntimeArchive {
  const GpuRuntimeArchive({required this.url, required this.members});

  final String url;
  final List<GpuRuntimeMember> members;
}

/// 一种环境的完整清单。
class GpuRuntimeEnvironment {
  const GpuRuntimeEnvironment({
    required this.kind,
    required this.version,
    required this.archives,
  });

  final GpuRuntimeKind kind;

  /// 版本（目录名）。换任何一个成员都要改它。
  final String version;
  final List<GpuRuntimeArchive> archives;

  Iterable<GpuRuntimeMember> get members =>
      archives.expand((GpuRuntimeArchive a) => a.members);

  /// 下载字节数（成员压缩大小之和）。
  int get downloadBytes => members.fold<int>(
    0,
    (int acc, GpuRuntimeMember m) => acc + m.compressedBytes,
  );

  /// 装好后占用的磁盘字节数。
  int get installedBytes =>
      members.fold<int>(0, (int acc, GpuRuntimeMember m) => acc + m.bytes);
}

/// CUDA 13 环境。实测最小集：去掉 cudnn_adv / nvblas 仍可跑（cudart 已静态链进
/// 插件）；只留 cnn/ops/graph/heuristic/precompiled 会在 Conv 报
/// `CUDNN_BACKEND_API_FAILED`。
const GpuRuntimeEnvironment kCudaRuntimeEnvironment = GpuRuntimeEnvironment(
  kind: GpuRuntimeKind.cuda,
  version: 'cu13-ep0.3.0-cudnn9.27',
  archives: <GpuRuntimeArchive>[
    GpuRuntimeArchive(
      url:
          'https://github.com/microsoft/onnxruntime/releases/download/'
          'plugin-ep-cuda/v0.3.0/cuda_ep_cuda13_0.3.0_win-x64.zip',
      members: <GpuRuntimeMember>[
        GpuRuntimeMember(
          path: 'onnxruntime_providers_cuda.dll',
          bytes: 195764536,
          compressedBytes: 152477385,
          sha256:
              'e88849e637c435a8b919b2007925a55b05d655bcf018e857cf943fa41ad5c86a',
        ),
      ],
    ),
    GpuRuntimeArchive(
      url:
          'https://files.pythonhosted.org/packages/a3/df/'
          'f1246959833e2c437db8be3e5b477f66b87f8817821ed40de6c7561c9a36/'
          'nvidia_cublas-13.8.0.4-py3-none-win_amd64.whl',
      members: <GpuRuntimeMember>[
        GpuRuntimeMember(
          path: 'nvidia/cu13/bin/x86_64/cublas64_13.dll',
          bytes: 54873200,
          compressedBytes: 50740237,
          sha256:
              '60bbba8868290311e9c1657b2193ddec667744eb555ff843f87acb7c039f9efa',
        ),
        GpuRuntimeMember(
          path: 'nvidia/cu13/bin/x86_64/cublasLt64_13.dll',
          bytes: 493474416,
          compressedBytes: 372350161,
          sha256:
              'cad63434448e7141629e240ea093ad596a7ef6a0f67b468ba9bc1df6e1eeee33',
        ),
      ],
    ),
    GpuRuntimeArchive(
      url:
          'https://files.pythonhosted.org/packages/87/6a/'
          'e55ff0ac26a5c6e2b21f41c9d04ad096b4ed6da593fba7e25845c61b0532/'
          'nvidia_cudnn_cu13-9.27.0.42-py3-none-win_amd64.whl',
      members: <GpuRuntimeMember>[
        GpuRuntimeMember(
          path: 'nvidia/cudnn/bin/cudnn64_9.dll',
          bytes: 270448,
          compressedBytes: 121298,
          sha256:
              '0016bd73ac9192537ae5af6a3f05814316726dad1d1da44f113f0a9ef00ae34c',
        ),
        GpuRuntimeMember(
          path: 'nvidia/cudnn/bin/cudnn_cnn64_9.dll',
          bytes: 1533040,
          compressedBytes: 1155789,
          sha256:
              '7dd1bcc6d8f00ad635f6a8a2cd076faba21626f3412e13c61a6bece3f88eacb1',
        ),
        GpuRuntimeMember(
          path: 'nvidia/cudnn/bin/cudnn_engines_precompiled64_9.dll',
          bytes: 231660656,
          compressedBytes: 198094908,
          sha256:
              '5d9b829228ae18594dafedf718d9612606c8ce6d199aa7151bea53e863baeefe',
        ),
        GpuRuntimeMember(
          path: 'nvidia/cudnn/bin/cudnn_engines_runtime_compiled64_9.dll',
          bytes: 39266928,
          compressedBytes: 18924122,
          sha256:
              '8e65eeb0a4a3b7afa48ea3ca71c4b88e355199f85485b6fc0badcc97ebc552ef',
        ),
        GpuRuntimeMember(
          path: 'nvidia/cudnn/bin/cudnn_engines_tensor_ir64_9.dll',
          bytes: 156272,
          compressedBytes: 70044,
          sha256:
              '51afb44ce4b901ccdac1434f9fc9d8d707b690f39ae1e2a6ffca98c5fd9dfa96',
        ),
        GpuRuntimeMember(
          path: 'nvidia/cudnn/bin/cudnn_ext64_9.dll',
          bytes: 130160,
          compressedBytes: 63256,
          sha256:
              'a0e0e2e8e8e4678956bbef93fdccc4730bd5edf9b23d38bff49030ebba1940a6',
        ),
        GpuRuntimeMember(
          path: 'nvidia/cudnn/bin/cudnn_graph64_9.dll',
          bytes: 116132464,
          compressedBytes: 48000207,
          sha256:
              'ccc90435b2fd37b5ddd6a9fa0fd053ad8f46c2dc8b0a6256ef0ebea7f3efbace',
        ),
        GpuRuntimeMember(
          path: 'nvidia/cudnn/bin/cudnn_heuristic64_9.dll',
          bytes: 94795376,
          compressedBytes: 34324022,
          sha256:
              'c0439ee74a3dbec8ecf56fecbc6ac2506efcce702453e36119649545d02509c3',
        ),
        GpuRuntimeMember(
          path: 'nvidia/cudnn/bin/cudnn_ops64_9.dll',
          bytes: 37462128,
          compressedBytes: 35208630,
          sha256:
              '2bd7f4122eaeccb85538c2a6f7923d7254ad77d7b7149fed0a8139f1e3cf0b07',
        ),
      ],
    ),
  ],
);

/// DirectML 环境：DirectML 版 ORT core + DirectML.dll（与 core 同目录，
/// `LoadLibraryEx(LOAD_WITH_ALTERED_SEARCH_PATH)` 从这里解析）。
const GpuRuntimeEnvironment kDirectMlRuntimeEnvironment = GpuRuntimeEnvironment(
  kind: GpuRuntimeKind.directml,
  version: 'ort1.24.4-dml1.15.4',
  archives: <GpuRuntimeArchive>[
    GpuRuntimeArchive(
      url:
          'https://api.nuget.org/v3-flatcontainer/'
          'microsoft.ml.onnxruntime.directml/1.24.4/'
          'microsoft.ml.onnxruntime.directml.1.24.4.nupkg',
      members: <GpuRuntimeMember>[
        GpuRuntimeMember(
          path: 'runtimes/win-x64/native/onnxruntime.dll',
          bytes: 17328152,
          compressedBytes: 6039111,
          sha256:
              'e7eedec6a6f26dc39dc948276a75ef6d2bee3fff944d874ceed0bbd3b97bff40',
        ),
      ],
    ),
    GpuRuntimeArchive(
      url:
          'https://api.nuget.org/v3-flatcontainer/microsoft.ai.directml/'
          '1.15.4/microsoft.ai.directml.1.15.4.nupkg',
      members: <GpuRuntimeMember>[
        GpuRuntimeMember(
          path: 'bin/x64-win/DirectML.dll',
          bytes: 18527776,
          compressedBytes: 9332741,
          sha256:
              '9c9e6d822561c6c41b90e6994b3e8857cf1d66dbfb1e0c4c799c7c89b4e92da1',
        ),
      ],
    ),
  ],
);

/// 按种类取生产清单。
GpuRuntimeEnvironment gpuRuntimeEnvironmentOf(GpuRuntimeKind kind) =>
    switch (kind) {
      GpuRuntimeKind.cuda => kCudaRuntimeEnvironment,
      GpuRuntimeKind.directml => kDirectMlRuntimeEnvironment,
    };

/// 安装进度阶段。
enum GpuRuntimeInstallPhase { download, verify, done }

/// 安装进度：[received] / [total] 按**整个环境**的下载字节累计。
class GpuRuntimeInstallProgress {
  const GpuRuntimeInstallProgress({
    required this.phase,
    required this.received,
    required this.total,
    this.fileName,
    this.memberReceived = 0,
    this.memberTotal = 0,
  });

  final GpuRuntimeInstallPhase phase;
  final int received;
  final int total;
  final String? fileName;

  /// 当前成员已收 / 应收的压缩字节（逐文件进度）。
  final int memberReceived;
  final int memberTotal;

  double get fraction => total <= 0 ? 0 : (received / total).clamp(0.0, 1.0);
}

/// 来源内容与清单不符（被换过、截断、校验和不对）。坏文件已删除，可重试。
class GpuRuntimeCorruptException implements Exception {
  const GpuRuntimeCorruptException(this.message);
  final String message;
  @override
  String toString() => 'GpuRuntimeCorruptException: $message';
}

/// 一种环境在磁盘上的安装。
class GpuRuntimeStore {
  GpuRuntimeStore(
    this.root,
    this.environment, {
    HttpClient Function()? httpClient,
  }) : _httpClient = httpClient ?? asr.createAsrHttpClient;

  /// `<数据根>/gpu_runtime`。
  final Directory root;
  final GpuRuntimeEnvironment environment;

  /// 出站客户端（生产经 `asrHttpClientFactory` 走全应用代理装配）。
  final HttpClient Function() _httpClient;

  Directory get _kindRoot =>
      Directory(p.join(root.path, environment.kind.name));

  /// 本版本的环境目录（CUDA 交给 `registerCudaRuntime`）。
  Directory get dir => Directory(p.join(_kindRoot.path, environment.version));

  /// DirectML 环境里要 `selectOrtRuntime` 的 core 路径。
  String get ortCorePath => p.join(dir.path, 'onnxruntime.dll');

  /// 还要下载的字节数（已落位的成员不算；`.deflate.part` 残留按全量估）。
  int get pendingDownloadBytes => environment.members
      .where((GpuRuntimeMember m) => !_memberReady(m))
      .fold<int>(0, (int acc, GpuRuntimeMember m) => acc + m.compressedBytes);

  /// 装完且每个文件字节数都对（sha256 在安装时已核过）。
  bool get isReady {
    if (!File(p.join(dir.path, _kMarker)).existsSync()) return false;
    for (final GpuRuntimeMember m in environment.members) {
      if (!_memberReady(m)) return false;
    }
    return true;
  }

  bool _memberReady(GpuRuntimeMember m) {
    final File f = File(p.join(dir.path, m.fileName));
    return f.existsSync() && f.lengthSync() == m.bytes;
  }

  /// 逐成员：Range 取压缩数据（续传）→ 本地解压并核 sha256 → 改名落位。
  /// 可重入：已落位的成员跳过。
  Stream<GpuRuntimeInstallProgress> install() async* {
    await dir.create(recursive: true);
    final int total = environment.downloadBytes;
    int base = 0;
    final HttpClient client = _httpClient();
    try {
      for (final GpuRuntimeArchive archive in environment.archives) {
        final List<GpuRuntimeMember> pending = archive.members
            .where((GpuRuntimeMember m) => !_memberReady(m))
            .toList();
        for (final GpuRuntimeMember m in archive.members) {
          if (!pending.contains(m)) base += m.compressedBytes;
        }
        if (pending.isEmpty) continue;
        final _RemoteZip zip = _RemoteZip(client, Uri.parse(archive.url));
        final Map<String, _ZipEntry> entries = await zip.centralDirectory();
        for (final GpuRuntimeMember m in pending) {
          final _ZipEntry? entry = entries[m.path];
          if (entry == null) {
            throw GpuRuntimeCorruptException('${archive.url} 里没有 ${m.path}');
          }
          if (entry.compressedSize != m.compressedBytes ||
              entry.size != m.bytes ||
              (entry.method != 0 && entry.method != 8)) {
            throw GpuRuntimeCorruptException(
              '${m.path} 在中央目录里是 ${entry.compressedSize}/${entry.size} '
              '字节（method ${entry.method}），清单是 '
              '${m.compressedBytes}/${m.bytes}',
            );
          }
          final File deflated = File(
            p.join(dir.path, '${m.fileName}.deflate.part'),
          );
          int reported = -1;
          await for (final int received in zip.fetchMember(entry, deflated)) {
            // 节流：几百 MB 的成员逐 chunk 回报会淹没 UI。
            if (reported >= 0 &&
                received - reported < _kProgressInterval &&
                received != m.compressedBytes) {
              continue;
            }
            reported = received;
            yield GpuRuntimeInstallProgress(
              phase: GpuRuntimeInstallPhase.download,
              received: base + received,
              total: total,
              fileName: m.fileName,
              memberReceived: received,
              memberTotal: m.compressedBytes,
            );
          }
          yield GpuRuntimeInstallProgress(
            phase: GpuRuntimeInstallPhase.verify,
            received: base + m.compressedBytes,
            total: total,
            fileName: m.fileName,
            memberReceived: m.compressedBytes,
            memberTotal: m.compressedBytes,
          );
          await _inflateAndVerify(deflated, entry.method, m);
          base += m.compressedBytes;
        }
      }
    } finally {
      client.close(force: true);
    }
    await File(p.join(dir.path, _kMarker)).writeAsString(environment.version);
    yield GpuRuntimeInstallProgress(
      phase: GpuRuntimeInstallPhase.done,
      received: total,
      total: total,
    );
  }

  Future<void> _inflateAndVerify(
    File deflated,
    int method,
    GpuRuntimeMember m,
  ) async {
    final File target = File(p.join(dir.path, m.fileName));
    final File part = File('${target.path}.part');
    final _DigestSink digestSink = _DigestSink();
    final ByteConversionSink hasher = sha256.startChunkedConversion(digestSink);
    final IOSink out = part.openWrite();
    int size = 0;
    try {
      final Stream<List<int>> raw = deflated.openRead();
      final Stream<List<int>> data = method == 8
          ? raw.transform(ZLibDecoder(raw: true))
          : raw;
      await for (final List<int> chunk in data) {
        size += chunk.length;
        hasher.add(chunk);
        out.add(chunk);
      }
    } on FormatException catch (error) {
      await out.close();
      await _deleteQuietly(part);
      await _deleteQuietly(deflated);
      throw GpuRuntimeCorruptException('${m.path} 解压失败：$error');
    }
    await out.close();
    hasher.close();
    final String digest = digestSink.value.toString();
    if (size != m.bytes || digest != m.sha256) {
      await _deleteQuietly(part);
      await _deleteQuietly(deflated);
      throw GpuRuntimeCorruptException(
        '${m.path} 解压后 $size 字节 sha256 $digest，'
        '预期 ${m.bytes} 字节 ${m.sha256}',
      );
    }
    if (await target.exists()) await target.delete();
    await part.rename(target.path);
    await _deleteQuietly(deflated);
  }

  /// 删掉本版本环境（设置里「移除」）。已加载进本进程的 DLL 删不掉——调用方应在
  /// 本进程没用它时调用（DirectML 环境要先在设置里换回别的再重启）。
  Future<void> remove() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// 清掉本种类其它版本的旧目录。
  Future<void> removeStale() async {
    if (!await _kindRoot.exists()) return;
    await for (final FileSystemEntity e in _kindRoot.list()) {
      if (e is Directory && p.basename(e.path) != environment.version) {
        await e.delete(recursive: true);
      }
    }
  }
}

Future<void> _deleteQuietly(File f) async {
  try {
    if (await f.exists()) await f.delete();
  } on FileSystemException {
    // 删不掉的残留下次安装会覆盖。
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// 中央目录里的一个条目。
class _ZipEntry {
  const _ZipEntry({
    required this.method,
    required this.compressedSize,
    required this.size,
    required this.localHeaderOffset,
  });

  final int method;
  final int compressedSize;
  final int size;
  final int localHeaderOffset;
}

/// 只靠 HTTP Range 读远端 zip。
class _RemoteZip {
  _RemoteZip(this._client, this._url);

  final HttpClient _client;
  final Uri _url;
  int? _length;

  /// 读整份中央目录（支持 zip64）：zip 路径 → 条目。
  Future<Map<String, _ZipEntry>> centralDirectory() async {
    final int length = await _contentLength();
    // EOCD 22 字节 + 最长 65535 字节注释；再多留 20 字节给 zip64 locator。
    final int tailLen = length < 65557 + 20 ? length : 65557 + 20;
    final Uint8List tail = await _read(length - tailLen, tailLen);
    final ByteData t = ByteData.sublistView(tail);
    int eocd = -1;
    for (int i = tail.length - 22; i >= 0; i--) {
      if (t.getUint32(i, Endian.little) == 0x06054b50) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw const GpuRuntimeCorruptException('找不到 zip 目录结尾');
    int count = t.getUint16(eocd + 10, Endian.little);
    int cdSize = t.getUint32(eocd + 12, Endian.little);
    int cdOffset = t.getUint32(eocd + 16, Endian.little);
    if (count == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF) {
      final int locator = eocd - 20;
      if (locator < 0 || t.getUint32(locator, Endian.little) != 0x07064b50) {
        throw const GpuRuntimeCorruptException('zip64 目录定位器缺失');
      }
      final int z64Offset = t.getUint64(locator + 8, Endian.little);
      final ByteData z = ByteData.sublistView(await _read(z64Offset, 56));
      if (z.getUint32(0, Endian.little) != 0x06064b50) {
        throw const GpuRuntimeCorruptException('zip64 目录结尾损坏');
      }
      count = z.getUint64(32, Endian.little);
      cdSize = z.getUint64(40, Endian.little);
      cdOffset = z.getUint64(48, Endian.little);
    }
    final Uint8List cd = await _read(cdOffset, cdSize);
    final ByteData c = ByteData.sublistView(cd);
    final Map<String, _ZipEntry> entries = <String, _ZipEntry>{};
    int pos = 0;
    for (int i = 0; i < count; i++) {
      if (pos + 46 > cd.length ||
          c.getUint32(pos, Endian.little) != 0x02014b50) {
        throw const GpuRuntimeCorruptException('zip 中央目录损坏');
      }
      final int method = c.getUint16(pos + 10, Endian.little);
      int compressed = c.getUint32(pos + 20, Endian.little);
      int size = c.getUint32(pos + 24, Endian.little);
      final int nameLen = c.getUint16(pos + 28, Endian.little);
      final int extraLen = c.getUint16(pos + 30, Endian.little);
      final int commentLen = c.getUint16(pos + 32, Endian.little);
      int offset = c.getUint32(pos + 42, Endian.little);
      final String name = String.fromCharCodes(
        cd.sublist(pos + 46, pos + 46 + nameLen),
      );
      // zip64 扩展字段：只有为 0xFFFFFFFF 的字段按 size/compressed/offset 顺序出现。
      int extra = pos + 46 + nameLen;
      final int extraEnd = extra + extraLen;
      while (extra + 4 <= extraEnd) {
        final int id = c.getUint16(extra, Endian.little);
        final int len = c.getUint16(extra + 2, Endian.little);
        if (id == 0x0001) {
          int f = extra + 4;
          if (size == 0xFFFFFFFF) {
            size = c.getUint64(f, Endian.little);
            f += 8;
          }
          if (compressed == 0xFFFFFFFF) {
            compressed = c.getUint64(f, Endian.little);
            f += 8;
          }
          if (offset == 0xFFFFFFFF) {
            offset = c.getUint64(f, Endian.little);
          }
        }
        extra += 4 + len;
      }
      entries[name] = _ZipEntry(
        method: method,
        compressedSize: compressed,
        size: size,
        localHeaderOffset: offset,
      );
      pos = extraEnd + commentLen;
    }
    return entries;
  }

  /// 把 [entry] 的压缩数据落到 [target]（已有部分从断点续传），逐块回报已收字节。
  Stream<int> fetchMember(_ZipEntry entry, File target) async* {
    final ByteData local = ByteData.sublistView(
      await _read(entry.localHeaderOffset, 30),
    );
    if (local.getUint32(0, Endian.little) != 0x04034b50) {
      throw const GpuRuntimeCorruptException('zip 本地文件头损坏');
    }
    final int dataStart =
        entry.localHeaderOffset +
        30 +
        local.getUint16(26, Endian.little) +
        local.getUint16(28, Endian.little);
    int have = await target.exists() ? await target.length() : 0;
    if (have > entry.compressedSize) {
      await target.delete();
      have = 0;
    }
    yield have;
    if (have == entry.compressedSize) return;
    final IOSink out = target.openWrite(mode: FileMode.append);
    try {
      await for (final List<int> chunk in _stream(
        dataStart + have,
        entry.compressedSize - have,
      )) {
        out.add(chunk);
        have += chunk.length;
        yield have;
      }
    } finally {
      await out.close();
    }
    if (have != entry.compressedSize) {
      throw GpuRuntimeCorruptException(
        '下载中断：$have / ${entry.compressedSize} 字节',
      );
    }
  }

  Future<int> _contentLength() async {
    final int? known = _length;
    if (known != null) return known;
    // 用 1 字节 Range 拿总长：`Content-Range: bytes 0-0/<total>`（有的 CDN 不回
    // HEAD 的 Content-Length）。
    final HttpClientRequest request = await _client.getUrl(_url);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
    final HttpClientResponse response = await request.close();
    await response.drain<void>();
    final String? range = response.headers.value(
      HttpHeaders.contentRangeHeader,
    );
    final int? total = range == null
        ? null
        : int.tryParse(range.substring(range.lastIndexOf('/') + 1));
    if (response.statusCode != HttpStatus.partialContent || total == null) {
      throw HttpException(
        '$_url 不支持按范围下载（HTTP ${response.statusCode}）',
        uri: _url,
      );
    }
    return _length = total;
  }

  Future<Uint8List> _read(int start, int length) async {
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in _stream(start, length)) {
      builder.add(chunk);
    }
    if (builder.length != length) {
      throw GpuRuntimeCorruptException(
        '范围读取不完整：${builder.length} / $length 字节',
      );
    }
    return builder.takeBytes();
  }

  Stream<List<int>> _stream(int start, int length) async* {
    if (length <= 0) return;
    final HttpClientRequest request = await _client.getUrl(_url);
    request.headers.set(
      HttpHeaders.rangeHeader,
      'bytes=$start-${start + length - 1}',
    );
    final HttpClientResponse response = await request.close();
    if (response.statusCode != HttpStatus.partialContent) {
      await response.drain<void>();
      throw HttpException(
        '$_url 范围请求返回 HTTP ${response.statusCode}',
        uri: _url,
      );
    }
    yield* response;
  }
}
