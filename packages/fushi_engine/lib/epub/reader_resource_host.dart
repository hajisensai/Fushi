/// 阅读器 WebView 拦截的资源虚拟域名。
///
/// 原在 app 的 `ReaderCustomFontCss.kReaderResourceHost`，`ReaderFushiSource.kHost`
/// 与 `ImageRevealKey.host` 都引用它；引擎里的 `EpubBook.resolveInternalLink`
/// 也要按这个域名识别 `/epub/<path>` 内链，所以常量下沉到引擎，app 三处反向引用。
/// 值不可改：已导入书籍的 CSS/内链缓存里写死了它。
library;

const String kReaderResourceHost = 'fushi.local';
