/// GPT-SoVITS 官方 Windows 整合包的清单、布局识别与安装（下载 → 解压 → 配置）。
///
/// 事实（2026-10-14 实测，见 PR 说明）：
/// - 整合包只发 `.7z`，HuggingFace `lj1995/GPT-SoVITS-windows-package` 是官方源，
///   ModelScope `FlowerCry/gpt-sovits-7z-pacakges`（仓库名原样拼写）是官方语雀页
///   指向的国内镜像，两边 sha256 一致；hf-mirror.com 会 308 跳回 huggingface.co，
///   不算镜像。
/// - 文件名形如 `GPT-SoVITS-v5-20261005.7z` / `…nvidia50x0.7z`（RTX 50 系，cu128）；
///   没有 CPU 专用包——普通包在没有 CUDA 的机器上会自动降到 CPU。
/// - 解压后的顶层目录名**不跟包名走**（v5 包解出 `GPT-SoVITS-v2pro-20261006/`），
///   所以装完按内容找 `runtime/python.exe` + `api_v2.py`，不按名字猜。
/// - 系统 `tar.exe`（libarchive + liblzma）能解整合包用到的 LZMA2 / BCJ / Delta；
///   老系统的 tar 可能没编 lzma，安装前按 `tar --version` 判。
/// - `api_v2.py` 启动和切权重时会把配置写回 `-c` 指定的 yaml，所以 app 用自己的一份
///   副本，不动包里那份。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/foundation/engine_notifier.dart';
import 'package:fushi_engine/tts/local/gpt_sovits_local_server.dart';
import 'package:fushi_engine/tts/local/local_service_support.dart';
import 'package:fushi_engine/utils/misc/helper_process_registry.dart';
import 'package:fushi_engine/utils/misc/resumable_downloader.dart';
import 'package:path/path.dart' as p;

export 'package:fushi_engine/tts/local/local_service_support.dart'
    show detectNvidiaGpuName;

/// 下载源。
enum GptSovitsPackageSource { huggingFace, modelScope }

/// 整合包变体：普通（cu118，RTX 50 以前的 N 卡与无 N 卡的 CPU 兜底）/ RTX 50 系。
enum GptSovitsPackageVariant { standard, nvidia50 }

class GptSovitsPackage {
  const GptSovitsPackage({
    required this.name,
    required this.sizeBytes,
    required this.sha256,
    required this.date,
    required this.variant,
  });

  final String name;
  final int sizeBytes;

  /// 小写十六进制；null = 清单里没给。没有摘要的包**不安装**（整合包里是要直接执行
  /// 的 python runtime，只校验体积等于不校验），见 [gptSovitsWithTrustedDigest]。
  final String? sha256;

  /// 文件名里的 `yyyymmdd`，用来挑最新。
  final String date;
  final GptSovitsPackageVariant variant;

  Uri url(GptSovitsPackageSource source) => switch (source) {
    GptSovitsPackageSource.huggingFace => Uri.parse(
      'https://huggingface.co/$kGptSovitsHfRepo/resolve/main/'
      '${Uri.encodeComponent(name)}',
    ),
    GptSovitsPackageSource.modelScope => Uri.parse(
      'https://www.modelscope.cn/models/$kGptSovitsModelScopeRepo/resolve/'
      'master/${Uri.encodeComponent(name)}',
    ),
  };
}

const String kGptSovitsHfRepo = 'lj1995/GPT-SoVITS-windows-package';
const String kGptSovitsModelScopeRepo = 'FlowerCry/gpt-sovits-7z-pacakges';

Uri gptSovitsListingUri(GptSovitsPackageSource source) => switch (source) {
  GptSovitsPackageSource.huggingFace => Uri.parse(
    'https://huggingface.co/api/models/$kGptSovitsHfRepo/tree/main',
  ),
  GptSovitsPackageSource.modelScope => Uri.parse(
    'https://www.modelscope.cn/api/v1/models/$kGptSovitsModelScopeRepo/repo/'
    'files?Revision=master&Recursive=true',
  ),
};

/// 清单取不到时的兜底（2026-10-08 官方仓库的最新两包）。
const List<GptSovitsPackage> kGptSovitsFallbackPackages = <GptSovitsPackage>[
  GptSovitsPackage(
    name: 'GPT-SoVITS-v5-20261005.7z',
    sizeBytes: 10869231773,
    sha256: '0a612a28208250b3b67ea341efa1557d10bc886219100eff6c02528f6b9bdde7',
    date: '20261005',
    variant: GptSovitsPackageVariant.standard,
  ),
  GptSovitsPackage(
    name: 'GPT-SoVITS-v5-20261005nvidia50x0.7z',
    sizeBytes: 10644775528,
    sha256: 'dadd331eff44e6cb5dc8f21ecb441e6882ae2096088419df2537f5292a064c93',
    date: '20261005',
    variant: GptSovitsPackageVariant.nvidia50,
  ),
];

/// 清单里的一包能不能装：自带 sha256 的原样返回；没带的只在名字与体积都和代码里钉死的
/// [kGptSovitsFallbackPackages] 某一包一致时借用那份摘要；都不满足返回 null（不装）。
GptSovitsPackage? gptSovitsWithTrustedDigest(GptSovitsPackage pkg) {
  if (pkg.sha256 != null) return pkg;
  for (final GptSovitsPackage pinned in kGptSovitsFallbackPackages) {
    if (pinned.name == pkg.name && pinned.sizeBytes == pkg.sizeBytes) {
      return pinned;
    }
  }
  return null;
}

/// 安装目录下 app 专属的子目录：下载包、`.part` 与解压结果全在这里，「删除」也只删
/// 它——用户选的安装目录本身（可能是 `D:\` 或装着别的东西）绝不碰。
const String kGptSovitsInstallSubdir = 'fushi-gpt-sovits';

/// [installDir] 对应的 app 专属子目录。
String gptSovitsPackageDir(String installDir) =>
    p.join(installDir, kGptSovitsInstallSubdir);

final RegExp _packageName = RegExp(
  r'^GPT-SoVITS-[^/]*?(\d{8})([^/]*)\.7z$',
  caseSensitive: false,
);

/// 从一个文件名认整合包；增量更新包、非 7z 返回 null。
GptSovitsPackage? gptSovitsPackageFromFile({
  required String path,
  required int size,
  String? sha256,
}) {
  final String name = path.split('/').last;
  if (name.toLowerCase().contains('update')) return null;
  final RegExpMatch? m = _packageName.firstMatch(name);
  if (m == null || size <= 0) return null;
  final String digest = (sha256 ?? '').trim().toLowerCase();
  return GptSovitsPackage(
    name: name,
    sizeBytes: size,
    sha256: RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ? digest : null,
    date: m.group(1)!,
    variant: m.group(2)!.toLowerCase().contains('nvidia50')
        ? GptSovitsPackageVariant.nvidia50
        : GptSovitsPackageVariant.standard,
  );
}

/// HF tree API：`[{type, path, size, lfs: {oid, size}}]`（`lfs.oid` 即 sha256）。
List<GptSovitsPackage> parseHfGptSovitsListing(
  Object? raw,
) => <GptSovitsPackage>[
  if (raw is List)
    for (final Object? e in raw)
      if (e is Map && e['type'] == 'file' && e['path'] is String)
        if (gptSovitsPackageFromFile(
              path: e['path'] as String,
              size:
                  _int(e['lfs'] is Map ? (e['lfs'] as Map)['size'] : null) ??
                  _int(e['size']) ??
                  0,
              sha256: e['lfs'] is Map
                  ? (e['lfs'] as Map)['oid']?.toString()
                  : null,
            )
            case final GptSovitsPackage pkg)
          pkg,
];

/// ModelScope files API：`{Data: {Files: [{Path, Size, Sha256, Type}]}}`。
List<GptSovitsPackage> parseModelScopeGptSovitsListing(Object? raw) {
  final Object? data = raw is Map ? raw['Data'] : null;
  final Object? files = data is Map ? data['Files'] : null;
  return <GptSovitsPackage>[
    if (files is List)
      for (final Object? e in files)
        if (e is Map && e['Type'] != 'tree' && e['Path'] is String)
          if (gptSovitsPackageFromFile(
                path: e['Path'] as String,
                size: _int(e['Size']) ?? 0,
                sha256: e['Sha256']?.toString(),
              )
              case final GptSovitsPackage pkg)
            pkg,
  ];
}

int? _int(Object? v) => v is int ? v : (v is String ? int.tryParse(v) : null);

/// 该变体里日期最新的一包；没有返回 null。
GptSovitsPackage? pickLatestGptSovitsPackage(
  Iterable<GptSovitsPackage> packages,
  GptSovitsPackageVariant variant,
) {
  GptSovitsPackage? best;
  for (final GptSovitsPackage pkg in packages) {
    if (pkg.variant != variant) continue;
    if (best == null || pkg.date.compareTo(best.date) > 0) best = pkg;
  }
  return best;
}

/// RTX 50 系（Blackwell）要 cu128 的那一包；普通包的 cu118 在 50 系上跑不起来。
GptSovitsPackageVariant gptSovitsVariantForGpu(String? gpuName) =>
    gpuName != null &&
        RegExp(r'RTX\s*50\d\d', caseSensitive: false).hasMatch(gpuName)
    ? GptSovitsPackageVariant.nvidia50
    : GptSovitsPackageVariant.standard;

/// 一份可用的整合包目录。
class GptSovitsInstallLayout {
  const GptSovitsInstallLayout(this.root);

  final String root;

  String get python => p.join(root, 'runtime', 'python.exe');
  String get apiScript => p.join(root, 'api_v2.py');
  String get packageConfig =>
      p.join(root, 'GPT_SoVITS', 'configs', 'tts_infer.yaml');

  /// app 自己的配置副本（相对 [root]，api_v2 以包根为工作目录）。
  static const String appConfigRelative =
      'GPT_SoVITS/configs/fushi_tts_infer.yaml';
  String get appConfig => p.join(root, p.joinAll(appConfigRelative.split('/')));

  /// 没有 app 副本时从包里那份复制一份。
  Future<void> ensureAppConfig() async {
    final File config = File(appConfig);
    if (await config.exists()) return;
    await File(packageConfig).copy(config.path);
  }

  GptSovitsLaunchSpec launchSpec(int port) => GptSovitsLaunchSpec(
    executable: python,
    // 与官方 go-webui.bat 同一形态：-I 隔离用户 site-packages。
    // `-I` 同时让 python 无视 PYTHON* 环境变量，所以 [LocalServiceProcess] 注入的
    // PYTHONIOENCODING / PYTHONUTF8 在这里不生效：中文 Windows 上服务端 print / 写日志
    // 用系统代码页，带中日文的请求直接 400（`'charmap' codec can't encode`），界面上只
    // 看到「语音服务拒绝了这个句子」。`-X utf8` 是命令行开关，`-I` 下照样生效。
    arguments: <String>[
      '-I',
      '-X',
      'utf8',
      'api_v2.py',
      '-a',
      '127.0.0.1',
      '-p',
      '$port',
      '-c',
      appConfigRelative,
    ],
    workingDirectory: root,
    port: port,
  );

  static bool _looksLikeRoot(Directory dir) =>
      File(p.join(dir.path, 'runtime', 'python.exe')).existsSync() &&
      File(p.join(dir.path, 'api_v2.py')).existsSync() &&
      File(
        p.join(dir.path, 'GPT_SoVITS', 'configs', 'tts_infer.yaml'),
      ).existsSync();

  /// [dir] 本身或它的直接子目录里找整合包根（解压出来多一层顶层目录很常见）。
  static GptSovitsInstallLayout? find(String dir) {
    final Directory base = Directory(dir);
    if (!base.existsSync()) return null;
    if (_looksLikeRoot(base)) return GptSovitsInstallLayout(base.path);
    final List<Directory> children = <Directory>[
      for (final FileSystemEntity e in base.listSync(followLinks: false))
        if (e is Directory) e,
    ]..sort((Directory a, Directory b) => b.path.compareTo(a.path));
    for (final Directory child in children) {
      if (_looksLikeRoot(child)) return GptSovitsInstallLayout(child.path);
    }
    return null;
  }
}

/// 安装进行到哪一步。
enum GptSovitsInstallStep {
  idle,
  listing,
  downloading,
  extracting,
  configuring,
  done,
  failed,
  cancelled,
}

/// 安装失败的原因（UI 翻译成文案）。
enum GptSovitsInstallFailure {
  /// 清单与下载都连不上。
  network,

  /// 下完体积 / sha256 对不上（已删掉坏文件，重试会从头下）。
  corrupt,

  /// 系统 tar 不能解 7z（老 Windows 没编 lzma）。
  noExtractor,

  /// 解压失败（多半是磁盘满）。
  extractFailed,

  /// 解完找不到 `runtime/python.exe` + `api_v2.py`。
  layoutMissing,

  /// 写不进安装目录。
  disk,
}

typedef GptSovitsCommandRunner = LocalCommandRunner;

/// 系统自带的 bsdtar。Windows 上点名 System32 那份：PATH 里常有别的工具链带的
/// GNU tar，它不认 7z。
String get gptSovitsTarExecutable {
  if (!Platform.isWindows) return 'tar';
  final String root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  return p.join(root, 'System32', 'tar.exe');
}

/// 系统 tar 能不能解整合包（libarchive 编进了 lzma）。
Future<bool> systemTarSupports7z({GptSovitsCommandRunner? run}) async {
  final ({int exitCode, String output}) r = await (run ?? runLocalCommand)(
    gptSovitsTarExecutable,
    const <String>['--version'],
  );
  return r.exitCode == 0 &&
      r.output.contains('libarchive') &&
      r.output.toLowerCase().contains('liblzma');
}

/// 发起一次 GET（下载与清单共用）。测试注入。
typedef GptSovitsHttpOpen =
    Future<ResumableDownloadResponse> Function(
      Uri uri,
      Map<String, String> headers,
    );

/// 下载 → 解压 → 配置的一次安装。进度经 [EngineChangeNotifier] 通知。
class GptSovitsInstaller extends EngineChangeNotifier {
  GptSovitsInstaller({
    required HttpClient Function() httpClientFactory,
    GptSovitsCommandRunner? run,
    Future<Process> Function(String exe, List<String> args)? spawn,
  }) : _httpClientFactory = httpClientFactory,
       _run = run ?? runLocalCommand,
       _spawn =
           spawn ??
           ((String exe, List<String> args) =>
               HelperProcessRegistry.instance.start(exe, args));

  final HttpClient Function() _httpClientFactory;
  final GptSovitsCommandRunner _run;
  final Future<Process> Function(String exe, List<String> args) _spawn;

  GptSovitsInstallStep step = GptSovitsInstallStep.idle;
  GptSovitsInstallFailure? failure;
  GptSovitsPackage? package;
  int receivedBytes = 0;
  int? totalBytes;

  /// 解压已写出的条目数（整合包约 7 万条）。
  int extractedEntries = 0;

  /// 失败时的技术细节（进日志，不直接给用户看）。
  String? detail;

  bool get isBusy =>
      _inFlight.active ||
      switch (step) {
        GptSovitsInstallStep.listing ||
        GptSovitsInstallStep.downloading ||
        GptSovitsInstallStep.extracting ||
        GptSovitsInstallStep.configuring => true,
        _ => false,
      };

  /// 在途安装登记：同步占位防并发重入，完成信号给「删除」等。
  final LocalInstallRun _inFlight = LocalInstallRun();

  bool _cancelled = false;
  HttpClient? _client;
  Process? _tar;

  void _set(GptSovitsInstallStep next, [GptSovitsInstallFailure? why]) {
    step = next;
    failure = why;
    notifyListeners();
  }

  void cancel() {
    if (!isBusy) return;
    _cancelled = true;
    _client?.close(force: true);
    _tar?.kill();
  }

  /// 取消并等安装函数真正返回（下载 client / 子进程 / 文件句柄都已收尾）。
  /// 「删除」必须先等它，再动安装目录。
  Future<void> cancelAndWait() {
    cancel();
    return _inFlight.idle;
  }

  /// 装进 [installDir] 下的专属子目录（[gptSovitsPackageDir]）。返回装好的布局；
  /// 失败 / 取消返回 null（原因在 [failure]）。下到一半的包留在专属子目录（`.part`），
  /// 下次安装从断点续。
  Future<GptSovitsInstallLayout?> install({
    required String installDir,
    required GptSovitsPackageSource source,
    required GptSovitsPackageVariant variant,
  }) async {
    if (!_inFlight.tryBegin()) return null;
    try {
      return await _install(
        installDir: installDir,
        source: source,
        variant: variant,
      );
    } finally {
      _inFlight.end();
      notifyListeners();
    }
  }

  Future<GptSovitsInstallLayout?> _install({
    required String installDir,
    required GptSovitsPackageSource source,
    required GptSovitsPackageVariant variant,
  }) async {
    _cancelled = false;
    receivedBytes = 0;
    totalBytes = null;
    extractedEntries = 0;
    detail = null;
    package = null;
    final HttpClient client = _httpClientFactory();
    _client = client;
    try {
      if (!await systemTarSupports7z(run: _run)) {
        _set(GptSovitsInstallStep.failed, GptSovitsInstallFailure.noExtractor);
        return null;
      }
      _set(GptSovitsInstallStep.listing);
      final GptSovitsPackage pkg =
          await _latest(client, source, variant) ??
          pickLatestGptSovitsPackage(kGptSovitsFallbackPackages, variant)!;
      package = pkg;
      if (_cancelled) return _cancel();
      if (pkg.sha256 == null) {
        // _latest 只挑有可信摘要的包、兜底包全部钉了摘要；走到这里是逻辑被改坏了。
        detail = 'no sha256 for ${pkg.name}';
        _set(GptSovitsInstallStep.failed, GptSovitsInstallFailure.corrupt);
        return null;
      }

      final String packageDir = gptSovitsPackageDir(installDir);
      try {
        await Directory(packageDir).create(recursive: true);
      } on FileSystemException catch (e) {
        detail = e.message;
        _set(GptSovitsInstallStep.failed, GptSovitsInstallFailure.disk);
        return null;
      }
      final File archive = File(p.join(packageDir, pkg.name));
      if (!await archive.exists() || await archive.length() != pkg.sizeBytes) {
        _set(GptSovitsInstallStep.downloading);
        try {
          await ResumableDownloader(
            url: pkg.url(source).toString(),
            destination: archive,
            partFile: File('${archive.path}.part'),
            open: (Uri uri, Map<String, String> headers) =>
                _open(client, uri, headers),
            expectedSize: pkg.sizeBytes,
            expectedSha256: pkg.sha256,
            firstByteTimeout: const Duration(seconds: 60),
            bodyTimeout: const Duration(seconds: 60),
            onProgress: (int received, int? total) {
              receivedBytes = received;
              totalBytes = total;
              notifyListeners();
            },
          ).download();
        } on ResumableDownloadIntegrityException catch (e) {
          detail = e.message;
          _set(GptSovitsInstallStep.failed, GptSovitsInstallFailure.corrupt);
          return null;
        } on FileSystemException catch (e) {
          if (_cancelled) return _cancel();
          detail = e.message;
          _set(GptSovitsInstallStep.failed, GptSovitsInstallFailure.disk);
          return null;
        } on Object catch (e) {
          if (_cancelled) return _cancel();
          detail = '$e';
          _set(GptSovitsInstallStep.failed, GptSovitsInstallFailure.network);
          return null;
        }
      }
      if (_cancelled) return _cancel();

      _set(GptSovitsInstallStep.extracting);
      final bool extracted = await _extract(archive.path, packageDir);
      if (_cancelled) return _cancel();
      if (!extracted) {
        _set(
          GptSovitsInstallStep.failed,
          GptSovitsInstallFailure.extractFailed,
        );
        return null;
      }

      _set(GptSovitsInstallStep.configuring);
      final GptSovitsInstallLayout? layout = GptSovitsInstallLayout.find(
        packageDir,
      );
      if (layout == null) {
        _set(
          GptSovitsInstallStep.failed,
          GptSovitsInstallFailure.layoutMissing,
        );
        return null;
      }
      try {
        await layout.ensureAppConfig();
        // 解完就删包：10 GB 的 7z 留着没用。
        await archive.delete();
      } on FileSystemException catch (e) {
        detail = e.message;
      }
      _set(GptSovitsInstallStep.done);
      return layout;
    } finally {
      _client = null;
      client.close(force: true);
    }
  }

  GptSovitsInstallLayout? _cancel() {
    _set(GptSovitsInstallStep.cancelled);
    return null;
  }

  Future<GptSovitsPackage?> _latest(
    HttpClient client,
    GptSovitsPackageSource source,
    GptSovitsPackageVariant variant,
  ) async {
    try {
      final ResumableDownloadResponse response = await _open(
        client,
        gptSovitsListingUri(source),
        const <String, String>{},
      ).timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) {
        await response.stream.drain<void>();
        return null;
      }
      final String body = await utf8.decodeStream(
        response.stream.timeout(const Duration(seconds: 30)),
      );
      final Object? json = jsonDecode(body);
      final List<GptSovitsPackage> listed = switch (source) {
        GptSovitsPackageSource.huggingFace => parseHfGptSovitsListing(json),
        GptSovitsPackageSource.modelScope => parseModelScopeGptSovitsListing(
          json,
        ),
      };
      // 没有可信摘要的包不参与挑选（宁可装钉死的兜底包）。
      return pickLatestGptSovitsPackage(<GptSovitsPackage>[
        for (final GptSovitsPackage pkg in listed)
          if (gptSovitsWithTrustedDigest(pkg) case final GptSovitsPackage ok)
            ok,
      ], variant);
    } on Object {
      // 清单只用来挑最新；取不到用内置兜底，不挡安装。
      return null;
    }
  }

  static Future<ResumableDownloadResponse> _open(
    HttpClient client,
    Uri uri,
    Map<String, String> headers,
  ) => openLocalServiceGet(client, uri, headers);

  Future<bool> _extract(String archive, String dest) async {
    final Process tar;
    try {
      tar = await _spawn(gptSovitsTarExecutable, <String>[
        '-xvf',
        archive,
        '-C',
        dest,
      ]);
    } on ProcessException catch (e) {
      detail = e.message;
      return false;
    }
    _tar = tar;
    // 取消落在子进程启动的 await 里时 cancel() 还看不到它：补杀。
    if (_cancelled) tar.kill();
    final List<String> errors = <String>[];
    // bsdtar 的 -v 逐条写到 stderr（`x path`）；按行数计进度。
    final Future<void> err = tar.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((String line) {
          if (line.startsWith('x ')) {
            extractedEntries++;
            if (extractedEntries % 200 == 0) notifyListeners();
          } else if (line.trim().isNotEmpty) {
            errors.add(line);
            if (errors.length > 20) errors.removeAt(0);
          }
        })
        .asFuture<void>();
    final Future<void> out = tar.stdout.drain<void>();
    final int code = await tar.exitCode;
    await Future.wait(<Future<void>>[
      err,
      out,
    ]).catchError((Object _) => <void>[]);
    _tar = null;
    if (code != 0) detail = errors.join('\n');
    return code == 0;
  }
}
