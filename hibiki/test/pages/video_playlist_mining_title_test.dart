import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';

import 'video_hibiki_page_source_corpus.dart';

/// TODO-761（方案 B）：播放列表中的视频制卡，`documentTitle`（渲染到 Anki
/// `{document-title}`）应额外带上播放列表（系列）名，拼成「系列名 - 剧集名」，
/// 老 Anki 卡片模板零改动自动带上系列名。单视频 / 远端视频无系列名，
/// documentTitle 仍是剧集名，向后兼容零变化。
///
/// 纯拼接逻辑下沉到顶层 [composeVideoMiningDocumentTitle]，直接单测（media_kit
/// 整页无法 headless 驱动）；再加源码守卫确认 `_mineVideoCard` 的 documentTitle
/// 确实经该 helper（拼接不被静默改回 `_title`）。
void main() {
  group('composeVideoMiningDocumentTitle（方案 B 拼接）', () {
    test('播放列表 → 「系列名 - 剧集名」', () {
      expect(
        composeVideoMiningDocumentTitle(
          isPlaylist: true,
          playlistTitle: 'コードギアス',
          episodeTitle: '第1話 魔神が生まれた日',
        ),
        'コードギアス - 第1話 魔神が生まれた日',
      );
    });

    test('单视频（非播放列表）→ documentTitle 不变 = 剧集/视频标题（向后兼容）', () {
      // 单视频路径不进 _init 的播放列表分支，_playlistTitle 恒 null，
      // _isPlaylist 恒 false → documentTitle 就是 row.title（此处即 episodeTitle）。
      expect(
        composeVideoMiningDocumentTitle(
          isPlaylist: false,
          playlistTitle: null,
          episodeTitle: '映画 君の名は。',
        ),
        '映画 君の名は。',
      );
    });

    test('远端视频 / 系列名为空 → 退化为剧集名（不留尾随分隔符）', () {
      expect(
        composeVideoMiningDocumentTitle(
          isPlaylist: true,
          playlistTitle: '',
          episodeTitle: 'Episode 3',
        ),
        'Episode 3',
      );
      expect(
        composeVideoMiningDocumentTitle(
          isPlaylist: true,
          playlistTitle: null,
          episodeTitle: 'Episode 3',
        ),
        'Episode 3',
      );
    });

    test('剧集名为空但有系列名 → 只回系列名（不拼空 + 分隔符）', () {
      expect(
        composeVideoMiningDocumentTitle(
          isPlaylist: true,
          playlistTitle: 'シリーズ',
          episodeTitle: null,
        ),
        'シリーズ',
      );
      expect(
        composeVideoMiningDocumentTitle(
          isPlaylist: true,
          playlistTitle: 'シリーズ',
          episodeTitle: '',
        ),
        'シリーズ',
      );
    });

    test('系列名与剧集名相同也照拼（不做去重特例，避免过度设计）', () {
      // 某些无 EXTINF 标题的 m3u8，episode.title 可能 = 文件名 = 系列名。
      // 方案 B 明确不做去重，保持简单直接拼接。
      expect(
        composeVideoMiningDocumentTitle(
          isPlaylist: true,
          playlistTitle: 'clip.mp4',
          episodeTitle: 'clip.mp4',
        ),
        'clip.mp4 - clip.mp4',
      );
    });

    test('单视频 + 非空系列名（不应发生）也按 isPlaylist 闸门退化为剧集名', () {
      // _isPlaylist 为假时即使 playlistTitle 非空也不拼，守住「只播放列表追加」契约。
      expect(
        composeVideoMiningDocumentTitle(
          isPlaylist: false,
          playlistTitle: 'シリーズ',
          episodeTitle: '単発動画',
        ),
        '単発動画',
      );
    });
  });

  group('源码守卫：制卡 documentTitle 经播放列表感知 helper', () {
    late String src;
    setUpAll(() {
      src = readVideoHibikiSource();
    });

    test('_init 播放列表分支记系列名到 _playlistTitle', () {
      expect(src.contains('String? _playlistTitle'), isTrue,
          reason: '需有播放列表系列名成员（方案 B）。');
      // 设值落在 _episodes.isNotEmpty 分支（确认是播放列表后），
      // 紧接其后即剧集索引解析，确保是在播放列表分支内赋值。
      final int branchIdx = src.indexOf('if (_episodes.isNotEmpty) {');
      expect(branchIdx, greaterThanOrEqualTo(0));
      final int setIdx = src.indexOf('_playlistTitle = row.title;', branchIdx);
      final int episodeIdxResolve =
          src.indexOf('row.currentEpisode)', branchIdx);
      expect(setIdx, greaterThan(branchIdx), reason: '系列名须在播放列表分支内赋值。');
      expect(setIdx, lessThan(episodeIdxResolve),
          reason: '系列名赋值须在 idx 解析前的播放列表分支头部。');
    });

    test('_mineVideoCard 的 AnkiMiningContext.documentTitle 经 helper 而非裸 _title',
        () {
      final int ctxIdx = src.indexOf('final AnkiMiningContext miningContext');
      expect(ctxIdx, greaterThanOrEqualTo(0));
      final int ctxEnd = src.indexOf('coverPath: coverPath,', ctxIdx);
      expect(ctxEnd, greaterThan(ctxIdx));
      final String ctx = src.substring(ctxIdx, ctxEnd);
      expect(ctx.contains('documentTitle: _videoMiningDocumentTitle()'), isTrue,
          reason: '制卡 documentTitle 必须经播放列表感知 helper，而非裸 _title。');
      expect(ctx.contains('documentTitle: _title,'), isFalse,
          reason: '不得保留旧的裸 _title 赋值（会绕过系列名拼接）。');
    });

    test('helper 委托顶层纯函数 composeVideoMiningDocumentTitle', () {
      expect(
        src.contains('String? _videoMiningDocumentTitle() =>'
            ' composeVideoMiningDocumentTitle('),
        isTrue,
        reason: 'helper 须委托可单测的顶层纯函数。',
      );
      expect(src.contains('isPlaylist: _isPlaylist'), isTrue);
      expect(src.contains('playlistTitle: _playlistTitle'), isTrue);
      expect(src.contains('episodeTitle: _title'), isTrue);
    });
  });
}
