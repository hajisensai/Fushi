import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-616 守卫：书架 / 历史页的「视频卡」封面必须完整显示（不裁切），与
/// 阶段 C 的视频库页（home_video_page.dart）保持一致；而「书封」（含 SRT /
/// 远端书封）仍按竖版书比例用 fitHeight，不被本次改动连带。
///
/// 背景：reader_history 下所有封面渲染都共享 `_bookCardCoverFit`
/// （[BoxFit.fitHeight]）。视频缩略图是 16:9 横构图，卡槽比它更窄，`fitHeight`
/// 等比铺满高度后宽度溢出被 `ClipRect` 裁掉两侧 —— 横向视频封面显示不完整。
/// 修复新增专用 `_videoCardCoverFit`（[BoxFit.contain]），仅视频封面调用点改用，
/// 书封调用点保持 `_bookCardCoverFit`。
///
/// 视频封面是 UI 渲染，难做像素断言，故用源码扫描守卫：锚定到 `_buildVideoCover`
/// 函数体断言用 `_videoCardCoverFit`、不含裁切类 fit；并断言两个 getter 各自
/// 解析为 contain / fitHeight，防回归。
void main() {
  const String cardWidgetsPath =
      'lib/src/pages/implementations/reader_history/card_widgets.part.dart';
  const String videoPartPath =
      'lib/src/pages/implementations/reader_history/video.part.dart';
  const String booksPartPath =
      'lib/src/pages/implementations/reader_history/books.part.dart';
  const String remotePartPath =
      'lib/src/pages/implementations/reader_history/remote.part.dart';
  const String historyPagePath =
      'lib/src/pages/implementations/reader_hibiki_history_page.dart';

  test('两个封面 fit getter 各自解析为 contain / fitHeight — TODO-616', () {
    final String source = File(cardWidgetsPath).readAsStringSync();

    expect(
      source,
      contains('BoxFit get _videoCardCoverFit => BoxFit.contain;'),
      reason: '视频卡封面 getter 必须是 BoxFit.contain（完整显示不裁切）',
    );
    expect(
      source,
      contains('BoxFit get _bookCardCoverFit => BoxFit.fitHeight;'),
      reason: '书封 getter 必须保持 BoxFit.fitHeight（竖版书封按高度等比，不变）',
    );
  });

  test('视频卡封面用 _videoCardCoverFit（contain），不裁切 — TODO-616', () {
    final String source = File(videoPartPath).readAsStringSync();
    final String body = _functionSource(source, 'Widget _buildVideoCover(');

    expect(
      body,
      contains('fit: _videoCardCoverFit'),
      reason: '_buildVideoCover 必须用 _videoCardCoverFit（contain）让 16:9 '
          '视频封面完整显示',
    );
    expect(
      body,
      isNot(contains('fit: _bookCardCoverFit')),
      reason: '_buildVideoCover 不得再用书封 fit（fitHeight 会裁掉横向视频两侧）',
    );
  });

  test('书封 / SRT / 远端书封 / 媒体卡封仍用 _bookCardCoverFit（fitHeight）— TODO-616', () {
    // SRT / EPUB-有声书封面（books.part.dart 的 _buildFileCover 路径）。
    final String booksSource = File(booksPartPath).readAsStringSync();
    expect(
      booksSource,
      isNot(contains('_videoCardCoverFit')),
      reason: 'books.part.dart（SRT/书封）不得改用视频 contain，竖版书封保持 fitHeight',
    );

    // 远端书封（remote.part.dart 的 _buildRemoteBookCover）。
    final String remoteSource = File(remotePartPath).readAsStringSync();
    final String remoteCover =
        _functionSource(remoteSource, 'Widget _buildRemoteBookCover(');
    expect(
      remoteCover,
      isNot(contains('_videoCardCoverFit')),
      reason: '_buildRemoteBookCover 是远端「书」封，不得改用视频 contain',
    );
    expect(
      RegExp(r'fit: _bookCardCoverFit').allMatches(remoteCover).length,
      2,
      reason: '_buildRemoteBookCover 缓存图与网络图两处都保持 _bookCardCoverFit',
    );

    // 历史媒体卡封面（buildMediaItemContent）。
    final String historySource = File(historyPagePath).readAsStringSync();
    final String mediaContent =
        _functionSource(historySource, 'Widget buildMediaItemContent(');
    expect(
      mediaContent,
      isNot(contains('_videoCardCoverFit')),
      reason: 'buildMediaItemContent 是书/有声书媒体卡封，不得改用视频 contain',
    );
    expect(
      mediaContent,
      contains('fit: _bookCardCoverFit'),
      reason: 'buildMediaItemContent 媒体卡封保持 _bookCardCoverFit',
    );
  });
}

/// 截取从 [startToken] 起到下一个顶层方法定义之前的源码片段。
String _functionSource(String source, String startToken) {
  final int start = source.indexOf(startToken);
  expect(start, isNonNegative, reason: 'missing $startToken');
  final RegExp nextWidget = RegExp(r'\n  Widget [_A-Za-z0-9]+\(');
  final RegExpMatch? next = nextWidget.firstMatch(
    source.substring(start + startToken.length),
  );
  final int end =
      next == null ? source.length : start + startToken.length + next.start + 1;
  return source.substring(start, end);
}
