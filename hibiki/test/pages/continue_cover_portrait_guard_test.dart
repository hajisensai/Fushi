import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1262 守卫：竖版海报封面在「继续 / 继续观看 / 合集详情」三处消费端必须
/// 走 [PortraitCoverImage] 槽向自适应，禁止回退成硬编码 fit 的裸 `Image.file`。
///
/// 根因：刮削会把 2:3 竖版海报写进 `video_books.cover_path`（与 16:9 抽帧同列
/// 无标记），旧实现三处各写各的横版硬槽——`BoxFit.cover` 把海报裁成中间一条、
/// `BoxFit.contain` 留两侧灰带。组件行为本体见
/// `test/widgets/portrait_cover_image_test.dart`；本守卫只锁「三处消费端确实
/// 接上了组件」这条布线，防各写各的回归。
///
/// 断言前剥掉整行注释：防止把断言字面量写进注释造成假绿（守卫变异纪律）。
void main() {
  const String dashboardPath =
      'lib/src/pages/implementations/home_dashboard_page.dart';
  const String videoHomePath =
      'lib/src/pages/implementations/home_video_page.dart';
  const String collectionDetailPath =
      'lib/src/pages/implementations/media_collection_detail_page.dart';

  test('首页「继续」卡：视频/游戏/远端封面走 PortraitCoverImage，无 16:9 宽度特例', () {
    final String source = File(dashboardPath).readAsStringSync();
    expect(
      source,
      isNot(contains('_kContinueVideoCoverWidth')),
      reason: '「继续」卡的视频专属 16:9 宽度特例已消灭（三类条目统一竖版槽），'
          '不得回退（BUG-1262）',
    );
    for (final String fn in <String>[
      'Widget _videoCover(',
      'Widget _gameCover(',
      'Widget _remoteCover(',
    ]) {
      final String body = _stripLineComments(_functionSource(source, fn));
      expect(
        body,
        contains('PortraitCoverImage('),
        reason: '$fn 必须走 PortraitCoverImage 槽向自适应（BUG-1262）',
      );
      expect(
        body,
        isNot(contains('BoxFit.cover')),
        reason: '$fn 不得再用 BoxFit.cover 硬裁——竖版海报会被裁成中间一条',
      );
    }
  });

  test('视频首页「继续观看」hero：本地/远端封面都走 poster 竖版槽', () {
    final String source = File(videoHomePath).readAsStringSync();
    for (final String fn in <String>[
      'Widget _buildContinueHero(',
      'Widget _buildContinueHeroRemote(',
    ]) {
      final String body = _stripLineComments(_functionSource(source, fn));
      expect(
        body,
        contains('poster: true'),
        reason: '$fn 封面必须走 poster 竖版槽路径（PortraitCoverImage 自适应），'
            '旧 148×84 横槽会让竖版海报两侧露灰带（BUG-1262）',
      );
    }
  });

  test('合集详情单集缩略图：走 PortraitCoverImage 横槽自适应', () {
    final String source = File(collectionDetailPath).readAsStringSync();
    final String body =
        _stripLineComments(_functionSource(source, 'Widget _episodeThumb('));
    expect(
      body,
      contains('PortraitCoverImage('),
      reason: '_episodeThumb 必须走 PortraitCoverImage（BUG-1262）',
    );
    expect(
      body,
      contains('landscapeSlot: true'),
      reason: '_episodeThumb 是 16:9 横槽，必须声明 landscapeSlot——否则竖版'
          '海报仍按竖槽语义 cover 硬裁',
    );
    expect(
      body,
      isNot(contains('BoxFit.cover')),
      reason: '_episodeThumb 不得再用 BoxFit.cover 硬裁竖版海报',
    );
  });
}

/// 截取从 [startToken] 起到下一个顶层 `  Widget xxx(` 方法定义之前的源码片段。
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

/// 剥掉整行注释（含行内 `//` 到行尾）：断言字面量写进注释不得让守卫假绿。
String _stripLineComments(String source) {
  return source
      .split('\n')
      .map((String line) => line.replaceFirst(RegExp(r'//.*$'), ''))
      .join('\n');
}
