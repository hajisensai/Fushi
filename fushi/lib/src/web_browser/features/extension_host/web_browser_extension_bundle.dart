import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// 浏览器扩展镜像根（与扩展源 `tools/browser-extension/` 逐字节一致，镜像守卫
/// `browser_extension_mirror_full_guard_test.dart`）。
const String kWebBrowserExtensionRoot = 'assets/browser_extension/';

/// app 宿主运行时（chrome 垫片、宿主适配口、Dart 反调入口），整栈闭包的第一段。
const String kWebBrowserExtensionRuntimeAsset =
    'assets/web_browser/extension_host_runtime.js';

/// 扩展 manifest 第一组 content_scripts 里，app 宿主**不装**的脚本——清单其余部分原样照装
/// （守卫 `web_browser_extension_bundle_test.dart` 钉死「装的 = manifest − 这张表」）：
/// - `vendor/popup.js`：页内查词弹窗的渲染器。宿主模式查词交给 app 自己的查词弹窗，
///   页内弹窗永远不画；它还会在页面主世界挂全局报错钩子。
/// - `nested-popup-host.js`：页内弹窗的嵌套查词层，随页内弹窗一起不要。
/// - `touch-lookup.js`：触屏正文查词。网页正文取词由宿主自己的取词脚本负责，两边都装会弹两次。
/// - `mobile-drawer.js`：触屏字幕抽屉（iframe 里开扩展页 side-panel.html）。宿主的字幕列表是
///   app 原生侧栏 / 底部抽屉。
const Set<String> kWebBrowserExtensionHostExcludedScripts = <String>{
  'vendor/popup.js',
  'nested-popup-host.js',
  'touch-lookup.js',
  'mobile-drawer.js',
};

/// 主世界桥（manifest 里 `world: MAIN` 的条目）中宿主不装的：Netflix 录制链路留后续阶段。
const Set<String> kWebBrowserExtensionHostExcludedBridges = <String>{
  'netflix-bridge.js',
};

/// 扩展源码里会和 app 自己注入的脚本撞名的全局，打包时改写到闭包局部的
/// `__fushiExtNs` 上：
/// - `fushiSelection`：app 的取词脚本（`ReaderSelectionScripts`）用同名全局；
/// - `flutter_inappwebview`：app 的 JS 桥。bridge-shim.js 会整个覆盖它（扩展在隔离世界无碍，
///   主世界里会废掉 app 的桥），改写后覆盖只落在闭包里；
/// - `__fushiCssHighlightsSupported`：content.js 为扩展的取词强制 DOM 包裹高亮，不能波及 app 的取词。
const List<String> kWebBrowserExtensionRewrittenGlobals = <String>[
  'fushiSelection',
  'flutter_inappwebview',
  '__fushiCssHighlightsSupported',
];

/// 宿主运行时与扩展源码共用的扩展 id（content.js 的存活检查只看它非空）。
const String kWebBrowserExtensionHostId = 'fushi-app-web-browser';

/// manifest 里的一组主世界桥。
typedef WebBrowserExtensionBridge = ({String script, List<String> matches});

/// 读 manifest：第一组 content_scripts（扩展的主栈）减去 [kWebBrowserExtensionHostExcludedScripts]。
List<String> webBrowserExtensionHostScripts(Map<String, dynamic> manifest) {
  final Object? groups = manifest['content_scripts'];
  if (groups is! List<dynamic> || groups.isEmpty) return const <String>[];
  final Object? first = groups.first;
  if (first is! Map<String, dynamic>) return const <String>[];
  final Object? js = first['js'];
  if (js is! List<dynamic>) return const <String>[];
  return <String>[
    for (final Object? s in js)
      if (s is String && !kWebBrowserExtensionHostExcludedScripts.contains(s))
        s,
  ];
}

/// 读 manifest：`world: MAIN` 的桥（含匹配规则），减去 [kWebBrowserExtensionHostExcludedBridges]。
List<WebBrowserExtensionBridge> webBrowserExtensionHostBridges(
  Map<String, dynamic> manifest,
) {
  final Object? groups = manifest['content_scripts'];
  if (groups is! List<dynamic>) return const <WebBrowserExtensionBridge>[];
  final List<WebBrowserExtensionBridge> out = <WebBrowserExtensionBridge>[];
  for (final Object? g in groups) {
    if (g is! Map<String, dynamic> || g['world'] != 'MAIN') continue;
    final Object? js = g['js'];
    final Object? matches = g['matches'];
    if (js is! List<dynamic> || matches is! List<dynamic>) continue;
    final List<String> m = <String>[
      for (final Object? p in matches)
        if (p is String) p,
    ];
    for (final Object? s in js) {
      if (s is String && !kWebBrowserExtensionHostExcludedBridges.contains(s)) {
        out.add((script: s, matches: m));
      }
    }
  }
  return out;
}

/// manifest 匹配规则 `*://*.youtube.com/*` → 主机规则（`*.youtube.com` = 本域及子域）。
/// 只认扩展实际用到的形态；认不出的返回 null（该条不参与匹配）。
String? webBrowserExtensionMatchHost(String pattern) {
  final RegExpMatch? m = RegExp(r'^(\*|https?)://([^/]+)/').firstMatch(pattern);
  return m?.group(2)?.toLowerCase();
}

/// 把扩展源码里 [kWebBrowserExtensionRewrittenGlobals] 的 `window.<名>` 改写到闭包局部的
/// `__fushiExtNs.<名>`。只改属性访问形态（扩展源码只用这一种，守卫测试钉死）。
String rewriteWebBrowserExtensionGlobals(String source) {
  final String names = kWebBrowserExtensionRewrittenGlobals.join('|');
  return source.replaceAllMapped(
    RegExp('\\bwindow\\.($names)(?![A-Za-z0-9_\$])'),
    (Match m) => '__fushiExtNs.${m.group(1)}',
  );
}

/// 打包所需的原料（全部来自资产；测试可直接构造）。
class WebBrowserExtensionBundleParts {
  const WebBrowserExtensionBundleParts({
    required this.runtime,
    required this.scripts,
    required this.bridges,
    required this.contentCss,
    required this.iconDataUrl,
  });

  /// [kWebBrowserExtensionRuntimeAsset] 的文本。
  final String runtime;

  /// 主栈脚本：路径 → 源码，按 manifest 顺序。
  final List<({String path, String source})> scripts;

  /// 主世界桥：匹配规则 + 源码。
  final List<({List<String> matches, String source})> bridges;
  final String contentCss;
  final String iconDataUrl;
}

/// 从资产读出打包原料。[loadString] / [loadBytes] 测试注入。
Future<WebBrowserExtensionBundleParts> loadWebBrowserExtensionBundleParts({
  Future<String> Function(String asset)? loadString,
  Future<ByteData> Function(String asset)? loadBytes,
}) async {
  final Future<String> Function(String) str =
      loadString ?? rootBundle.loadString;
  final Future<ByteData> Function(String) bytes = loadBytes ?? rootBundle.load;
  final Map<String, dynamic> manifest =
      jsonDecode(await str('${kWebBrowserExtensionRoot}manifest.json'))
          as Map<String, dynamic>;
  final List<String> scriptPaths = webBrowserExtensionHostScripts(manifest);
  final List<WebBrowserExtensionBridge> bridges =
      webBrowserExtensionHostBridges(manifest);
  final List<String> sources = await Future.wait(<Future<String>>[
    for (final String p in scriptPaths) str('$kWebBrowserExtensionRoot$p'),
  ]);
  final List<String> bridgeSources = await Future.wait(<Future<String>>[
    for (final WebBrowserExtensionBridge b in bridges)
      str('$kWebBrowserExtensionRoot${b.script}'),
  ]);
  final ByteData icon = await bytes('${kWebBrowserExtensionRoot}icon-32.png');
  return WebBrowserExtensionBundleParts(
    runtime: await str(kWebBrowserExtensionRuntimeAsset),
    scripts: <({String path, String source})>[
      for (int i = 0; i < scriptPaths.length; i++)
        (path: scriptPaths[i], source: sources[i]),
    ],
    bridges: <({List<String> matches, String source})>[
      for (int i = 0; i < bridges.length; i++)
        (matches: bridges[i].matches, source: bridgeSources[i]),
    ],
    contentCss: await str('${kWebBrowserExtensionRoot}vendor/content.css'),
    iconDataUrl:
        'data:image/png;base64,${base64Encode(icon.buffer.asUint8List(icon.offsetInBytes, icon.lengthInBytes))}',
  );
}

/// 文档里装没装过整栈的标记（同一文档只装一次；onLoadStop 补装时据此跳过）。
const String kWebBrowserExtensionInstalledFlag = '__fushiExtHostInstalled';

/// 拼出注入标签页的整段脚本：一个闭包，只在顶层框架、http(s) 文档里执行一次。
///
/// 顺序：宿主运行时 → 主世界桥（document-start 当场跑，按主机匹配）→ 主栈（DOM 就绪且页面
/// 是视频站 / 出现了 `<video>` 才跑，等价扩展的 document_idle）。主栈的脚本直接拼在一个函数体
/// 里——扩展的内容脚本本来就共享一个全局作用域（隔离世界），彼此按名字互调；拼进同一个函数
/// 作用域语义一致，且全部局部、页面拿不到。
String buildWebBrowserExtensionBundle(
  WebBrowserExtensionBundleParts parts, {
  required String secret,
}) {
  final StringBuffer out = StringBuffer()
    ..writeln('(function(){')
    ..writeln('if (window.top !== window.self) return;')
    ..writeln(r'if (!/^https?:$/.test(location.protocol)) return;')
    ..writeln('if (window.$kWebBrowserExtensionInstalledFlag) return;')
    ..writeln(
      'try { Object.defineProperty(window, "$kWebBrowserExtensionInstalledFlag", '
      '{value: true}); } catch (_) { return; }',
    )
    ..writeln('var __fushiExtSecret = ${jsonEncode(secret)};')
    ..writeln(
      'var __fushiExtBoot = ${jsonEncode(<String, Object>{'contentCss': parts.contentCss, 'iconDataUrl': parts.iconDataUrl, 'extensionId': kWebBrowserExtensionHostId, 'forceStart': false})};',
    )
    ..writeln(_kHostMatchJs)
    ..writeln(parts.runtime)
    ..writeln(';');
  for (final ({List<String> matches, String source}) b in parts.bridges) {
    final List<String> hosts = <String>[
      for (final String p in b.matches)
        if (webBrowserExtensionMatchHost(p) case final String h) h,
    ];
    out
      ..writeln('if (__fushiExtHostMatch(${jsonEncode(hosts)})) {')
      ..writeln('__fushiExtBoot.forceStart = true;')
      ..writeln(b.source)
      ..writeln(';}');
  }
  out.writeln('__fushiExtWhenReady(function(){');
  for (final ({String path, String source}) s in parts.scripts) {
    out
      ..writeln('// ---- ${s.path}')
      ..writeln(rewriteWebBrowserExtensionGlobals(s.source))
      ..writeln(';');
  }
  out
    ..writeln('});')
    ..writeln('})();');
  return out.toString();
}

/// 主机匹配：`*.example.com` = 本域及子域；其余精确匹配。
const String _kHostMatchJs = r'''
function __fushiExtHostMatch(hosts) {
  var h = String(location.hostname || '').toLowerCase().replace(/\.$/, '');
  for (var i = 0; i < hosts.length; i++) {
    var p = hosts[i];
    if (p.indexOf('*.') === 0) {
      var base = p.slice(2);
      if (h === base || h.slice(-(base.length + 1)) === '.' + base) return true;
    } else if (p === '*' || h === p) {
      return true;
    }
  }
  return false;
}''';
