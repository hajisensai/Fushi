import 'dart:convert';

import 'package:crypto/crypto.dart' show sha1;

import 'package:hibiki/src/reader/reader_engine_config.dart';

/// BUG-1140 第二阶段①：把阅读器引擎 JS 从「每次导航现拼一份内联字符串」改成
/// 「一份零插值的静态资源 + 每次导航只下发一小份 config」。
///
/// 为什么是 `<script src>` 外链而不是 UserScript：
/// - 章节文档本来就走 hoshi.local 资源拦截器（Android/Windows `shouldInterceptRequest`、
///   iOS/macOS 自定义 scheme），引擎脚本挂同一条通道，5 端零平台分支。
/// - 本仓已有实证：图片响应挂 `Cache-Control: max-age=3600` 后 WebView 不再回拦截器
///   重新读盘（TODO-1074 那段注释）。引擎脚本用**内容哈希 URL + `immutable` 强缓存**，
///   于是「跨 platform channel 传 145K 字符 + 从零解析编译」每章一次 → 全书一次。
/// - `initialUserScripts` 在 WebView 创建时就定死，而运行时 `addUserScript` 在
///   `flutter_inappwebview_windows` fork 上未经验证；外链没有这个平台风险。
///
/// 时序不变（这是能否合并的判据）：引擎脚本**只定义不执行**（整份 body 是
/// `window.__hoshiEngine.install` 的函数体），真正的执行仍由 Dart 在 `onLoadStop` 之后
/// 调 [bootInvocation] 触发——与改动前 `evaluateJavascript(整份 setup 脚本)` 是同一时刻、
/// 同一同步执行序。`<script defer>` 保证引擎在 DOMContentLoaded 前就绪，故 boot 时
/// `window.__hoshiEngine` 必然已在。
class ReaderEngineScript {
  ReaderEngineScript._();

  /// 引擎脚本在 hoshi.local 上的路径前缀（拦截器据此分派）。
  static const String pathPrefix = '/reader-engine/';

  static const String contentType = 'application/javascript';

  /// [bootInvocation] 的返回值：引擎已就位并完成 install。
  static const String bootOk = 'ok';

  /// [bootInvocation] 的返回值：`window.__hoshiEngine` 不在（外链没加载成功 / 页面来自
  /// 尚未注入 script 标签的旧缓存）。Dart 侧据此就地内联同一份引擎重来一次，
  /// 见 [inlineFallback]。这是**确定性的能力检查**，不是重试或等待。
  static const String bootEngineMissing = 'engine-missing';

  /// 强缓存：URL 里带内容哈希，内容一变 URL 就变，所以可以 `immutable`。
  static const Map<String, String> cacheHeaders = <String, String>{
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'public, max-age=31536000, immutable',
  };

  /// 引擎源码的内容哈希（URL 版本段）。
  static String versionOf(String source) =>
      sha1.convert(utf8.encode(source)).toString().substring(0, 16);

  /// 拦截器路径判定 + 路径构造，成对，不能各写各的。
  static String pathFor(String version) => '$pathPrefix$version.js';

  static bool isEnginePath(String path) =>
      path.startsWith(pathPrefix) && path.endsWith('.js');

  /// 注进章节 HTML `</head>` 之前的标签。
  ///
  /// `defer`：不阻塞 HTML 解析，但保证在 DOMContentLoaded 之前执行完 → 早于
  /// `onLoadStop`（load 事件）→ Dart 发 boot 时引擎必已定义。
  static String tag(String url) =>
      '<script src="${const HtmlEscape(HtmlEscapeMode.attribute).convert(url)}" '
      'defer></script>';

  /// 每次导航下发的**全部**内容：config + 一次 install 调用。
  ///
  /// 返回值是表达式（IIFE），`evaluateJavascript` 会把它的返回值带回 Dart，
  /// 供 [bootOk] / [bootEngineMissing] 判定。
  static String bootInvocation(ReaderEngineConfig config) {
    // install 的抛错**不**回落到内联兜底：兜底解决的是「引擎不在」，引擎已经在的情况下
    // 把同一份代码再跑一遍只会把事件监听器装两遍。就地 console.error（与两个 shell 的
    // boot try/catch 同款），BUG-1017 的 microtask 照样摘 cloak，与改动前一致。
    return '(function(){'
        'var C = ${config.toJsLiteral()};'
        'window.__hoshiReaderConfig = C;'
        'if (!window.__hoshiEngine || typeof window.__hoshiEngine.install !== "function")'
        ' return "$bootEngineMissing";'
        'try { window.__hoshiEngine.install(C); }'
        ' catch (e) { try { if (window.console && console.error)'
        ' console.error("[HoshiReader] engine install failed", e); }'
        ' catch (_ignored) {} }'
        'return "$bootOk";'
        '})()';
  }

  /// 外链没就位时的兜底：把同一份引擎源码就地内联，再走同一个 boot。
  ///
  /// 语义与外链路径逐字相同（同一份 [source]、同一份 config、同一次 install），
  /// 只是少了缓存复用。
  static String inlineFallback({
    required String source,
    required ReaderEngineConfig config,
  }) =>
      '$source\n${bootInvocation(config)}';
}
