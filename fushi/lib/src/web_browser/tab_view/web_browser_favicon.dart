import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/net/app_http_image.dart';

/// 首字母色块的底色（设计图 v4 `.fav` 的 f1..f4 + 补几色），按站点稳定取色。
const List<Color> kWebBrowserFaviconColors = <Color>[
  Color(0xFFFF0033),
  Color(0xFF3E8ED0),
  Color(0xFF2C9B63),
  Color(0xFFF08C00),
  Color(0xFF7B5CD6),
  Color(0xFFD6336C),
  Color(0xFF0B8A8A),
  Color(0xFF5C6B7A),
];

/// 站点（host）→ 色块底色，同一站点恒同色。
Color webBrowserFaviconColorFor(String key) {
  int hash = 0;
  for (final int unit in key.toLowerCase().codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return kWebBrowserFaviconColors[hash % kWebBrowserFaviconColors.length];
}

/// 色块上的字：标题首字（去掉空白与常见前缀符号），退到域名首字母（去 `www.`）。
String webBrowserFaviconLetter({required String title, required Uri? url}) {
  final String t = title.trim();
  if (t.isNotEmpty) return t.characters.first.toUpperCase();
  String host = url?.host ?? '';
  if (host.startsWith('www.')) host = host.substring(4);
  if (host.isNotEmpty) return host.characters.first.toUpperCase();
  return '·';
}

/// 标签页图标：20dp 圆角方块。有站点图标就画图标，取不到（无地址 / 加载失败）用
/// 首字母色块（设计图 v4 `.fav`）。
class WebBrowserFavicon extends StatelessWidget {
  const WebBrowserFavicon({
    required this.url,
    required this.title,
    this.faviconUrl,
    this.size = 20,
    super.key,
  });

  /// 页面地址（取色与首字母用）。
  final Uri? url;
  final String title;
  final Uri? faviconUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius = BorderRadius.circular(size * 0.3);
    final Widget letter = _LetterTile(
      letter: webBrowserFaviconLetter(title: title, url: url),
      color: webBrowserFaviconColorFor(url?.host ?? title),
      size: size,
      radius: radius,
    );
    final Uri? icon = faviconUrl;
    final Widget child = icon == null
        ? letter
        : ClipRRect(
            borderRadius: radius,
            child: Image(
              // 走应用代理出口，不用直连的 NetworkImage。
              image: AppHttpImage(icon.toString()),
              key: ValueKey<String>('web-browser-favicon-$icon'),
              width: size,
              height: size,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
              errorBuilder: (BuildContext _, Object _, StackTrace? _) => letter,
              frameBuilder:
                  (
                    BuildContext _,
                    Widget image,
                    int? frame,
                    bool synchronous,
                  ) => frame == null && !synchronous ? letter : image,
            ),
          );
    return SizedBox.square(dimension: size, child: child);
  }
}

class _LetterTile extends StatelessWidget {
  const _LetterTile({
    required this.letter,
    required this.color,
    required this.size,
    required this.radius,
  });

  final String letter;
  final Color color;
  final double size;
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: color, borderRadius: radius),
    child: Center(
      // 字形高度跟方块走（约 0.55 倍边长）、不跟系统字号：
      // FittedBox 把排版令牌的字缩放进固定比例的框，不手写字号。
      child: SizedBox(
        width: size * 0.9,
        height: size * 0.55,
        child: FittedBox(
          child: Text(
            letter,
            maxLines: 1,
            textScaler: TextScaler.noScaling,
            style: (Theme.of(context).textTheme.labelSmall ?? const TextStyle())
                .copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  height: 1,
                ),
          ),
        ),
      ),
    ),
  );
}
