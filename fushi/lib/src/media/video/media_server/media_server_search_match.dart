/// 媒体服务器搜索结果的**客户端把关**（BUG-2608）。
///
/// `/Items?SearchTerm=` 的匹配语义完全由服务器决定，三家实测并不一致：
/// - Jellyfin：`CleanName` / `OriginalTitle` 子串；
/// - Emby 4.10：按空格分词、每个词做**词首前缀**、多词 AND；
/// - UHD Media Server 这类兼容层：按字模糊 + 相关度打分，搜「怪奇物语」回来
///   121 部电影（怪形 / 尘兔 / 绿毛怪格林奇……），精确命中的剧被压在第 2 页之后。
///
/// 客户端不猜服务器是哪家，只坚持一条对三家都无损的下限：**查询里每个空白分隔的
/// 词都得出现在条目的标题或原名里**（两侧都过 [normalizeMediaSearchText]，与
/// 书架 / 视频 / 游戏三个库页同一口径）。Jellyfin 的子串命中与 Emby 的词首前缀
/// 命中本来就满足这条，一条都不会被滤掉；兼容层的按字模糊命中才会被挡在外面。
///
/// 刻意不做的事：不折叠变音符（Jellyfin `CleanName` 会把 é 当 e），这与本仓
/// 库页搜索的既有口径一致，等有真实反馈再统一升级 [normalizeMediaSearchText]。
library;

import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';

/// 把查询拆成归一化后的词（按空白切、逐词 [normalizeMediaSearchText]、丢空）。
/// 空列表 = 查询没有可匹配内容（空白 / 纯标点），调用方据此不发请求。
List<String> mediaServerSearchTokens(String query) => <String>[
  for (final String raw in query.split(RegExp(r'\s+')))
    if (normalizeMediaSearchText(raw) case final String token
        when token.isNotEmpty)
      token,
];

/// [item] 是否命中 [tokens]（每个词都是归一化标题**或**归一化原名的子串）。
/// [tokens] 为空恒 false——空查询该在上游短路成空页，不该走到这里。
bool mediaServerSearchMatches(List<String> tokens, MediaServerItem item) {
  if (tokens.isEmpty) return false;
  final String name = normalizeMediaSearchText(item.name);
  final String original = normalizeMediaSearchText(item.originalTitle ?? '');
  for (final String token in tokens) {
    if (!name.contains(token) && !original.contains(token)) return false;
  }
  return true;
}

/// 过滤 + 页内排序：先滤掉不命中 [query] 的条目，再把「标题或原名恰好等于查询」
/// 的排最前、「标题或原名以查询开头」的其次、其余保持服务器顺序（稳定）。
///
/// 只在一页内排：跨页的全局排序要先把全部结果拉下来，和分页契约冲突；实际搜索
/// 里精确命中通常就落在第 1 页（服务器自己按相关度或名称排），页内置顶已够用。
List<MediaServerItem> rankMediaServerSearchHits(
  String query,
  Iterable<MediaServerItem> items,
) {
  final List<String> tokens = mediaServerSearchTokens(query);
  if (tokens.isEmpty) return const <MediaServerItem>[];
  final String whole = normalizeMediaSearchText(query);
  final List<MediaServerItem> exact = <MediaServerItem>[];
  final List<MediaServerItem> prefix = <MediaServerItem>[];
  final List<MediaServerItem> rest = <MediaServerItem>[];
  for (final MediaServerItem item in items) {
    if (!mediaServerSearchMatches(tokens, item)) continue;
    final String name = normalizeMediaSearchText(item.name);
    final String original = normalizeMediaSearchText(item.originalTitle ?? '');
    if (name == whole || original == whole) {
      exact.add(item);
    } else if (name.startsWith(whole) || original.startsWith(whole)) {
      prefix.add(item);
    } else {
      rest.add(item);
    }
  }
  return <MediaServerItem>[...exact, ...prefix, ...rest];
}
