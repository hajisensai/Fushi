import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 守卫 `stat_format_chars_wan`（阅读统计里 ≥10000 字符的汇总文案）在 **每种语言**
/// 都带上「万」倍率单位（BUG-935 / TODO）。
///
/// 事故特征：阅读统计页把字符数除以 10000 后交给 `stat_format_chars_wan` 补单位，
/// 但 12 种非 CJK 语言（en/de/es/fr/ar/id/it/nl/pt-BR/ru/th/tr/vi）的译文只写了
/// 「$n characters」之类，漏掉了倍率标记 —— 于是 192000 字被渲染成「19.2 characters」
/// 而不是「19.2万 characters」，与图表坐标轴标签（`stat_charts.dart` 里硬编码「$x万」）
/// 不一致。修复方式是在这些语言的译文里补回「万」。CJK 语言各自用 万/萬/만 表达万位。
///
/// 本守卫直接扫源文件（json），防止任一语言再次漏掉倍率单位而回潮。

const String _key = 'stat_format_chars_wan';

/// 各语言允许的「万」倍率标记：简体/日文/英文等用 万，繁体用 萬，韩文用 만。
const List<String> _myriadMarkers = <String>['万', '萬', '만'];

/// 17 个 slang 源文件（相对 `hibiki/` 工作目录）。
const List<String> _localeFiles = <String>[
  'strings.i18n.json', // en（默认）
  'strings_ar.i18n.json',
  'strings_de.i18n.json',
  'strings_es.i18n.json',
  'strings_fr.i18n.json',
  'strings_id.i18n.json',
  'strings_it.i18n.json',
  'strings_ja.i18n.json',
  'strings_ko.i18n.json',
  'strings_nl.i18n.json',
  'strings_pt-BR.i18n.json',
  'strings_ru.i18n.json',
  'strings_th.i18n.json',
  'strings_tr.i18n.json',
  'strings_vi.i18n.json',
  'strings_zh-CN.i18n.json',
  'strings_zh-HK.i18n.json',
];

void main() {
  group('stat_format_chars_wan myriad-unit guard (BUG-935)', () {
    test('every locale keeps the 万/萬/만 multiplier marker', () {
      final List<String> offenders = <String>[];
      for (final String name in _localeFiles) {
        final File file =
            File(p.join(Directory.current.path, 'lib', 'i18n', name));
        expect(file.existsSync(), isTrue, reason: '$name 应存在于 ${file.path}');
        final Map<String, dynamic> json =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        expect(json.containsKey(_key), isTrue, reason: '$name 缺少 key "$_key"');
        final String value = json[_key] as String;
        final bool hasMarker =
            _myriadMarkers.any((String m) => value.contains(m));
        if (!hasMarker) {
          offenders.add('$name: "$value"');
        }
      }
      expect(offenders, isEmpty,
          reason: '以下语言的 "$_key" 漏掉「万」倍率单位（会渲染成「19.2 characters」而非'
              '「19.2万 characters」，与图表坐标轴不一致）：\n${offenders.join("\n")}');
    });
  });
}
