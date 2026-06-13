import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-047 part2/3/4 守卫：句子收藏扩展接线不得回归。
/// B=视频端收藏句子按钮（且为句子星标、非 BUG-123 删的单词☆）
/// C=视频页头收藏夹入口 + 图标顺序统一
/// D=收藏夹页展示 video 来源句子
/// E=两统计页有「收藏语句」卡片
void main() {
  String read(String rel) => File(rel).readAsStringSync();

  group('B 视频端收藏句子按钮', () {
    final String src = read(
      'lib/src/pages/implementations/video_hibiki_page.dart',
    );

    test('视频查词浮层 header 渲染句子收藏星标（star/star_border）', () {
      expect(
        src,
        contains('buildPopupHeaderFor'),
        reason: '应覆写 mixin 的 buildPopupHeaderFor 注入句子收藏星标',
      );
      expect(src, contains("Key('video_favorite_sentence_button')"));
      expect(src, contains('Icons.star'));
      expect(src, contains('Icons.star_border'));
    });

    test('收藏句子来源标 video、记 dateKey=今日键', () {
      expect(src, contains('source: kFavoriteSentenceSourceVideo'));
      expect(src, contains('dateKey: statTodayKey()'));
      expect(src, contains('_toggleFavoriteSentenceForVideo'));
    });

    test('视频收藏句写入 cue startMs 锚点并用兼容匹配判定收藏态', () {
      expect(
        src,
        contains('normCharOffset: cue.startMs'),
        reason: '字幕列表收藏必须把 cue.startMs 存入 FavoriteSentence',
      );
      expect(
        src,
        contains('sectionIndex: _currentEpisode'),
        reason: '播放列表收藏必须把 episode index 存进 FavoriteSentence.sectionIndex',
      );
      expect(
        src,
        contains('_matchingVideoFavorites'),
        reason: '收藏态需要同时兼容新 startMs 锚点和旧 text-only 条目',
      );
    });

    test('只在顶层(index==0)显示，嵌套递归层不显示', () {
      final int idx = src.indexOf('Widget? buildPopupHeaderFor(int index)');
      expect(idx, greaterThanOrEqualTo(0));
      final String body = src.substring(idx, idx + 200);
      expect(
        body.contains('if (index != 0) return null'),
        isTrue,
        reason: 'index>0 是递归查词层，不属于某条字幕句',
      );
    });

    test('不恢复 BUG-123 删除的单词收藏☆按钮', () {
      // 句子星标走 FavoriteSentence；不得引入单词收藏 favoriteEntry 弹窗按钮工厂。
      expect(src, isNot(contains('createFavoriteButton')));
    });
  });

  group('B mixin header 钩子默认 null（其它 mixin 使用方零行为变化）', () {
    final String src = read(
      'lib/src/pages/implementations/dictionary_page_mixin.dart',
    );
    test('buildPopupHeaderFor 默认返回 null 并注入 headerWidget', () {
      expect(src, contains('Widget? buildPopupHeaderFor(int index) => null'));
      expect(src, contains('headerWidget: buildPopupHeaderFor(index)'));
    });
  });

  group('C 视频页头收藏夹入口 + 图标顺序统一', () {
    final String src = read(
      'lib/src/pages/implementations/home_video_page.dart',
    );
    test('导入 CollectionsPage 并有 _openCollections', () {
      expect(
        src,
        contains(
          "import 'package:hibiki/src/pages/implementations/collections_page.dart';",
        ),
      );
      expect(src, contains('void _openCollections()'));
      expect(src, contains('CollectionsPage()'));
    });

    test('页头有收藏夹按钮（collections 图标）排在统计前', () {
      expect(src, contains('Icons.collections_bookmark_outlined'));
      expect(src, contains('t.collections'));
      final int collIdx = src.indexOf('Icons.collections_bookmark_outlined');
      final int statIdx = src.indexOf('Icons.bar_chart_outlined');
      expect(collIdx, greaterThanOrEqualTo(0));
      expect(statIdx, greaterThan(collIdx), reason: '图标顺序统一为 收藏夹 → 统计（与书架一致）');
    });
  });

  group('D 收藏夹页展示 video 来源', () {
    final String src = read(
      'lib/src/pages/implementations/collections_page.dart',
    );
    test('_CollectionItem 带 source 并从 fav.source 透传', () {
      expect(src, contains('final String source'));
      expect(src, contains('source: fav.source'));
    });

    test('视频来源句子标注「视频」前缀且跳回视频 startMs（不当书打开）', () {
      expect(src, contains('kFavoriteSentenceSourceVideo'));
      expect(src, contains('isVideoSentence'));
      expect(
        src,
        contains('VideoHibikiPage.neutralized'),
        reason: 'video 来源 bookKey 是视频 uid，应打开视频页而不是 EPUB 阅读器',
      );
      expect(
        src,
        contains('initialCueStartMs: target.startMs'),
        reason: '收藏页必须把视频 cue startMs 传给视频页 seek',
      );
      expect(
        src,
        contains('initialEpisodeIndex: target.episodeIndex'),
        reason: '播放列表收藏页必须把 episode index 传给视频页，避免只靠 bookUid+startMs 打开错集',
      );
      expect(
        src,
        contains('initialSubtitleListVisible: true'),
        reason: '跳回视频后打开字幕列表，让当前 cue 高亮/星标可见',
      );
      expect(
        src,
        contains('_resolveVideoFavoriteStartMs'),
        reason: '旧收藏无 startMs 时要按文本从已保存 cue 里回退解析',
      );
      expect(src, contains('t.nav_video'), reason: '视频来源句子前缀标注');
    });

    test('视频页初始化播放列表时消费收藏页传入的 episode + cue startMs', () {
      final String videoSrc = read(
        'lib/src/pages/implementations/video_hibiki_page.dart',
      );
      expect(videoSrc, contains('final int? initialEpisodeIndex'));
      expect(
        videoSrc,
        contains('widget.initialEpisodeIndex ?? row.currentEpisode'),
        reason: '播放列表打开应优先使用收藏句 episode 锚点，再回退上次播放集',
      );
      expect(
        videoSrc,
        contains('widget.initialCueStartMs ?? _episodes[idx].positionMs'),
        reason: '定位到收藏 episode 后，还要 seek 到该 cue 的 startMs',
      );
    });

    test('播放列表旧收藏无 episode 锚点时保持文本 fallback 但不伪造稳定定位', () {
      expect(
        src,
        contains('resolveVideoFavoriteOpenTarget'),
        reason: '新收藏有 episode 锚点时必须精确定位',
      );
      expect(
        src,
        contains('favoriteSectionIndex == null'),
        reason: '旧收藏缺 episode identity 时只能保留兼容 fallback，不能假装稳定定位到某集',
      );
    });
  });

  group('TODO-310 收藏夹音频播放反馈 + 视频收藏句播放按钮', () {
    final String src = read(
      'lib/src/pages/implementations/collections_page.dart',
    );

    test('① 抽音失败(result==null)弹 audio_clip_failed 提示，不再静默(BUG-252)', () {
      // 修前 _playItemAudio 在 result!=null 时才 playFile，else 什么都不做。
      expect(
        src,
        contains('HibikiToast.show(msg: t.audio_clip_failed)'),
        reason: 'ffmpeg 抽音失败必须给用户可见反馈，否则点了像没反应',
      );
      // 失败提示必须挂在 extractAudioSegment 返回 null 的 else 分支上。
      final int playIdx = src.indexOf('_extractAndPlay({');
      expect(playIdx, greaterThanOrEqualTo(0),
          reason: '抽音+播放+失败提示应收敛到单一 _extractAndPlay 路径');
      final String body = src.substring(playIdx, playIdx + 900);
      expect(body.contains('if (result != null)'), isTrue);
      expect(
        body.contains('} else {') && body.contains('t.audio_clip_failed'),
        isTrue,
        reason: '失败提示必须在 result==null 的 else 分支',
      );
    });

    test('② 视频来源句也能解析音频片段并显示播放按钮', () {
      // _load 增查 VideoBookRepository 填 _videoRowMap。
      expect(src, contains('VideoBookRepository(db)'));
      expect(src, contains('_videoRowMap'));
      expect(src, contains('getByBookUid'));
      // _hasAudio / _playItemAudio 对视频来源走 resolveVideoFavoriteAudioClip。
      expect(src, contains('resolveVideoFavoriteAudioClip'));
      expect(
        src,
        contains('item.source == kFavoriteSentenceSourceVideo'),
        reason: '视频来源句的音频解析路径必须与书内/有声书分开',
      );
      expect(src, contains('_playVideoFavoriteAudio'));
    });

    test('视频抽音复用 cue 时间窗(normCharOffset=startMs / normCharLength=时长)', () {
      // 收藏字段语义：视频收藏句的 normCharOffset 存 cue startMs、normCharLength 存时长。
      expect(src, contains('favoriteStartMs: item.normCharOffset'));
      expect(src, contains('favoriteDurationMs: item.normCharLength'));
      expect(src, contains('favoriteSectionIndex: item.sectionIndex'));
    });
  });

  group('E 两统计页有「收藏语句」卡片', () {
    test('阅读统计页加收藏语句桶（非 video 来源）', () {
      final String src = read(
        'lib/src/pages/implementations/reading_statistics_page.dart',
      );
      expect(src, contains('_favoritedSentences'));
      expect(src, contains('t.stat_favorited_sentence'));
      expect(src, contains('FavoriteSentenceRepository'));
      expect(
        src,
        contains('s.source != kFavoriteSentenceSourceVideo'),
        reason: '书内/有声书/歌词归阅读统计',
      );
      expect(
        src,
        contains('s.dateKey != null'),
        reason: '旧条目无 dateKey 不参与分桶（不崩）',
      );
    });

    test('视频统计页加收藏语句桶（仅 video 来源）', () {
      final String src = read(
        'lib/src/pages/implementations/video_statistics_page.dart',
      );
      expect(src, contains('_favoritedSentences'));
      expect(src, contains('t.stat_favorited_sentence'));
      expect(src, contains('s.source == kFavoriteSentenceSourceVideo'));
      expect(src, contains('s.dateKey != null'));
    });
  });
}
