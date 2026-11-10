// BUG-4283：扩展端 `dict-media-key.js` 派生的词典媒体作用域 key 必须与 host 端
// [dictionaryMediaKeyFor] 逐字节一致，否则扩展换用派生 key 后图片一律 401。
//
// 在 node 里真加载生产文件（随包镜像 assets/browser_extension/），对几组固定 token
// 求 key，与 Dart 实现比对。node：本地缺时 skip 并写明原因，CI 上缺一律失败
// （见 test/helpers/node_runtime.dart）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';

import '../helpers/node_runtime.dart';

void main() {
  final NodeTestRuntime runtime = NodeTestRuntime.probe();

  test(
    'dict-media-key.js derives the same fmk1 key as dictionaryMediaKeyFor',
    skip: runtime.skipReason,
    () async {
      final String node = runtime.requireNode();
      const List<String> tokens = <String>[
        'test-token-media',
        'a"b\\cé鍵 x',
        '',
        'legacy-0123456789abcdef',
      ];
      final File script = File('assets/browser_extension/dict-media-key.js');
      expect(script.existsSync(), isTrue, reason: '${script.path} 缺失');
      const String driver = r'''
const api = require(process.argv[1]);
const tokens = JSON.parse(process.argv[2]);
Promise.all(tokens.map((t) => api.derive(t))).then((keys) => {
  process.stdout.write(JSON.stringify(keys));
}, (e) => { console.error(e); process.exit(1); });
''';
      final ProcessResult result = await Process.run(node, <String>[
        '-e',
        driver,
        script.absolute.path,
        jsonEncode(tokens),
      ], stdoutEncoding: utf8);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final List<dynamic> keys = jsonDecode(result.stdout as String) as List;
      expect(keys, <String>[
        for (final String t in tokens) dictionaryMediaKeyFor(t),
      ]);
    },
  );
}
