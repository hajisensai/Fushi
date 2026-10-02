import 'package:url_launcher/url_launcher.dart';

import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 系统浏览器打开函数的签名；生产用 [launchUrl]，测试注入假实现。
typedef DictionaryLinkLauncher =
    Future<bool> Function(Uri uri, {LaunchMode mode});

/// 词典正文里的外链（Pixiv「pixivで読む」、Jitendex 来源链接、MDX 原始 HTML 的
/// `<a href="https://…">` 等）→ 可交给系统浏览器的 [Uri]；不可打开时返回 null。
///
/// 词典是用户从网上下的第三方内容，只放行 http / https：popup.js 那侧也只把
/// `^https?://` 交给 `openLink`，这里在宿主侧再收一次口，防止 `file:` /
/// `javascript:` / 自定义协议经桥被 ShellExecute 拉起本机程序。
Uri? parseDictionaryExternalLink(String raw) {
  final Uri? uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.host.isEmpty) {
    return null;
  }
  final String scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') {
    return null;
  }
  return uri;
}

/// popup.js `openLink` 桥的唯一宿主实现：app 内查词弹窗（`DictionaryPopupWebview`）
/// 与 app 外查词窗（全局查词 / galgame 游戏内查词卡，`GlobalLookupController`）共用。
///
/// BUG-2868：后者此前根本没有 `openLink` 分支，消息进了 `_onJsMessage` 就被丢掉，
/// 点「pixivで読む」毫无反应。打不开返回 false，**不抛**——桥回调里漏出的异常
/// 只会变成一条未捕获异步错误，用户看到的仍是「没反应」。
Future<bool> openDictionaryExternalLink(
  String raw, {
  DictionaryLinkLauncher launcher = launchUrl,
}) async {
  final Uri? uri = parseDictionaryExternalLink(raw);
  if (uri == null) {
    return false;
  }
  try {
    return await launcher(uri, mode: LaunchMode.externalApplication);
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('openDictionaryExternalLink', error, stack);
    return false;
  }
}
