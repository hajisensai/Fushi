/// 通用种子 RSS / Atom 搜索结果解析（用户自配的「RSS 搜索站」共用）。
///
/// 不认任何站点的私有结构，只按**通用字段 + 已知扩展命名空间**取值，所以各家
/// 种子站的 RSS 以及标准 Torznab/Atom 源都走这一个函数（`nyaa:` 是事实标准的
/// 种子 RSS 扩展命名空间，按它的元素名解析是 wire 格式，不是站点特判）：
///
/// - 下载地址：磁链优先（Torznab `magneturl` attr → enclosure → link → guid →
///   Atom `<link href>` → description 里的 `magnet:` 链接）；否则取 `.torrent`
///   地址（enclosure → 以 `.torrent` 结尾的 link → Atom `rel="enclosure"`）。
///   两者都没有的条目下载不了，直接跳过。
/// - infoHash：磁链 `btih` → `nyaa:infoHash` → Torznab `infohash` attr → `.torrent`
///   地址 / link / guid 里独立出现的 40 位十六进制（蜜柑的种子地址与详情页都带它）。
/// - 体积：`nyaa:size`（`1.4 GiB`）→ Torznab `size` attr → 蜜柑 `<torrent>
///   <contentLength>` → enclosure `length`（见 [_plausibleEnclosureLength]）。
/// - 做种 / 下载数：`nyaa:seeders|leechers|downloads`、Torznab `seeders|peers|grabs`，
///   没有就是 0。
/// - 时间：`pubDate`（RFC 822）→ 蜜柑 `<torrent><pubDate>`（ISO 8601）→ Atom
///   `published` / `updated`。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:xml/xml.dart';

import 'package:fushi_engine/media/torrent/magnet_utils.dart';
import 'package:fushi_engine/media/torrent/torrent_download_fetch.dart'
    show safePublicDetailsUrl;

/// RSS 搜索站返回的一个可下载条目。
class RssSearchItem {
  const RssSearchItem({
    required this.title,
    required this.remoteId,
    this.magnetUri,
    this.torrentUri,
    this.detailsUrl,
    this.infoHash,
    this.sizeBytes,
    this.seeders = 0,
    this.leechers = 0,
    this.downloads = 0,
    this.publishedAt,
    this.category,
    this.trusted = false,
  }) : assert(magnetUri != null || torrentUri != null);

  final String title;

  /// 站内稳定标识（guid / infoHash / 下载地址的 SHA-1），重启后重搜按它找回条目。
  final String remoteId;

  /// `magnet:` 磁链；有它就不用再下 `.torrent`。
  final String? magnetUri;

  /// `.torrent` 下载地址（http/https）。只在没有磁链时才会被用到。
  final Uri? torrentUri;

  /// 条目详情页（http/https），「在浏览器打开」用。
  final String? detailsUrl;

  /// 40 位（v1）或 64 位（v2）小写十六进制；认不出为 null。
  final String? infoHash;
  final int? sizeBytes;
  final int seeders;
  final int leechers;
  final int downloads;
  final DateTime? publishedAt;

  /// 站内分类（`nyaa:categoryId` 优先，其次 `<category>`）。
  final String? category;

  /// 源标记的 trusted 发布（`nyaa:trusted` 为 `Yes`）；其它源恒 false。
  final bool trusted;
}

/// 解析 RSS 2.0 / RSS 1.0 / Atom 搜索结果。
///
/// 不是 XML、根元素不是 `<rss>` / `<feed>` / `<RDF>`（如被 Cloudflare 拦下来的
/// HTML 页）一律抛 [FormatException]——「站点挂了」不能被读成「0 条结果」。结构
/// 有效但没有可下载条目时返回空列表。
List<RssSearchItem> parseRssSearchFeed(String body) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(body);
  } on XmlException {
    throw const FormatException('RSS search response is not valid XML');
  }
  final String root = document.rootElement.name.local;
  if (root != 'rss' && root != 'feed' && root != 'RDF') {
    throw FormatException(
      'RSS search response root must be <rss> or <feed>, '
      'got <$root>',
    );
  }
  final List<RssSearchItem> output = <RssSearchItem>[];
  for (final XmlElement element
      in document.rootElement.descendants.whereType<XmlElement>()) {
    final String local = element.name.local;
    if (local != 'item' && local != 'entry') continue;
    final RssSearchItem? item = _parseItem(element, output.length);
    if (item != null) output.add(item);
  }
  return List<RssSearchItem>.unmodifiable(output);
}

RssSearchItem? _parseItem(XmlElement item, int index) {
  final String title = _childText(item, 'title');
  if (title.isEmpty) return null;

  final Map<String, String> torznab = <String, String>{};
  for (final XmlElement element in item.childElements) {
    if (element.name.local != 'attr') continue;
    final String? name = _attribute(element, 'name')?.toLowerCase();
    final String? value = _attribute(element, 'value');
    if (name != null && value != null && value.isNotEmpty) {
      torznab[name] = value;
    }
  }

  final XmlElement? enclosure = _child(item, 'enclosure');
  final String? enclosureUrl = enclosure == null
      ? null
      : _attribute(enclosure, 'url');
  final String? enclosureType = enclosure == null
      ? null
      : _attribute(enclosure, 'type')?.toLowerCase();
  final String linkText = _childText(item, 'link');
  final String guid = _childText(item, 'guid');
  final List<_AtomLink> atomLinks = <_AtomLink>[
    for (final XmlElement element in item.childElements)
      if (element.name.local == 'link' && _attribute(element, 'href') != null)
        _AtomLink(
          href: _attribute(element, 'href')!,
          rel: (_attribute(element, 'rel') ?? 'alternate').toLowerCase(),
          type: _attribute(element, 'type')?.toLowerCase(),
          length: _attribute(element, 'length'),
        ),
  ];
  final XmlElement? mikanTorrent = _child(item, 'torrent');

  final String? magnet = _firstMagnet(<String?>[
    torznab['magneturl'],
    torznab['magnet'],
    _childText(item, 'magneturl'),
    enclosureUrl,
    linkText,
    guid,
    for (final _AtomLink link in atomLinks) link.href,
    _magnetInText(_childText(item, 'description')),
    _magnetInText(_childText(item, 'content')),
  ]);

  final Uri? torrentUri = magnet != null
      ? null
      : _firstHttpUri(<String?>[
          if (enclosureUrl != null &&
              (enclosureType == null ||
                  enclosureType.contains('bittorrent') ||
                  _looksLikeTorrentFile(enclosureUrl)))
            enclosureUrl,
          if (_looksLikeTorrentFile(linkText)) linkText,
          for (final _AtomLink link in atomLinks)
            if (link.rel == 'enclosure' &&
                (link.type == null ||
                    link.type!.contains('bittorrent') ||
                    _looksLikeTorrentFile(link.href)))
              link.href,
        ]);
  if (magnet == null && torrentUri == null) return null;

  final String? infoHash = _normalizeHash(
    _firstNonEmpty(<String?>[
      magnet == null ? null : parseMagnetInfoHash(magnet),
      _childText(item, 'infoHash'),
      torznab['infohash'],
      torznab['torrenthash'],
      _hexHashIn(torrentUri?.toString()),
      _hexHashIn(enclosureUrl),
      _hexHashIn(linkText),
      _hexHashIn(guid),
      if (mikanTorrent != null) _hexHashIn(_childText(mikanTorrent, 'link')),
    ]),
  );

  final Uri? detailsUri = _firstHttpUri(<String?>[
    if (!_looksLikeTorrentFile(linkText)) linkText,
    guid,
    for (final _AtomLink link in atomLinks)
      if (link.rel == 'alternate') link.href,
    if (mikanTorrent != null) _childText(mikanTorrent, 'link'),
  ], exclude: torrentUri);
  // 私有站 RSS 的链接常带 passkey：带凭据参数的地址不当详情页公开。
  final String? detailsUrl = detailsUri == null
      ? null
      : safePublicDetailsUrl(detailsUri.toString());

  final int? sizeBytes = _firstSize(<int? Function()>[
    () => parseHumanByteSize(_childText(item, 'size')),
    () => int.tryParse(torznab['size'] ?? ''),
    () => mikanTorrent == null
        ? null
        : int.tryParse(_childText(mikanTorrent, 'contentLength')),
    () => _plausibleEnclosureLength(
      enclosure == null ? null : _attribute(enclosure, 'length'),
    ),
    for (final _AtomLink link in atomLinks)
      if (link.rel == 'enclosure') () => _plausibleEnclosureLength(link.length),
  ]);

  final DateTime? publishedAt = _firstDate(<String>[
    _childText(item, 'pubDate'),
    if (mikanTorrent != null) _childText(mikanTorrent, 'pubDate'),
    _childText(item, 'published'),
    _childText(item, 'updated'),
    _childText(item, 'date'),
  ]);

  final String opaqueSeed =
      _firstNonEmpty(<String?>[
        guid,
        _childText(item, 'id'),
        infoHash,
        torrentUri?.toString(),
        magnet,
      ]) ??
      '$title:$index';

  return RssSearchItem(
    title: title,
    remoteId: crypto.sha1.convert(utf8.encode(opaqueSeed)).toString(),
    magnetUri: magnet,
    torrentUri: torrentUri,
    detailsUrl: detailsUrl,
    infoHash: infoHash,
    sizeBytes: sizeBytes,
    seeders: _firstInt(<String?>[
      _childText(item, 'seeders'),
      torznab['seeders'],
    ]),
    leechers: _firstInt(<String?>[
      _childText(item, 'leechers'),
      torznab['peers'],
      torznab['leechers'],
    ]),
    downloads: _firstInt(<String?>[
      _childText(item, 'downloads'),
      torznab['grabs'],
    ]),
    publishedAt: publishedAt,
    category: _firstNonEmpty(<String?>[
      _childText(item, 'categoryId'),
      torznab['category'],
      _childText(item, 'category'),
    ]),
    trusted: _childText(item, 'trusted').toLowerCase() == 'yes',
  );
}

class _AtomLink {
  const _AtomLink({
    required this.href,
    required this.rel,
    this.type,
    this.length,
  });

  final String href;
  final String rel;
  final String? type;
  final String? length;
}

const Map<String, int> _rfc822Months = <String, int>{
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

/// 解析 RSS `pubDate` 的 RFC 822 时间（如 `Fri, 03 Nov 2023 12:30:00 -0000`），
/// 归一到 UTC。纯函数，解析失败返回 null。字母时区（GMT/UT 等）按 0 偏移处理。
DateTime? parseRssPubDate(String raw) {
  final RegExpMatch? m = RegExp(
    r'(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([+-]\d{4}|[A-Za-z]{1,3})?',
  ).firstMatch(raw);
  if (m == null) return null;
  final int? month = _rfc822Months[m.group(2)!.toLowerCase()];
  if (month == null) return null;
  int offsetMinutes = 0;
  final String? zone = m.group(7);
  if (zone != null && RegExp(r'^[+-]\d{4}$').hasMatch(zone)) {
    final int sign = zone.startsWith('-') ? -1 : 1;
    offsetMinutes =
        sign *
        (int.parse(zone.substring(1, 3)) * 60 + int.parse(zone.substring(3)));
  }
  final DateTime utc = DateTime.utc(
    int.parse(m.group(3)!),
    month,
    int.parse(m.group(1)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
    int.parse(m.group(6) ?? '0'),
  );
  return utc.subtract(Duration(minutes: offsetMinutes));
}

/// RFC 822 优先，否则按 ISO 8601（Atom / 蜜柑）解析；不带时区的 ISO 时刻按 UTC
/// 处理（不随运行设备的时区漂移）。都认不出返回 null。
DateTime? parseRssDate(String raw) {
  final String value = raw.trim();
  if (value.isEmpty) return null;
  final DateTime? rfc = parseRssPubDate(value);
  if (rfc != null) return rfc;
  final bool hasZone = RegExp(r'(?:[zZ]|[+-]\d{2}:?\d{2})$').hasMatch(value);
  final DateTime? iso = DateTime.tryParse(hasZone ? value : '${value}Z');
  return iso?.toUtc();
}

/// 人类可读体积（`1.4 GiB` / `700 MB` / `1.2GB` / `980 KiB` / `123 B`）换算字节；
/// 十进制单位（KB/MB/GB/TB）与二进制单位一样按 1024 进位——种子站的 `GB` 绝大多数
/// 就是 GiB。纯数字按字节。认不出返回 null。
int? parseHumanByteSize(String text) {
  final String value = text.trim();
  if (value.isEmpty) return null;
  final int? plain = int.tryParse(value);
  if (plain != null) return plain >= 0 ? plain : null;
  final RegExpMatch? m = RegExp(
    r'^(\d+(?:\.\d+)?)\s*(B|KiB|MiB|GiB|TiB|KB|MB|GB|TB)$',
    caseSensitive: false,
  ).firstMatch(value);
  if (m == null) return null;
  final int exponent = switch (m.group(2)!.toLowerCase()) {
    'b' => 0,
    'kib' || 'kb' => 1,
    'mib' || 'mb' => 2,
    'gib' || 'gb' => 3,
    _ => 4,
  };
  double bytes = double.parse(m.group(1)!);
  for (int i = 0; i < exponent; i++) {
    bytes *= 1024;
  }
  return bytes.round();
}

/// enclosure 的 `length` 按 RSS 规范是「被附文件」的字节数：附的是 `.torrent` 时
/// 那只是种子文件本身（几十 KB），动漫花园给磁链时干脆填 `1`；只有蜜柑把它写成
/// 内容体积。种子文件几乎不会超过 1 MiB、视频资源几乎不会小于它，所以低于 1 MiB
/// 的一律当「不知道」，免得把 40 KB 的种子文件当成资源体积显示。
int? _plausibleEnclosureLength(String? raw) {
  final int? value = int.tryParse(raw?.trim() ?? '');
  return value != null && value >= 1024 * 1024 ? value : null;
}

final RegExp _magnetPattern = RegExp(r'''magnet:\?[^\s"'<>]+''');

String? _magnetInText(String text) {
  final RegExpMatch? match = _magnetPattern.firstMatch(text);
  return match?.group(0)?.replaceAll('&amp;', '&');
}

String? _firstMagnet(Iterable<String?> values) {
  for (final String? value in values) {
    final String trimmed = value?.trim() ?? '';
    if (trimmed.toLowerCase().startsWith('magnet:?')) return trimmed;
  }
  return null;
}

bool _looksLikeTorrentFile(String? raw) {
  final Uri? uri = Uri.tryParse(raw?.trim() ?? '');
  return uri != null && uri.path.toLowerCase().endsWith('.torrent');
}

Uri? _firstHttpUri(Iterable<String?> values, {Uri? exclude}) {
  for (final String? value in values) {
    final Uri? uri = Uri.tryParse(value?.trim() ?? '');
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      continue;
    }
    if (exclude != null && uri == exclude) continue;
    return uri;
  }
  return null;
}

final RegExp _hexHash = RegExp(
  r'(?<![0-9a-fA-F])[0-9a-fA-F]{40}(?![0-9a-fA-F])',
);

String? _hexHashIn(String? text) =>
    text == null ? null : _hexHash.firstMatch(text)?.group(0)?.toLowerCase();

String? _normalizeHash(String? raw) {
  if (raw == null) return null;
  final String value = raw.trim().toLowerCase();
  if (RegExp(r'^[0-9a-f]{40}$').hasMatch(value) ||
      RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    return value;
  }
  return null;
}

int? _firstSize(Iterable<int? Function()> readers) {
  for (final int? Function() read in readers) {
    final int? value = read();
    if (value != null && value > 0) return value;
  }
  return null;
}

DateTime? _firstDate(Iterable<String> values) {
  for (final String value in values) {
    final DateTime? parsed = parseRssDate(value);
    if (parsed != null) return parsed;
  }
  return null;
}

int _firstInt(Iterable<String?> values) {
  for (final String? value in values) {
    final int? parsed = int.tryParse(value?.trim() ?? '');
    if (parsed != null && parsed >= 0) return parsed;
  }
  return 0;
}

XmlElement? _child(XmlElement element, String localName) {
  for (final XmlElement child in element.childElements) {
    if (child.name.local == localName) return child;
  }
  return null;
}

String _childText(XmlElement element, String localName) =>
    _child(element, localName)?.innerText.trim() ?? '';

String? _attribute(XmlElement element, String localName) {
  for (final XmlAttribute attribute in element.attributes) {
    if (attribute.name.local == localName) return attribute.value.trim();
  }
  return null;
}

String? _firstNonEmpty(Iterable<String?> values) {
  for (final String? value in values) {
    if (value != null && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}
