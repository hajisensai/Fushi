@Tags(<String>['chrome'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/node_runtime.dart';

/// BUG-3705 / BUG-3706：恶意词典不能在查词弹窗主文档里执行脚本、调原生桥或外联。
///
/// ① 行为级 —— 真 Chrome 里跑生产 `dict-media.js` + `selection.js` + `popup.js`
///    （`popup_dict_sandbox_harness.mjs`）：结构化内容标签白名单、HTML 释义净化、带脚本的
///    释义只进 `sandbox="allow-scripts"` iframe 且只在宿主回专用锁定值后挂载、沙箱发来的
///    无用户激活动作被丢、沙箱伪造的外链即便父页面有激活也不放行、词典 CSS 外部引用被剥。
/// ② 源码级 —— 三份 dict-media.js 镜像都不再有主文档执行词典脚本的通路。
void main() {
  final NodeTestRuntime runtime = NodeTestRuntime.probe(needsChrome: true);

  test(
    'dictionary content cannot run script in the popup document',
    () async {
      final String node = runtime.requireNode();
      final Directory temp = Directory.systemTemp.createTempSync(
        'popup-dict-sandbox-',
      );
      try {
        final File payload = File('${temp.path}/scripts.json')
          ..writeAsStringSync(
            jsonEncode(<String, String>{
              'dictMedia': File(
                'assets/popup/dict-media.js',
              ).readAsStringSync(),
              'selection': File('assets/popup/selection.js').readAsStringSync(),
              'popup': File('assets/popup/popup.js').readAsStringSync(),
            }),
          );
        final ProcessResult run = await Process.run(node, <String>[
          'test/pages/popup_dict_sandbox_harness.mjs',
          payload.path,
        ]).timeout(const Duration(seconds: 80));
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
        expect(run.stdout, contains('PASS 10 dictionary sandbox scenarios'));
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: runtime.skipReason,
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'no dict-media.js mirror executes dictionary scripts in the document',
    () {
      const List<String> mirrors = <String>[
        'assets/popup/dict-media.js',
        'assets/browser_extension/vendor/dict-media.js',
        '../tools/browser-extension/vendor/dict-media.js',
      ];
      for (final String path in mirrors) {
        final String source = File(path).readAsStringSync();
        for (final String forbidden in <String>[
          'new Function',
          'function runDictScripts',
          'function createScopedWindow',
        ]) {
          expect(
            source.contains(forbidden),
            isFalse,
            reason:
                '$path must not run dictionary scripts in the popup '
                'document ($forbidden); they belong in the sandbox iframe',
          );
        }
      }
      final String popup = File('assets/popup/popup.js').readAsStringSync();
      expect(popup.contains('runDictScripts('), isFalse);
      expect(
        popup.contains("frame.setAttribute('sandbox', 'allow-scripts');"),
        isTrue,
      );
      expect(
        RegExp(
          r"setAttribute\('sandbox',[^)]*allow-same-origin",
        ).hasMatch(popup),
        isFalse,
        reason:
            'allow-same-origin + allow-scripts lets the frame un-sandbox '
            'itself',
      );
    },
  );
}
