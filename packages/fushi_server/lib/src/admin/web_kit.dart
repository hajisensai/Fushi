/// WebUI 的设计系统共享库：与浏览器扩展同一套 token / 配色算法 / 主题决议 / 控件形态 /
/// 下拉 / 图标。文件内容在生成的 [kWebKitFiles] 里（真源 `tools/browser-extension/`，
/// `scripts/sync-mirrors.mjs` 重生成），这里只负责以 `/kit/<文件名>?v=<内容哈希>` 提供。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:fushi_server/src/admin/web_kit.g.dart';
import 'package:shelf/shelf.dart' as shelf;

/// 文件名 → (算版本号时的内容, 内容哈希前 12 位)。URL 里的版本号必须跟着内容走：内容变了地址就变，
/// 才能放心给一年的 immutable 缓存。按「内容是否还是同一份」判缓存，而不是只按文件名记一次——
/// 开发时热重载换了 [kWebKitFiles] 的内容，进程里旧的版本号若不失效，浏览器会一直吃旧文件。
final Map<String, (String, String)> _versions = <String, (String, String)>{};

String _versionOf(String name) {
  final String content = kWebKitFiles[name]!;
  final (String, String)? cached = _versions[name];
  if (cached != null && identical(cached.$1, content)) return cached.$2;
  final String version = sha256
      .convert(utf8.encode(content))
      .toString()
      .substring(0, 12);
  _versions[name] = (content, version);
  return version;
}

/// 页面里引用共享库文件的地址（带版本号）。
String webKitUrl(String name) {
  if (!kWebKitFiles.containsKey(name)) {
    throw ArgumentError.value(name, 'name', 'not a web kit file');
  }
  return '/kit/$name?v=${_versionOf(name)}';
}

/// `GET /kit/<name>`：不存在 404；存在则带一年的不可变缓存（地址里已有内容哈希）。
shelf.Response serveWebKitFile(String name) {
  final String? body = kWebKitFiles[name];
  if (body == null) return shelf.Response.notFound('not found');
  final String type = name.endsWith('.css')
      ? 'text/css; charset=utf-8'
      : 'text/javascript; charset=utf-8';
  return shelf.Response.ok(
    body,
    headers: <String, String>{
      'Content-Type': type,
      'Cache-Control': 'public, max-age=31536000, immutable',
    },
  );
}

/// 页面 `<head>` 里加载共享库的标签：样式两份 + 主题脚本（同步，首帧前套上主题）；
/// 图标与下拉放 `<body>` 末尾（见 [webKitBodyScripts]）。
String webKitHeadTags() {
  final StringBuffer b = StringBuffer()
    ..writeln('<link rel="stylesheet" href="${webKitUrl('theme.css')}">')
    ..writeln('<link rel="stylesheet" href="${webKitUrl('material.css')}">')
    ..writeln('<script src="${webKitUrl('material-color.js')}"></script>')
    ..writeln('<script src="${webKitUrl('theme-palette.js')}"></script>')
    ..writeln('<script src="${webKitUrl('theme.js')}"></script>');
  return b.toString();
}

/// `<body>` 末尾的共享库脚本：图标（自动填 `data-fushi-icon`）与统一下拉。
String webKitBodyScripts() {
  final StringBuffer b = StringBuffer()
    ..writeln('<script src="${webKitUrl('icons.js')}"></script>')
    ..writeln('<script src="${webKitUrl('glass-select.js')}"></script>');
  return b.toString();
}
