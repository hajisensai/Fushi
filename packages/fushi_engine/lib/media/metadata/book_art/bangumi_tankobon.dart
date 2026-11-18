/// Bangumi 书籍系列的「单行本」解析（纯函数，无 IO）：系列搜索结果 → 候选，
/// `/v0/subjects/{id}/subjects` 里 `relation == '单行本'` 的条目 → 每卷封面。
///
/// 单行本卷号**不能**用 `parseBookSeriesKey`（它只认结尾卷号）：
/// `ソードアート・オンライン (5) ファントム・バレット`、`キノの旅 XIV -the Beautiful World-`
/// 的卷号在中间。[bangumiTankobonVolume] 先剥掉系列名前缀，再认开头的卷号写法。
library;

import 'dart:convert';

import 'package:fushi_engine/media/metadata/book_art/book_art_matcher.dart';

/// Bangumi 搜索结果里的一个书籍条目（只取系列匹配要用的字段）。
class BangumiBookSubject {
  const BangumiBookSubject({
    required this.id,
    required this.name,
    this.nameCn,
    this.platform,
    this.isSeries = false,
    this.isNsfw = false,
    this.authors = const <String>[],
    this.volumes,
  });

  final int id;
  final String name;
  final String? nameCn;

  /// `漫画` / `小说` / …
  final String? platform;

  /// 系列条目（`series: true`）；否则多半是单卷条目。
  final bool isSeries;
  final bool isNsfw;

  /// infobox 的 作者 / 作画 / 原作（日文原名）。
  final List<String> authors;

  /// infobox / `volumes` 字段给的卷数；0 视为未知。
  final int? volumes;

  /// 作为系列匹配候选。
  BookArtCandidate toCandidate() => BookArtCandidate(
    source: 'bangumi',
    id: '$id',
    displayTitle: name,
    titles: <String>[name, ?nameCn],
    kind: bangumiKind(platform),
    authors: authors,
    finalVolume: volumes,
    isAdult: isNsfw,
  );

  static BangumiBookSubject? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? rawId = json['id'];
    final int? id = rawId is int ? rawId : int.tryParse('$rawId');
    final String? name = _string(json['name']);
    if (id == null || name == null) return null;
    final Object? vols = json['volumes'];
    final int? volumes = vols is int && vols > 0 ? vols : null;
    return BangumiBookSubject(
      id: id,
      name: name,
      nameCn: _string(json['name_cn']),
      platform: _string(json['platform']),
      isSeries: json['series'] == true,
      isNsfw: json['nsfw'] == true,
      authors: _infoboxAuthors(json['infobox']),
      volumes: volumes,
    );
  }
}

/// 解析 Bangumi `/v0/search/subjects` 响应体，**系列条目排在前**（同序稳定）。
///
/// 不先排系列的话，搜「涼宮ハルヒ」会落到单卷条目上，拿不到单行本关联。
List<BangumiBookSubject> parseBangumiBookSearch(String body) {
  final Object? decoded = _decode(body);
  final Object? data = decoded is Map ? decoded['data'] : null;
  final List<BangumiBookSubject> out = <BangumiBookSubject>[
    if (data is List)
      for (final Object? item in data) ?BangumiBookSubject.fromJson(item),
  ];
  return seriesFirst(out, (BangumiBookSubject s) => s.isSeries);
}

/// 稳定地把 [isSeries] 为真的项排到前面。
List<T> seriesFirst<T>(List<T> items, bool Function(T item) isSeries) => <T>[
  ...items.where(isSeries),
  ...items.where((T i) => !isSeries(i)),
];

/// 一本单行本：卷号 + 封面原图。
class BangumiTankobon {
  const BangumiTankobon({
    required this.subjectId,
    required this.name,
    required this.volume,
    required this.coverUrl,
  });

  final int subjectId;
  final String name;
  final num volume;
  final String coverUrl;
}

/// 解析 `/v0/subjects/{id}/subjects`，取 `relation == '单行本'`、卷号认得出、有封面
/// 的条目。同一卷号多条时保留第一条。
List<BangumiTankobon> parseBangumiTankobons(
  String body, {
  required String seriesName,
}) {
  final Object? decoded = _decode(body);
  if (decoded is! List) return const <BangumiTankobon>[];
  final List<BangumiTankobon> out = <BangumiTankobon>[];
  for (final Object? item in decoded) {
    if (item is! Map || item['relation'] != '单行本') continue;
    final String? name = _string(item['name']);
    final Object? rawId = item['id'];
    final int? id = rawId is int ? rawId : int.tryParse('$rawId');
    final Object? images = item['images'];
    final String? large = images is Map ? _string(images['large']) : null;
    if (name == null || id == null || large == null) continue;
    final num? volume = bangumiTankobonVolume(name, seriesName: seriesName);
    if (volume == null) continue;
    if (out.any(
      (BangumiTankobon t) => bookArtHasVolume(<num>[t.volume], volume),
    )) {
      continue;
    }
    out.add(
      BangumiTankobon(
        subjectId: id,
        name: name,
        volume: volume,
        coverUrl: bangumiOriginalImageUrl(large),
      ),
    );
  }
  return out;
}

/// Bangumi 封面 URL → 原图（去掉 `/r/<尺寸>/` 缩放段）。
String bangumiOriginalImageUrl(String url) =>
    url.replaceFirst(RegExp(r'/r/\d+(?:x\d+)?/'), '/');

const Map<String, int> _roman = <String, int>{
  'I': 1,
  'II': 2,
  'III': 3,
  'IV': 4,
  'V': 5,
  'VI': 6,
  'VII': 7,
  'VIII': 8,
  'IX': 9,
  'X': 10,
  'XI': 11,
  'XII': 12,
  'XIII': 13,
  'XIV': 14,
  'XV': 15,
  'XVI': 16,
  'XVII': 17,
  'XVIII': 18,
  'XIX': 19,
  'XX': 20,
};

final RegExp _halfVolume = RegExp(r'[〈<（(【\[]\s*[上中下]\s*[〉>）)】\]]');
final RegExp _leadSeparators = RegExp(r'^[\s:：\-‐―—~〜～・]+');
final RegExp _paren = RegExp(r'^[(（]\s*(\d{1,4}(?:\.\d)?)\s*[)）]');
final RegExp _dai = RegExp(r'^第\s*(\d{1,4}(?:\.\d)?)\s*[巻卷册冊]');
final RegExp _vol = RegExp(
  r'^(?:vol(?:ume)?\.?|ep\.?|#)\s*(\d{1,4}(?:\.\d)?)(?![\d])',
  caseSensitive: false,
);
final RegExp _plain = RegExp(r'^(\d{1,4}(?:\.\d)?)(?![\d.])');
final RegExp _romanLead = RegExp(r'^([IVX]{1,5})(?=$|[\s\-‐―—~〜～:：(（])');

/// 单行本条目名 [name] 的卷号；认不出返回 null。
///
/// 先剥掉系列名 [seriesName]（折宽、不分大小写；名字不以它开头时剥最长公共前缀，
/// 且不切断数字 / 字母），再认开头的 `(N)` / `第N巻` / `N` / `Vol.N` / `Ep.N` /
/// 罗马数字 I–XX。带 `〈上〉〈下〉` 的分册返回 null——那一册不能回落到「同卷号的别的
/// 图」。
num? bangumiTankobonVolume(String name, {required String seriesName}) {
  final String folded = foldBookArtWidth(name).trim();
  if (_halfVolume.hasMatch(folded)) return null;
  final String series = foldBookArtWidth(seriesName).trim();
  String rest = folded.substring(_commonPrefixLength(folded, series));
  rest = rest.replaceFirst(_leadSeparators, '');
  for (final RegExp re in <RegExp>[_paren, _dai, _vol, _plain]) {
    final RegExpMatch? m = re.firstMatch(rest);
    if (m != null) return num.parse(m.group(1)!);
  }
  final RegExpMatch? roman = _romanLead.firstMatch(rest);
  if (roman != null) return _roman[roman.group(1)!];
  return null;
}

int _commonPrefixLength(String a, String b) {
  final String la = a.toLowerCase();
  final String lb = b.toLowerCase();
  int n = 0;
  while (n < la.length && n < lb.length && la[n] == lb[n]) {
    n++;
  }
  // 不切断数字 / 字母（`ONE PIECE (1` 与 `ONE PIECE (10)` 的公共前缀不能吃掉 1）。
  bool word(String c) => RegExp(r'[0-9A-Za-z]').hasMatch(c);
  while (n > 0 && n < a.length && word(a[n - 1]) && word(a[n])) {
    n--;
  }
  return n;
}

List<String> _infoboxAuthors(Object? infobox) {
  if (infobox is! List) return const <String>[];
  final List<String> out = <String>[];
  for (final Object? row in infobox) {
    if (row is! Map) continue;
    final Object? key = row['key'];
    if (key != '作者' && key != '作画' && key != '原作') continue;
    final Object? value = row['value'];
    if (value is String) {
      final String? v = _string(value);
      if (v != null) out.add(v);
    } else if (value is List) {
      for (final Object? v in value) {
        final String? text = v is Map ? _string(v['v']) : _string(v);
        if (text != null) out.add(text);
      }
    }
  }
  return out;
}

Object? _decode(String body) {
  try {
    return jsonDecode(body);
  } on FormatException {
    return null;
  }
}

String? _string(Object? value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
