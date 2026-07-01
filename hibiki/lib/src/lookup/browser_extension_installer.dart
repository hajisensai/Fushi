import 'dart:io';

import 'package:flutter/services.dart' show AssetManifest, ByteData, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// TODO-1000：浏览器扩展「安装助手」。自建 MV3 扩展没有真·一键（浏览器封了商店外侧载），
/// 助手把随 app 打包的扩展解压到磁盘 + 给出「开发者模式 → 加载已解压 → 粘贴路径」引导。

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

/// 把随 app 打包的扩展文件解压到 `<appSupport>/hibiki-browser-extension/`，返回该目录
/// 绝对路径（供用户在浏览器「加载已解压的扩展程序」时粘贴）。每次调用覆盖写入，保证与
/// app 内置版本一致（升级即刷新）。仅桌面有意义。
Future<String> prepareBundledBrowserExtension() async {
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
  return dest.path;
}
