/// BUG-1666：`fushi://lookup?word=<词>` 深链解析。
///
/// 产生端是制卡导出的释义 HTML（popup.js `rewriteExportedGlossaryAnchors` 把词典
/// 内部交叉引用改写成本深链），消费端分平台：
///  - Android：manifest 给 `:popup` 词典窗注册了 `fushi://lookup` 的 VIEW
///    intent-filter（Kotlin `extractProcessText` 解析同一 `word` 参数）；
///  - Windows：系统协议注册（安装包 HKCU `Software\Classes\fushi`）把链接交给
///    `fushi.exe "%1"`——冷启动走 Dart `main(args)`，热启动走单实例 WM_COPYDATA
///    转交（与外部视频同一条 `app.fushi/external_video` 通道，见
///    [docs/agent/external-video-open.md]），两条路都汇到本解析器。
///
/// `hibiki` scheme 是改名前残留，兼容保留（与 Kotlin 侧一致）。
String? lookupWordFromDeepLink(String url) {
  final String trimmed = url.trim();
  if (trimmed.isEmpty) return null;
  final Uri? uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  final String scheme = uri.scheme.toLowerCase();
  if (scheme != 'fushi' && scheme != 'hibiki') return null;
  if (uri.host.toLowerCase() != 'lookup') return null;
  final String? word = uri.queryParameters['word']?.trim();
  if (word == null || word.isEmpty) return null;
  return word;
}
