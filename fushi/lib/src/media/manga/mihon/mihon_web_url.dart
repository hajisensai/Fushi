import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';

/// 作品在源站的网页地址——详情页「在网站打开」入口用。
///
/// 先问扩展（[MihonWebUrlRuntime]，即 Mihon `getMangaUrl` / Aniyomi
/// `getAnimeUrl`：源可以覆盖成与 `url` 不同的页面，例如 `url` 是 API 路径的源）；
/// 运行时没这能力、扩展抛错或回了个不是 http(s) 的东西，就回落到
/// `baseUrl + url` 拼接（Mangayomi 的做法；Mihon 的默认实现也是详情请求的 URL，
/// 绝大多数源两者等价）。两条路都拿不到就是 null，调用方给「该源没有网页」提示。
Future<Uri?> resolveMihonMangaWebUrl({
  required Object runtime,
  required MihonSourceContext context,
  required MihonManga manga,
}) async {
  if (runtime is MihonWebUrlRuntime) {
    try {
      final Uri? parsed = mihonWebUrlOrNull(
        await runtime.getMangaWebUrl(
          context.extension,
          context.source,
          manga,
          preferences: context.preferences,
        ),
      );
      if (parsed != null) return parsed;
    } on Object {
      // 扩展侧失败不阻断入口：下面按 baseUrl 拼。
    }
  }
  return mihonWebUrlFallback(baseUrl: context.source.baseUrl, url: manga.url);
}

/// 视频扩展版，语义同 [resolveMihonMangaWebUrl]。
Future<Uri?> resolveMihonAnimeWebUrl({
  required Object runtime,
  required MihonSourceContext context,
  required MihonAnime anime,
}) async {
  if (runtime is MihonWebUrlRuntime) {
    try {
      final Uri? parsed = mihonWebUrlOrNull(
        await runtime.getAnimeWebUrl(
          context.extension,
          context.source,
          anime,
          preferences: context.preferences,
        ),
      );
      if (parsed != null) return parsed;
    } on Object {
      // 同上。
    }
  }
  return mihonWebUrlFallback(baseUrl: context.source.baseUrl, url: anime.url);
}

/// `baseUrl + url` 拼接：[url] 本身已是绝对 http(s) 地址就原样用（不少源把
/// 完整地址存在 `url` 里）；否则要求 [baseUrl] 非空，路径之间只留一个 `/`。
Uri? mihonWebUrlFallback({required String baseUrl, required String url}) {
  final Uri? absolute = mihonWebUrlOrNull(url);
  if (absolute != null) return absolute;
  final String base = baseUrl.trim();
  final String path = url.trim();
  if (base.isEmpty) return null;
  if (path.isEmpty) return mihonWebUrlOrNull(base);
  final String joined = base.endsWith('/') && path.startsWith('/')
      ? '$base${path.substring(1)}'
      : !base.endsWith('/') && !path.startsWith('/')
      ? '$base/$path'
      : '$base$path';
  return mihonWebUrlOrNull(joined);
}

/// 只认带 host 的 http(s) 地址——扩展偶尔会回空串、相对路径或 `null` 字面量，
/// 那些交给系统浏览器只会弹一个莫名其妙的错误。
Uri? mihonWebUrlOrNull(String? value) {
  if (value == null) return null;
  final Uri? uri = Uri.tryParse(value.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return uri;
}
