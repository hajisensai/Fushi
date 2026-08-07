import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder, Uint8List;

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/services.dart' show AssetManifest, ByteData, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// TODO-1000：浏览器扩展「安装助手」。自建 MV3 扩展没有真·一键（浏览器封了商店外侧载），
/// 助手把随 app 打包的扩展解压到磁盘 + 给出「开发者模式 → 加载已解压 → 粘贴路径」引导。
///
/// TODO-1087：解压时把当前 yomitan-api server 的 host/port/token 写进扩展的
/// `fushi-defaults.js`，于是「加载已解压扩展」后无需用户手填连接信息（自动配置）。

/// 目标浏览器（决定扩展管理页 URL）。
enum BrowserKind { chrome, edge }

/// 纯函数：浏览器扩展管理页 URL。用于引导用户打开对应页面（外部窗无法直接导航，
/// 复制给用户粘贴到地址栏）。
String browserExtensionsPageUrl(BrowserKind kind) {
  switch (kind) {
    case BrowserKind.chrome:
      return 'chrome://extensions';
    case BrowserKind.edge:
      return 'edge://extensions';
  }
}

const String _kBundlePrefix = 'assets/browser_extension/';

/// TODO-1087：扩展要连的 Hibiki yomitan-api server 连接信息（自动配置真值）。
/// 由安装助手写进扩展的 `fushi-defaults.js`，扩展默认即用、无需用户手填。
class BrowserExtensionServerConfig {
  const BrowserExtensionServerConfig({
    required this.host,
    required this.port,
    required this.token,
  });

  /// server 监听主机。本机扩展连本机 app，固定环回地址。
  final String host;

  /// server 端口（默认 kYomitanApiDefaultPort=19633，用户可在 app 内改）。
  final int port;

  /// 配对 token（yomitan-api key）。空串表示 app 侧未设 token。
  final String token;
}

const String _kDefaultsFileName = 'fushi-defaults.js';

/// 生成扩展 `fushi-defaults.js` 的内容：注入当前 server 真值作为默认。
/// 纯函数，便于测试；host/token 走 JSON 编码避免注入/转义问题。
///
/// BUG-726：[build] 是本次解压的扩展内容指纹（[computeBrowserExtensionFingerprint]）。
/// server 随查词响应下发同一指纹（`extensionBuild`），扩展 background 对比自身
/// `FUSHI_DEFAULTS.build`，不一致即 `chrome.runtime.reload()` 从磁盘拉新——app 升级
/// 后弹窗自动跟上，无需用户重装/手动 reload。null（占位/旧调用）时不写该键。
String buildBrowserExtensionDefaultsJs(
  BrowserExtensionServerConfig config, {
  String? build,
}) {
  final String host = jsonEncode(config.host);
  final String token = jsonEncode(config.token);
  final StringBuffer b = StringBuffer();
  b.writeln('// TODO-1087: written by Fushi install helper on extract.');
  b.writeln('// Priority: chrome.storage.local (manual override) > this file.');
  b.writeln('self.FUSHI_DEFAULTS = {');
  b.writeln('  host: $host,');
  b.writeln('  port: ${config.port},');
  b.writeln('  token: $token,');
  if (build != null) {
    b.writeln('  build: ${jsonEncode(build)},');
  }
  b.writeln('};');
  return b.toString();
}

/// BUG-726：扩展内容指纹。对「相对路径 → 字节」的全量 map（排除安装时会被重写的
/// `fushi-defaults.js`）按路径排序后做 sha256，取前 16 hex。纯函数，便于测试；
/// 同一份内置扩展在任何机器上指纹恒等，内容变（app 升级带来新扩展）指纹必变。
String computeBrowserExtensionFingerprint(Map<String, List<int>> assets) {
  final List<String> keys =
      assets.keys.where((String k) => k != _kDefaultsFileName).toList()..sort();
  final BytesBuilder input = BytesBuilder(copy: false);
  for (final String key in keys) {
    input.add(utf8.encode(key));
    input.addByte(0);
    input.add(assets[key]!);
    input.addByte(0);
  }
  return sha256.convert(input.takeBytes()).toString().substring(0, 16);
}

/// BUG-726：从已解压副本的 `fushi-defaults.js` 源码里解析 `build` 指纹。
/// 旧版副本（无 build 键）返回 null —— 与当前指纹必然不等，触发刷新，正是所求。
String? parseBrowserExtensionBuild(String defaultsJs) {
  final RegExpMatch? m =
      RegExp('build:\\s*"([0-9a-f]+)"').firstMatch(defaultsJs);
  return m?.group(1);
}

/// 把随 app 打包的扩展文件解压到 `<appSupport>/hibiki-browser-extension/`，返回该目录
/// 绝对路径（供用户在浏览器「加载已解压的扩展程序」时粘贴）。每次调用覆盖写入，保证与
/// app 内置版本一致（升级即刷新）。仅桌面有意义。
///
/// TODO-1087：传入 [serverConfig] 时，用其真值重写解压出的 `fushi-defaults.js`，
/// 于是扩展默认即连本机 app、无需用户手填 host/port/token。不传则保留打包内的占位默认。
Future<String> prepareBundledBrowserExtension({
  BrowserExtensionServerConfig? serverConfig,
}) async {
  final Directory dest = await _extensionDestDir();
  if (dest.existsSync()) {
    await dest.delete(recursive: true);
  }
  await dest.create(recursive: true);

  final Map<String, Uint8List> assets = await _loadBundledExtensionAssets();
  for (final MapEntry<String, Uint8List> entry in assets.entries) {
    final File out =
        File(p.join(dest.path, p.joinAll(p.posix.split(entry.key))));
    await out.parent.create(recursive: true);
    await out.writeAsBytes(entry.value);
  }

  // TODO-1087：用当前 server 真值覆盖占位默认，实现自动配置。
  // BUG-726：同时写入内容指纹 build，供「app 升级 → 磁盘副本刷新 → 扩展自 reload」链路。
  if (serverConfig != null) {
    final File defaults = File(p.join(dest.path, _kDefaultsFileName));
    await defaults.writeAsString(buildBrowserExtensionDefaultsJs(
      serverConfig,
      build: computeBrowserExtensionFingerprint(assets),
    ));
  }
  return dest.path;
}

Future<Directory> _extensionDestDir() async {
  final Directory support = await getApplicationSupportDirectory();
  return Directory(p.join(support.path, 'hibiki-browser-extension'));
}

/// 读出随 app 打包的全部扩展资产（相对路径 → 字节）。
Future<Map<String, Uint8List>> _loadBundledExtensionAssets() async {
  final AssetManifest manifest =
      await AssetManifest.loadFromAssetBundle(rootBundle);
  final Iterable<String> keys =
      manifest.listAssets().where((String k) => k.startsWith(_kBundlePrefix));
  final Map<String, Uint8List> assets = <String, Uint8List>{};
  for (final String key in keys) {
    final String rel = key.substring(_kBundlePrefix.length);
    if (rel.isEmpty) continue;
    final ByteData data = await rootBundle.load(key);
    assets[rel] = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
  }
  return assets;
}

/// BUG-726：当前 app 内置扩展的内容指纹（进程内缓存；内置资产运行期不变）。
Future<String> bundledBrowserExtensionFingerprint() async {
  return _bundledFingerprintCache ??=
      computeBrowserExtensionFingerprint(await _loadBundledExtensionAssets());
}

String? _bundledFingerprintCache;

/// BUG-726：app 启动时把 `<appSupport>/hibiki-browser-extension/` 的已解压副本刷新到
/// 当前内置版本。此前该副本只在用户手动跑「安装扩展」助手时写入，app 升级从不刷新——
/// 用户浏览器里的扩展弹窗永远停在安装当天的旧版（BUG-621/688 修了也到不了浏览器）。
///
/// - 副本目录不存在（用户从没装过扩展）→ 不落盘、返回 false；
/// - 副本 `fushi-defaults.js` 里的 build 指纹与内置一致 → 已最新、返回 false；
/// - 否则整目录重解压（注入 [serverConfig] 真值 + 新指纹）→ 返回 true。
Future<bool> refreshBundledBrowserExtensionIfStale({
  required BrowserExtensionServerConfig serverConfig,
}) async {
  final Directory dest = await _extensionDestDir();
  if (!dest.existsSync()) return false;
  final File defaults = File(p.join(dest.path, _kDefaultsFileName));
  final String? installed = defaults.existsSync()
      ? parseBrowserExtensionBuild(await defaults.readAsString())
      : null;
  if (installed != null &&
      installed == await bundledBrowserExtensionFingerprint()) {
    return false;
  }
  await prepareBundledBrowserExtension(serverConfig: serverConfig);
  return true;
}
