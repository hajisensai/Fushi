import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 源码守卫：剧集面板条目 `_episodePanelEntries()` 按输入身份 memo，不再每帧对全部
/// N 集重新 new `VideoEpisodeEntry` + 远端封面 provider + 跑 `parsedEpisodeNumberOf`。
///
/// 面板常驻挂在 `_videoWithSubtitlePanel` 的 Stack 里（隐藏态留树做 slide + fade，
/// BUG-1301 的焦点门依赖这个常驻），页面每次 setState 都重建它；远端合集几十集时
/// 每帧几十次正则 + provider 构造，iOS 远端播放卡死的一份账。memo 的正确性前提是
/// 三个输入都**整体替换、从不原地改**——本守卫把前提一起钉住。
void main() {
  late String src;
  late String body;
  setUpAll(() {
    // 注释掩成空白：负向断言（原地改 / _currentEpisode）只看代码，不被注释里的
    // 同名 token 假阳性命中。
    src = maskComments(readVideoFushiSource());
    final int start = src.indexOf(
      'List<VideoEpisodeEntry> _episodePanelEntries() {',
    );
    expect(start, greaterThan(-1), reason: '应保留 _episodePanelEntries');
    final int end = src.indexOf('\n  }', start);
    body = src.substring(start, end);
  });

  test('命中 memo 时直接返回，三个输入按身份比较', () {
    expect(
      body.contains('identical(_episodePanelEntriesEpisodes, _episodes)'),
      isTrue,
      reason: '集表按身份比较',
    );
    expect(
      body.contains('identical(_episodePanelEntriesFetcher, fetcher)'),
      isTrue,
      reason: '远端封面拉取器按身份比较（换 client 后 provider 必须重建）',
    );
    expect(
      body.contains(
        'identical(_episodePanelEntriesImages, _playlistCollectionImages)',
      ),
      isTrue,
      reason: '合集图组按身份比较（回退链换图要重算）',
    );
    expect(
      body.contains('return memo;'),
      isTrue,
      reason: '命中时直接返回缓存列表（同一实例，面板不换 provider）',
    );
    expect(
      body.contains('return _episodePanelEntriesMemo = entries;'),
      isTrue,
      reason: '未命中时重算并写回 memo',
    );
    // memo 写回前要记录三个输入快照，缺一个就是「永远命中」或「永远不命中」。
    for (final String snapshot in <String>[
      '_episodePanelEntriesEpisodes = _episodes;',
      '_episodePanelEntriesFetcher = fetcher;',
      '_episodePanelEntriesImages = _playlistCollectionImages;',
    ]) {
      expect(body.contains(snapshot), isTrue, reason: '应记录快照：$snapshot');
    }
  });

  test('memo 前提：集表与合集图组从不原地改，只整体替换', () {
    final RegExp inPlace = RegExp(
      r'_(episodes|playlistCollectionImages)\.(add|addAll|insert|insertAll|remove|removeAt|removeWhere|removeLast|clear|sort|shuffle|setAll|replaceRange|fillRange)\(',
    );
    expect(
      inPlace.hasMatch(src),
      isFalse,
      reason: '原地改会绕过身份 memo：${inPlace.firstMatch(src)?.group(0)}',
    );
    final RegExp indexAssign = RegExp(
      r'_(episodes|playlistCollectionImages)\[[^\]]+\]\s*=[^=]',
    );
    expect(
      indexAssign.hasMatch(src),
      isFalse,
      reason: '下标赋值同样是原地改：${indexAssign.firstMatch(src)?.group(0)}',
    );
  });

  test('当前集不进 entries：高亮由面板按 currentIndex 单独跟随', () {
    expect(
      body.contains('_currentEpisode'),
      isFalse,
      reason: '把当前集揉进 entries 会让每次换集都失效 memo，且面板已单独接收',
    );
    final int panelAt = src.indexOf(
      'Widget _episodeOverlayPanel(bool visible) {',
    );
    expect(panelAt, greaterThan(-1));
    final String panel = src.substring(panelAt, src.indexOf('\n  }', panelAt));
    expect(panel.contains('episodes: _episodePanelEntries(),'), isTrue);
    expect(panel.contains('currentIndex: _currentEpisode,'), isTrue);
  });
}
