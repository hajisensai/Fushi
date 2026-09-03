import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:path/path.dart' as p;

/// TODO-049: 词典弹窗字体的 CSS 构造。
///
/// 词典弹窗是一个独立的小 WebView（assets/popup/popup.css 里把 `font-family` 写死成
/// `"Hiragino Sans", ...`），既不走阅读器的 `fushi.local/fonts/` 拦截器，Windows 端
/// 又用 about:blank 的 `NavigateToString` 加载，无法用相对/虚拟 URL 引用磁盘字体文件。
///
/// 为在 5 平台一致地支持用户配置的词典字体，这里用两条零跨平台差异的注入路径：
///   - 系统字体（`path == null`）：直接产出 CSS `font-family: "Name"`，由各平台字体栈
///     解析，无需任何文件服务。
///   - 导入字体文件（`path != null`）：把字体字节内联成 `data:` URL 的 `@font-face`
///     `src`，WebView 自行解码 ttf/otf/woff/woff2/ttc。`data:` URL 在 about:blank 与
///     所有平台都有效，无需拦截器或自定义 scheme。
///
/// 返回的 [fontFamily] 串可拼到 popup 的 `font-family`（在词典名之前作为首选），
/// [fontFaces] 是若干 `@font-face` 声明。两者均为空时调用方应回退到 popup.css 默认。
class DictionaryFontCss {
  const DictionaryFontCss._();

  /// MIME `format()` hint per font extension, so the WebView picks the right
  /// decoder for the inlined `data:` URL.
  static const Map<String, ({String mime, String format})> _fontTypes =
      <String, ({String mime, String format})>{
        '.ttf': (mime: 'font/ttf', format: 'truetype'),
        '.otf': (mime: 'font/otf', format: 'opentype'),
        '.ttc': (mime: 'font/collection', format: 'collection'),
        '.woff': (mime: 'font/woff', format: 'woff'),
        '.woff2': (mime: 'font/woff2', format: 'woff2'),
      };

  /// 一条 `[{name,path,enabled}]` 条目是否启用（缺 `enabled` 视为启用，兼容旧数据）。
  ///
  /// 唯一判据：[build]（产 CSS）、[fontListFingerprint]（产 memo 键）和字体 URL
  /// 拦截器的白名单（`configuredDictionaryFontPaths`）必须用同一个谓词。三处各写
  /// 一遍的话，被用户停用的字体会出现在其中一处而不在另一处——BUG-1868 里拦截器就
  /// 漏了这个过滤，于是停用的字体文件仍可经 `/dictfonts/` 读出。
  static bool isEntryEnabled(Map<String, dynamic> e) =>
      e['enabled'] as bool? ?? true;

  /// Builds the dictionary font CSS for [fonts] (a `[{name,path,enabled}]`
  /// list). [allowedDirectories] gates which file paths may be inlined (same
  /// whitelist model as the reader's font serving). Reads happen synchronously;
  /// any unreadable / oversized / unknown-extension file is skipped, degrading
  /// to the remaining usable fonts (and ultimately the popup.css default).
  /// [fontUrlBuilder] 非空时**不读文件、不做 base64**，直接把它对通过白名单校验的
  /// 绝对路径产出的 URL 写进 `@font-face src`，由宿主 WebView 的资源拦截器按需供字节。
  ///
  /// 为什么要有这条路：内联 `data:` URL 的代价不是「多几个字节」，而是它把字体塞进了
  /// **每次渲染都要重新注入的那段脚本**里。两个 CJK 字体（8.3 MB + 17 MB）base64 之后
  /// 是三十多 MB；而 in-app 弹窗每嵌套一层就新建一个 WebView（新 JS realm，window.*
  /// 全空，静态段必须重发），于是「在弹窗里点词」每点一次就重新序列化、跨平台通道、
  /// 重新解析这三十多 MB。换成 URL 后这段脚本降到 KB 级，字体由浏览器按 URL 取并
  /// **跨 WebView 共享 HTTP 缓存**——data: URL 每次都是一个全新资源，永远共享不了。
  ///
  /// 留成可选参数而不是直接切换：iOS / macOS 的 in-app 弹窗**不能**走这条路（它们只有
  /// WKURLSchemeHandler，构造的 URLResponse 带不了任何 header，而字体是强制 CORS 模式
  /// 的子资源，拿不到 `Access-Control-Allow-Origin` 就会被拒），那两个平台继续内联。
  static ({String fontFamily, String fontFaces, List<String> families}) build(
    Iterable<Map<String, dynamic>> fonts, {
    Iterable<String> allowedDirectories = const <String>[],
    int maxFileBytes = defaultMaxFileBytes,
    String Function(String safePath)? fontUrlBuilder,
  }) {
    final Iterable<Map<String, dynamic>> enabled = fonts.where(isEntryEnabled);
    final List<String> families = <String>[];
    // 内容语言字体链要把用户字体接在每条 :lang() 规则的链首，而那条链自己负责加
    // 引号，所以这里同时留一份**裸**家族名（families 里是 CSS 化后带引号的形态）。
    // 两份都由同一轮过滤产出，避免「哪些字体文件可内联」出现第二份判据。
    final List<String> rawFamilies = <String>[];
    final List<String> faces = <String>[];

    for (final Map<String, dynamic> e in enabled) {
      final String? rawName = e['name'] as String?;
      if (rawName == null || rawName.trim().isEmpty) continue;
      final String cssName = ReaderCustomFontCss.cssFontFamilyName(rawName);
      final String bareName = ReaderCustomFontCss.normalizedFontFamilyName(
        rawName,
      );

      final String? fontPath = e['path'] as String?;
      if (fontPath == null) {
        // System font: the platform resolves it by family name directly.
        families.add(cssName);
        rawFamilies.add(bareName);
        continue;
      }

      final ({String mime, String format})? type =
          _fontTypes[p.extension(fontPath).toLowerCase()];
      if (type == null) continue;

      final String? safePath = ReaderCustomFontCss.safeFontPath(
        fontPath,
        allowedRoots: allowedDirectories,
      );
      if (safePath == null) continue;

      final String? src;
      if (fontUrlBuilder != null) {
        // URL 模式：只确认文件还在（一次 stat，不碰内容），字节由宿主拦截器按需供。
        // 文件消失时跳过这条，与内联模式「不可读就降级掉这一条」的语义一致。
        if (!_fontFileUsable(safePath, maxFileBytes)) continue;
        src = fontUrlBuilder(safePath);
      } else {
        src = _inlineFontDataUrl(safePath, type.mime, maxFileBytes);
      }
      if (src == null) continue;

      families.add(cssName);
      rawFamilies.add(bareName);
      faces.add(
        '@font-face { font-family: $cssName; '
        'src: url("$src") format("${type.format}"); '
        'font-display: swap; }',
      );
    }

    return (
      fontFamily: families.join(', '),
      fontFaces: faces.join('\n'),
      families: List<String>.unmodifiable(rawFamilies),
    );
  }

  /// Default cap on a single inlined font file (32 MiB). Recommended CJK fonts
  /// such as Klee One and Noto Sans JP are commonly 8–10 MiB, so the former
  /// 8 MiB limit silently removed them from dictionary popup CSS. The bounded
  /// cap still prevents an arbitrary-size synchronous read/data-URL payload.
  @visibleForTesting
  static const int defaultMaxFileBytes = 32 * 1024 * 1024;

  /// BUG-717 ③：启用字体条目的内容指纹，供上层对 [build] 的**最终产物**做 memo。
  ///
  /// 键语义与 [_dataUrlCache]（(path, mtime, size) 内容键）完全一致：
  ///   - 系统字体条目：`name`；
  ///   - 文件字体条目：`name + path + mtimeUs:size`（文件缺失记 `missing`，
  ///     stat 异常记 `err`——两者都会在文件恢复可读时换键，自动失效）；
  ///   - 禁用 / 空名条目不参与（与 [build] 的过滤一致：切换启用状态即换键）；
  ///   - 白名单目录参与键（目录变化改变可内联集合）。
  /// 只做 statSync 不读文件内容，热路径成本是每个字体条目一次 stat。
  static String fontListFingerprint(
    Iterable<Map<String, dynamic>> fonts, {
    Iterable<String> allowedDirectories = const <String>[],
  }) {
    final StringBuffer buffer = StringBuffer();
    for (final Map<String, dynamic> e in fonts) {
      if (!isEntryEnabled(e)) continue;
      final String? name = e['name'] as String?;
      if (name == null || name.trim().isEmpty) continue;
      buffer
        ..write(name)
        ..write('\u0001');
      final String? fontPath = e['path'] as String?;
      if (fontPath == null) {
        buffer.write('sys\u0002');
        continue;
      }
      buffer
        ..write(fontPath)
        ..write('\u0001');
      try {
        final FileStat stat = FileStat.statSync(fontPath);
        buffer.write(
          stat.type == FileSystemEntityType.notFound
              ? 'missing'
              : '${stat.modified.microsecondsSinceEpoch}:${stat.size}',
        );
      } catch (_) {
        buffer.write('err');
      }
      buffer.write('\u0002');
    }
    buffer
      ..write('|roots:')
      ..writeAll(allowedDirectories, '\u0001');
    return buffer.toString();
  }

  /// [_inlineFontDataUrl] 读盘/编码异常的累计计数。指纹（stat 结果）不携带
  /// 「stat 成功但读文件失败」这种瞬时信息，上层 memo 用「build 前后计数未变」
  /// 判定本次产物无瞬时降级、可安全缓存；有失败则跳过缓存，下次查词自然重试
  /// （与 [_dataUrlCache] 「失败不缓存」同语义）。
  static int get inlineFailureCount => _inlineFailureCount;
  static int _inlineFailureCount = 0;

  /// (mtime, size) 内容键的进程内缓存：同一字体文件只读盘 + base64 一次。
  /// 每次查词推结果都会重建注入串（in-app 弹窗 / 全局查词栈 / 剪贴板面板共用
  /// [build]），导入字体无缓存时每次数十 ms 的同步读盘+编码是查词热路径的纯
  /// 浪费。文件被原地覆盖时 mtime/size 变化自动失效；路径变（导入落盘名带时间
  /// 戳、启动自愈迁移）天然换键，无需接任何设置变更通知。
  static final Map<String, ({int mtimeUs, int size, String dataUrl})>
  _dataUrlCache = <String, ({int mtimeUs, int size, String dataUrl})>{};

  /// URL 模式下对字体文件的可用性判据：与 [_inlineFontDataUrl] **同一套门槛**
  /// （存在、非空、不超 [maxBytes]），但只 stat、不读内容、不编码。
  ///
  /// 保持门槛一致是有意的：同一份字体列表在内联模式与 URL 模式下必须产出同一组
  /// `@font-face`，否则「换个平台字体就多一条/少一条」会变成极难查的显示差异。
  static bool _fontFileUsable(String path, int maxBytes) {
    try {
      final FileStat stat = FileStat.statSync(path);
      if (stat.type == FileSystemEntityType.notFound) return false;
      final int length = stat.size;
      if (length <= 0 || length > maxBytes) return false;
      // 只 stat 是**不够**的：内联路径会真的 readAsBytesSync，于是「文件在、大小
      // 合法、但读不出来」（权限、被独占、路径其实是目录）在那边会抛 → 计入
      // _inlineFailureCount → 跳过该条且本次产物不进 memo。URL 路径若只 stat 就
      // 放行，同一份字体列表在两种模式下会选出**不同**的字体集合（正是本函数
      // 声称要避免的事），而且更糟：那条坏字体的产物会被 memo 永久缓存，拦截器
      // 每次请求都 403 并写一条错误日志。
      // 这里开一下再关，代价是一次 open/close，不读任何内容。
      final RandomAccessFile handle = File(path).openSync();
      handle.closeSync();
      return true;
    } catch (e, stack) {
      // 与内联路径同一套失败记账：上层 memo 用「build 前后计数未变」判定本次产物
      // 没有瞬时降级、可安全缓存。失败却不计数，会把一次「字体临时读不到」的残缺
      // 产物永久缓存下来。
      _inlineFailureCount++;
      ErrorLogService.instance.log('DictionaryFontCss.probe', e, stack);
      return false;
    }
  }

  static String? _inlineFontDataUrl(String path, String mime, int maxBytes) {
    try {
      final FileStat stat = FileStat.statSync(path);
      if (stat.type == FileSystemEntityType.notFound) return null;
      final int length = stat.size;
      // 上限检查放在缓存命中之前：大文件已缓存后，更小的 maxBytes 调用方仍须
      // 拒绝它（dictionary_font_css_test.dart 覆盖该语义）。
      if (length <= 0 || length > maxBytes) return null;
      final int mtimeUs = stat.modified.microsecondsSinceEpoch;
      final ({int mtimeUs, int size, String dataUrl})? cached =
          _dataUrlCache[path];
      if (cached != null &&
          cached.mtimeUs == mtimeUs &&
          cached.size == length) {
        return cached.dataUrl;
      }
      final List<int> bytes = File(path).readAsBytesSync();
      final String dataUrl = 'data:$mime;base64,${base64Encode(bytes)}';
      _dataUrlCache[path] = (mtimeUs: mtimeUs, size: length, dataUrl: dataUrl);
      return dataUrl;
    } catch (e, stack) {
      _inlineFailureCount++;
      ErrorLogService.instance.log('DictionaryFontCss.inline', e, stack);
      return null;
    }
  }
}
