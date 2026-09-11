import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/source_guard.dart';

// BUG-2454 源码守卫：钉住「刮削语言」这条**接线**的不变式，而不是钉某个具体值。
//
// 为什么需要它：这次修复的根因本身就是「参数声明了却没人传」——
// `VideoSourceScrapeGlobalConfig.imageLanguages` 声明了从没被读过，
// `selectVideoMetadataImages` 的 `languageOrder` 有默认值而唯一调用点从不传值。
// 两者都让「中文优先」在代码里看起来是可配置的，实际写死。单测对着派生类本身
// 全绿也抓不到这种「派生了但没接上」。
//
// 「每个装配点都传了界面语言」这一条**不在这里**：`fromPreferences` 的
// `uiLocaleTag` 已改成必填，漏传是编译错误，比数字面量出现次数可靠。

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
      expect(provider, contains('_languages.tmdbIncludeImageLanguage'),
          reason: 'include_image_language 必须从 language 派生');
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

    test('配置端的 zh-CN 副本已消除，界面语言是必填输入', () {
      final String config =
          _codeOnly('$_engineMetadata/video_source_scrape_config.dart');
      expect(config, isNot(contains('zh-CN')), reason: '全局刮削语言不得再写死任何一种自然语言');
      expect(config, isNot(contains('imageLanguages')),
          reason: '死字段 imageLanguages 已删：声明了没人读的字段比没有字段更坏');
      expect(config, contains('required String uiLocaleTag'),
          reason: '界面语言必填：给默认值 = 让某个装配点漏传时静默退回兜底');
      expect(config, isNot(contains('VideoMetadataLanguages get ')),
          reason: '不得从全局 locale 派生 getter——消费端一律从有效 locale（含来源级覆盖）派生');
    });

    test('设置页的默认值与占位不得写死中文，空值语义是「跟随界面语言」', () {
      final String settings =
          _codeOnly('lib/src/settings/settings_schema_video.dart');
      expect(settings, isNot(contains('zh-CN')));
      expect(settings, contains('t.video_source_scrape_locale_follow_ui'),
          reason: '占位文案必须说明空值 = 跟随界面语言');
      expect(settings, isNot(contains('appLocale.toLanguageTag()')),
          reason: '不得把界面语言的具体串预填进输入框：没动过的框上按回车会把它钉死');
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
