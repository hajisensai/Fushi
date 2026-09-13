import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart';
import 'package:path/path.dart' as p;

/// 守卫统计页大数缩写的**进制按语言选**（承接 BUG-935，替换原
/// `stat_chars_wan_unit_guard_test.dart`）。
///
/// 事故演进：
///  - 一期（原始 bug）：阅读统计把字符数除以 10000 后交给 `stat_format_chars_wan`
///    补单位，13 种非 CJK 译文只写了「$n characters」漏掉倍率标记，于是 192000 字
///    渲染成「19.2 characters」。
///  - 二期（原修复留下的病根，本轮修的就是它）：当时的修法是把「万」**补进那 13
///    种语言的译文**，于是英文界面显示「6.8万 characters」——这个数对英文读者既不
///    是 68000 也不是任何可读写法，等于把中文数量级当成了通用缩写。
///
/// 现在倍率分组由 [formatCompactCount] 按语言决定（语言属性，不是可翻译文案），
/// i18n 词条只留「$n characters」模板。本守卫因此钉两条：
///  1. 行为：CJK 走万进制并带各自单位，非 CJK 走千进制 K/M —— 除数与单位必须配套
///     （这正是一期与二期各自失败的地方）。
///  2. 回潮：非 CJK 语言的 json 里不得再出现 万/萬/만 —— 二期的修法会在这里变红。
const List<String> _myriadMarkers = <String>['万', '萬', '만'];

/// 13 个非 CJK slang 源文件（相对 `fushi/` 工作目录）。ja / ko / zh-CN / zh-HK
/// 刻意不在此列——它们的译文本来就可以出现这些字。
const List<String> _nonCjkLocaleFiles = <String>[
  'strings.i18n.json', // en（默认）
  'strings_ar.i18n.json',
  'strings_de.i18n.json',
  'strings_es.i18n.json',
  'strings_fr.i18n.json',
  'strings_id.i18n.json',
  'strings_it.i18n.json',
  'strings_nl.i18n.json',
  'strings_pt-BR.i18n.json',
  'strings_ru.i18n.json',
  'strings_th.i18n.json',
  'strings_tr.i18n.json',
  'strings_vi.i18n.json',
];

const List<String> _allLocaleFiles = <String>[
  ..._nonCjkLocaleFiles,
  'strings_ja.i18n.json',
  'strings_ko.i18n.json',
  'strings_zh-CN.i18n.json',
  'strings_zh-HK.i18n.json',
];

Map<String, dynamic> _readLocale(String name) {
  final File file = File(p.join(Directory.current.path, 'lib', 'i18n', name));
  expect(file.existsSync(), isTrue, reason: '$name 应存在于 ${file.path}');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  group('formatCompactCount：进制按语言选（BUG-935 二期）', () {
    test('CJK 走万进制，单位随书写系统', () {
      // 68000 = 6.8 万。除数与单位配套，这是一期失败的点。
      expect(formatCompactCount(68000, 'zh-CN'), '6.8万');
      expect(formatCompactCount(68000, 'ja'), '6.8万');
      expect(formatCompactCount(68000, 'ko'), '6.8만');
      expect(formatCompactCount(68000, 'zh-HK'), '6.8萬');
      // 整万不留多余的 .0。
      expect(formatCompactCount(240000, 'zh-CN'), '24万');
    });

    test('非 CJK 走千进制 K/M，且绝不出现万倍率标记', () {
      // 二期的病根：英文显示「6.8万」。68000 对英文读者是 68K。
      expect(formatCompactCount(68000, 'en'), '68K');
      expect(formatCompactCount(173000, 'en'), '173K');
      expect(formatCompactCount(1200000, 'fr'), '1.2M');
      for (final String tag in <String>['en', 'de', 'ru', 'ar', 'th', 'vi']) {
        final String out = formatCompactCount(68000, tag);
        for (final String marker in _myriadMarkers) {
          expect(out.contains(marker), isFalse,
              reason: '$tag 的缩写「$out」不该带万倍率标记「$marker」');
        }
      }
    });

    test('不足一万所有语言都显示原值（同一张卡不会一半缩写一半不缩写）', () {
      for (final String tag in <String>['en', 'zh-CN', 'ja', 'ko']) {
        expect(formatCompactCount(1645, tag), '1645');
        expect(formatCompactCount(9999, tag), '9999');
        expect(formatCompactCount(0, tag), '0');
      }
    });

    test('语言标签带地区/脚本后缀仍认得出书写系统', () {
      expect(formatCompactCount(68000, 'zh-Hant-TW'), '6.8萬');
      expect(formatCompactCount(68000, 'zh-Hans-CN'), '6.8万');
      expect(formatCompactCount(68000, 'ja-JP'), '6.8万');
      expect(formatCompactCount(68000, 'en-US'), '68K');
    });
  });

  group('i18n 词条不得再承载倍率单位', () {
    test('非 CJK 语言的译文里没有 万/萬/만（防二期修法回潮）', () {
      final List<String> offenders = <String>[];
      for (final String name in _nonCjkLocaleFiles) {
        final Map<String, dynamic> json = _readLocale(name);
        json.forEach((String key, dynamic value) {
          if (value is! String) return;
          for (final String marker in _myriadMarkers) {
            if (value.contains(marker)) {
              offenders.add('$name / $key: "$value"');
            }
          }
        });
      }
      expect(offenders, isEmpty,
          reason: '倍率分组是语言属性、由 formatCompactCount 决定，不该写进译文'
              '（写进去就会让英文等界面显示「6.8万 characters」）：\n'
              '${offenders.join("\n")}');
    });

    test('已退役的 stat_format_chars_wan 键在所有语言都不存在', () {
      for (final String name in _allLocaleFiles) {
        expect(_readLocale(name).containsKey('stat_format_chars_wan'), isFalse,
            reason: '$name 仍留着已退役的 stat_format_chars_wan 键');
      }
    });

    test(r'stat_format_chars 模板在所有语言都在且带 $n 占位', () {
      for (final String name in _allLocaleFiles) {
        final Map<String, dynamic> json = _readLocale(name);
        expect(json.containsKey('stat_format_chars'), isTrue,
            reason: '$name 缺少 key "stat_format_chars"');
        expect((json['stat_format_chars'] as String).contains(r'$n'), isTrue,
            reason: '$name 的 stat_format_chars 丢了 \$n 占位符');
      }
    });
  });
}
