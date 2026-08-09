import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-766 source guard: the video home page must not reuse the book-worded
/// batch strings (`batch_delete_confirm` / `batch_delete_success` /
/// `batch_tag_added` / `batch_tag_removed`), whose zh-CN copy counts items with
/// the book measure word「本书」. Videos are not books; the confirm dialog read
/// "确定删除 26 本书？" for a video multi-select. The page must call the
/// `*_video` variants instead, and those variants must carry video wording.
void main() {
  final File pageFile = File(
    'lib/src/pages/implementations/home_video_page.dart',
  );

  group('video batch strings use the video measure word (BUG-766)', () {
    test('home_video_page.dart calls the *_video batch keys', () {
      final String source = pageFile.readAsStringSync();

      const List<String> requiredKeys = <String>[
        't.batch_delete_confirm_video(',
        't.batch_delete_success_video(',
        't.batch_tag_added_video(',
        't.batch_tag_removed_video(',
      ];
      for (final String key in requiredKeys) {
        expect(
          source.contains(key),
          isTrue,
          reason: 'video page must call $key',
        );
      }

      // The book-worded variants must not leak back into the video page.
      final RegExp bookKey = RegExp(
        r't\.batch_(delete_confirm|delete_success|tag_added|tag_removed)\(',
      );
      expect(
        bookKey.hasMatch(source),
        isFalse,
        reason: 'video page must not reuse the book-worded batch strings; '
            'use the *_video variants (BUG-766).',
      );
    });

    test('zh-CN video batch strings say 视频, never 本书', () {
      final Map<String, dynamic> zhCn = jsonDecode(
        File('lib/i18n/strings_zh-CN.i18n.json').readAsStringSync(),
      ) as Map<String, dynamic>;

      const List<String> videoKeys = <String>[
        'batch_delete_confirm_video',
        'batch_delete_success_video',
        'batch_tag_added_video',
        'batch_tag_removed_video',
      ];
      for (final String key in videoKeys) {
        final String value = zhCn[key] as String;
        expect(value.contains('视频'), isTrue, reason: '$key must mention 视频');
        expect(
          value.contains('本书'),
          isFalse,
          reason: '$key must not use the book measure word 本书 (BUG-766)',
        );
      }
    });
  });
}
