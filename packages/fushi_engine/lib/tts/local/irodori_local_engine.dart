/// 「本机 Irodori-TTS」的应用级门面：安装位置 / 端口 / 后端 / 模型 / 下载源的持久化 +
/// 安装器 + 服务进程，外加朗读时按需自动拉起服务。
///
/// 部署的是官方 `Aratako/Irodori-TTS-Server`（OpenAI 兼容），与所有者自己的有声书
/// 工作台（`IrodoriTtsDescriptor`，端口 7870）无关，两者并存。桌面三端提供
/// （uv 三端都有）；移动端没有入口。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/foundation/engine_notifier.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/tts/local/irodori_local_package.dart';
import 'package:fushi_engine/tts/local/irodori_local_server.dart';
import 'package:fushi_engine/tts/local/local_service_process.dart';
import 'package:fushi_engine/tts/local/local_service_support.dart';
import 'package:fushi_engine/tts/providers/irodori_server_tts_provider.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:path/path.dart' as p;

/// 持久化：`{dir, port, source, backend, model, owned}`（设备本地，不进同步 / 备份）。
const String kIrodoriLocalPrefKey = 'tts_irodori_local';

/// 官方默认端口（`IRODORI_PORT`）。
const int kIrodoriDefaultPort = 8088;

/// 不能用的端口：Irodori 工作台 7870、GPT-SoVITS 工作台 7871、GPT-SoVITS api_v2 9880。
const Set<int> kIrodoriReservedPorts = <int>{7870, 7871, 9880};

/// 端口能不能给本机 Irodori 用（非特权端口、不撞另外三个本机服务）。
bool irodoriPortAllowed(int port) =>
    port >= 1024 && port <= 65535 && !kIrodoriReservedPorts.contains(port);

class IrodoriLocalSettings {
  const IrodoriLocalSettings({
    this.dir,
    this.port = kIrodoriDefaultPort,
    this.source = IrodoriDownloadSource.huggingFace,
    this.backend,
    this.model = IrodoriModelChoice.small,
    this.owned = false,
  });

  /// 专属子目录（[kIrodoriInstallSubdir]）。null = 没装。
  final String? dir;
  final int port;
  final IrodoriDownloadSource source;

  /// 用户指定的 PyTorch 后端；null = 按显卡自动选（[irodoriBackendFor]）。
  final IrodoriTorchBackend? backend;
  final IrodoriModelChoice model;

  /// 是不是 app 装的（只有 app 装的才删文件）。
  final bool owned;

  IrodoriLocalSettings copyWith({
    String? dir,
    bool clearDir = false,
    int? port,
    IrodoriDownloadSource? source,
    IrodoriTorchBackend? backend,
    bool clearBackend = false,
    IrodoriModelChoice? model,
    bool? owned,
  }) => IrodoriLocalSettings(
    dir: clearDir ? null : (dir ?? this.dir),
    port: port ?? this.port,
    source: source ?? this.source,
    backend: clearBackend ? null : (backend ?? this.backend),
    model: model ?? this.model,
    owned: owned ?? this.owned,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    if (dir != null) 'dir': dir,
    'port': port,
    'source': source.name,
    if (backend != null) 'backend': backend!.name,
    'model': model.name,
    'owned': owned,
  };

  static T? _enum<T extends Enum>(List<T> values, Object? raw) =>
      values.where((T v) => v.name == raw).firstOrNull;

  static IrodoriLocalSettings fromJson(Object? raw) {
    if (raw is! Map) return const IrodoriLocalSettings();
    final Object? dir = raw['dir'];
    final Object? port = raw['port'];
    return IrodoriLocalSettings(
      dir: dir is String && dir.isNotEmpty ? dir : null,
      port: port is int && irodoriPortAllowed(port)
          ? port
          : kIrodoriDefaultPort,
      source:
          _enum(IrodoriDownloadSource.values, raw['source']) ??
          IrodoriDownloadSource.huggingFace,
      backend: _enum(IrodoriTorchBackend.values, raw['backend']),
      model:
          _enum(IrodoriModelChoice.values, raw['model']) ??
          IrodoriModelChoice.small,
      owned: raw['owned'] == true,
    );
  }
}

class IrodoriLocalEngine extends EngineChangeNotifier {
  IrodoriLocalEngine({
    required PrefStore prefs,
    required HttpClient Function() httpClientFactory,
    Future<Map<String, String>> Function()? childProxyEnvironment,
    IrodoriInstaller? installer,
    IrodoriLocalServer? server,
    this.manifest = kIrodoriManifest,
    bool? supported,
  }) : _prefs = prefs,
       installer =
           installer ??
           IrodoriInstaller(
             httpClientFactory: httpClientFactory,
             manifest: manifest,
             childProxyEnvironment: childProxyEnvironment,
           ),
       server = server ?? IrodoriLocalServer(),
       isSupported = supported ?? platformSupported {
    this.installer.addListener(notifyListeners);
    this.server.addListener(notifyListeners);
  }

  /// 桌面三端（有 uv 发行包、且有 PyTorch 轮子的架构）。不必先建实例就能判（设置页
  /// 可见性用它）。
  static bool get platformSupported =>
      (Platform.isWindows || Platform.isMacOS || Platform.isLinux) &&
      irodoriPlatformKey() != null;

  final PrefStore _prefs;
  final IrodoriManifest manifest;
  final IrodoriInstaller installer;
  final IrodoriLocalServer server;
  final bool isSupported;

  IrodoriLocalSettings get settings {
    final Object? raw = _prefs.getPref(kIrodoriLocalPrefKey, defaultValue: '');
    if (raw is! String || raw.isEmpty) return const IrodoriLocalSettings();
    try {
      return IrodoriLocalSettings.fromJson(jsonDecode(raw));
    } on FormatException {
      return const IrodoriLocalSettings();
    }
  }

  Future<void> _save(IrodoriLocalSettings next) async {
    await _prefs.setPref(kIrodoriLocalPrefKey, jsonEncode(next.toJson()));
    notifyListeners();
  }

  Future<void> setSource(IrodoriDownloadSource source) =>
      _save(settings.copyWith(source: source));

  /// null = 回到按显卡自动选。
  Future<void> setBackend(IrodoriTorchBackend? backend) => _save(
    backend == null
        ? settings.copyWith(clearBackend: true)
        : settings.copyWith(backend: backend),
  );

  /// 换模型：服务在跑就先停（下次启动加载新模型）；新模型没下过时 [isInstalled] 变
  /// false，页面给「下载并安装」补下。
  Future<void> setModel(IrodoriModelChoice model) async {
    if (model == settings.model) return;
    _autoStartBlocked = false;
    if (server.phase != LocalServicePhase.stopped) await server.stop();
    await _save(settings.copyWith(model: model));
  }

  /// 改端口（不合法返回 false 不保存）。服务在跑就先停。
  Future<bool> setPort(int port) async {
    if (!irodoriPortAllowed(port)) return false;
    _autoStartBlocked = false;
    if (server.phase != LocalServicePhase.stopped) await server.stop();
    await _save(settings.copyWith(port: port));
    return true;
  }

  /// 朗读时自动拉起失败过一次就不再自动重拉，直到用户有所动作（手动启动、重装、改
  /// 端口 / 模型）。
  bool _autoStartBlocked = false;
  bool get autoStartBlocked => _autoStartBlocked;

  /// 记录的安装目录布局（不管装没装完）。
  IrodoriInstallLayout? get _recordedLayout {
    final String? dir = settings.dir;
    return dir == null ? null : IrodoriInstallLayout(dir);
  }

  /// Python 环境装好了（不管当前模型下没下）。
  bool get environmentReady {
    final IrodoriInstallLayout? layout = _recordedLayout;
    if (layout == null) return false;
    final IrodoriInstallState? state = layout.readState();
    return state != null &&
        state.environmentRevision == manifest.environmentRevision &&
        File(layout.venvPython).existsSync();
  }

  /// 可用的安装：环境好了、当前所选模型与编解码器都在。没装 / 被删 / 换了没下过的
  /// 模型返回 null。
  IrodoriInstallLayout? get layout {
    final IrodoriInstallLayout? recorded = _recordedLayout;
    final IrodoriModelRepo? model = manifest.models[settings.model];
    if (recorded == null || model == null || !environmentReady) return null;
    if (!recorded.hasModel(model) || !recorded.hasModel(manifest.codec)) {
      return null;
    }
    return recorded;
  }

  bool get isInstalled => layout != null;

  /// 已装的后端（状态文件里记的）；没装返回 null。
  IrodoriTorchBackend? get installedBackend =>
      _recordedLayout?.readState()?.backend;

  /// 「删除」会不会真删文件：只有 app 装的、且记录的是专属子目录时才会。
  bool get canDeleteFiles {
    final IrodoriLocalSettings current = settings;
    final String? dir = current.dir;
    return current.owned &&
        dir != null &&
        p.basename(dir) == kIrodoriInstallSubdir;
  }

  /// 服务地址（预设里填它）。
  String get endpoint => 'http://127.0.0.1:${settings.port}';

  /// 默认安装位置：数据目录下（用户可在安装前换到空间大的盘）。
  static String defaultInstallDir(Directory supportRoot) =>
      p.join(supportRoot.path, 'irodori_tts');

  /// 下载并安装到 [installDir] 下的专属子目录。[backend] 为 null 时用设置里的（再没有
  /// 就由调用方先按显卡定好再传）。已装好的部分跳过（换模型 = 只补下模型）。
  Future<bool> install({
    required String installDir,
    required IrodoriTorchBackend backend,
  }) async {
    // 已有安装在跑：不停服务、不改记录（它会把在途安装的目录记录覆盖掉）。
    if (installer.isBusy) return false;
    _autoStartBlocked = false;
    // 换后端要重建 .venv：服务在用它，先停。
    if (server.phase != LocalServicePhase.stopped) await server.stop();
    final String root = irodoriPackageDir(installDir);
    final bool ok = await installer.install(
      root: root,
      backend: backend,
      model: settings.model,
      source: settings.source,
    );
    // 失败也记下目录：下到一半的东西在专属子目录里，「删除」要能找到它清掉。
    await _save(settings.copyWith(dir: root, owned: true));
    return ok;
  }

  /// 停服务并忘掉安装；[deleteFiles] 且是 app 装的才真删——整个专属子目录（uv、
  /// Python、缓存、环境、模型、上传的声音）一起删。
  Future<void> remove({required bool deleteFiles}) async {
    await installer.cancelAndWait();
    await server.stop();
    _autoStartBlocked = false;
    final IrodoriLocalSettings current = settings;
    final String? dir = current.dir;
    if (deleteFiles && canDeleteFiles && dir != null) {
      await deleteLocalInstallDir(dir);
    }
    await _save(current.copyWith(clearDir: true, owned: false));
  }

  /// 服务的启动参数（与官方 `uv run --no-sync python -m irodori_openai_tts --host
  /// --port` 等价：直接用 `.venv` 里的解释器，不经 uv）。
  LocalServiceLaunchSpec launchSpec(IrodoriInstallLayout layout) {
    final IrodoriLocalSettings s = settings;
    final IrodoriModelRepo model = manifest.models[s.model]!;
    final IrodoriModelRepo codec = manifest.codec;
    return LocalServiceLaunchSpec(
      executable: layout.venvPython,
      arguments: <String>[
        '-m',
        'irodori_openai_tts',
        '--host',
        '127.0.0.1',
        '--port',
        '${s.port}',
      ],
      workingDirectory: layout.serverDir,
      port: s.port,
      environment: irodoriServerEnvironment(
        layout: layout,
        model: model,
        codec: codec,
        port: s.port,
        source: s.source,
      ),
    );
  }

  /// 用户手动启动（同时解除自动拉起的失败暂停）。
  Future<bool> start() {
    _autoStartBlocked = false;
    return _launch();
  }

  Future<bool> _launch() async {
    final IrodoriInstallLayout? found = layout;
    if (found == null) return false;
    return server.start(launchSpec(found));
  }

  Future<void> stop() => server.stop();

  /// 退出 app 时调用：停服务，并取消进行中的安装（uv 子进程一并杀掉）。
  Future<void> shutdown() async {
    installer.cancel();
    await server.stop();
  }

  /// 朗读要用 [endpoint] 时调用：它指向本机托管的端口且已安装，就把服务拉起来并
  /// 等就绪；与本机托管无关的地址什么都不做。
  Future<void> ensureRunningFor(String endpoint) async {
    if (!isSupported || !isInstalled || server.isRunning) return;
    if (_autoStartBlocked || installer.isBusy) return;
    if (!localServiceEndpointIsManaged(endpoint, settings.port)) return;
    final bool ok = await _launch();
    if (!ok && server.phase == LocalServicePhase.failed) {
      _autoStartBlocked = true;
    }
  }

  @override
  void dispose() {
    installer.removeListener(notifyListeners);
    server.removeListener(notifyListeners);
    server.dispose();
    installer.dispose();
    super.dispose();
  }
}

/// 服务进程的环境变量（纯函数，测试直接调）。全部走官方 `IRODORI_*` 配置项：
/// 模型以本地路径给出（app 已下好、校验过），声音目录在专属目录里，启动时就把模型
/// 读进来（端口能答 = 就绪）；HF 缓存与镜像只剩水印模型这类小文件会用到。
Map<String, String> irodoriServerEnvironment({
  required IrodoriInstallLayout layout,
  required IrodoriModelRepo model,
  required IrodoriModelRepo codec,
  required int port,
  required IrodoriDownloadSource source,
}) {
  IrodoriPinnedFile file(IrodoriModelRepo repo, String path) =>
      repo.files.firstWhere((IrodoriPinnedFile f) => f.path == path);
  return <String, String>{
    'IRODORI_HOST': '127.0.0.1',
    'IRODORI_PORT': '$port',
    'IRODORI_HF_CHECKPOINT': model.repo,
    'IRODORI_CHECKPOINT': layout.modelFile(
      model,
      file(model, 'model.safetensors'),
    ),
    'IRODORI_CODEC_REPO': layout.modelFile(codec, file(codec, 'weights.pth')),
    'IRODORI_MODEL_DEVICE': 'auto',
    'IRODORI_CODEC_DEVICE': 'auto',
    'IRODORI_VOICES_DIR': layout.voicesDir,
    'IRODORI_PRELOAD': 'true',
    'IRODORI_MAX_CONCURRENT_SYNTHESIS': '1',
    'IRODORI_DEFAULT_RESPONSE_FORMAT': 'wav',
    'HF_HOME': layout.hfHome,
    'HF_ENDPOINT': irodoriHfEndpoint(source),
    'HF_HUB_DISABLE_TELEMETRY': '1',
    // 中文 Windows 控制台是 GBK：日文日志 / 文本会让 print 直接抛错（GPT-SoVITS 的
    // 经验），一律 UTF-8。用户环境里的 PYTHONPATH / PYTHONHOME 不带进来（空值
    // Python 视同未设）。
    'PYTHONUTF8': '1',
    'PYTHONIOENCODING': 'utf-8',
    'PYTHONNOUSERSITE': '1',
    'PYTHONPATH': '',
    'PYTHONHOME': '',
  };
}

/// 注册表里替换 [IrodoriServerTtsDescriptor] 的版本：合成 / 列声音前先确保本机
/// 托管的服务在跑。id、参数表、缓存键与原描述符完全相同。
class AutoStartIrodoriServerTtsDescriptor extends IrodoriServerTtsDescriptor {
  const AutoStartIrodoriServerTtsDescriptor(this.engine);

  final IrodoriLocalEngine engine;

  @override
  TtsProvider create(TtsVoicePreset preset, TtsHost host) =>
      AutoStartTtsProvider(
        super.create(preset, host),
        () => engine.ensureRunningFor(
          preset.param(
            IrodoriServerTtsDescriptor.endpointKey,
            fallback: IrodoriServerTtsDescriptor.defaultEndpoint,
          ),
        ),
      );
}
