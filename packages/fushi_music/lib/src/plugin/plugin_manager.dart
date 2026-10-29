import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'plugin_ffi.dart';
import 'plugin_instance.dart';
import 'plugin_models.dart';
import 'plugin_net_guard.dart';
import 'plugin_source.dart';

/// 一个已安装插件：校验摘要 + 启用状态；[error] 非空表示已装文件校验失败（被改过 / 不完整）。
class InstalledMusicPlugin {
  const InstalledMusicPlugin({
    required this.id,
    required this.enabled,
    this.info,
    this.error,
  });

  final String id;
  final bool enabled;
  final MusicPluginPackageInfo? info;
  final String? error;

  bool get usable => enabled && info != null;
}

/// 插件目录管理：安装 / 启停 / 卸载 / 按需开实例（docs/specs/2026-10-28-music-plugins.md §5）。
///
/// 目录布局（全部在 [rootDir] 下，不进 Drift——删掉整个目录就是彻底卸载）：
/// - `<id>/`：已安装的插件包（含 `files.json` / `signature.json`）；
/// - `.storage/<id>.json`：插件的 `fushi.storage`；
/// - `.state.json`：`{"enabled": {"<id>": bool}}`（缺省启用）。
class MusicPluginManager {
  MusicPluginManager({
    required this.rootDir,
    required MusicPluginHttpClientFactory httpClientFactory,
    required MusicPluginLogSink log,
    this.budgetMs = 2000,
    MusicPluginVaultKeyProvider? vaultKey,
    MusicPluginHttpPerformer? httpPerformer,
    MusicPluginResolver? resolver,
    MusicPluginAddressBlocker? addressBlocker,
    MusicPluginMediaProbe? mediaProbe,
  }) : _vaultKey = vaultKey,
       _httpClientFactory = httpClientFactory,
       _httpPerformer = httpPerformer,
       _resolver = resolver,
       _addressBlocker = addressBlocker,
       _mediaProbe = mediaProbe,
       _log = log;

  final Directory rootDir;
  final MusicPluginHttpClientFactory _httpClientFactory;
  final MusicPluginLogSink _log;
  final MusicPluginHttpPerformer? _httpPerformer;

  /// 凭据保险库数据密钥来源（见 [MusicPluginVaultKeyProvider]）。
  final MusicPluginVaultKeyProvider? _vaultKey;

  /// 出站解析 / 私网判据 / 媒体探测的注入点（测试用；缺省走系统 DNS 与真实探测）。
  final MusicPluginResolver? _resolver;
  final MusicPluginAddressBlocker? _addressBlocker;
  final MusicPluginMediaProbe? _mediaProbe;
  final int budgetMs;

  final Map<String, Future<MusicPluginInstance>> _instances =
      <String, Future<MusicPluginInstance>>{};
  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// 安装 / 卸载 / 启停后触发（设置页与浏览入口据此刷新）。
  Stream<void> get changes => _changes.stream;

  /// 本平台是否带插件运行时。
  static bool get isSupported => MusicPluginNative.isSupported;

  /// 与 Rust `manifest::valid_id` 同一判据：首尾字母或数字、不得有连续的点。
  static final RegExp _idPattern = RegExp(
    r'^(?!.*\.\.)[a-z0-9][a-z0-9._-]{0,62}[a-z0-9]$',
  );

  File get _stateFile => File('${rootDir.path}/.state.json');

  File storageFileFor(String id) => File('${rootDir.path}/.storage/$id.json');

  /// 启停状态的内存副本（首次读盘后常驻；[setEnabled] / [uninstall] 先改它再写盘，
  /// [instance] 据此同步判可用，不会在读盘的空档里放过刚停用的插件）。
  Map<String, bool>? _enabledCache;

  /// 正在卸载的插件：卸载期间（删目录前后）不再开实例。
  final Set<String> _uninstalling = <String>{};
  int _stateWrites = 0;

  Future<Map<String, bool>> _enabledState() async =>
      _enabledCache ??= await _readEnabled();

  Future<Map<String, bool>> _readEnabled() async {
    try {
      final Map<Object?, Object?> j =
          jsonDecode(await _stateFile.readAsString()) as Map<Object?, Object?>;
      final Map<Object?, Object?> e =
          (j['enabled'] as Map<Object?, Object?>?) ??
          const <Object?, Object?>{};
      return <String, bool>{
        for (final MapEntry<Object?, Object?> x in e.entries)
          if (x.value is bool) '${x.key}': x.value! as bool,
      };
    } on FileSystemException {
      return <String, bool>{};
    } on FormatException {
      return <String, bool>{};
    }
  }

  Future<void> _writeEnabled(Map<String, bool> enabled) async {
    await rootDir.create(recursive: true);
    final File tmp = File('${_stateFile.path}.$pid.${++_stateWrites}.tmp');
    await tmp.writeAsString(jsonEncode(<String, Object?>{'enabled': enabled}));
    await tmp.rename(_stateFile.path);
  }

  /// 列出已安装插件（逐个重新哈希校验）。
  Future<List<InstalledMusicPlugin>> list() async {
    if (!rootDir.existsSync()) return const <InstalledMusicPlugin>[];
    final Map<String, bool> enabled = await _readEnabled();
    final List<InstalledMusicPlugin> out = <InstalledMusicPlugin>[];
    for (final FileSystemEntity e in rootDir.listSync()) {
      if (e is! Directory) continue;
      final String id = e.uri.pathSegments
          .where((String s) => s.isNotEmpty)
          .last;
      if (!_idPattern.hasMatch(id)) continue;
      final Map<String, Object?> r = await MusicPluginNativeAsync.verify(
        e.path,
      );
      final Object? error = r['error'];
      out.add(
        InstalledMusicPlugin(
          id: id,
          enabled: enabled[id] ?? true,
          info: error == null ? MusicPluginPackageInfo.fromJson(r) : null,
          error: error is String ? error : null,
        ),
      );
    }
    out.sort(
      (InstalledMusicPlugin a, InstalledMusicPlugin b) =>
          (a.info?.manifest.name ?? a.id).compareTo(
            b.info?.manifest.name ?? b.id,
          ),
    );
    return out;
  }

  /// 校验一个待安装包（不写盘），供确认弹窗展示。坏包抛 [MusicPluginException]。
  Future<MusicPluginPackageInfo> inspect(Uint8List zip) async {
    final Map<String, Object?> r = await MusicPluginNativeAsync.inspect(zip);
    if (r['error'] case final String e) throw MusicPluginException(e);
    return MusicPluginPackageInfo.fromJson(r);
  }

  /// 待装包 [info] 与已装的同 id 插件是否换了签名者（含「有签名 ↔ 无签名」、已装包校验失败）。
  /// 没装过同 id 插件时为 false。换了签名者的包按新插件处理：[install] 会清掉旧插件的
  /// 登录凭据与存储，不让别人用同一个 id 继承用户的登录态。
  Future<bool> signerChanged(MusicPluginPackageInfo info) async {
    final String id = info.manifest.id;
    if (!_idPattern.hasMatch(id)) return false;
    final Directory dir = Directory('${rootDir.path}/$id');
    if (!dir.existsSync()) return false;
    final Map<String, Object?> r = await MusicPluginNativeAsync.verify(
      dir.path,
    );
    if (r['error'] != null) return true;
    return MusicPluginPackageInfo.fromJson(r).signer != info.signer;
  }

  /// 安装用户确认过的包（[digest] 来自 [inspect]）。同 id 覆盖升级，旧实例关闭；签名者变了
  /// （[signerChanged]）时清掉旧插件的凭据与存储，按新插件处理。
  Future<MusicPluginPackageInfo> install(Uint8List zip, String digest) async {
    final MusicPluginPackageInfo pending = await inspect(zip);
    final String id = pending.manifest.id;
    final bool reset = await signerChanged(pending);
    if (reset) _uninstalling.add(id);
    try {
      if (reset) await _dropInstance(id);
      final Map<String, Object?> r = await MusicPluginNativeAsync.install(
        zip,
        rootDir.path,
        digest,
      );
      if (r['error'] case final String e) throw MusicPluginException(e);
      final MusicPluginPackageInfo info = MusicPluginPackageInfo.fromJson(r);
      await _dropInstance(info.manifest.id);
      if (reset) {
        _log(id, 'warn', '签名者与已安装版本不同：按新插件处理，已清除旧凭据与存储');
        await _clearData(id);
      }
      _changes.add(null);
      return info;
    } finally {
      if (reset) _uninstalling.remove(id);
    }
  }

  /// 清掉插件的 `fushi.storage` 与加密凭据（卸载 / 换签名者覆盖安装）。
  Future<void> _clearData(String id) async {
    final File storage = storageFileFor(id);
    if (storage.existsSync()) await storage.delete();
    final Map<String, Object?> r = await MusicPluginNativeAsync.vault(
      rootDir.path,
      <String, Object?>{'op': 'clear', 'plugin': id},
    );
    if (r['error'] case final String e) {
      throw MusicPluginException('清除插件凭据失败：$e', pluginId: id);
    }
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final Map<String, bool> state = await _enabledState();
    state[id] = enabled;
    await _writeEnabled(state);
    if (!enabled) await _dropInstance(id);
    _changes.add(null);
  }

  /// 卸载：删包、插件存储与加密凭据。
  Future<void> uninstall(String id) async {
    if (!_idPattern.hasMatch(id)) return;
    _uninstalling.add(id);
    try {
      await _dropInstance(id);
      final Directory dir = Directory('${rootDir.path}/$id');
      if (dir.existsSync()) await dir.delete(recursive: true);
      await _clearData(id);
      final Map<String, bool> state = await _enabledState()
        ..remove(id);
      await _writeEnabled(state);
    } finally {
      _uninstalling.remove(id);
    }
    _changes.add(null);
  }

  /// 取（必要时打开）某插件的实例。已作废的实例自动重建。没装 / 已停用 / 正在卸载抛
  /// [MusicPluginUnavailableException]（不碰插件代码）。
  Future<MusicPluginInstance> instance(String id) async {
    if (!_idPattern.hasMatch(id)) {
      throw MusicPluginException('插件 id 不合法', pluginId: id);
    }
    final Map<String, bool> enabled = await _enabledState();
    while (true) {
      _requireUsable(id, enabled);
      final Future<MusicPluginInstance>? existing = _instances[id];
      if (existing == null) break;
      try {
        final MusicPluginInstance inst = await existing;
        // 等待期间可能被停用 / 卸载（那时实例已被 _dropInstance 关掉，这里不会是活的）。
        if (inst.isAlive) {
          _requireUsable(id, enabled);
          return inst;
        }
      } on MusicPluginException {
        // 上次打开失败：重开（用户可能刚重装）。
      }
      // 只移除自己看到的那一个：别的调用方可能已经换上了新开的实例，不能把它摘掉
      // （摘掉 = 下一个调用方再开一份，前一份永远没人关）。
      if (identical(_instances[id], existing)) {
        _instances.remove(id);
        break;
      }
    }
    // 从这里到登记新实例之间没有 await：判定与登记对其它调用方是原子的。
    _requireUsable(id, enabled);
    final Future<MusicPluginInstance> opening = MusicPluginInstance.open(
      dir: '${rootDir.path}/$id',
      storageFile: storageFileFor(id),
      httpClientFactory: _httpClientFactory,
      log: _log,
      vaultRoot: rootDir.path,
      vaultKey: _vaultKey,
      budgetMs: budgetMs,
      httpPerformer: _httpPerformer,
      resolver: _resolver,
      addressBlocker: _addressBlocker,
      mediaProbe: _mediaProbe,
    );
    _instances[id] = opening;
    return opening;
  }

  void _requireUsable(String id, Map<String, bool> enabled) {
    if (_uninstalling.contains(id) ||
        !Directory('${rootDir.path}/$id').existsSync()) {
      throw MusicPluginUnavailableException(
        '插件未安装',
        pluginId: id,
        reason: MusicPluginUnavailableReason.notInstalled,
      );
    }
    if (enabled[id] == false) {
      throw MusicPluginUnavailableException(
        '插件已停用',
        pluginId: id,
        reason: MusicPluginUnavailableReason.disabled,
      );
    }
  }

  /// 某插件的类型化能力入口。
  MusicPluginSource source(String id) => MusicPluginSource(this, id);

  Future<void> _dropInstance(String id) async {
    final Future<MusicPluginInstance>? f = _instances.remove(id);
    if (f == null) return;
    try {
      await (await f).close();
    } on MusicPluginException {
      // 打开就失败的实例没有东西要关。
    }
  }

  Future<void> dispose() async {
    for (final String id in _instances.keys.toList()) {
      await _dropInstance(id);
    }
    await _changes.close();
  }
}
