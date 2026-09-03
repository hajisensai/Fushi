/// 视频元数据国家字段的**展示映射**。
///
/// 模型层的 `countries` 混着两个值域：TMDB `production_countries` 给英文全称
/// （United States of America），`origin_country` / AniList `countryOfOrigin`
/// 给 ISO 3166-1 alpha-2 代码（US、JP）。发现页 region 过滤依赖代码存在
/// （`video_discovery_service.dart` 的 `_canonicalRegion` 匹配），所以模型层
/// 刻意不去重；展示层只呈现一个值域——有全称时全称优先，纯代码列表原样保留，
/// 避免「United States of America · US」这种同一国家双词条堆叠。
library;

final RegExp _isoAlpha2 = RegExp(r'^[A-Za-z]{2}$');

/// 把模型层国家列表映射为展示用列表：去空白、去重复；当列表中存在
/// 全称（非两字母代码）时丢弃所有裸 alpha-2 代码，否则保留代码本身。
List<String> formatVideoCountriesForDisplay(Iterable<String> countries) {
  final Set<String> seen = <String>{};
  final List<String> unique = <String>[
    for (final String country in countries)
      if (country.trim() case final String value
          when value.isNotEmpty && seen.add(value))
        value,
  ];
  final bool hasFullName =
      unique.any((String value) => !_isoAlpha2.hasMatch(value));
  if (!hasFullName) return unique;
  return <String>[
    for (final String value in unique)
      if (!_isoAlpha2.hasMatch(value)) value,
  ];
}
