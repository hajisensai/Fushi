import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 链接 / 图片的长按（移动）与右键（桌面）菜单：命中目标的归一化与菜单项决策（纯
/// 逻辑）。弹出与执行在 `WebBrowserTabView` 里。

/// 长按 / 右键命中的东西。两者都可能有（图片链接）。
@immutable
class WebBrowserHitTarget {
  const WebBrowserHitTarget({this.link, this.linkText = '', this.image});

  /// 可打开的链接（http / https）。
  final Uri? link;
  final String linkText;

  /// 图片地址（http / https / data:image）。
  final Uri? image;

  bool get isEmpty => link == null && image == null;

  @override
  bool operator ==(Object other) =>
      other is WebBrowserHitTarget &&
      other.link == link &&
      other.linkText == linkText &&
      other.image == image;

  @override
  int get hashCode => Object.hash(link, linkText, image);

  @override
  String toString() => 'WebBrowserHitTarget(link: $link, image: $image)';
}

Uri? _openableLink(String? raw, {Uri? base}) {
  if (raw == null || raw.trim().isEmpty) return null;
  Uri? uri = Uri.tryParse(raw.trim());
  if (uri == null) return null;
  if (!uri.hasScheme && base != null) uri = base.resolveUri(uri);
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return uri.host.isEmpty ? null : uri;
}

Uri? _imageSource(String? raw, {Uri? base}) {
  if (raw == null || raw.trim().isEmpty) return null;
  final String s = raw.trim();
  if (s.startsWith('data:image/')) return Uri.tryParse(s);
  return _openableLink(s, base: base);
}

/// 移动端 `onLongPressHitTestResult` → 命中目标。图片链接（`SRC_IMAGE_ANCHOR_TYPE`）
/// 的 `extra` 是图片地址，链接地址要另外从 `requestFocusNodeHref` 取（[focusHref]）。
WebBrowserHitTarget webBrowserHitTargetFromHitTest(
  InAppWebViewHitTestResult result, {
  Uri? focusHref,
  String focusTitle = '',
}) {
  final InAppWebViewHitTestResultType? type = result.type;
  final String? extra = result.extra;
  if (type == InAppWebViewHitTestResultType.SRC_ANCHOR_TYPE) {
    return WebBrowserHitTarget(
      link: _openableLink(extra) ?? focusHref,
      linkText: focusTitle,
    );
  }
  if (type == InAppWebViewHitTestResultType.SRC_IMAGE_ANCHOR_TYPE) {
    return WebBrowserHitTarget(
      link: focusHref,
      linkText: focusTitle,
      image: _imageSource(extra),
    );
  }
  if (type == InAppWebViewHitTestResultType.IMAGE_TYPE) {
    return WebBrowserHitTarget(image: _imageSource(extra));
  }
  return const WebBrowserHitTarget();
}

/// 桌面右键脚本上报的 `{link, linkText, image, x, y}` → 命中目标。
WebBrowserHitTarget webBrowserHitTargetFromJs(Object? payload, {Uri? base}) {
  if (payload is! Map) return const WebBrowserHitTarget();
  final Object? link = payload['link'];
  final Object? text = payload['linkText'];
  final Object? image = payload['image'];
  return WebBrowserHitTarget(
    link: link is String ? _openableLink(link, base: base) : null,
    linkText: text is String ? text : '',
    image: image is String ? _imageSource(image, base: base) : null,
  );
}

/// 菜单项（顺序即显示顺序）。
enum WebBrowserContextMenuItem {
  openNewTab,
  openBackgroundTab,
  openIncognitoTab,
  copyLink,
  shareLink,
  openImageNewTab,
  saveImage,
  copyImageUrl,
  ocrImage,
}

/// 命中目标 → 菜单项。
///
/// - [incognitoAvailable]：本平台有无痕隔离（见 `webBrowserIncognitoSupported`）且
///   当前不是无痕标签页（无痕页里「新标签页打开」本来就是无痕的）；
/// - [ocrAvailable]：本机有系统 OCR。
List<WebBrowserContextMenuItem> webBrowserContextMenuItems(
  WebBrowserHitTarget target, {
  required bool incognitoAvailable,
  required bool ocrAvailable,
}) {
  final Uri? image = target.image;
  final bool webImage =
      image != null && (image.scheme == 'http' || image.scheme == 'https');
  return <WebBrowserContextMenuItem>[
    if (target.link != null) ...<WebBrowserContextMenuItem>[
      WebBrowserContextMenuItem.openNewTab,
      WebBrowserContextMenuItem.openBackgroundTab,
      if (incognitoAvailable) WebBrowserContextMenuItem.openIncognitoTab,
      WebBrowserContextMenuItem.copyLink,
      WebBrowserContextMenuItem.shareLink,
    ],
    if (image != null) ...<WebBrowserContextMenuItem>[
      if (webImage) WebBrowserContextMenuItem.openImageNewTab,
      WebBrowserContextMenuItem.saveImage,
      if (webImage) WebBrowserContextMenuItem.copyImageUrl,
      if (ocrAvailable) WebBrowserContextMenuItem.ocrImage,
    ],
  ];
}
