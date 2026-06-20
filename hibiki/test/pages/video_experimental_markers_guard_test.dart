import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：锁定「视频功能已毕业为常驻 tab，移除所有实验性视觉标记」，防回归：
///   1. 设置页不再有「实验性功能」区块里的视频开关（功能不再受开关门控）。
///   2. 底栏视频 tab 图标不带实验性小圆点徽标（视频已是常驻功能）。
///   3. 视频页头下方不再有实验性提示横幅，且 i18n key video_experimental_banner 已删除。
///
/// 用源码扫描而非整页 widget pump：底栏自绘导航 + 视频页都依赖完整 AppModel + DB +
/// HibikiFocusRoot，整页启动成本高且脆弱；这些不变式正是本次需求的精确正面，源码
/// 扫描足以守住（与 video_tags_menu_source_guard_test 同范式）。
String _read(String relative) {
  final File f = File(relative);
  if (!f.existsSync()) {
    throw StateError(
        'missing source: $relative (cwd=${Directory.current.path})');
  }
  return f.readAsStringSync();
}

void main() {
  group('视频功能毕业：设置不再门控', () {
    // TODO-586：实验视频开关若存在只会落在 video 或 system 领域文件，拼两份扫描。
    final String schemaSrc =
        _read('lib/src/settings/settings_schema_video.dart') +
            _read('lib/src/settings/settings_schema_system.dart');

    test('设置 schema 不再有实验视频开关项', () {
      expect(schemaSrc.contains('system.experimental_video'), isFalse,
          reason: '实验视频开关应已从设置中删除（视频改为常驻）');
      expect(schemaSrc.contains('setExperimentalVideoEnabled'), isFalse,
          reason: '不应再调用已删除的 setExperimentalVideoEnabled');
      expect(schemaSrc.contains('t.section_experimental'), isFalse,
          reason: '「实验性功能」设置区块应已删除');
    });
  });

  group('底栏视频 tab 实验性徽标', () {
    final String navSrc =
        _read('lib/src/utils/adaptive/adaptive_navigation.dart');
    final String homeSrc =
        _read('lib/src/pages/implementations/home_page.dart');

    test('AdaptiveNavItem 暴露 experimentalBadge 字段', () {
      expect(navSrc.contains('this.experimentalBadge'), isTrue);
    });

    test('实验性目的地用 MD3 Badge 叠加图标', () {
      // 无 label 的 Badge 即小圆点。Material 与 Cupertino 两路都经 _maybeBadge。
      expect(navSrc.contains('Badge(child: child)'), isTrue,
          reason: '_maybeBadge 应用无 label 的 Badge 渲染小圆点');
      expect(navSrc.contains('_maybeBadge('), isTrue);
    });

    test('视频 tab 导航项不再带实验性小圆点徽标（底栏小红点已移除）', () {
      // 锚定到 HomeTab.video 分支：截取该 case 到下一个 case 之间，确保断言落在
      // 视频项而非别的 tab。用户要求去掉视频底栏小红点。
      final int videoAt = homeSrc.indexOf('case HomeTab.video:');
      expect(videoAt, greaterThan(0), reason: '应有 HomeTab.video 导航项');
      final int nextCaseAt = homeSrc.indexOf('case HomeTab.', videoAt + 10);
      final String videoCase = homeSrc.substring(
          videoAt, nextCaseAt > 0 ? nextCaseAt : homeSrc.length);
      expect(videoCase.contains('experimentalBadge'), isFalse,
          reason: '视频 tab 不应再带实验性徽标（底栏小红点已移除）');
    });
  });

  group('视频页不再有实验性提示横幅', () {
    final String videoSrc =
        _read('lib/src/pages/implementations/home_video_page.dart');
    final String baseI18n = _read('lib/i18n/strings.i18n.json');
    final String zhI18n = _read('lib/i18n/strings_zh-CN.i18n.json');

    test('视频页不再渲染实验性横幅（方法与调用均已删除）', () {
      expect(videoSrc.contains('_buildExperimentalBanner'), isFalse,
          reason: '视频已是常驻功能，实验性横幅方法/调用应已删除');
      expect(videoSrc.contains('video_experimental_banner'), isFalse,
          reason: '视频页不应再引用 video_experimental_banner 文案');
      expect(videoSrc.contains('Icons.science_outlined'), isFalse,
          reason: '实验性烧瓶图标应随横幅一并删除');
    });

    test('i18n key video_experimental_banner 已从源文件删除', () {
      expect(baseI18n.contains('video_experimental_banner'), isFalse,
          reason: '英文源文件不应再有该 key');
      expect(zhI18n.contains('video_experimental_banner'), isFalse,
          reason: '中文源文件不应再有该 key');
    });
  });

  group('视频页页头与书架/词典统一', () {
    final String videoSrc =
        _read('lib/src/pages/implementations/home_video_page.dart');

    test('改用 HibikiPageHeader 大标题，不再用 adaptiveAppBar 小标题', () {
      expect(videoSrc.contains('HibikiPageHeader('), isTrue,
          reason: '标题字号要与书架/词典统一，须用 HibikiPageHeader');
      expect(videoSrc.contains('appBar: adaptiveAppBar('), isFalse,
          reason: '不应再用独立 Scaffold + adaptiveAppBar（小标题）');
    });

    test('动作按钮用 HibikiIconButton（与书架按钮位置/样式统一）', () {
      expect(videoSrc.contains('HibikiIconButton('), isTrue);
      // 旧实现用 Material IconButton(onPressed: ...)；统一后走 HibikiIconButton(onTap:)。
      expect(videoSrc.contains('onTap: _openStatistics'), isTrue);
      expect(videoSrc.contains('onTap: _openImport'), isTrue);
      expect(videoSrc.contains('onPressed: _openStatistics'), isFalse,
          reason: '不应再用裸 Material IconButton(onPressed:) 作页头动作');
      expect(videoSrc.contains('onPressed: _openImport'), isFalse);
    });

    test('用 DesktopContentLayout 约束宽度（与书架 readerShelf 一致）', () {
      expect(videoSrc.contains('DesktopContentLayout('), isTrue);
      expect(videoSrc.contains('DesktopContentKind.readerShelf'), isTrue,
          reason: '桌面内容宽度应与书架统一');
    });

    test('页头仅在非 Cupertino 渲染（与书架/词典同门控）', () {
      expect(
          videoSrc
              .contains('if (!isCupertinoPlatform(context)) _buildPageHeader('),
          isTrue);
    });
  });
}
