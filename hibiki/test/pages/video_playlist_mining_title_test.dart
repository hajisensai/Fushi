import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';

import '../helpers/source_scan_helpers.dart';
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
      // 必须先剥行注释：否则把 helper 调用降级成注释、生产改回裸 `_title`，
      // 下面的 contains 仍会命中注释里的字面量而假绿。
      src = stripLineComments(readVideoHibikiSource());
    });

    test('_init 播放列表分支记合集名到 _playlistTitle', () {
      expect(src.contains('String? _playlistTitle'), isTrue,
          reason: '需有播放列表系列名成员（方案 B）。');
      // 统一合集 Phase 3：设值落在合集成员 >1（确认是多集播放列表）分支，取 playlist
      // 合集名（col?.name）作系列名。
      final int branchIdx = src.indexOf('if (refs.length > 1) {');
      expect(branchIdx, greaterThanOrEqualTo(0),
          reason: '系列名须在多集（refs.length > 1）分支内赋值。');
      final int setIdx = src.indexOf('_playlistTitle = col?.name;', branchIdx);
      expect(setIdx, greaterThan(branchIdx), reason: '系列名（合集名）须在多集播放列表分支内赋值。');
    });

    test('_mineVideoCard 的 documentTitle 经 helper 而非裸 _title（喂进沉浸引擎请求）', () {
      // TODO-1000: AnkiMiningContext 组装搬进 ImmersionMiningEngine。排队制卡
      // 必须在点击时先冻结 helper 结果，再把该快照喂进请求，不能到出队时重读页面状态。
      final int mineIdx =
          src.indexOf('Future<MinePopupResult> _mineVideoCard({');
      final int mineEnd =
          src.indexOf('Future<void> _recordMinedSentenceForVideo(', mineIdx);
      expect(mineIdx, greaterThanOrEqualTo(0));
      expect(mineEnd, greaterThan(mineIdx));
      final String mine = src.substring(mineIdx, mineEnd);
      expect(
        mine,
        contains(
          'final String? documentTitle = _videoMiningDocumentTitle();',
        ),
        reason: '排队前须冻结播放列表感知标题，防换集后串到下一集',
      );
      final int reqIdx = mine.indexOf('ImmersionMiningRequest(');
      expect(reqIdx, greaterThanOrEqualTo(0));
      final int reqEnd = mine.indexOf('source: AnkiMiningSource.video', reqIdx);
      expect(reqEnd, greaterThan(reqIdx));
      final String req = mine.substring(reqIdx, reqEnd);
      expect(req.contains('documentTitle: documentTitle,'), isTrue,
          reason: '制卡请求必须使用入队前冻结的播放列表感知标题。');
      expect(req.contains('documentTitle: _title,'), isFalse,
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
