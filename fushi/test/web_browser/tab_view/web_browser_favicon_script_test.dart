import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_page_scripts.dart';

/// 标签页图标脚本：标签栏用 Flutter `Image` 解码，不认 SVG。jiten.moe 同时声明
/// `favicon.svg`（`sizes="any"`）与 48px ico，旧打分让 SVG 先胜出，标签只剩首字母
/// 色块。node 真执行脚本，喂假的 `document` / `location`。
void main() {
  final String? nodeExe = _resolveNode();

  Future<String?> pick(List<Map<String, String>> links) async {
    final String harness =
        '''
const links = ${jsonEncode(links)}.map(a => ({ getAttribute: k => (k in a ? a[k] : null) }));
globalThis.document = { querySelectorAll: () => links };
globalThis.location = { href: 'https://jiten.moe/decks/1', origin: 'https://jiten.moe', protocol: 'https:' };
const r = eval(${jsonEncode(kWebBrowserFaviconScript)});
process.stdout.write(JSON.stringify(r));
''';
    final ProcessResult result = await Process.run(nodeExe!, <String>[
      '-e',
      harness,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return jsonDecode(result.stdout as String) as String?;
  }

  test('jiten.moe 的图标组合跳过 SVG、选位图', () async {
    final String? icon = await pick(<Map<String, String>>[
      <String, String>{
        'rel': 'icon',
        'type': 'image/svg+xml',
        'href': '/favicon.svg',
        'sizes': 'any',
      },
      <String, String>{
        'rel': 'icon',
        'type': 'image/png',
        'sizes': '96x96',
        'href': '/favicon-96x96.png',
      },
      <String, String>{
        'rel': 'icon',
        'type': 'image/x-icon',
        'sizes': '48x48',
        'href': '/favicon.ico',
      },
      <String, String>{
        'rel': 'apple-touch-icon',
        'sizes': '180x180',
        'href': '/apple-touch-icon.png',
      },
    ]);
    expect(icon, 'https://jiten.moe/favicon.ico');
  }, skip: nodeExe == null ? 'node not found on PATH' : false);

  test('没写 type 的 .svg 与 data:image/svg 也跳过，只剩 SVG 时退到 /favicon.ico', () async {
    final String? icon = await pick(<Map<String, String>>[
      <String, String>{'rel': 'icon', 'href': '/logo.svg?v=3'},
      <String, String>{
        'rel': 'shortcut icon',
        'href': 'data:image/svg+xml;base64,AAAA',
      },
    ]);
    expect(icon, 'https://jiten.moe/favicon.ico');
  }, skip: nodeExe == null ? 'node not found on PATH' : false);
}

String? _resolveNode() {
  final String exe = Platform.isWindows ? 'node.exe' : 'node';
  final String pathEnv = Platform.environment['PATH'] ?? '';
  final String separator = Platform.isWindows ? ';' : ':';
  for (final String dir in pathEnv.split(separator)) {
    if (dir.isEmpty) continue;
    final File candidate = File('$dir${Platform.pathSeparator}$exe');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}
