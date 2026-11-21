/// 用户导入的 BT 站解析规则（[BtSiteFormat.custom] 站点的「格式」）。
///
/// 自动探测只认识几种通用接口（`bt_site_probe.dart`）；论坛式私有站（Kinozal、
/// RuTracker 一类）页面结构各不相同，内置一个站一个解析器既跟不上改版、也不该由
/// Fushi 替用户挑站。所以把「怎么从搜索页里拿出种子」交给一份**可导入、可分享**
/// 的声明式规则：搜索地址模板 + 结果行 CSS 选择器 + 各字段选择器，必要时再到详情
/// 页取磁链 / 种子文件。规则只描述页面结构，**不含登录凭据**——Cookie 是站点配置
/// 的独立字段（[BtSiteConfig.cookie]），分享规则不会把账号带出去。
///
/// JSON 形状（版本 [kBtSiteParserRuleVersion]）：
///
/// ```json
/// {
///   "fushiBtSiteParser": 1,
///   "name": "Example tracker",
///   "encoding": "windows-1251",
///   "search": "/browse.php?s={query}&c={category}",
///   "categories": {"anime": "20", "movie": "1002", "tv": "1001"},
///   "testQuery": "test",
///   "rows": "table.t_peer tr.bg",
///   "fields": {
///     "title": "td.nam a",
///     "details": "td.nam a@href",
///     "size": "td.s",
///     "seeders": "td.sl_s",
///     "leechers": "td.sl_p",
///     "magnet": "a[href^='magnet:']@href",
///     "torrent": "a[href*='download']@href",
///     "infoHash": {"selector": "td.hash", "regex": "([0-9A-Fa-f]{40})"}
///   },
///   "detail": {
///     "magnet": "a[href^='magnet:']@href",
///     "torrent": "a[href*='download.php']@href",
///     "infoHash": {"selector": "li", "regex": "([0-9A-Fa-f]{40})"}
///   }
/// }
/// ```
///
/// * `search`：以 `/` 开头的站内路径模板，必须含 `{query}`；含 `{category}` 时
///   只有 `categories` 里列出的域生效（同 Nyaa 式站点的分类映射）。
/// * 字段选择器两种写法：字符串 `"css"`（取文本）/ `"css@attr"`（取属性），或对象
///   `{"selector", "attr", "regex"}`；`selector` 为空 = 结果行本身；`regex` 有捕获组
///   取第一组，否则取整段匹配。
/// * `title` 必填；每行至少要能走通一条下载路线：行内 `magnet` / `torrent` /
///   `infoHash`，或 `details` + `detail` 段（解析时再进详情页取）。
/// * `encoding`：`utf-8`（默认）/ `windows-1251` / `latin1`；同时决定查询词怎么
///   百分号编码与响应怎么解码。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:html/dom.dart' as html_dom;

import 'package:fushi_engine/media/torrent/bt_site_config.dart'
    show BtSiteDomain;

/// 规则 JSON 的版本标记键与当前版本。
const String kBtSiteParserRuleMarker = 'fushiBtSiteParser';
const int kBtSiteParserRuleVersion = 1;

/// 通用规则模板：app 设置对话框的「怎么写解析规则」与服务端 WebUI 都直接展示 /
/// 填入这一份。只用占位选择器、不对应任何真实站点（所有者 2026-11 拍板：给通用
/// 写法，不维护逐站示例——站点改版就失效）。必须能被 [BtSiteParserRule.fromJson]
/// 解析，`custom_bt_site_test.dart` 守着。
const String kBtSiteParserRuleTemplate = r'''{
  "fushiBtSiteParser": 1,
  "name": "My tracker",
  "encoding": "utf-8",
  "search": "/search?q={query}",
  "testQuery": "test",
  "rows": "table.results tbody tr",
  "fields": {
    "title": "td.title a",
    "details": "td.title a@href",
    "magnet": "a[href^='magnet:']@href",
    "torrent": "a[href$='.torrent']@href",
    "size": "td.size",
    "seeders": "td.seeders",
    "leechers": "td.leechers"
  },
  "detail": {
    "magnet": "a[href^='magnet:']@href",
    "torrent": "a[href*='download']@href"
  }
}''';

/// 规则能服务的媒体域：只有三个视频域（发现页走 Nyaa 式分类，不接自定义规则）。
const Set<BtSiteDomain> kBtSiteParserDomains = <BtSiteDomain>{
  BtSiteDomain.anime,
  BtSiteDomain.movie,
  BtSiteDomain.tv,
};

/// 站点页面编码。
enum BtSiteParserEncoding {
  utf8('utf-8'),
  windows1251('windows-1251'),
  latin1('latin1');

  const BtSiteParserEncoding(this.wire);

  final String wire;

  static BtSiteParserEncoding? fromWire(String? raw) {
    final String value = (raw ?? '').trim().toLowerCase().replaceAll('_', '-');
    return switch (value) {
      'utf-8' || 'utf8' => BtSiteParserEncoding.utf8,
      'windows-1251' ||
      'cp1251' ||
      'win-1251' => BtSiteParserEncoding.windows1251,
      'latin1' || 'latin-1' || 'iso-8859-1' => BtSiteParserEncoding.latin1,
      _ => null,
    };
  }

  /// 解码响应字节（宽松：坏字节换成 U+FFFD，不让一个坏字符拖垮整页）。
  String decode(List<int> bytes) => switch (this) {
    BtSiteParserEncoding.utf8 => const Utf8Decoder(
      allowMalformed: true,
    ).convert(bytes),
    BtSiteParserEncoding.windows1251 => decodeWindows1251(bytes),
    BtSiteParserEncoding.latin1 => const Latin1Decoder(
      allowInvalid: true,
    ).convert(bytes),
  };

  /// 把查询词编码成 query 组件（空格 → `+`，其余非保留字节 `%XX`）。
  String encodeQueryComponent(String value) {
    final List<int> bytes = switch (this) {
      BtSiteParserEncoding.utf8 => const Utf8Encoder().convert(value),
      BtSiteParserEncoding.windows1251 => encodeWindows1251(value),
      BtSiteParserEncoding.latin1 => <int>[
        for (final int rune in value.runes) rune <= 0xFF ? rune : 0x3F,
      ],
    };
    final StringBuffer out = StringBuffer();
    for (final int byte in bytes) {
      if ((byte >= 0x30 && byte <= 0x39) ||
          (byte >= 0x41 && byte <= 0x5A) ||
          (byte >= 0x61 && byte <= 0x7A) ||
          byte == 0x2D ||
          byte == 0x2E ||
          byte == 0x5F ||
          byte == 0x7E) {
        out.writeCharCode(byte);
      } else if (byte == 0x20) {
        out.write('+');
      } else {
        out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }
}

/// windows-1251 的 0x80–0xBF 段（0xC0–0xFF 是连续的 А–я；0x98 未定义）。
const List<int> _cp1251High = <int>[
  0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
  0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
  0xFFFD, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
  0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7,
  0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
  0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7,
  0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
];

/// windows-1251 → 字符串。
String decodeWindows1251(List<int> bytes) {
  final StringBuffer out = StringBuffer();
  for (final int byte in bytes) {
    if (byte < 0x80) {
      out.writeCharCode(byte);
    } else if (byte < 0xC0) {
      out.writeCharCode(_cp1251High[byte - 0x80]);
    } else {
      out.writeCharCode(0x0410 + (byte - 0xC0));
    }
  }
  return out.toString();
}

/// 字符串 → windows-1251；编码不了的字符写 `?`。
Uint8List encodeWindows1251(String value) {
  final List<int> out = <int>[];
  for (final int rune in value.runes) {
    if (rune < 0x80) {
      out.add(rune);
    } else if (rune >= 0x0410 && rune <= 0x044F) {
      out.add(0xC0 + (rune - 0x0410));
    } else {
      final int index = rune == 0xFFFD ? -1 : _cp1251High.indexOf(rune);
      out.add(index >= 0 ? 0x80 + index : 0x3F);
    }
  }
  return Uint8List.fromList(out);
}

final RegExp _attrName = RegExp(r'^[A-Za-z_:][-A-Za-z0-9_:.]*$');

/// 一个字段的取值规则：CSS 选择器（空 = 上下文元素本身）+ 可选属性 + 可选正则。
class BtSiteFieldSelector {
  BtSiteFieldSelector({this.selector = '', this.attr, String? regex})
    : regexSource = (regex == null || regex.isEmpty) ? null : regex,
      _regex = (regex == null || regex.isEmpty) ? null : _compile(regex);

  /// 解析 `"css"` / `"css@attr"` / `{"selector","attr","regex"}`。畸形抛
  /// [FormatException]。
  factory BtSiteFieldSelector.parse(Object? raw, String field) {
    if (raw is String) {
      final String text = raw.trim();
      final int at = text.lastIndexOf('@');
      if (at >= 0 && _attrName.hasMatch(text.substring(at + 1))) {
        return BtSiteFieldSelector(
          selector: text.substring(0, at).trim(),
          attr: text.substring(at + 1),
        );
      }
      if (text.isEmpty) {
        throw FormatException('field "$field" has an empty selector');
      }
      return BtSiteFieldSelector(selector: text);
    }
    if (raw is Map) {
      final Object? selector = raw['selector'];
      final Object? attr = raw['attr'];
      final Object? regex = raw['regex'];
      if ((selector != null && selector is! String) ||
          (attr != null && (attr is! String || !_attrName.hasMatch(attr))) ||
          (regex != null && regex is! String)) {
        throw FormatException('field "$field" is malformed');
      }
      final String css = ((selector as String?) ?? '').trim();
      if (css.isEmpty && attr == null && regex == null) {
        throw FormatException('field "$field" selects nothing');
      }
      return BtSiteFieldSelector(
        selector: css,
        attr: attr as String?,
        regex: regex as String?,
      );
    }
    throw FormatException('field "$field" must be a string or an object');
  }

  static RegExp _compile(String source) {
    try {
      return RegExp(source, caseSensitive: false);
    } on FormatException {
      throw FormatException('invalid regular expression: $source');
    }
  }

  final String selector;
  final String? attr;
  final String? regexSource;
  final RegExp? _regex;

  /// 在 [context] 里取值；取不到（选择器无命中 / 属性缺失 / 正则不匹配 / 空串）
  /// 返回 null。
  String? extract(html_dom.Element context) {
    final html_dom.Element? element = selector.isEmpty
        ? context
        : context.querySelector(selector);
    if (element == null) return null;
    final String? raw = attr == null ? element.text : element.attributes[attr!];
    if (raw == null) return null;
    String value = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    final RegExp? regex = _regex;
    if (regex != null) {
      final RegExpMatch? match = regex.firstMatch(value);
      if (match == null) return null;
      value = (match.groupCount >= 1 ? match.group(1) : match.group(0)) ?? '';
      value = value.trim();
    }
    return value.isEmpty ? null : value;
  }

  /// 校验选择器在 `package:html` 里能用（语法错误在导入时就报，不等到搜索）。
  void validate(String field) {
    if (selector.isEmpty) return;
    try {
      html_dom.Element.tag('div').querySelector(selector);
    } on Object {
      throw FormatException('field "$field" has an invalid CSS selector');
    }
  }

  Object toJson() {
    if (regexSource == null) {
      return attr == null ? selector : '$selector@$attr';
    }
    return <String, Object?>{
      if (selector.isNotEmpty) 'selector': selector,
      if (attr != null) 'attr': attr,
      'regex': regexSource,
    };
  }
}

/// 一份站点解析规则（不可变；构造即校验）。
class BtSiteParserRule {
  BtSiteParserRule({
    required this.searchPath,
    required this.rows,
    required this.title,
    this.name = '',
    this.encoding = BtSiteParserEncoding.utf8,
    Map<BtSiteDomain, String> categories = const <BtSiteDomain, String>{},
    this.testQuery = 'test',
    this.details,
    this.magnet,
    this.torrent,
    this.infoHash,
    this.size,
    this.seeders,
    this.leechers,
    this.detailMagnet,
    this.detailTorrent,
    this.detailInfoHash,
  }) : categories = Map<BtSiteDomain, String>.unmodifiable(categories) {
    if (!searchPath.startsWith('/') || searchPath.startsWith('//')) {
      throw const FormatException(
        '"search" must be a path on the site that starts with "/"',
      );
    }
    if (!searchPath.contains('{query}')) {
      throw const FormatException('"search" must contain {query}');
    }
    if (searchPath.contains('{category}') && categories.isEmpty) {
      throw const FormatException(
        '"search" uses {category} but "categories" is empty',
      );
    }
    for (final BtSiteDomain domain in categories.keys) {
      if (!kBtSiteParserDomains.contains(domain)) {
        throw FormatException(
          'category domain "${domain.name}" is not a '
          'video domain (anime / movie / tv)',
        );
      }
    }
    if (rows.trim().isEmpty) {
      throw const FormatException('"rows" selector is required');
    }
    try {
      html_dom.Element.tag('div').querySelector(rows);
    } on Object {
      throw const FormatException('"rows" is not a valid CSS selector');
    }
    if (testQuery.trim().isEmpty) {
      throw const FormatException('"testQuery" must not be empty');
    }
    final bool rowRoute = magnet != null || torrent != null || infoHash != null;
    final bool detailRoute =
        details != null &&
        (detailMagnet != null ||
            detailTorrent != null ||
            detailInfoHash != null);
    if (!rowRoute && !detailRoute) {
      throw const FormatException(
        'the rule needs a download route: "magnet", "torrent" or "infoHash" '
        'in "fields", or "details" plus a "detail" section',
      );
    }
    for (final (String field, BtSiteFieldSelector? s)
        in <(String, BtSiteFieldSelector?)>[
          ('title', title),
          ('details', details),
          ('magnet', magnet),
          ('torrent', torrent),
          ('infoHash', infoHash),
          ('size', size),
          ('seeders', seeders),
          ('leechers', leechers),
          ('detail.magnet', detailMagnet),
          ('detail.torrent', detailTorrent),
          ('detail.infoHash', detailInfoHash),
        ]) {
      s?.validate(field);
    }
  }

  /// 解析规则 JSON（对象或 JSON 文本）。畸形一律抛 [FormatException]，消息说明
  /// 哪一处不对。
  factory BtSiteParserRule.fromJson(Object? json) {
    Object? decoded = json;
    if (decoded is String) {
      try {
        decoded = jsonDecode(decoded);
      } on FormatException {
        throw const FormatException('the parser rule is not valid JSON');
      }
    }
    if (decoded is! Map) {
      throw const FormatException('the parser rule must be a JSON object');
    }
    final Map<Object?, Object?> map = decoded;
    final Object? version = map[kBtSiteParserRuleMarker];
    if (version is! int) {
      throw const FormatException(
        'missing "$kBtSiteParserRuleMarker" version marker',
      );
    }
    if (version != kBtSiteParserRuleVersion) {
      throw FormatException('unsupported parser rule version $version');
    }
    String requireString(String key) {
      final Object? value = map[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('"$key" is required');
      }
      return value.trim();
    }

    String? optionalString(String key) {
      final Object? value = map[key];
      if (value == null) return null;
      if (value is! String) throw FormatException('"$key" must be a string');
      return value.trim();
    }

    final BtSiteParserEncoding encoding;
    final String? rawEncoding = optionalString('encoding');
    if (rawEncoding == null || rawEncoding.isEmpty) {
      encoding = BtSiteParserEncoding.utf8;
    } else {
      encoding =
          BtSiteParserEncoding.fromWire(rawEncoding) ??
          (throw FormatException('unsupported encoding "$rawEncoding"'));
    }

    final Object? rawCategories = map['categories'];
    final Map<BtSiteDomain, String> categories = <BtSiteDomain, String>{};
    if (rawCategories != null) {
      if (rawCategories is! Map) {
        throw const FormatException('"categories" must be an object');
      }
      for (final MapEntry<Object?, Object?> entry in rawCategories.entries) {
        final BtSiteDomain? domain = BtSiteDomain.fromWire('${entry.key}');
        final Object? value = entry.value;
        if (domain == null) {
          throw FormatException('unknown category domain "${entry.key}"');
        }
        if (value is! String || value.trim().isEmpty) {
          throw FormatException('category "${entry.key}" must be a string');
        }
        categories[domain] = value.trim();
      }
    }

    Map<Object?, Object?> section(String key, {required bool required}) {
      final Object? value = map[key];
      if (value == null) {
        if (required) throw FormatException('"$key" is required');
        return const <Object?, Object?>{};
      }
      if (value is! Map) throw FormatException('"$key" must be an object');
      return value;
    }

    final Map<Object?, Object?> fields = section('fields', required: true);
    final Map<Object?, Object?> detail = section('detail', required: false);
    BtSiteFieldSelector? field(
      Map<Object?, Object?> from,
      String key,
      String label,
    ) => from[key] == null ? null : BtSiteFieldSelector.parse(from[key], label);

    final BtSiteFieldSelector? title = field(fields, 'title', 'title');
    if (title == null) {
      throw const FormatException('"fields.title" is required');
    }

    return BtSiteParserRule(
      name: optionalString('name') ?? '',
      searchPath: requireString('search'),
      encoding: encoding,
      categories: categories,
      testQuery: optionalString('testQuery') ?? 'test',
      rows: requireString('rows'),
      title: title,
      details: field(fields, 'details', 'details'),
      magnet: field(fields, 'magnet', 'magnet'),
      torrent: field(fields, 'torrent', 'torrent'),
      infoHash: field(fields, 'infoHash', 'infoHash'),
      size: field(fields, 'size', 'size'),
      seeders: field(fields, 'seeders', 'seeders'),
      leechers: field(fields, 'leechers', 'leechers'),
      detailMagnet: field(detail, 'magnet', 'detail.magnet'),
      detailTorrent: field(detail, 'torrent', 'detail.torrent'),
      detailInfoHash: field(detail, 'infoHash', 'detail.infoHash'),
    );
  }

  /// 规则自己的名字（分享时便于辨认；站点显示名仍由用户起名 / 主机名决定）。
  final String name;

  /// 站内搜索路径模板（含 `{query}`，可含 `{category}`）。
  final String searchPath;
  final BtSiteParserEncoding encoding;

  /// 媒体域 → 站点分类值（`{category}` 的取值）。
  final Map<BtSiteDomain, String> categories;

  /// 添加时验证规则用的关键词（必须能搜出至少一行）。
  final String testQuery;

  /// 结果行选择器。
  final String rows;

  final BtSiteFieldSelector title;
  final BtSiteFieldSelector? details;
  final BtSiteFieldSelector? magnet;
  final BtSiteFieldSelector? torrent;
  final BtSiteFieldSelector? infoHash;
  final BtSiteFieldSelector? size;
  final BtSiteFieldSelector? seeders;
  final BtSiteFieldSelector? leechers;
  final BtSiteFieldSelector? detailMagnet;
  final BtSiteFieldSelector? detailTorrent;
  final BtSiteFieldSelector? detailInfoHash;

  bool get usesCategory => searchPath.contains('{category}');

  bool get hasDetailRoute =>
      details != null &&
      (detailMagnet != null || detailTorrent != null || detailInfoHash != null);

  /// 这份规则能不能搜 [domain]：必须是视频域；模板含 `{category}` 时还要有映射。
  bool coversDomain(BtSiteDomain domain) =>
      kBtSiteParserDomains.contains(domain) &&
      (!usesCategory || categories.containsKey(domain));

  /// 填好模板的站内路径（含 query 串，已按 [encoding] 编码）。
  String searchPathFor(String query, {BtSiteDomain? domain}) {
    String path = searchPath.replaceAll(
      '{query}',
      encoding.encodeQueryComponent(query),
    );
    if (usesCategory) {
      final String? category = domain == null ? null : categories[domain];
      if (category == null) {
        throw ArgumentError.value(domain, 'domain', 'no category for domain');
      }
      path = path.replaceAll(
        '{category}',
        encoding.encodeQueryComponent(category),
      );
    }
    return path;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    kBtSiteParserRuleMarker: kBtSiteParserRuleVersion,
    if (name.isNotEmpty) 'name': name,
    'encoding': encoding.wire,
    'search': searchPath,
    if (categories.isNotEmpty)
      'categories': <String, String>{
        for (final BtSiteDomain domain in BtSiteDomain.values)
          if (categories[domain] case final String value) domain.name: value,
      },
    if (testQuery != 'test') 'testQuery': testQuery,
    'rows': rows,
    'fields': <String, Object?>{
      'title': title.toJson(),
      if (details != null) 'details': details!.toJson(),
      if (magnet != null) 'magnet': magnet!.toJson(),
      if (torrent != null) 'torrent': torrent!.toJson(),
      if (infoHash != null) 'infoHash': infoHash!.toJson(),
      if (size != null) 'size': size!.toJson(),
      if (seeders != null) 'seeders': seeders!.toJson(),
      if (leechers != null) 'leechers': leechers!.toJson(),
    },
    if (detailMagnet != null || detailTorrent != null || detailInfoHash != null)
      'detail': <String, Object?>{
        if (detailMagnet != null) 'magnet': detailMagnet!.toJson(),
        if (detailTorrent != null) 'torrent': detailTorrent!.toJson(),
        if (detailInfoHash != null) 'infoHash': detailInfoHash!.toJson(),
      },
  };

  /// 便于粘贴 / 分享的缩进 JSON。
  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());
}

/// 「1.37 GB」「700 МБ」「1,4 GiB」「512 KB」→ 字节数；认不出返回 null。
/// 拉丁与西里尔单位都认，一律按 1024 进制（种子站惯例）。
int? parseBtSiteHumanSize(String? raw) {
  if (raw == null) return null;
  final RegExpMatch? match = RegExp(
    r'(\d+(?:[.,]\d+)?)\s*([KkMmGgTtКкМмГгТт])?(?:i)?([BbБб])',
  ).firstMatch(raw.replaceAll(' ', ' '));
  if (match == null) return null;
  final double? number = double.tryParse(match.group(1)!.replaceAll(',', '.'));
  if (number == null) return null;
  final int exponent = switch ((match.group(2) ?? '').toLowerCase()) {
    'k' || 'к' => 1,
    'm' || 'м' => 2,
    'g' || 'г' => 3,
    't' || 'т' => 4,
    _ => 0,
  };
  double bytes = number;
  for (int i = 0; i < exponent; i++) {
    bytes *= 1024;
  }
  return bytes.round();
}

/// 文本里的第一个整数（「12」「Seeders: 1 024」→ 12 / 1024）；没有返回 0。
int parseBtSiteCount(String? raw) {
  if (raw == null) return 0;
  final RegExpMatch? match = RegExp(r'\d[\d  ,]*').firstMatch(raw);
  if (match == null) return 0;
  return int.tryParse(match.group(0)!.replaceAll(RegExp(r'[^\d]'), '')) ?? 0;
}
