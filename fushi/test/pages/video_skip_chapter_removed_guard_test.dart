import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'video_fushi_page_source_corpus.dart';

/// BUG-3218：「跳过片头 / 片尾」按钮按用户决定整条移除（反馈：OP/ED 章节强制
/// 弹按钮、设置里无处关闭、影响看 OP/ED）。按章节名识别片头片尾 + 播放页右下角
/// 跳过按钮这一整条链路不得再回来；章节面板、章节刻度与「下一章」本身保留。
///
/// BUG-3850：作品图谱 L2 换了个名字（声纹识别 + `VideoThemeSongOverlay`）把跳过按钮
/// 带了回来，还加了 OP 期间左上角「♪ 曲名 · 在音乐库打开」角标——上面按符号名钉的
/// 守卫一个都没拦住。两个提示一起删掉；这次再按**用户看得见的文案**钉一层：任何
/// 名字的实现想再画「跳过片头 / 片尾」按钮都得先有这句文案。声纹识别出的 OP / ED
/// 只剩设置里默认关的「自动跳过」与进度条刻度。
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
      final String chrome = File(
        'lib/src/media/video/video_m3e_chrome.dart',
      ).readAsStringSync();
      expect(chrome, isNot(contains('VideoSkipChapterButton')));
    });

    test('shared chapter features stay wired', () {
      expect(src, contains('_buildChapterMarkersOverlay(controller)'));
      expect(src, contains('_buildChapterSidePanel'));
      expect(src, contains('controller.seekToChapter(chapter.index)'));
    });
  });

  group('BUG-3850 theme-song skip button and now-playing pill removed', () {
    final String src = readVideoFushiSource();

    test('video page mounts no theme-song overlay', () {
      expect(src, isNot(contains('VideoThemeSongOverlay')));
      expect(src, isNot(contains('_buildThemeSongOverlay')));
      expect(src, isNot(contains('_skipThemeSong')));
      expect(src, isNot(contains('MusicTrackDetailPage')));
      expect(
        File(
          'lib/src/media/video/theme_song/video_theme_song_overlay.dart',
        ).existsSync(),
        isFalse,
      );
    });

    test('no user-visible "skip intro / credits" or now-playing string', () {
      final Map<String, Object?> en =
          jsonDecode(File('lib/i18n/strings.i18n.json').readAsStringSync())
              as Map<String, Object?>;
      final RegExp skipText = RegExp(
        r'^skip (the )?(intro|opening|ending|credits|outro|op|ed)\b',
        caseSensitive: false,
      );
      // 视频页「♪ 曲名 · 在音乐库打开」角标的文案。
      final RegExp nowPlayingText = RegExp(
        r'open in (the )?music library',
        caseSensitive: false,
      );
      final List<String> offenders = <String>[
        for (final MapEntry<String, Object?> e in en.entries)
          if (e.value is String &&
              (skipText.hasMatch(e.value! as String) ||
                  e.key.startsWith('video_theme_song_') ||
                  (e.key.startsWith('video_') &&
                      nowPlayingText.hasMatch(e.value! as String))))
            e.key,
      ];
      expect(
        offenders,
        isEmpty,
        reason: '跳过片头 / 片尾按钮与视频页曲名角标按用户决定删除（BUG-3218 / BUG-3850）',
      );
    });

    test('opt-in auto skip and progress-bar ticks stay wired', () {
      expect(src, contains('_themeSongTracker'));
      expect(src, contains('_themeSongChapters.value'));
    });
  });
}
