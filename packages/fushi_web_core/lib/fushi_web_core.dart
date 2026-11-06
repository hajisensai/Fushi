/// 网页内容计算核心（native/fushi_web_core，Rust）的纯 Dart FFI 封装：
/// 广告 / 跟踪拦截（[AdblockCore]，状态全在 Rust）+ 网页漫画章末广告页识别
/// （[ComicAdDetector]）+ 网页小说正文提取与连载会话（[WebNovelSession] / [WebArticleExtractor]）。
/// 无 Flutter / 插件依赖；WebView 接线在 app 侧。
library;

export 'src/adblock/adblock_core.dart';
export 'src/adblock/adblock_snapshot.dart';
export 'src/article/web_novel_session.dart';
export 'src/comic_ad/comic_ad_detector.dart';
export 'src/ffi/fushi_web_core_bindings.dart'
    show FushiWebCoreBindings, FwcAdblockCore, FwcComicAdRules, FwcNovelSession;
export 'src/fushi_web_core_library.dart';
