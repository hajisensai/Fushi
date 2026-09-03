import 'package:fushi/src/media/video/scraper/title_normalizer.dart';

/// 识别标题全文中的显式季度记号，不负责候选匹配或外部查询。
Set<int> detectVideoSeasonsInText(String rawName) {
  final String text = TitleNormalizer.normalize(rawName);
  final Set<int> seasons = <int>{};
  for (final RegExpMatch match in RegExp(
    '第\\s*([0-9]+|[一二三四五六七八九十])\\s*[季期部]',
  ).allMatches(text)) {
    final String digits = match.group(1)!;
    final int? value = int.tryParse(digits) ?? _cjkDigits[digits];
    if (value != null && value >= 1 && value <= 20) seasons.add(value);
  }
  for (final RegExpMatch match in RegExp(
    r'(?:([0-9]+)\s*(?:st|nd|rd|th)\s+season)|(?:(?:season|part)\s*([0-9]+))',
  ).allMatches(text)) {
    final int? value = int.tryParse(match.group(1) ?? match.group(2) ?? '');
    if (value != null && value >= 1 && value <= 20) seasons.add(value);
  }
  for (final String token in TitleNormalizer.tokens(text)) {
    final int? roman = _romanTokens[token];
    if (roman != null) {
      seasons.add(roman);
      continue;
    }
    final RegExpMatch? match = RegExp(r'^s([0-9]{1,2})$').firstMatch(token);
    if (match == null) continue;
    final int? value = int.tryParse(match.group(1)!);
    if (value != null && value >= 1 && value <= 20) seasons.add(value);
  }
  return seasons;
}

const Map<String, int> _cjkDigits = <String, int>{
  '一': 1,
  '二': 2,
  '三': 3,
  '四': 4,
  '五': 5,
  '六': 6,
  '七': 7,
  '八': 8,
  '九': 9,
  '十': 10,
};

/// 单独的 i / v / x 误报率太高，不作为季度记号。
const Map<String, int> _romanTokens = <String, int>{
  'ⅱ': 2,
  'ⅲ': 3,
  'ⅳ': 4,
  'ⅵ': 6,
  'ⅶ': 7,
  'ⅷ': 8,
  'ⅸ': 9,
  'ii': 2,
  'iii': 3,
  'iv': 4,
  'vi': 6,
  'vii': 7,
  'viii': 8,
  'ix': 9,
};
