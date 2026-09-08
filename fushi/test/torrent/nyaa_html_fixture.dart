/// 测试用 Nyaa HTML 搜索页构造器。
///
/// `NyaaClient.search` 现在只走 HTML 搜索页（RSS 被 nyaa 后端强制按 id 倒序、
/// 忽略排序与分页），所以所有喂给 `NyaaClient` 的 mock 响应都必须长得像
/// `table.torrent-list`。这里按真实页面结构（分类 / 标题 / 下载 / 体积 / 时间 /
/// 做种 / 下载中 / 完成数 八列，行 class `success` = trusted、`danger` = remake）
/// 生成，各测试只描述数据、不再各写一份 HTML。
library;

import 'dart:convert';

/// 一行种子。[title] 会做 HTML 转义后写进 `title` 属性。
class NyaaHtmlRow {
  const NyaaHtmlRow({
    required this.title,
    required this.infoHash,
    this.id,
    this.seeders = 0,
    this.leechers = 0,
    this.downloads = 0,
    this.size = '1.0 MiB',
    this.categoryId = '1_2',
    this.trusted = false,
    this.remake = false,
    this.timestampSeconds = 1700000000,
  });

  final String title;

  /// 40 位十六进制 infoHash（大小写不限，页面 magnet 里原样写）。
  final String infoHash;

  /// 站内种子 id（`/view/<id>`）；null 时用 infoHash 前 8 位派生。
  final String? id;
  final int seeders;
  final int leechers;
  final int downloads;
  final String size;
  final String categoryId;
  final bool trusted;
  final bool remake;
  final int timestampSeconds;
}

/// 「No results found」页：nyaa 对无结果的搜索返回 200 + 这个标题、没有表格。
const String kNyaaNoResultsHtml = '''
<!doctype html><html><body>
<div class="container"><h3>No results found</h3></div>
</body></html>''';

/// 生成一页 HTML 搜索结果。[host] 只影响相对链接解析后的 pageUrl（测试断言
/// `https://nyaa.si/view/<id>` 时保持默认即可，client 会用请求 URL 解析）。
String nyaaSearchHtml(Iterable<NyaaHtmlRow> rows) {
  final StringBuffer sb = StringBuffer()
    ..writeln('<!doctype html><html><body>')
    ..writeln('<table class="table table-bordered table-hover table-striped '
        'torrent-list"><tbody>');
  for (final NyaaHtmlRow row in rows) {
    final String id = row.id ?? row.infoHash.substring(0, 8);
    final String title =
        const HtmlEscape(HtmlEscapeMode.attribute).convert(row.title);
    // remake 盖过 trusted：nyaa 模板的行 class 优先级 deleted > hidden > remake
    // > trusted，trusted 用户发的 remake 只显示 danger。
    final String rowClass = row.remake
        ? 'danger'
        : row.trusted
            ? 'success'
            : 'default';
    sb
      ..writeln('  <tr class="$rowClass">')
      ..writeln('    <td><a href="/?c=${row.categoryId}" title="cat">'
          '<img src="/static/img/icons/x.png" alt="cat"></a></td>')
      ..writeln('    <td colspan="2"><a href="/view/$id" title="$title">'
          '$title</a></td>')
      ..writeln('    <td class="text-center">'
          '<a href="/download/$id.torrent"><i class="fa fa-download"></i></a>'
          '<a href="magnet:?xt=urn:btih:${row.infoHash}&amp;dn=x">'
          '<i class="fa fa-magnet"></i></a></td>')
      ..writeln('    <td class="text-center">${row.size}</td>')
      ..writeln('    <td class="text-center" '
          'data-timestamp="${row.timestampSeconds}">2023-11-14 22:13</td>')
      ..writeln('    <td class="text-center">${row.seeders}</td>')
      ..writeln('    <td class="text-center">${row.leechers}</td>')
      ..writeln('    <td class="text-center">${row.downloads}</td>')
      ..writeln('  </tr>');
  }
  sb
    ..writeln('</tbody></table>')
    ..writeln('</body></html>');
  return sb.toString();
}
