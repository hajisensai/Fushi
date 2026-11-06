/// 「本机 GPT-SoVITS」的应用级门面：安装位置 / 端口 / 下载源的持久化 + 安装器 +
/// 服务进程，外加朗读时按需自动拉起服务。
///
/// 只在 Windows 提供（官方只有 Windows 免安装整合包；macOS / Linux 要 conda 装，
/// 仍按「外部服务」手填地址）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/foundation/engine_notifier.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/tts/local/gpt_sovits_local_package.dart';
import 'package:fushi_engine/tts/local/gpt_sovits_local_server.dart';
import 'package:fushi_engine/tts/local/local_service_support.dart';
import 'package:fushi_engine/tts/providers/gpt_sovits_tts_provider.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:path/path.dart' as p;

/// 持久化：`{dir, port, source, owned}`（设备本地，不进同步 / 备份）。
const String kGptSovitsLocalPrefKey = 'tts_gpt_sovits_local';

/// 官方默认端口。
const int kGptSovitsDefaultPort = 9880;

class GptSovitsLocalSettings {
  const GptSovitsLocalSettings({
    this.dir,
    this.port = kGptSovitsDefaultPort,
    this.source = GptSovitsPackageSource.huggingFace,
    this.owned = false,
  });

  /// 整合包所在目录（安装目录或用户指定的已有整合包）。null = 没装。
  final String? dir;
  final int port;
  final GptSovitsPackageSource source;

  /// 是不是 app 装的：只有 app 装的才提供「删除」（用户自己的整合包只「移除」）。
  /// app 装的 [dir] 恒为安装目录下的专属子目录（[kGptSovitsInstallSubdir]）。
  final bool owned;

  GptSovitsLocalSettings copyWith({
    String? dir,
    bool clearDir = false,
    int? port,
    GptSovitsPackageSource? source,
    bool? owned,
  }) => GptSovitsLocalSettings(
    dir: clearDir ? null : (dir ?? this.dir),
    port: port ?? this.port,
    source: source ?? this.source,
    owned: owned ?? this.owned,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    if (dir != null) 'dir': dir,
    'port': port,
    'source': source.name,
    'owned': owned,
  };

  static GptSovitsLocalSettings fromJson(Object? raw) {
    if (raw is! Map) return const GptSovitsLocalSettings();
    final Object? dir = raw['dir'];
    final Object? port = raw['port'];
    return GptSovitsLocalSettings(
      dir: dir is String && dir.isNotEmpty ? dir : null,
      port: port is int && port > 0 && port < 65536
          ? port
          : kGptSovitsDefaultPort,
      source: GptSovitsPackageSource.values.firstWhere(
        (GptSovitsPackageSource s) => s.name == raw['source'],
        orElse: () => GptSovitsPackageSource.huggingFace,
      ),
      owned: raw['owned'] == true,
    );
  }
}

class GptSovitsLocalEngine extends EngineChangeNotifier {
  GptSovitsLocalEngine({
    required PrefStore prefs,
    required HttpClient Function() httpClientFactory,
    GptSovitsInstaller? installer,
    GptSovitsLocalServer? server,
    bool? supported,
  }) : _prefs = prefs,
       installer =
           installer ??
           GptSovitsInstaller(httpClientFactory: httpClientFactory),
       server = server ?? GptSovitsLocalServer(),
       isSupported = supported ?? platformSupported {
    this.installer.addListener(notifyListeners);
    this.server.addListener(notifyListeners);
  }

  /// 本平台有没有官方免安装整合包（只有 Windows）。不必先建实例就能判（设置页
  /// 可见性用它）。
  static bool get platformSupported => Platform.isWindows;

  final PrefStore _prefs;
  final GptSovitsInstaller installer;
  final GptSovitsLocalServer server;
  final bool isSupported;

  GptSovitsLocalSettings get settings {
    final Object? raw = _prefs.getPref(
      kGptSovitsLocalPrefKey,
      defaultValue: '',
    );
    if (raw is! String || raw.isEmpty) return const GptSovitsLocalSettings();
    try {
      return GptSovitsLocalSettings.fromJson(jsonDecode(raw));
    } on FormatException {
      return const GptSovitsLocalSettings();
    }
  }

  Future<void> _save(GptSovitsLocalSettings next) async {
    await _prefs.setPref(kGptSovitsLocalPrefKey, jsonEncode(next.toJson()));
    notifyListeners();
  }

  Future<void> setSource(GptSovitsPackageSource source) =>
      _save(settings.copyWith(source: source));

  /// 朗读时自动拉起失败过一次就不再自动重拉（否则每一句都要再等一轮 5 分钟超时、
  /// 再起一次注定失败的进程），直到用户有所动作：手动启动、重装、换整合包、改端口。
  bool _autoStartBlocked = false;

  /// 自动拉起是否已因失败暂停（设置页 / 测试读）。
  bool get autoStartBlocked => _autoStartBlocked;

  Future<void> setPort(int port) async {
    _autoStartBlocked = false;
    if (server.phase != GptSovitsServerPhase.stopped) await server.stop();
    await _save(settings.copyWith(port: port));
  }

  /// 当前可用的整合包布局；没装 / 目录被删返回 null。
  GptSovitsInstallLayout? get layout {
    final String? dir = settings.dir;
    return dir == null ? null : GptSovitsInstallLayout.find(dir);
  }

  bool get isInstalled => layout != null;

  /// 「删除」会不会真删文件：只有 app 装的、且记录的是专属子目录时才会。
  bool get canDeleteFiles {
    final GptSovitsLocalSettings current = settings;
    final String? dir = current.dir;
    return current.owned &&
        dir != null &&
        p.basename(dir) == kGptSovitsInstallSubdir;
  }

  /// 服务地址（预设里填它）。
  String get endpoint => 'http://127.0.0.1:${settings.port}';

  /// 默认安装位置：数据目录下（用户可在安装前换到空间大的盘）。
  static String defaultInstallDir(Directory supportRoot) =>
      p.join(supportRoot.path, 'gpt_sovits');

  /// 下载并安装到 [installDir] 下的专属子目录（[gptSovitsPackageDir]）。记下的、
  /// 将来「删除」会删的只有那个子目录。
  Future<bool> install({
    required String installDir,
    required GptSovitsPackageVariant variant,
  }) async {
    _autoStartBlocked = false;
    final GptSovitsInstallLayout? installed = await installer.install(
      installDir: installDir,
      source: settings.source,
      variant: variant,
    );
    if (installed == null) return false;
    await _save(
      settings.copyWith(dir: gptSovitsPackageDir(installDir), owned: true),
    );
    return true;
  }

  /// 指向一份已解压的整合包（用户自己下过的）。认不出返回 false、不保存。
  Future<bool> useExisting(String dir) async {
    final GptSovitsInstallLayout? found = GptSovitsInstallLayout.find(dir);
    if (found == null) return false;
    try {
      await found.ensureAppConfig();
    } on FileSystemException {
      return false;
    }
    _autoStartBlocked = false;
    await _save(settings.copyWith(dir: dir, owned: false));
    return true;
  }

  /// 停服务并忘掉整合包；[deleteFiles] 且是 app 装的才真删——只删 app 专属子目录
  /// （名字不是 [kGptSovitsInstallSubdir] 的一律不删，防记录被改坏时误删用户目录）。
  Future<void> remove({required bool deleteFiles}) async {
    await installer.cancelAndWait();
    await server.stop();
    _autoStartBlocked = false;
    final GptSovitsLocalSettings current = settings;
    final String? dir = current.dir;
    if (deleteFiles && canDeleteFiles && dir != null) {
      await deleteLocalInstallDir(dir);
    }
    await _save(current.copyWith(clearDir: true, owned: false));
  }

  /// 用户手动启动（同时解除自动拉起的失败暂停）。
  Future<bool> start() {
    _autoStartBlocked = false;
    return _launch();
  }

  Future<bool> _launch() async {
    final GptSovitsInstallLayout? found = layout;
    if (found == null) return false;
    try {
      await found.ensureAppConfig();
    } on FileSystemException {
      // 配置副本写不出来交给 server 起不来时报。
    }
    return server.start(found.launchSpec(settings.port));
  }

  Future<void> stop() => server.stop();

  /// 退出 app 时调用：停服务，并取消进行中的安装（解压中的 tar 子进程一并杀掉）。
  Future<void> shutdown() async {
    installer.cancel();
    await server.stop();
  }

  /// 朗读要用 [endpoint] 时调用：它指向本机托管的端口且已安装，就把服务拉起来并
  /// 等就绪；与本机托管无关的地址什么都不做。自动拉起失败过就不再重试（见
  /// [autoStartBlocked]），照常让请求去连、报「无法连接语音服务」。
  Future<void> ensureRunningFor(String endpoint) async {
    if (!isSupported || !isInstalled || server.isRunning) return;
    if (_autoStartBlocked) return;
    if (!gptSovitsEndpointIsManaged(endpoint, settings.port)) return;
    final bool ok = await _launch();
    // 被用户停止（stopped）不算失败；起不来才暂停自动拉起。
    if (!ok && server.phase == GptSovitsServerPhase.failed) {
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

/// 注册表里替换 [GptSovitsTtsDescriptor] 的版本：合成 / 列声音前先确保本机托管的
/// 服务在跑（朗读时自动拉起，用户不必先进设置页点「启动」）。id、参数表、缓存键与
/// 原描述符完全相同。
class AutoStartGptSovitsTtsDescriptor extends GptSovitsTtsDescriptor {
  const AutoStartGptSovitsTtsDescriptor(this.engine);

  final GptSovitsLocalEngine engine;

  @override
  TtsProvider create(TtsVoicePreset preset, TtsHost host) =>
      AutoStartTtsProvider(
        super.create(preset, host),
        () => engine.ensureRunningFor(
          preset.param(
            GptSovitsTtsDescriptor.endpointKey,
            fallback: params.first.defaultValue,
          ),
        ),
      );
}

/// [endpoint] 是不是本机托管服务的地址（回环主机 + 托管端口）。
bool gptSovitsEndpointIsManaged(String endpoint, int port) =>
    localServiceEndpointIsManaged(endpoint, port);
