import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 守卫 `strings_zh-CN.i18n.json` 不再出现 GBK→Latin-1 mojibake（BUG-234 / TODO-289）。
///
/// 事故特征：把 GBK 字节按 Latin-1 错误解码后，简体中文会被存成一串
/// Latin-1 Supplement / Latin Extended / spacing-modifier / 组合附加符
/// 的字母（如 `popup_bottom_docked` 曾存成 `µײ¿¹̶¨µ¯´°`）。正常的 zh-CN
/// 文案只用 ASCII、CJK、全角标点、通用标点和极少数符号（· ± → 等），
/// 绝不会出现上述拉丁字母/变音区间。

/// mojibake 才会出现、合法 zh-CN 文案不会出现的字符区间。
/// 注意：U+00B7 MIDDLE DOT(·) 和 U+00B1 PLUS-MINUS(±) 是合法符号，
/// 但它们不是字母/变音符，不落入下列任一区间，无需单独 allowlist。
bool _isMojibakeChar(int codeUnit) {
  // Latin-1 Supplement 字母段（À-ÖØ-öø-ÿ）。
  if (codeUnit >= 0x00C0 && codeUnit <= 0x00FF) return true;
  // Latin Extended-A / Latin Extended-B。
  if (codeUnit >= 0x0100 && codeUnit <= 0x024F) return true;
  // Spacing Modifier Letters（ˆ ˇ ˉ ´ ¨ 等，常见于 GBK 误解码）。
  if (codeUnit >= 0x02B0 && codeUnit <= 0x02FF) return true;
  // Combining Diacritical Marks（̶ ̈ 等游离组合符）。
  if (codeUnit >= 0x0300 && codeUnit <= 0x036F) return true;
  return false;
}

final RegExp _cjk = RegExp(r'[一-鿿]');

/// 展平成 dottedKey -> 叶子字符串值。
Map<String, String> _flattenStrings(
  Map<String, dynamic> map, [
  String prefix = '',
]) {
  final out = <String, String>{};
  for (final entry in map.entries) {
    final full = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
    final value = entry.value;
    if (value is Map) {
      out.addAll(_flattenStrings(value as Map<String, dynamic>, full));
    } else if (value is String) {
      out[full] = value;
    }
  }
  return out;
}

void main() {
  group('zh-CN mojibake guard (BUG-234)', () {
    late Map<String, String> zhStrings;

    setUpAll(() {
      final file = File(
        p.join(
            Directory.current.path, 'lib', 'i18n', 'strings_zh-CN.i18n.json'),
      );
      expect(file.existsSync(), isTrue,
          reason: 'strings_zh-CN.i18n.json 应存在于 ${file.path}');
      zhStrings = _flattenStrings(
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
      );
      expect(zhStrings, isNotEmpty);
    });

    test('no leaf value contains GBK->Latin1 mojibake characters', () {
      final offenders = <String>[];
      for (final entry in zhStrings.entries) {
        final bad = entry.value.runes.where(_isMojibakeChar).toList();
        if (bad.isNotEmpty) {
          final hex = bad
              .take(8)
              .map((c) =>
                  'U+${c.toRadixString(16).toUpperCase().padLeft(4, '0')}')
              .join(' ');
          offenders.add('${entry.key}: [$hex]');
        }
      }
      expect(offenders, isEmpty,
          reason: '以下 zh-CN key 仍含 mojibake 字符，需用正确中文修复：\n'
              '${offenders.join("\n")}');
    });

    test('previously-corrupted keys now contain CJK characters', () {
      const repairedKeys = <String>[
        'backup_export_categories_title',
        'backup_export_categories_hint',
        'backup_category_dictionary',
        'backup_category_books',
        'backup_category_audiobooks',
        'backup_category_fonts',
        'popup_bottom_docked',
        'popup_bottom_docked_hint',
      ];
      for (final key in repairedKeys) {
        expect(zhStrings.containsKey(key), isTrue,
            reason: 'key "$key" 应存在于 zh-CN');
        expect(_cjk.hasMatch(zhStrings[key]!), isTrue,
            reason: 'key "$key" 的 zh-CN 值应含中文字符，实际为：'
                '"${zhStrings[key]}"');
      }
    });

    test('TODO-434 clip export keys use Chinese clip wording', () {
      const clipKeys = <String>[
        'video_clip_export',
        'video_clip_export_start',
        'video_clip_export_stop',
        'video_clip_exporting',
        'video_clip_exported',
        'video_clip_export_failed',
        'video_clip_export_remote_download_required',
        'video_clip_export_invalid_range',
      ];
      final String formerPixelCaptureTerm =
          String.fromCharCodes(<int>[0x5f55, 0x5c4f]);
      for (final key in clipKeys) {
        expect(zhStrings.containsKey(key), isTrue,
            reason: 'key "$key" 应存在于 zh-CN');
        final String value = zhStrings[key]!;
        expect(_cjk.hasMatch(value), isTrue,
            reason: 'key "$key" 的 zh-CN 值应含中文字符，实际为："$value"');
        expect(value.contains(formerPixelCaptureTerm), isFalse,
            reason: 'TODO-434 片段导出文案应保持源片段语义：$key="$value"');
      }
    });
  });
}
