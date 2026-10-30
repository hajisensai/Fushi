import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-3356：iOS 上阅读器左缘横滑（用户习惯的侧滑返回）把正文跳走。
///
/// 根因：flutter_inappwebview 的 `allowsBackForwardNavigationGestures` 默认 true，
/// WKWebView 把边缘横滑当成**自己的历史前进 / 后退**；阅读器跨章 `loadUrl`、歌词文档
/// `loadData` 都会往 WebView 历史里压条目，侧滑就退回上一章 / 旧文档。路由侧滑早被
/// 页面 `PopScope(canPop: false)` 关掉，剩下的就是 WebView 这一层。
///
/// 补漏：漫画阅读器（spread 窗口逐次 `loadData`）与 SRS 卡面（换卡 / 翻面 `loadData`）
/// 是同一形态，一并关掉。
///
/// 覆盖边界：手势本身只有 iOS 真机 / 模拟器能验；这里钉住这些 WebView 的
/// `initialSettings` 都显式关掉它（删掉这行即红），并要求 `lib/` 下每个
/// `InAppWebViewSettings(` 所在文件都在下面两张表之一里有归类——新加的 WebView
/// 必须先想清楚它的历史是否对应用户导航。
void main() {
  /// 会多次 load、WebView 历史不对应用户导航的 WebView：必须关掉历史侧滑。
  const List<String> disabled = <String>[
    'lib/src/pages/implementations/reader_fushi/webview.part.dart',
    'lib/src/pages/implementations/reader_fushi/lyrics.part.dart',
    'lib/src/media/manga/reader/manga_fushi_page.dart',
    'lib/src/pages/implementations/srs/srs_card_face.dart',
  ];

  /// 不需要关的 WebView 及理由（保持默认）。
  const Map<String, String> exempt = <String, String>{
    'lib/src/pages/implementations/web_video_fushi_page.dart':
        '浏览器类页面：历史就是用户的网页导航，后退手势合理',
    'lib/src/media/video/web_video_session.dart':
        '原生播放器页网页档的站点 WebView（Windows WebView2）：历史是用户在站点里的导航',
    // #2500 把 WebView 从 fushi_web_browser_page.dart 拆进每标签页视图；加载失败页是
    // Flutter 侧状态、阅读模式就地换 body，都不往 WebView 历史压条目。
    'lib/src/web_browser/tab_view/web_browser_tab_view.dart':
        '浏览器模块（通用 app 内浏览器）的标签页 WebView：历史就是用户的网页导航，后退手势合理',
    'lib/src/media/manga/web/web_comic_scanner.dart':
        '网页漫画章节扫描用 HeadlessInAppWebView，不可见、无手势',
    'lib/src/media/novel/web/web_novel_page_fetcher.dart':
        '网页小说取页用 HeadlessInAppWebView，不可见、无手势',
    'lib/src/media/manga/cookie/cloudflare_challenge_page.dart':
        '浏览器类页面（站点验证），历史对应真实网页跳转',
    'lib/src/media/manga/mihon/mihon_web_login_page.dart':
        '浏览器类页面（站点登录），历史对应真实网页跳转',
    'lib/src/pages/implementations/music/music_plugin_login.dart':
        '浏览器类页面（音乐插件网页登录），历史对应真实网页跳转',
    'lib/src/media/novel/online/lnreader_runtime.dart': '无头运行时 WebView，不可见、无手势',
    'lib/src/media/audiobook/audiobook_clip_webview_render.dart':
        '离屏渲染用 WebView，不可见、无手势',
    'lib/src/pages/implementations/dictionary_popup_webview.dart':
        '生产路径只加载一次文档（嵌套查词走 JS 更新），无历史可退',
    'lib/src/pages/implementations/dict_style_preview.dart': '只加载一次预览文档，无历史可退',
    'lib/src/anki/lapis_style_editor_page.dart': '只加载一次预览文档，无历史可退',
    'lib/src/anki/anki_video_template_page.dart': '只加载一次预览文档，无历史可退',
  };

  /// 从 `initialSettings: InAppWebViewSettings(` 起按圆括号配对截出整段实参。
  String settingsBlock(String path, String src) {
    const String anchor = 'initialSettings: InAppWebViewSettings(';
    final int start = src.indexOf(anchor);
    expect(start, isNonNegative, reason: '$path 找不到 initialSettings');
    int depth = 0;
    for (int i = start + anchor.length - 1; i < src.length; i++) {
      final String c = src[i];
      if (c == '(') depth++;
      if (c == ')') {
        depth--;
        if (depth == 0) return src.substring(start, i + 1);
      }
    }
    fail('$path 的 InAppWebViewSettings( 括号不配对');
  }

  for (final String path in disabled) {
    test('$path 的 InAppWebViewSettings 关掉 WebView 历史侧滑', () {
      final String src = File(path).readAsStringSync();
      expect(
        settingsBlock(path, src),
        contains('allowsBackForwardNavigationGestures: false,'),
        reason: 'WKWebView 默认把边缘横滑当历史前进 / 后退，逐次 load 的阅读类 WebView 会被侧滑退回旧文档',
      );
    });
  }

  test('lib/ 下每个 InAppWebViewSettings 都已归类（关掉 / 有理由保持默认）', () {
    final List<String> found = <String>[];
    for (final FileSystemEntity e in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      if (!e.readAsStringSync().contains('InAppWebViewSettings(')) continue;
      found.add(e.path.replaceAll(r'\', '/'));
    }
    expect(found, isNotEmpty);
    final List<String> unclassified = found
        .where((String p) => !disabled.contains(p) && !exempt.containsKey(p))
        .toList();
    expect(
      unclassified,
      isEmpty,
      reason:
          '新 WebView：若会多次 load 且历史不对应用户导航，加 '
          'allowsBackForwardNavigationGestures: false 并登记到 disabled；否则在 exempt 写明理由',
    );
    for (final String p in <String>[...disabled, ...exempt.keys]) {
      expect(
        found,
        contains(p),
        reason: '$p 已不含 InAppWebViewSettings，表里的条目过期了',
      );
    }
  });
}
