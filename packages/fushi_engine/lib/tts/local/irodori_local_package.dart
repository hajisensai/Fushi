/// 本机部署官方 Irodori-TTS-Server（`Aratako/Irodori-TTS-Server`）的清单、目录布局与
/// 安装器（下载 uv → 取源码 → 受管 Python 3.10 → 按官方 `uv.lock` 装依赖 → 下模型）。
///
/// 事实（2026-10-16 读上游核实，见 `docs/specs/2026-10-11-tts-pipeline.md` §本机 Irodori）：
/// - 官方装法是 `uv sync --extra cu128|rocm|cpu` + `uv run --no-sync python -m
///   irodori_openai_tts`；`pyproject.toml` 钉 Python ≥3.10（`.python-version` = 3.10）、
///   `torch>=2.10,<2.11`。三个 extra 互斥；cpu 在 macOS 落到 PyPI 的 torch（MPS）。
/// - 依赖里有三个 **git 依赖**（`irodori-tts`、它带的 `dacvae` 与 `silentcipher`），
///   uv 取 git 依赖**必须调用系统 git**（实测：没装 git 报「Git executable not
///   found」）。所以这里不让 uv 去 clone：三个仓库按 `uv.lock` 里钉死的 commit 下
///   GitHub 源码 zip（sha256 校验），`uv export --frozen` 导出锁定的依赖清单（带
///   哈希），把那三行 git 地址换成本地目录，再 `uv pip sync` 装进 `.venv`——版本与
///   哈希全部来自官方锁文件，只是取源码不经 git。
/// - 模型在启动前由本 app 下载（可续传、可显示进度、sha256 校验），以本地路径交给
///   服务（`IRODORI_CHECKPOINT` / `IRODORI_CODEC_REPO`），服务首次加载不再去 HF 拉。
/// - uv、受管 Python、uv 缓存、虚拟环境、模型、上传的声音全在一个专属目录里，删除就是
///   整目录删掉；不写 PATH / 注册表（`--no-bin --no-registry`），不碰系统 Python。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:fushi_engine/foundation/engine_notifier.dart';
import 'package:fushi_engine/tts/local/local_service_support.dart';
import 'package:fushi_engine/utils/misc/helper_process_registry.dart';
import 'package:fushi_engine/utils/misc/resumable_downloader.dart';
import 'package:path/path.dart' as p;

/// PyTorch 后端（官方 `pyproject.toml` 的三个互斥 extra）。
enum IrodoriTorchBackend { cu128, rocm, cpu }

/// 模型（都是官方 v4.1 Small；MF = MeanFlow，4 步采样，CPU 上快得多）。
enum IrodoriModelChoice { small, smallMeanFlow }

/// 模型下载源。hf-mirror.com 只是国内镜像，从境外出口访问会 308 回 huggingface.co。
enum IrodoriDownloadSource { huggingFace, hfMirror }

String irodoriHfEndpoint(IrodoriDownloadSource source) => switch (source) {
  IrodoriDownloadSource.huggingFace => 'https://huggingface.co',
  IrodoriDownloadSource.hfMirror => 'https://hf-mirror.com',
};

/// 一个钉死摘要的文件。
class IrodoriPinnedFile {
  const IrodoriPinnedFile({
    required this.path,
    required this.size,
    required this.sha256,
  });

  /// 仓库内相对路径（`/` 分隔）。
  final String path;
  final int size;
  final String sha256;
}

/// 一个钉死 commit 的 HF 模型仓库。
class IrodoriModelRepo {
  const IrodoriModelRepo({
    required this.repo,
    required this.revision,
    required this.files,
  });

  final String repo;
  final String revision;
  final List<IrodoriPinnedFile> files;

  /// 本地目录名（仓库名，`Aratako/Foo` → `Foo`）。
  String get dirName => repo.split('/').last;

  int get totalBytes =>
      files.fold<int>(0, (int sum, IrodoriPinnedFile f) => sum + f.size);

  Uri url(IrodoriDownloadSource source, IrodoriPinnedFile file) => Uri.parse(
    '${irodoriHfEndpoint(source)}/$repo/resolve/$revision/'
    '${file.path.split('/').map(Uri.encodeComponent).join('/')}',
  );
}

/// 一个钉死 commit 的 GitHub 源码 zip。
class IrodoriSourceArchive {
  const IrodoriSourceArchive({
    required this.repo,
    required this.commit,
    required this.dirName,
    required this.size,
    required this.sha256,
    this.lockedRequirement,
  });

  /// `owner/name`。
  final String repo;
  final String commit;

  /// 解到 `src/` 下的目录名。
  final String dirName;
  final int size;
  final String sha256;

  /// `uv export` 里这个 git 依赖的原样一行（`name @ git+url@commit`）；null = 不是
  /// 依赖（服务本体）。
  final String? lockedRequirement;

  /// 依赖名（`lockedRequirement` 的 `@` 前一段）。
  String? get packageName => lockedRequirement?.split(' @ ').first.trim();

  Uri get url => Uri.parse('https://codeload.github.com/$repo/zip/$commit');
}

/// uv 的一个发行包。
class IrodoriUvAsset {
  const IrodoriUvAsset({
    required this.name,
    required this.size,
    required this.sha256,
  });

  final String name;
  final int size;
  final String sha256;

  bool get isZip => name.endsWith('.zip');
}

/// 部署清单：要下的每一样东西都钉了版本与 sha256。测试注入小清单。
class IrodoriManifest {
  const IrodoriManifest({
    required this.uvVersion,
    required this.uvAssets,
    required this.pythonVersion,
    required this.server,
    required this.dependencies,
    required this.models,
    required this.codec,
  });

  final String uvVersion;

  /// [Abi] 名 → 发行包。
  final Map<String, IrodoriUvAsset> uvAssets;

  /// `uv python install` 的版本（官方 `.python-version`）。
  final String pythonVersion;
  final IrodoriSourceArchive server;

  /// 锁文件里的 git 依赖（不经 git 取源码）。
  final List<IrodoriSourceArchive> dependencies;
  final Map<IrodoriModelChoice, IrodoriModelRepo> models;
  final IrodoriModelRepo codec;

  /// 环境指纹：清单里任何决定 `.venv` 内容的东西变了，已装的环境就作废重装。
  String get environmentRevision => <String>[
    uvVersion,
    pythonVersion,
    server.commit,
    for (final IrodoriSourceArchive d in dependencies) d.commit,
  ].join('|');

  Uri uvUrl(IrodoriUvAsset asset) => Uri.parse(
    'https://github.com/astral-sh/uv/releases/download/$uvVersion/${asset.name}',
  );
}

/// 2026-10-16 钉死的部署清单（上游 Irodori-TTS-Server main 61012c7，2026-09-13）。
const IrodoriManifest kIrodoriManifest = IrodoriManifest(
  uvVersion: '0.12.21',
  uvAssets: <String, IrodoriUvAsset>{
    'windows_x64': IrodoriUvAsset(
      name: 'uv-x86_64-pc-windows-msvc.zip',
      size: 17992232,
      sha256:
          '5d223efa0bf00208c3853246af09420419dfbd352536aa6bb8163d6170e23890',
    ),
    'macos_arm64': IrodoriUvAsset(
      name: 'uv-aarch64-apple-darwin.tar.gz',
      size: 17001427,
      sha256:
          'b88bda573e566ef9bced66b155fe0408626fbbc053aee1c30ba686f0728c9447',
    ),
    'linux_x64': IrodoriUvAsset(
      name: 'uv-x86_64-unknown-linux-gnu.tar.gz',
      size: 19782662,
      sha256:
          '23f02075b652bb1df64178cfae41b5caf160822e720e2663568f3f5d63bc52c0',
    ),
    'linux_arm64': IrodoriUvAsset(
      name: 'uv-aarch64-unknown-linux-gnu.tar.gz',
      size: 18943621,
      sha256:
          '030b69227b40af8c1981b7301793dc66e71ed3c796ea8688209dd268bd91ec51',
    ),
  },
  pythonVersion: '3.10',
  server: IrodoriSourceArchive(
    repo: 'Aratako/Irodori-TTS-Server',
    commit: '61012c760f22f7b4a6c21c5c5f8f9e148120b6f9',
    dirName: 'server',
    size: 403358,
    sha256: '31266fb1c4bb458a74147bf297d5de5e75ed837c9035fe648c70ab5c181de139',
  ),
  dependencies: <IrodoriSourceArchive>[
    IrodoriSourceArchive(
      repo: 'Aratako/Irodori-TTS',
      commit: '89f9d8fbd4d51ea019867ee1197725ede1df13c5',
      dirName: 'irodori-tts',
      size: 536407,
      sha256:
          '3697a48ef320368404b353ff1323680ab2c4b5a03bbde7ee09a6871190a68422',
      lockedRequirement:
          'irodori-tts @ git+https://github.com/Aratako/Irodori-TTS.git'
          '@89f9d8fbd4d51ea019867ee1197725ede1df13c5',
    ),
    IrodoriSourceArchive(
      repo: 'facebookresearch/dacvae',
      commit: '414c20785fc3a28373073ea8ef7a1316eeeaca6e',
      dirName: 'dacvae',
      size: 31258,
      sha256:
          'f8ca32de462acc6405d2b07e07f284c56ebddb79e2501b1bb3dd408ac34072b3',
      lockedRequirement:
          'dacvae @ git+https://github.com/facebookresearch/dacvae'
          '@414c20785fc3a28373073ea8ef7a1316eeeaca6e',
    ),
    IrodoriSourceArchive(
      repo: 'SesameAILabs/silentcipher',
      commit: 'd46d7d0893a583d8968ab3a6626e2289faec9152',
      dirName: 'silentcipher',
      size: 6074692,
      sha256:
          'c9e47951a01cd05c8cbf1c5bd9e0b5e7990f0f7bd7ebcf6c39c00aa18bc2f18c',
      lockedRequirement:
          'silentcipher @ git+https://github.com/SesameAILabs/silentcipher.git'
          '@d46d7d0893a583d8968ab3a6626e2289faec9152',
    ),
  ],
  models: <IrodoriModelChoice, IrodoriModelRepo>{
    IrodoriModelChoice.small: IrodoriModelRepo(
      repo: 'Aratako/Irodori-TTS-v4.1-Small',
      revision: '2b28324dc263ed5e6638b3cf3dd94c82ead07b4b',
      files: <IrodoriPinnedFile>[
        IrodoriPinnedFile(
          path: 'model.safetensors',
          size: 3064295596,
          sha256:
              'c85de88c01700cb53538e706f128ebcb1b8513ad21d7d0e75f58bc82cdbf89f6',
        ),
        _kTokenizerJson,
        _kTokenizerConfig,
      ],
    ),
    IrodoriModelChoice.smallMeanFlow: IrodoriModelRepo(
      repo: 'Aratako/Irodori-TTS-v4.1-Small-MF',
      revision: 'ccc78f5d480b6e51b69b2d5042a14c4da04fea6e',
      files: <IrodoriPinnedFile>[
        IrodoriPinnedFile(
          path: 'model.safetensors',
          size: 3093131788,
          sha256:
              'a3f204b3ee06058f4e639a1af38408e7e3af5b6c75176897ecb8bfaaebb4fd54',
        ),
        _kTokenizerJson,
        _kTokenizerConfig,
      ],
    ),
  },
  codec: IrodoriModelRepo(
    repo: 'Aratako/Semantic-DACVAE-Japanese-32dim',
    revision: '47376ee24834d7a05a48ebabfe3cde29b3c5e214',
    files: <IrodoriPinnedFile>[
      IrodoriPinnedFile(
        path: 'weights.pth',
        size: 429620065,
        sha256:
            'db120339c5ee7eca1912cdf29bc612b947a0808e69c3cebfb4936b45a762c1d5',
      ),
    ],
  ),
);

const IrodoriPinnedFile _kTokenizerJson = IrodoriPinnedFile(
  path: 'tokenizer/tokenizer.json',
  size: 6718495,
  sha256: '6a0734cf21c802169defaffe719bc2ef12bb9d0be37e54b61ed27aa89394723d',
);
const IrodoriPinnedFile _kTokenizerConfig = IrodoriPinnedFile(
  path: 'tokenizer/tokenizer_config.json',
  size: 668,
  sha256: 'd229a271c64de1a7939d20d3665498e873fa91d5ee2edf135d73ec752cb9c9d3',
);

/// 本机平台对应的 uv 发行包键（[IrodoriManifest.uvAssets]）；不支持返回 null。
/// macOS 只出 Apple Silicon（torch 2.10 也没有 Intel Mac 的轮子）。
String? irodoriPlatformKey([Abi? abi]) => switch (abi ?? Abi.current()) {
  Abi.windowsX64 => 'windows_x64',
  Abi.macosArm64 => 'macos_arm64',
  Abi.linuxX64 => 'linux_x64',
  Abi.linuxArm64 => 'linux_arm64',
  _ => null,
};

/// 后端的默认值：N 卡 → cu128；其余 → cpu（macOS 的 cpu extra 走 PyPI torch，
/// 服务按 `IRODORI_MODEL_DEVICE=auto` 自己用上 MPS）。ROCm 只能手选（只有 Linux）。
IrodoriTorchBackend irodoriBackendFor({
  required String? nvidiaGpu,
  required bool isMacOS,
}) => !isMacOS && nvidiaGpu != null
    ? IrodoriTorchBackend.cu128
    : IrodoriTorchBackend.cpu;

/// 本平台可选的后端（官方：cu128 只有 Linux / Windows 轮子，rocm 只有 Linux）。
List<IrodoriTorchBackend> irodoriBackendsFor({
  required bool isMacOS,
  required bool isLinux,
}) => <IrodoriTorchBackend>[
  if (!isMacOS) IrodoriTorchBackend.cu128,
  if (isLinux) IrodoriTorchBackend.rocm,
  IrodoriTorchBackend.cpu,
];

/// 后端在 PyTorch 官方源里的索引（`pyproject.toml` 的 `[[tool.uv.index]]`）。
String irodoriTorchIndexUrl(IrodoriTorchBackend backend) => switch (backend) {
  IrodoriTorchBackend.cu128 => 'https://download.pytorch.org/whl/cu128',
  IrodoriTorchBackend.rocm => 'https://download.pytorch.org/whl/rocm7.1',
  IrodoriTorchBackend.cpu => 'https://download.pytorch.org/whl/cpu',
};

/// 安装目录下 app 专属的子目录：一切（uv、Python、缓存、环境、模型、声音）都在这里，
/// 「删除」也只删它——用户选的安装目录本身绝不碰。
const String kIrodoriInstallSubdir = 'fushi-irodori-tts';

String irodoriPackageDir(String installDir) =>
    p.join(installDir, kIrodoriInstallSubdir);

/// 一份安装的目录布局（[root] = 专属子目录）。
class IrodoriInstallLayout {
  const IrodoriInstallLayout(this.root, {this.windows});

  final String root;

  /// 测试可强制按某个平台排布；null = 本机。
  final bool? windows;

  bool get _win => windows ?? Platform.isWindows;

  String get uvDir => p.join(root, 'uv');
  String get uvExecutable => p.join(uvDir, _win ? 'uv.exe' : 'uv');
  String get uvVersionMarker => p.join(uvDir, '.fushi_version');
  String get pythonDir => p.join(root, 'python');
  String get cacheDir => p.join(root, 'cache');
  String get srcDir => p.join(root, 'src');
  String sourceDir(IrodoriSourceArchive archive) =>
      p.join(srcDir, archive.dirName);
  String get serverDir => p.join(srcDir, 'server');
  String get venvDir => p.join(serverDir, '.venv');
  String get venvPython => _win
      ? p.join(venvDir, 'Scripts', 'python.exe')
      : p.join(venvDir, 'bin', 'python');
  String get exportedRequirements => p.join(root, 'requirements.lock.txt');
  String get requirements => p.join(root, 'requirements.txt');
  String get modelsDir => p.join(root, 'models');
  String modelDir(IrodoriModelRepo repo) => p.join(modelsDir, repo.dirName);
  String modelFile(IrodoriModelRepo repo, IrodoriPinnedFile file) =>
      p.join(modelDir(repo), p.joinAll(file.path.split('/')));
  String get voicesDir => p.join(root, 'voices');
  String get hfHome => p.join(root, 'hf');
  String get downloadsDir => p.join(root, 'downloads');
  String get stateFile => p.join(root, 'fushi_irodori_state.json');

  /// 已装好的环境（[IrodoriInstallState]）；没有 / 坏了返回 null。
  IrodoriInstallState? readState() {
    try {
      final File file = File(stateFile);
      if (!file.existsSync()) return null;
      return IrodoriInstallState.fromJson(jsonDecode(file.readAsStringSync()));
    } on Object {
      return null;
    }
  }

  void writeState(IrodoriInstallState state) {
    File(stateFile).writeAsStringSync(jsonEncode(state.toJson()));
  }

  /// [repo] 的文件是不是都在（下载器只在校验通过后才落成正式文件，所以体积对就是
  /// 校验过的那份）。
  bool hasModel(IrodoriModelRepo repo) {
    for (final IrodoriPinnedFile f in repo.files) {
      final File file = File(modelFile(repo, f));
      if (!file.existsSync() || file.lengthSync() != f.size) return false;
    }
    return true;
  }
}

/// 专属目录里记下的「装到哪一步了」。
class IrodoriInstallState {
  const IrodoriInstallState({
    required this.environmentRevision,
    required this.backend,
  });

  /// 装环境时的 [IrodoriManifest.environmentRevision]。
  final String environmentRevision;
  final IrodoriTorchBackend backend;

  Map<String, Object?> toJson() => <String, Object?>{
    'environmentRevision': environmentRevision,
    'backend': backend.name,
  };

  static IrodoriInstallState? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? revision = raw['environmentRevision'];
    final IrodoriTorchBackend? backend = IrodoriTorchBackend.values
        .where((IrodoriTorchBackend b) => b.name == raw['backend'])
        .firstOrNull;
    if (revision is! String || backend == null) return null;
    return IrodoriInstallState(environmentRevision: revision, backend: backend);
  }
}

/// 把 `uv export --frozen` 的锁定清单改成不需要 git 的版本（纯函数，测试直接调）：
/// - [localSources] 里每一行 git 依赖（原样一行 → 本地目录）换成 `name @ file:///…`；
///   少一行或多出别的 git 依赖都抛 [FormatException]（锁文件与清单对不上，宁可不装）；
/// - `--extra-index-url` 只留所选后端那一个 PyTorch 源（macOS 一个都不留：cpu extra
///   在 macOS 用 PyPI 的 torch）；
/// - 末尾加上服务本体（[serverDir]，`--no-emit-project` 导出时没带它）。
String rewriteIrodoriRequirements(
  String exported, {
  required Map<String, String> localSources,
  required IrodoriTorchBackend backend,
  required bool isMacOS,
  required String serverDir,
  required bool windowsPaths,
}) {
  String fileUri(String dir) => Uri.file(dir, windows: windowsPaths).toString();
  final String keepIndex = irodoriTorchIndexUrl(backend);
  final Set<String> replaced = <String>{};
  final List<String> out = <String>[];
  for (final String line in const LineSplitter().convert(exported)) {
    final String trimmed = line.trim();
    if (trimmed.startsWith('--extra-index-url')) {
      final String url = trimmed.substring('--extra-index-url'.length).trim();
      if (!isMacOS && url == keepIndex) out.add(line);
      continue;
    }
    String? rewritten;
    for (final MapEntry<String, String> e in localSources.entries) {
      if (trimmed == e.key || trimmed.startsWith('${e.key} ')) {
        final String name = e.key.split(' @ ').first.trim();
        rewritten =
            '$name @ ${fileUri(e.value)}${trimmed.substring(e.key.length)}';
        replaced.add(e.key);
        break;
      }
    }
    if (rewritten != null) {
      out.add(rewritten);
      continue;
    }
    if (!trimmed.startsWith('#') && trimmed.contains('git+')) {
      throw FormatException('unexpected git requirement: $trimmed');
    }
    out.add(line);
  }
  final Set<String> missing = localSources.keys.toSet().difference(replaced);
  if (missing.isNotEmpty) {
    throw FormatException('locked git requirement not found: $missing');
  }
  out.add('irodori-tts-server @ ${fileUri(serverDir)}');
  return '${out.join('\n')}\n';
}

/// 安装进行到哪一步。
enum IrodoriInstallStep {
  idle,
  downloadingUv,
  downloadingSource,
  installingPython,
  installingPackages,
  downloadingModel,
  done,
  failed,
  cancelled,
}

/// 安装失败的原因（UI 翻译成文案；细节在 [IrodoriInstaller.detail] 与安装日志）。
enum IrodoriInstallFailure {
  /// 本平台没有可用的 uv / PyTorch 组合。
  unsupported,

  /// 下载连不上。
  network,

  /// 下完体积 / sha256 对不上（已删掉坏文件，重试会从头下）。
  corrupt,

  /// 写不进安装目录（权限、磁盘满）。
  disk,

  /// uv / Python 环境那几步失败（看安装日志）。
  environment,
}

/// 起一个安装命令（测试注入假进程）。不继承父进程里 `UV_*` / `VIRTUAL_ENV` 之类会
/// 改变 uv 行为的环境变量：[environment] 是完整环境。
typedef IrodoriCommandSpawn =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      required String workingDirectory,
      required Map<String, String> environment,
    });

Future<Process> _registrySpawn(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required Map<String, String> environment,
}) => HelperProcessRegistry.instance.start(
  executable,
  arguments,
  workingDirectory: workingDirectory,
  environment: environment,
  includeParentEnvironment: false,
);

/// 父进程环境里会改变 uv / Python 行为的变量（不传给安装命令与服务）。
bool irodoriInheritedEnvBlocked(String key) {
  final String k = key.toUpperCase();
  return k.startsWith('UV_') ||
      k == 'VIRTUAL_ENV' ||
      k.startsWith('CONDA') ||
      k == 'PYTHONPATH' ||
      k == 'PYTHONHOME' ||
      k == 'PYTHONSTARTUP' ||
      k == 'PIP_INDEX_URL' ||
      k == 'PIP_EXTRA_INDEX_URL';
}

/// 下载 uv → 取源码 → 装 Python 与依赖 → 下模型。进度经 [EngineChangeNotifier] 通知。
/// 每一步都可重入：已完成的（uv 版本对、源码 commit 对、环境指纹与后端对、模型文件
/// 齐）直接跳过，所以「换模型」「装到一半取消后重装」都只补缺的那部分。
class IrodoriInstaller extends EngineChangeNotifier {
  IrodoriInstaller({
    required HttpClient Function() httpClientFactory,
    this.manifest = kIrodoriManifest,
    ResumableDownloadOpen? open,
    IrodoriCommandSpawn? spawn,
    Future<Map<String, String>> Function()? childProxyEnvironment,
    String? platformKey,
    bool? isMacOS,
    bool? windowsPaths,
  }) : _httpClientFactory = httpClientFactory,
       _openOverride = open,
       _spawn = spawn ?? _registrySpawn,
       _childProxyEnvironment = childProxyEnvironment,
       _platformKey = platformKey ?? irodoriPlatformKey(),
       _isMacOS = isMacOS ?? Platform.isMacOS,
       _windowsPaths = windowsPaths ?? Platform.isWindows;

  final IrodoriManifest manifest;
  final HttpClient Function() _httpClientFactory;
  final ResumableDownloadOpen? _openOverride;
  final IrodoriCommandSpawn _spawn;
  final Future<Map<String, String>> Function()? _childProxyEnvironment;
  final String? _platformKey;
  final bool _isMacOS;
  final bool _windowsPaths;

  IrodoriInstallStep step = IrodoriInstallStep.idle;
  IrodoriInstallFailure? failure;

  /// 当前在下的东西（文件名 / 仓库名），UI 显示用。
  String? currentItem;
  int receivedBytes = 0;
  int? totalBytes;

  /// 失败时的技术细节（进日志，不直接给用户看）。
  String? detail;

  /// 安装命令的输出尾（UI「安装日志」）。
  static const int logTailLines = 300;
  final List<String> _log = <String>[];
  List<String> get logTail => List<String>.unmodifiable(_log);

  bool get isBusy =>
      _inFlight.active ||
      switch (step) {
        IrodoriInstallStep.downloadingUv ||
        IrodoriInstallStep.downloadingSource ||
        IrodoriInstallStep.installingPython ||
        IrodoriInstallStep.installingPackages ||
        IrodoriInstallStep.downloadingModel => true,
        _ => false,
      };

  /// 在途安装登记：同步占位防并发重入，完成信号给「删除」等。
  final LocalInstallRun _inFlight = LocalInstallRun();

  bool _cancelled = false;
  HttpClient? _client;
  Process? _process;

  void _set(IrodoriInstallStep next, [IrodoriInstallFailure? why]) {
    step = next;
    failure = why;
    notifyListeners();
  }

  void _appendLog(String line) {
    _log.add(line);
    if (_log.length > logTailLines) {
      _log.removeRange(0, _log.length - logTailLines);
    }
  }

  void cancel() {
    if (!isBusy) return;
    _cancelled = true;
    _client?.close(force: true);
    _process?.kill();
  }

  /// 取消并等安装函数真正返回（下载 client / 子进程 / 文件句柄都已收尾）。
  /// 「删除」必须先等它，再动安装目录。
  Future<void> cancelAndWait() {
    cancel();
    return _inFlight.idle;
  }

  /// 装进 [root]（专属子目录，见 [irodoriPackageDir]）。成功返回 true；失败 / 取消
  /// 返回 false（原因在 [failure]）。
  Future<bool> install({
    required String root,
    required IrodoriTorchBackend backend,
    required IrodoriModelChoice model,
    required IrodoriDownloadSource source,
  }) async {
    if (!_inFlight.tryBegin()) return false;
    try {
      return await _install(
        root: root,
        backend: backend,
        model: model,
        source: source,
      );
    } finally {
      _inFlight.end();
      notifyListeners();
    }
  }

  Future<bool> _install({
    required String root,
    required IrodoriTorchBackend backend,
    required IrodoriModelChoice model,
    required IrodoriDownloadSource source,
  }) async {
    _cancelled = false;
    receivedBytes = 0;
    totalBytes = null;
    currentItem = null;
    detail = null;
    _log.clear();
    final IrodoriUvAsset? uvAsset = _platformKey == null
        ? null
        : manifest.uvAssets[_platformKey];
    final IrodoriModelRepo? modelRepo = manifest.models[model];
    if (uvAsset == null || modelRepo == null) {
      detail = 'platform $_platformKey';
      _set(IrodoriInstallStep.failed, IrodoriInstallFailure.unsupported);
      return false;
    }
    final IrodoriInstallLayout layout = IrodoriInstallLayout(
      root,
      windows: _windowsPaths,
    );
    final HttpClient client = _httpClientFactory();
    _client = client;
    try {
      try {
        for (final String dir in <String>[
          layout.root,
          layout.downloadsDir,
          layout.srcDir,
          layout.voicesDir,
          layout.modelsDir,
        ]) {
          await Directory(dir).create(recursive: true);
        }
      } on FileSystemException catch (e) {
        return _fail(IrodoriInstallFailure.disk, e.message);
      }

      // ① uv（单文件可执行，钉版本 + sha256）。
      if (!_uvReady(layout)) {
        _set(IrodoriInstallStep.downloadingUv);
        final File? archive = await _download(
          client,
          url: manifest.uvUrl(uvAsset),
          destination: File(p.join(layout.downloadsDir, uvAsset.name)),
          size: uvAsset.size,
          sha256: uvAsset.sha256,
          label: 'uv ${manifest.uvVersion}',
        );
        if (archive == null) return false;
        if (!await _installUv(layout, archive, uvAsset)) return false;
      }
      if (_cancelled) return _cancel();

      // ② 源码（服务本体 + 三个 git 依赖，按锁文件的 commit）。
      final IrodoriInstallState? state = layout.readState();
      final bool environmentReady =
          state != null &&
          state.environmentRevision == manifest.environmentRevision &&
          state.backend == backend &&
          File(layout.venvPython).existsSync();
      if (!environmentReady) {
        for (final IrodoriSourceArchive archive in <IrodoriSourceArchive>[
          manifest.server,
          ...manifest.dependencies,
        ]) {
          if (_sourceReady(layout, archive)) continue;
          _set(IrodoriInstallStep.downloadingSource);
          final File? zip = await _download(
            client,
            url: archive.url,
            destination: File(
              p.join(layout.downloadsDir, '${archive.dirName}.zip'),
            ),
            size: archive.size,
            sha256: archive.sha256,
            label: archive.repo,
          );
          if (zip == null) return false;
          if (!await _extractSource(layout, archive, zip)) return false;
          if (_cancelled) return _cancel();
        }

        // ③ 受管 Python + 锁定依赖。
        if (!await _installEnvironment(layout, backend)) return false;
        try {
          layout.writeState(
            IrodoriInstallState(
              environmentRevision: manifest.environmentRevision,
              backend: backend,
            ),
          );
        } on FileSystemException catch (e) {
          return _fail(IrodoriInstallFailure.disk, e.message);
        }
      }
      if (_cancelled) return _cancel();

      // ④ 模型（可续传、sha256 校验；服务启动时以本地路径加载）。
      for (final IrodoriModelRepo repo in <IrodoriModelRepo>[
        modelRepo,
        manifest.codec,
      ]) {
        if (!await _downloadModel(client, layout, repo, source)) return false;
      }
      currentItem = null;
      // 下载暂存区只放 uv / 源码 zip，装完就没用了。
      try {
        await Directory(layout.downloadsDir).delete(recursive: true);
      } on FileSystemException {
        // 删不掉不影响使用。
      }
      _set(IrodoriInstallStep.done);
      return true;
    } finally {
      _client = null;
      client.close(force: true);
    }
  }

  bool _fail(IrodoriInstallFailure why, String? message) {
    if (_cancelled) return _cancel();
    detail = message;
    if (message != null) _appendLog('[failed] $message');
    _set(IrodoriInstallStep.failed, why);
    return false;
  }

  bool _cancel() {
    _set(IrodoriInstallStep.cancelled);
    return false;
  }

  bool _uvReady(IrodoriInstallLayout layout) {
    try {
      return File(layout.uvExecutable).existsSync() &&
          File(layout.uvVersionMarker).readAsStringSync().trim() ==
              manifest.uvVersion;
    } on FileSystemException {
      return false;
    }
  }

  static String _sourceMarker(String dir) => p.join(dir, '.fushi_commit');

  bool _sourceReady(IrodoriInstallLayout layout, IrodoriSourceArchive a) {
    try {
      return File(
            _sourceMarker(layout.sourceDir(a)),
          ).readAsStringSync().trim() ==
          a.commit;
    } on FileSystemException {
      return false;
    }
  }

  Future<ResumableDownloadResponse> _open(
    HttpClient client,
    Uri uri,
    Map<String, String> headers,
  ) {
    final ResumableDownloadOpen? override = _openOverride;
    if (override != null) return override(uri, headers);
    return openLocalServiceGet(client, uri, headers);
  }

  /// 下一个钉死摘要的文件；失败已置好 [failure] 并返回 null。
  Future<File?> _download(
    HttpClient client, {
    required Uri url,
    required File destination,
    required int size,
    required String sha256,
    required String label,
    int baseReceived = 0,
    int? overallTotal,
  }) async {
    currentItem = label;
    receivedBytes = baseReceived;
    totalBytes = overallTotal ?? size;
    notifyListeners();
    if (await destination.exists() && await destination.length() == size) {
      receivedBytes = baseReceived + size;
      return destination;
    }
    try {
      await destination.parent.create(recursive: true);
      return await ResumableDownloader(
        url: url.toString(),
        destination: destination,
        partFile: File('${destination.path}.part'),
        open: (Uri uri, Map<String, String> headers) =>
            _open(client, uri, headers),
        expectedSize: size,
        expectedSha256: sha256,
        firstByteTimeout: const Duration(seconds: 60),
        bodyTimeout: const Duration(seconds: 60),
        onProgress: (int received, int? _) {
          receivedBytes = baseReceived + received;
          notifyListeners();
        },
      ).download();
    } on ResumableDownloadIntegrityException catch (e) {
      _fail(IrodoriInstallFailure.corrupt, '$label: ${e.message}');
      return null;
    } on FileSystemException catch (e) {
      _fail(IrodoriInstallFailure.disk, '$label: ${e.message}');
      return null;
    } on Object catch (e) {
      _fail(IrodoriInstallFailure.network, '$label: $e');
      return null;
    }
  }

  Future<bool> _installUv(
    IrodoriInstallLayout layout,
    File archive,
    IrodoriUvAsset asset,
  ) async {
    try {
      final List<int> bytes = await archive.readAsBytes();
      final Archive decoded = asset.isZip
          ? ZipDecoder().decodeBytes(bytes)
          : TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
      final String wanted = _windowsPaths ? 'uv.exe' : 'uv';
      final ArchiveFile? entry = decoded.files
          .where(
            (ArchiveFile f) => f.isFile && p.posix.basename(f.name) == wanted,
          )
          .firstOrNull;
      if (entry == null) {
        return _fail(IrodoriInstallFailure.corrupt, 'no $wanted in archive');
      }
      await Directory(layout.uvDir).create(recursive: true);
      await File(
        layout.uvExecutable,
      ).writeAsBytes(entry.content as List<int>, flush: true);
      if (!_windowsPaths) {
        final ProcessResult r = await Process.run('chmod', <String>[
          '755',
          layout.uvExecutable,
        ]);
        if (r.exitCode != 0) {
          return _fail(IrodoriInstallFailure.disk, 'chmod: ${r.stderr}');
        }
      }
      await File(layout.uvVersionMarker).writeAsString(manifest.uvVersion);
      await archive.delete();
      return true;
    } on FileSystemException catch (e) {
      return _fail(IrodoriInstallFailure.disk, e.message);
    } on Object catch (e) {
      return _fail(IrodoriInstallFailure.corrupt, 'uv archive: $e');
    }
  }

  /// 解一个 GitHub 源码 zip 到 `src/<dirName>`：去掉 GitHub 加的那层顶层目录，拒绝
  /// 越出目标目录的条目。
  Future<bool> _extractSource(
    IrodoriInstallLayout layout,
    IrodoriSourceArchive archive,
    File zip,
  ) async {
    final String target = layout.sourceDir(archive);
    try {
      final Directory dir = Directory(target);
      if (await dir.exists()) await dir.delete(recursive: true);
      await dir.create(recursive: true);
      final Archive decoded = ZipDecoder().decodeBytes(await zip.readAsBytes());
      for (final ArchiveFile f in decoded.files) {
        final List<String> parts = f.name
            .split('/')
            .where((String s) => s.isNotEmpty)
            .toList();
        if (parts.length < 2) continue;
        final String relative = parts.skip(1).join('/');
        final String out = p.normalize(p.join(target, relative));
        if (!p.isWithin(target, out)) {
          return _fail(IrodoriInstallFailure.corrupt, 'bad entry ${f.name}');
        }
        if (f.isFile) {
          await File(out).parent.create(recursive: true);
          await File(out).writeAsBytes(f.content as List<int>);
        } else {
          await Directory(out).create(recursive: true);
        }
      }
      await File(_sourceMarker(target)).writeAsString(archive.commit);
      await zip.delete();
      return true;
    } on FileSystemException catch (e) {
      return _fail(IrodoriInstallFailure.disk, e.message);
    } on Object catch (e) {
      return _fail(IrodoriInstallFailure.corrupt, '${archive.repo}: $e');
    }
  }

  /// uv 命令的环境：缓存 / 受管 Python 都钉在专属目录；父进程里会改变 uv 行为的
  /// 变量不带；app 设了代理时经本机中继出网。
  Future<Map<String, String>> _uvEnvironment(
    IrodoriInstallLayout layout,
  ) async {
    Map<String, String> proxy = const <String, String>{};
    final Future<Map<String, String>> Function()? proxyEnv =
        _childProxyEnvironment;
    if (proxyEnv != null) {
      try {
        proxy = await proxyEnv();
      } on Object catch (e) {
        _appendLog('[proxy relay unavailable: $e]');
      }
    }
    return <String, String>{
      for (final MapEntry<String, String> e in Platform.environment.entries)
        if (!irodoriInheritedEnvBlocked(e.key)) e.key: e.value,
      ...proxy,
      'UV_CACHE_DIR': layout.cacheDir,
      'UV_PYTHON_INSTALL_DIR': layout.pythonDir,
      'UV_PYTHON_BIN_DIR': p.join(layout.pythonDir, 'bin'),
      'UV_NO_PROGRESS': '1',
      'PYTHONUTF8': '1',
      'PYTHONIOENCODING': 'utf-8',
    };
  }

  Future<bool> _installEnvironment(
    IrodoriInstallLayout layout,
    IrodoriTorchBackend backend,
  ) async {
    final Map<String, String> env = await _uvEnvironment(layout);
    final String uv = layout.uvExecutable;
    currentItem = null;
    receivedBytes = 0;
    totalBytes = null;

    _set(IrodoriInstallStep.installingPython);
    if (!await _runStep(
      uv,
      <String>[
        'python',
        'install',
        manifest.pythonVersion,
        '--no-bin',
        '--no-registry',
        '--no-config',
      ],
      workingDirectory: layout.root,
      environment: env,
    )) {
      return false;
    }
    if (_cancelled) return _cancel();

    _set(IrodoriInstallStep.installingPackages);
    // 导出官方锁文件里该 extra 的依赖（--frozen：只读 uv.lock，不重新解析、不碰 git）。
    if (!await _runStep(
      uv,
      <String>[
        'export',
        '--frozen',
        '--extra',
        backend.name,
        '--no-emit-project',
        '--emit-index-url',
        '--format',
        'requirements-txt',
        '--output-file',
        layout.exportedRequirements,
      ],
      workingDirectory: layout.serverDir,
      environment: env,
    )) {
      return false;
    }
    try {
      final String rewritten = rewriteIrodoriRequirements(
        await File(layout.exportedRequirements).readAsString(),
        localSources: <String, String>{
          for (final IrodoriSourceArchive d in manifest.dependencies)
            if (d.lockedRequirement != null)
              d.lockedRequirement!: layout.sourceDir(d),
        },
        backend: backend,
        isMacOS: _isMacOS,
        serverDir: layout.serverDir,
        windowsPaths: _windowsPaths,
      );
      await File(layout.requirements).writeAsString(rewritten);
    } on FormatException catch (e) {
      return _fail(IrodoriInstallFailure.environment, e.message);
    } on FileSystemException catch (e) {
      return _fail(IrodoriInstallFailure.disk, e.message);
    }
    if (_cancelled) return _cancel();
    if (!await _runStep(
      uv,
      <String>[
        'venv',
        layout.venvDir,
        '--python',
        manifest.pythonVersion,
        '--managed-python',
        '--no-python-downloads',
        '--clear',
        '--no-config',
      ],
      workingDirectory: layout.serverDir,
      environment: env,
    )) {
      return false;
    }
    if (_cancelled) return _cancel();
    // 每个包都带锁文件里的 sha256，多个索引里不论从哪取都必须是那个文件。
    return _runStep(
      uv,
      <String>[
        'pip',
        'sync',
        '--python',
        layout.venvPython,
        '--index-strategy',
        'unsafe-best-match',
        '--no-config',
        layout.requirements,
      ],
      workingDirectory: layout.serverDir,
      environment: env,
    );
  }

  /// 跑一条安装命令，输出进安装日志；非零退出 → environment 失败。
  Future<bool> _runStep(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
  }) async {
    if (_cancelled) return _cancel();
    _appendLog('\$ ${p.basename(executable)} ${arguments.join(' ')}');
    notifyListeners();
    final Process process;
    try {
      process = await _spawn(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
      );
    } on ProcessException catch (e) {
      return _fail(IrodoriInstallFailure.environment, e.message);
    }
    _process = process;
    // 取消落在子进程启动的 await 里时 cancel() 还看不到它：补杀。
    if (_cancelled) process.kill();
    final List<Future<void>> streams = <Future<void>>[
      for (final Stream<List<int>> s in <Stream<List<int>>>[
        process.stdout,
        process.stderr,
      ])
        s
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .listen((String line) {
              if (line.trim().isEmpty) return;
              _appendLog(line);
              notifyListeners();
            })
            .asFuture<void>()
            .catchError((Object _) {}),
    ];
    final int code = await process.exitCode;
    await Future.wait(streams);
    _process = null;
    if (_cancelled) return _cancel();
    if (code != 0) {
      return _fail(
        IrodoriInstallFailure.environment,
        '${p.basename(executable)} ${arguments.first} exited $code',
      );
    }
    return true;
  }

  Future<bool> _downloadModel(
    HttpClient client,
    IrodoriInstallLayout layout,
    IrodoriModelRepo repo,
    IrodoriDownloadSource source,
  ) async {
    if (layout.hasModel(repo)) return true;
    _set(IrodoriInstallStep.downloadingModel);
    int done = 0;
    for (final IrodoriPinnedFile f in repo.files) {
      final File? got = await _download(
        client,
        url: repo.url(source, f),
        destination: File(layout.modelFile(repo, f)),
        size: f.size,
        sha256: f.sha256,
        label: repo.dirName,
        baseReceived: done,
        overallTotal: repo.totalBytes,
      );
      if (got == null) return false;
      if (_cancelled) return _cancel();
      done += f.size;
    }
    return true;
  }
}
