import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/source_guard.dart';

// BUG-2454 源码守卫：钉住「刮削语言」这条**接线**，而不是钉某个具体值。
//
// 为什么需要它：这次修复的根因本身就是「参数声明了却没人传」——
// `VideoSourceScrapeGlobalConfig.imageLanguages` 声明了从没被读过，
// `selectVideoMetadataImages` 的 `languageOrder` 有默认值而唯一调用点从不传值。
// 两者都让「中文优先」在代码里看起来是可配置的，实际写死。单测对着派生类本身
// 全绿也抓不到这种「派生了但没接上」。

const String _engineMetadata =
    '../packages/fushi_engine/lib/media/video/metadata';

/// 剥掉注释再判「不得出现 X」：解释这次修复的注释（「此前这里写死 `zh-CN`」）
/// 不能把守卫自己判红——守卫要钉的是**代码里还有没有这个值**。
String _codeOnly(String path) => maskComments(File(path).readAsStringSync());

void main() {
  group('刮削语言接线守卫（BUG-2454）', () {
    test('TMDB 请求端图片语言由 locale 派生，不再有裸 zh 字面量', () {
      final String provider =
          _codeOnly('$_engineMetadata/tmdb_video_metadata_provider.dart');
      expect(provider, isNot(contains("'zh,en,null'")),
          reason: '请求端图片语言必须由 locale 推导');
      expect(provider, isNot(contains("'zh-CN'")),
          reason: '搜索别名语言不得再无条件追加中文（非中文用户每次搜索白搭一次请求）');
      // 四个 TMDB 详情请求（作品 / 季 / 季分集 / 单集）都必须走派生值。
      expect(
        '_languages.tmdbIncludeImageLanguage'.allMatches(provider).length,
        4,
        reason: '作品 / 季详情 / 季分集 / 单集四处 include_image_language 必须同源',
      );
    });

    test('选择端显式传本趟 locale 派生出的语言序，与请求端同源', () {
      final String coordinator =
          _codeOnly('$_engineMetadata/video_source_scrape_coordinator.dart');
      expect(coordinator,
          contains('languageOrder: VideoMetadataLanguages(_locale)'),
          reason: '选择端必须显式传本趟 locale 推导出的语言序，'
              '否则请求回来的图会被另一套语言序重新排一遍');

      final String merge =
          _codeOnly('$_engineMetadata/video_metadata_merge.dart');
      expect(merge, contains('required List<String> languageOrder'),
          reason: 'languageOrder 不得再有默认值——默认值把「忘了接线」伪装成「有意的策略」');
      expect(merge, isNot(contains("'zh'")), reason: '选择端不得再写死任何一种自然语言');
    });

    test('配置端的 zh-CN 副本已消除，默认改为跟随界面语言', () {
      final String config =
          _codeOnly('$_engineMetadata/video_source_scrape_config.dart');
      expect(config, isNot(contains('zh-CN')), reason: '全局刮削语言不得再写死任何一种自然语言');
      expect(config, isNot(contains('imageLanguages')),
          reason: '死字段 imageLanguages 已删：声明了没人读的字段比没有字段更坏');
      expect(config, contains('uiLocaleTag'));

      // 三个真正会发刮削请求的生产装配点都必须把界面语言传下去；漏一处那条
      // 路径就静默退回 en-US 兜底。只查凭据的 video_online_services_preferences
      // 与无头服务端拿不到界面语言，有意不在此列。
      const Map<String, int> wiredCallSites = <String, int>{
        'lib/src/models/app_model.dart': 1,
        'lib/src/pages/implementations/home_page.dart': 2,
      };
      for (final MapEntry<String, int> entry in wiredCallSites.entries) {
        final String source = _codeOnly(entry.key);
        expect(
          'VideoSourceScrapeGlobalConfig.fromPreferences('
              .allMatches(source)
              .length,
          entry.value,
          reason: '${entry.key} 构造点数量变了，本守卫需要跟着更新',
        );
        expect(
          'uiLocaleTag: '.allMatches(source).length,
          entry.value,
          reason: '${entry.key} 每个 fromPreferences 构造点都必须传 uiLocaleTag',
        );
      }
    });

    test('设置页的默认值与 placeholder 不得写死中文，显示的默认值来自界面语言', () {
      final String settings =
          _codeOnly('lib/src/settings/settings_schema_video.dart');
      expect(settings, isNot(contains('zh-CN')));
      expect(settings, contains('appLocale.toLanguageTag()'),
          reason: '设置页显示的默认值必须来自界面语言');
    });

    test('其它 provider 的构造默认语言同样不写死中文', () {
      for (final String path in <String>[
        '$_engineMetadata/anidb_video_metadata_provider.dart',
        'lib/src/media/video/discovery/video_discovery_adapters.dart',
      ]) {
        expect(_codeOnly(path), isNot(contains("language = 'zh-CN'")),
            reason: '$path 的默认语言必须是 kFallbackVideoMetadataLocale');
      }
    });
  });
}
