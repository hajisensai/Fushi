import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1123 文案守卫：视频加载失败文案不得把用户指向「书架」。
///
/// `video_load_failed_not_found` 在 `video_hibiki_page.dart` 的 `_init()` 中
/// `repo.getByBookUid` 返回 null（视频条目不在媒体库）时展示。zh-CN 曾写成
/// 「在书架中找不到该条目」——书架是书侧概念，视频侧统一叫「媒体库」
/// （对齐 `section_video_library` = 媒体库）。
/// 本守卫扫 en / zh-CN / zh-HK 的全部 `video_` 前缀 key，钉死视频侧报错
/// 不再出现书架措辞。
Map<String, dynamic> _load(String file) {
  final File f = File('lib/i18n/$file');
  return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  group('BUG-1123 视频报错文案不指向书架', () {
    test('zh-CN：video_load_failed_not_found 指向媒体库而非书架', () {
      final Map<String, dynamic> zh = _load('strings_zh-CN.i18n.json');
      final String v = zh['video_load_failed_not_found'] as String;
      expect(v.contains('媒体库'), isTrue, reason: '视频条目缺失文案必须指向媒体库（视频侧库的统一称呼）');
      expect(v.contains('书架'), isFalse, reason: '视频报错不得把用户指向书侧的「书架」');
    });

    test('en：video_load_failed_not_found 指向 library 而非 bookshelf', () {
      final Map<String, dynamic> en = _load('strings.i18n.json');
      final String v =
          (en['video_load_failed_not_found'] as String).toLowerCase();
      expect(v.contains('library'), isTrue);
      expect(v.contains('bookshelf'), isFalse);
    });

    test('全部 video_ 前缀 key：zh-CN / zh-HK 值不得出现书架/書架', () {
      for (final (String file, String banned) in <(String, String)>[
        ('strings_zh-CN.i18n.json', '书架'),
        ('strings_zh-HK.i18n.json', '書架'),
      ]) {
        final Map<String, dynamic> json = _load(file);
        for (final MapEntry<String, dynamic> entry in json.entries) {
          if (!entry.key.startsWith('video_')) continue;
          final String v = entry.value as String;
          expect(v.contains(banned), isFalse,
              reason: '$file 的 ${entry.key} 不得用书侧的「$banned」描述视频侧');
        }
      }
    });
  });
}
