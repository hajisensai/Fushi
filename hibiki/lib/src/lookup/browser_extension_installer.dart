import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show AssetManifest, ByteData, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// TODO-1000：浏览器扩展「安装助手」。自建 MV3 扩展没有真·一键（浏览器封了商店外侧载），
/// 助手把随 app 打包的扩展解压到磁盘 + 给出「开发者模式 → 加载已解压 → 粘贴路径」引导。
///
/// TODO-1087：解压时把当前 yomitan-api server 的 host/port/token 写进扩展的
/// `hibiki-defaults.js`，于是「加载已解压扩展」后无需用户手填连接信息（自动配置）。

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
/// 由安装助手写进扩展的 `hibiki-defaults.js`，扩展默认即用、无需用户手填。
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

const String _kDefaultsFileName = 'hibiki-defaults.js';

/// 生成扩展 `hibiki-defaults.js` 的内容：注入当前 server 真值作为默认。
/// 纯函数，便于测试；host/token 走 JSON 编码避免注入/转义问题。
String buildBrowserExtensionDefaultsJs(BrowserExtensionServerConfig config) {
  final String host = jsonEncode(config.host);
  final String token = jsonEncode(config.token);
  final StringBuffer b = StringBuffer();
  b.writeln('// TODO-1087: written by Hibiki install helper on extract.');
  b.writeln('// Priority: chrome.storage.local (manual override) > this file.');
  b.writeln('self.HIBIKI_DEFAULTS = {');
  b.writeln('  host: $host,');
  b.writeln('  port: ${config.port},');
  b.writeln('  token: $token,');
  b.writeln('};');
  return b.toString();
}

/// 把随 app 打包的扩展文件解压到 `<appSupport>/hibiki-browser-extension/`，返回该目录
/// 绝对路径（供用户在浏览器「加载已解压的扩展程序」时粘贴）。每次调用覆盖写入，保证与
/// app 内置版本一致（升级即刷新）。仅桌面有意义。
///
/// TODO-1087：传入 [serverConfig] 时，用其真值重写解压出的 `hibiki-defaults.js`，
/// 于是扩展默认即连本机 app、无需用户手填 host/port/token。不传则保留打包内的占位默认。
Future<String> prepareBundledBrowserExtension({
  BrowserExtensionServerConfig? serverConfig,
}) async {
  final Directory support = await getApplicationSupportDirectory();
  final Directory dest =
      Directory(p.join(support.path, 'hibiki-browser-extension'));
  if (dest.existsSync()) {
    await dest.delete(recursive: true);
  }
  await dest.create(recursive: true);

  final AssetManifest manifest =
      await AssetManifest.loadFromAssetBundle(rootBundle);
  final Iterable<String> keys =
      manifest.listAssets().where((String k) => k.startsWith(_kBundlePrefix));
  for (final String key in keys) {
    final String rel = key.substring(_kBundlePrefix.length);
    if (rel.isEmpty) continue;
    final ByteData data = await rootBundle.load(key);
    final File out = File(p.join(dest.path, p.joinAll(p.posix.split(rel))));
    await out.parent.create(recursive: true);
    await out.writeAsBytes(data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    ));
  }

  // TODO-1087：用当前 server 真值覆盖占位默认，实现自动配置。
  if (serverConfig != null) {
    final File defaults = File(p.join(dest.path, _kDefaultsFileName));
    await defaults.writeAsString(buildBrowserExtensionDefaultsJs(serverConfig));
  }
  return dest.path;
}
