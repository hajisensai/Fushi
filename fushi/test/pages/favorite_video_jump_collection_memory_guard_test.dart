import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1067 接线守卫：从收藏夹的视频句子跳转进播放器时，必须解析并透传该视频所属
/// 的主 playlist 合集 id（`playlistCollectionId`）。否则视频初始化时系列级音轨/字幕
/// 调轴记忆分支（video_fushi_page 的 `widget.playlistCollectionId != null` 门，schema
/// v52）被整段跳过，退回读本集 per-book 默认值（音轨 null / 调轴 0），表现为「从收藏
/// 跳转后音轨与调好的字幕轴又被重置」。
///
/// 解析口径必须与书架 `_open`（`collection.id`）、首页 dashboard 续播
/// （`_primaryCollectionByEntry['video|<bookUid>']`）一致，命中同一 collectionId。
///
/// 这是源码扫描守卫（跳转经 Navigator + 平台视频页，widget 层难真触发），盯死接线不回归。
void main() {
  final String src = File('lib/src/pages/implementations/collections_page.dart')
      .readAsStringSync();

  test('_openVideoSentence 解析主合集 id 用统一 key 口径 video|<bookUid>', () {
    expect(
      src,
      contains('getPrimaryCollectionIdByEntry()'),
      reason: '必须用与书架/dashboard 同口径的主合集映射解析归属合集',
    );
    expect(
      src,
      contains('primaryByEntry[MediaKind.video.compositeKey(bookUid)]'),
      reason: 'key 必须是 video|<bookUid>（P5 经 MediaKind.video.compositeKey 生成，'
          '串与 getPrimaryCollectionIdByEntry 的建 key 口径逐字节一致）',
    );
  });

  test('_openVideoSentence 把解析出的 playlistCollectionId 透传进 VideoFushiPage', () {
    // 定位到 _openVideoSentence 里的 neutralized 构造调用段。
    final int openIdx = src.indexOf('Future<void> _openVideoSentence(');
    expect(openIdx, greaterThanOrEqualTo(0), reason: '_openVideoSentence 必须存在');
    final int nextMethodIdx =
        src.indexOf('Future<int?> _resolveVideoFavoriteStartMs(');
    expect(nextMethodIdx, greaterThan(openIdx));
    final String openBody = src.substring(openIdx, nextMethodIdx);
    expect(
      openBody,
      contains('_resolveVideoPlaylistCollectionId('),
      reason: '_openVideoSentence 必须解析所属合集 id',
    );
    expect(
      openBody,
      contains('playlistCollectionId: playlistCollectionId'),
      reason: '必须把解析出的合集 id 透传进 VideoFushiPage.neutralized，否则记忆分支被跳过',
    );
  });
}
