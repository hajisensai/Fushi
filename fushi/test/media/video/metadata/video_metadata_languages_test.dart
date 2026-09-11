import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_languages.dart';

void main() {
  group('VideoMetadataLanguages', () {
    test('zh-CN 派生结果与修复前写死的常量逐字相同（中文用户请求端零变化）', () {
      const VideoMetadataLanguages languages = VideoMetadataLanguages('zh-CN');
      expect(languages.primarySubtag, 'zh');
      // 修复前 selectVideoMetadataImages 的默认 languageOrder。
      expect(languages.imageLanguages, <String>['zh', 'en', '']);
      // 修复前 TMDB 请求里 4 处 include_image_language 字面量。
      expect(languages.tmdbIncludeImageLanguage, 'zh,en,null');
    });

    test('资料语言设成 ja 时请求的是日文海报，而不是中文', () {
      // 用户报告的原始路径：video_metadata_locale = ja，标题简介已是日文，
      // 海报却是中文——因为请求端从没要过 ja。
      const VideoMetadataLanguages japanese = VideoMetadataLanguages('ja');
      expect(japanese.primarySubtag, 'ja');
      expect(japanese.imageLanguages, <String>['ja', 'en', '']);
      expect(japanese.tmdbIncludeImageLanguage, 'ja,en,null');
      expect(japanese.tmdbIncludeImageLanguage, isNot(contains('zh')));
    });

    test('非中文语言拿到的是自己的语言，而不是中文', () {
      const VideoMetadataLanguages german = VideoMetadataLanguages('de-DE');
      expect(german.primarySubtag, 'de');
      expect(german.imageLanguages, <String>['de', 'en', '']);
      expect(german.tmdbIncludeImageLanguage, 'de,en,null');
      expect(german.tmdbIncludeImageLanguage, isNot(contains('zh')));
    });

    test('英语用户不会因为「本语言恰好是 en」而丢掉无语言纯图这一档', () {
      const VideoMetadataLanguages english = VideoMetadataLanguages('en-US');
      expect(english.imageLanguages, <String>['en', '']);
      expect(english.tmdbIncludeImageLanguage, 'en,null');
    });

    test('空白 locale 回落到全局兜底，而不是回落到某一种自然语言', () {
      expect(const VideoMetadataLanguages('').normalizedLocale,
          kFallbackVideoMetadataLocale);
      expect(const VideoMetadataLanguages('   ').normalizedLocale,
          kFallbackVideoMetadataLocale);
      expect(kFallbackVideoMetadataLocale, 'en-US');
    });

    test('搜索别名语言：本语言在前，只补 en-US / ja-JP 两个有领域理由的', () {
      expect(const VideoMetadataLanguages('de-DE').searchLocales,
          <String>['de-DE', 'en-US', 'ja-JP']);
      // 此前这个列表尾部无条件追加 zh-CN，非中文用户每次搜索白搭一次请求。
      expect(const VideoMetadataLanguages('de-DE').searchLocales,
          isNot(contains('zh-CN')));
    });

    test('别名语言按查询串的文字扩，而不是按资料语言', () {
      // 资料语言英语 + 中文目录名：TMDB 命中与 language 无关，但响应 title 只
      // 投影成请求的语言。不并入 zh-CN 就只拿到 en/ja 标题，上层 exact gate
      // 比不中，自动应用门不过，整批记识别失败。
      const VideoMetadataLanguages english = VideoMetadataLanguages('en-US');
      expect(english.searchLocalesForQuery('葬送のフリーレン'), contains('zh-CN'),
          reason: '查询串含汉字 → 必须一并请求中文投影');
      expect(english.searchLocalesForQuery('Frieren'), isNot(contains('zh-CN')),
          reason: '纯拉丁查询串没有中文证据，不该白搭一次请求');
    });

    test('日语 ja 与别名表的 ja-JP 整串不等，也不对同一语言请求两次', () {
      final List<String> locales =
          const VideoMetadataLanguages('ja').searchLocales;
      expect(locales.where((String tag) => tag.toLowerCase().startsWith('ja')),
          hasLength(1));
      expect(locales, <String>['ja', 'en-US']);
    });

    test('本语言与兜底语言重合时不重复请求同一种语言', () {
      expect(const VideoMetadataLanguages('en-US').searchLocales,
          <String>['en-US', 'ja-JP']);
      expect(const VideoMetadataLanguages('ja-JP').searchLocales,
          <String>['ja-JP', 'en-US']);
      // 地区不同但主语言相同，同样只请求一次。
      expect(const VideoMetadataLanguages('en-GB').searchLocales,
          <String>['en-GB', 'ja-JP']);
      // 大小写不同也算同一种语言，不该请求两次。
      expect(const VideoMetadataLanguages('EN-us').searchLocales,
          <String>['EN-us', 'ja-JP']);
    });
  });
}
