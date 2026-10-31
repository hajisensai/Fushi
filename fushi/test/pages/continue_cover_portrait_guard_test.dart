import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-1299 守卫：竖版海报封面在「继续 / 继续观看 / 合集详情」三处消费端必须
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

  test('首页「继续」卡：视频/游戏/远端封面走 PortraitCoverImage，横竖跟着图走', () {
    final String source = File(dashboardPath).readAsStringSync();
    expect(
      source,
      isNot(contains('_kContinueVideoCoverWidth')),
      reason:
          '不得回退成按媒体类型写死的视频 16:9 宽度常量：横竖只看实际用到的那张图'
          '（用户 2026-10-14「卡片比例跟着实际用到的图走」，BUG-3360）',
    );
    // 本机 / 远端视频封面与游戏封面的渲染都收在 `_coverImage` 一处
    // （`PortraitCoverImage`，横槽 / 竖槽由探测出的真实宽高比决定）；远端书封面仍是
    // 独立渲染点 `_remoteCover`。守卫分两段：渲染点必须接组件，委托点必须真的委托
    // 过去——否则「某处自己又写一个裸 Image」会绕过守卫。
    for (final String fn in <String>[
      'Widget _coverImage(',
      'Widget _remoteCover(',
    ]) {
      final String body = _stripLineComments(_functionSource(source, fn));
      expect(
        body,
        contains('PortraitCoverImage('),
        reason: '$fn 必须走 PortraitCoverImage 槽向自适应（BUG-1299）',
      );
      expect(
        body,
        isNot(contains('BoxFit.cover')),
        reason: '$fn 不得再用 BoxFit.cover 硬裁——竖版海报会被裁成中间一条',
      );
    }
    for (final (String fn, String delegate) in <(String, String)>[
      ('Widget _localCover(', '_coverImage('),
      ('Widget _gameCover(', '_localCover('),
    ]) {
      final String body = _stripLineComments(_functionSource(source, fn));
      expect(
        body,
        contains(delegate),
        reason:
            '$fn 必须委托给 $delegate（统一来源解析 + 槽向自适应渲染），'
            '不得自己另写一套封面渲染（BUG-1299）',
      );
      // 判据必须用带标识符边界的匹配，不能用裸子串 'Image('：
      // - 裸子串漏掉 `Image.file(` / `Image.memory(` / `Image.network(` /
      //   `Image.asset(`（`Image` 后是 `.` 不是 `(`），而 BUG-1272 的原始回归形态
      //   正是「自己写一条 Image.file(..., fit: BoxFit.cover) 硬编码封面槽特例」；
      // - 裸子串又会误伤 `PortraitCoverImage(`（含子串 `Image(`），把本守卫要求的
      //   正确写法判成违规。两个方向都由 [containsIdentifierCall] 堵上。
      expect(
        containsIdentifierCall(body, 'Image'),
        isFalse,
        reason:
            '$fn 不得绕过 _coverImage 直接构造 Image'
            '（含 Image.file / Image.memory / Image.network / Image.asset）',
      );
    }
    // 视频分支：封面走 `_coverImage`，横竖由同一 provider 的真实宽高比探测决定。
    final String cover = _stripLineComments(
      _functionSource(source, 'Widget _continueCover('),
    );
    expect(cover, contains('_coverImage('));
    expect(containsIdentifierCall(cover, 'Image'), isFalse);
    expect(source, contains('orientationImage: image'));
  });

  test('视频首页横滚行/主卡：封面都走槽向自适应组件（BUG-1299 血缘）', () {
    // 2026-10 首页重设计：横滚行卡**恒竖版 2:3**（不再按封面朝向探测横 / 竖卡，
    // 横图进竖槽由 PortraitCoverImage 垫模糊底）；首屏主卡大图走
    // LandscapeCoverImage（竖版海报回落时模糊垫底、不硬裁）。两者都不得回退到
    // 硬编码 fit 的裸 Image（旧 148×84 横槽让竖版海报两侧露灰带的祖病）。
    final String source = File(videoHomePath).readAsStringSync();
    final String rowCard = _stripLineComments(
      _functionSource(source, 'Widget _buildRowMediaCard('),
    );
    expect(
      rowCard,
      contains('PortraitCoverImage('),
      reason: '横滚行卡封面必须走 PortraitCoverImage 槽向自适应（BUG-1299）',
    );
    expect(
      rowCard,
      contains('videoCoverHeightForPortraitWidth(cardWidth)'),
      reason: '横滚行卡封面区恒 2:3 竖槽：高度由卡宽按竖版换算',
    );
    expect(
      rowCard,
      isNot(contains('landscapeSlot:')),
      reason: '首页行卡统一竖封面（2026-10 重设计），不得再按探测朝向切横槽',
    );
    expect(
      containsIdentifierCall(rowCard, 'Image'),
      isFalse,
      reason: '横滚行卡不得绕过槽向组件直接构造 Image',
    );
    final String heroImage = _stripLineComments(
      _functionSource(source, 'Widget _buildHomeHeroImage('),
    );
    expect(
      heroImage,
      contains('LandscapeCoverImage('),
      reason: '主卡大图必须走 LandscapeCoverImage（竖图回落时模糊垫底，不硬裁）',
    );
    expect(
      containsIdentifierCall(heroImage, 'Image'),
      isFalse,
      reason: '主卡大图不得绕过槽向组件直接构造 Image',
    );
    expect(
      heroImage,
      isNot(contains('BoxFit.cover')),
      reason: '主卡大图不得用 BoxFit.cover 硬裁',
    );
  });

  test('合集详情单集缩略图：走 PortraitCoverImage 横槽自适应', () {
    // 集缩略图的视觉已随共享布局（本地系列 + 媒体服务器详情页同一套）搬到
    // `collectionEpisodeThumb`；页面只负责把该集自己的封面 provider 喂进去。
    // 两段各锁一半：页面必须调共享函数，共享函数必须走 PortraitCoverImage 横槽。
    final String page = _stripLineComments(
      File(collectionDetailPath).readAsStringSync(),
    );
    expect(
      page,
      contains('collectionEpisodeThumb(context, _episodeCover('),
      reason: '本地详情页集缩略图必须消费共享 collectionEpisodeThumb，不得自己再画',
    );
    final String layout = File(
      'lib/src/media/collections/collection_detail_layout.dart',
    ).readAsStringSync();
    final int start = layout.indexOf('Widget collectionEpisodeThumb(');
    final int end = layout.indexOf('Widget collectionEpisodeThumbPlaceholder(');
    expect(start, isNonNegative, reason: 'missing collectionEpisodeThumb');
    expect(end, greaterThan(start));
    final String body = _stripLineComments(layout.substring(start, end));
    expect(
      body,
      contains('PortraitCoverImage('),
      reason: 'collectionEpisodeThumb 必须走 PortraitCoverImage（BUG-1299）',
    );
    expect(
      body,
      contains('landscapeSlot: true'),
      reason:
          'collectionEpisodeThumb 是 16:9 横槽，必须声明 landscapeSlot——否则'
          '竖版海报仍按竖槽语义 cover 硬裁',
    );
    expect(
      body,
      isNot(contains('BoxFit.cover')),
      reason: 'collectionEpisodeThumb 不得再用 BoxFit.cover 硬裁竖版海报',
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
  final int end = next == null
      ? source.length
      : start + startToken.length + next.start + 1;
  return source.substring(start, end);
}

/// 剥掉整行注释（含行内 `//` 到行尾）：断言字面量写进注释不得让守卫假绿。
String _stripLineComments(String source) => maskComments(source);
