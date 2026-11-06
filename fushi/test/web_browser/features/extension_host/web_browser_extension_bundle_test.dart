import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/web_adblock/web_adblock_wiring.dart'
    show kWebAdblockCosmeticScript;
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_bundle.dart';

/// flutter test 的 cwd 是 fushi 包根：直接读磁盘上的资产（与 rootBundle 同一份文件）。
Future<String> _readString(String asset) => File(asset).readAsString();
Future<ByteData> _readBytes(String asset) async =>
    ByteData.sublistView(await File(asset).readAsBytes());

Map<String, dynamic> _manifest() =>
    jsonDecode(
          File('assets/browser_extension/manifest.json').readAsStringSync(),
        )
        as Map<String, dynamic>;

String? _resolveNode() {
  final String exe = Platform.isWindows ? 'node.exe' : 'node';
  final String separator = Platform.isWindows ? ';' : ':';
  for (final String dir in (Platform.environment['PATH'] ?? '').split(
    separator,
  )) {
    if (dir.isEmpty) continue;
    final File candidate = File('$dir${Platform.pathSeparator}$exe');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}

void main() {
  group('装哪些脚本：manifest 主栈 − 显式排除表', () {
    test('主栈 = manifest 第一组 content_scripts 去掉排除项，顺序不变', () {
      final Map<String, dynamic> manifest = _manifest();
      final List<String> all = <String>[
        for (final Object? s
            in ((manifest['content_scripts'] as List<dynamic>).first
                    as Map<String, dynamic>)['js']
                as List<dynamic>)
          s! as String,
      ];
      expect(webBrowserExtensionHostScripts(manifest), <String>[
        for (final String s in all)
          if (!kWebBrowserExtensionHostExcludedScripts.contains(s)) s,
      ]);
      // 排除表里的每一项都真在 manifest 里：扩展改名 / 删脚本时排除表跟着改，不留死条目。
      for (final String excluded in kWebBrowserExtensionHostExcludedScripts) {
        expect(all, contains(excluded), reason: '$excluded 不在 manifest 主栈里');
      }
      // 宿主运行时依赖的脚本必须在：content.js（适配口）、subtitle-panel.js（侧栏契约）、
      // player-controls.js（播放器菜单）、study-tracker.js（沉浸计时）、bridge-shim.js。
      expect(
        webBrowserExtensionHostScripts(manifest),
        containsAll(<String>[
          'bridge-shim.js',
          'content.js',
          'subtitle-panel.js',
          'subtitle-style.js',
          'player-controls.js',
          'study-tracker.js',
        ]),
      );
    });

    test('主世界桥：YouTube / 流媒体桥装，Netflix 桥留后续', () {
      final List<WebBrowserExtensionBridge> bridges =
          webBrowserExtensionHostBridges(_manifest());
      final List<String> scripts = <String>[
        for (final WebBrowserExtensionBridge b in bridges) b.script,
      ];
      expect(
        scripts,
        containsAll(<String>['youtube-bridge.js', 'stream-bridge.js']),
      );
      expect(scripts, isNot(contains('netflix-bridge.js')));
      final WebBrowserExtensionBridge yt = bridges.firstWhere(
        (WebBrowserExtensionBridge b) => b.script == 'youtube-bridge.js',
      );
      expect(<String?>[
        for (final String p in yt.matches) webBrowserExtensionMatchHost(p),
      ], contains('*.youtube.com'));
    });
  });

  group('全局改写', () {
    test('只改 window.<名> 属性访问，前缀相同的别的名字不动', () {
      expect(
        rewriteWebBrowserExtensionGlobals(
          'window.fushiSelection.x; window.fushiSelectionInEditable(); '
          'window.flutter_inappwebview.callHandler(); '
          'window.__fushiCssHighlightsSupported = false; window.fushiT();',
        ),
        '__fushiExtNs.fushiSelection.x; window.fushiSelectionInEditable(); '
        '__fushiExtNs.flutter_inappwebview.callHandler(); '
        '__fushiExtNs.__fushiCssHighlightsSupported = false; window.fushiT();',
      );
    });

    test('扩展主栈源码不用方括号访问这几个全局（改写才完整）', () {
      for (final String script in webBrowserExtensionHostScripts(_manifest())) {
        final String src = File(
          'assets/browser_extension/$script',
        ).readAsStringSync();
        for (final String name in kWebBrowserExtensionRewrittenGlobals) {
          expect(
            src.contains("['$name']") || src.contains('["$name"]'),
            isFalse,
            reason: '$script 用方括号访问 $name，打包改写覆盖不到',
          );
        }
      }
    });
  });

  test('拼出的整栈：主栈里不再出现被改写的全局，密钥写进源码', () async {
    final WebBrowserExtensionBundleParts parts =
        await loadWebBrowserExtensionBundleParts(
          loadString: _readString,
          loadBytes: _readBytes,
        );
    final String bundle = buildWebBrowserExtensionBundle(
      parts,
      secret: 'S3CRET',
    );
    final int stackStart = bundle.indexOf('__fushiExtWhenReady(function(){');
    expect(stackStart, greaterThan(0));
    final String stack = bundle.substring(stackStart);
    for (final String name in kWebBrowserExtensionRewrittenGlobals) {
      expect(stack.contains('window.$name'), isFalse, reason: name);
    }
    expect(bundle, contains('var __fushiExtSecret = "S3CRET";'));
    expect(parts.iconDataUrl, startsWith('data:image/png;base64,'));
    for (final String excluded in kWebBrowserExtensionHostExcludedScripts) {
      expect(bundle.contains('// ---- $excluded\n'), isFalse, reason: excluded);
    }
  });

  test('在 node vm 里真跑整栈：拼装、宿主边界、密钥、存储与消息往返', () async {
    final String? node = _resolveNode();
    if (node == null) {
      markTestSkipped('node not found on PATH');
      return;
    }
    final WebBrowserExtensionBundleParts parts =
        await loadWebBrowserExtensionBundleParts(
          loadString: _readString,
          loadBytes: _readBytes,
        );
    const String secret = 'test-secret-123';
    final Directory tmp = await Directory.systemTemp.createTemp('fushi-ext');
    try {
      final File file = File('${tmp.path}/bundle.js');
      await file.writeAsString(
        buildWebBrowserExtensionBundle(parts, secret: secret),
      );
      final File adblock = File('${tmp.path}/adblock.js');
      await adblock.writeAsString(kWebAdblockCosmeticScript);
      final ProcessResult result = await Process.run(node, <String>[
        'test/web_browser/features/extension_host/extension_host_bundle_test.js',
        file.path,
        secret,
        adblock.path,
      ]);
      expect(
        result.exitCode,
        0,
        reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(result.stdout.toString(), contains('all assertions passed'));
    } finally {
      await tmp.delete(recursive: true);
    }
  });
}
