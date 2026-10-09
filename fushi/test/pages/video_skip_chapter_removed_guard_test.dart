import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'video_fushi_page_source_corpus.dart';

/// BUG-3218：「跳过片头 / 片尾」按钮按用户决定整条移除（反馈：OP/ED 章节强制
/// 弹按钮、设置里无处关闭、影响看 OP/ED）。按章节名识别片头片尾 + 播放页右下角
/// 跳过按钮这一整条链路不得再回来；章节面板、章节刻度与「下一章」本身保留。
void main() {
  group('BUG-3218 skip opening/ending chapter feature removed', () {
    final String src = readVideoFushiSource();

    test('video page no longer mounts a skip-chapter button', () {
      expect(src, isNot(contains('_buildSkipChapterButton')));
      expect(src, isNot(contains('VideoSkipChapterButton')));
      expect(src, isNot(contains('videoSkippableChapterKind')));
      expect(src, isNot(contains('video_chapter_skip.dart')));
    });

    test('chapter-title opening/ending classifier is gone', () {
      expect(
        File('lib/src/media/video/video_chapter_skip.dart').existsSync(),
        isFalse,
      );
      final String chrome =
          File('lib/src/media/video/video_m3e_chrome.dart').readAsStringSync();
      expect(chrome, isNot(contains('VideoSkipChapterButton')));
    });

    test('shared chapter features stay wired', () {
      expect(src, contains('_buildChapterMarkersOverlay(controller)'));
      expect(src, contains('_buildChapterSidePanel'));
      expect(src, contains('controller.seekToChapter(chapter.index)'));
    });
  });
}
