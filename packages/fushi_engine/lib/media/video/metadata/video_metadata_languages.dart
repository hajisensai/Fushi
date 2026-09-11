/// 元数据语言族：由「有效资料语言」一次派生出各 provider 需要的全部语言参数。
///
/// 这里是刮削侧语言的唯一真相源。此前 `zh` / `zh-CN` 被当成语言无关代码里的隐含
/// 常量，在三条互不知情的路径上各写死一份：
///
///  1. 请求端 —— TMDB `include_image_language: 'zh,en,null'`（4 处字面量）；
///  2. 选择端 —— `selectVideoMetadataImages` 的 `languageOrder` 默认
///     `['zh','en','']`，而唯一调用点从不传值；
///  3. 配置端 —— `VideoSourceScrapeGlobalConfig.imageLanguages`，声明了却从没被
///     任何地方读过（死字段）。
///
/// 叠加后果不是「默认值不合口味」，而是用户把资料语言设成 `ja` 之后：标题、简介
/// 确实按日语走了（`language` 参数有接线），但**请求时根本没要日文海报**（1 只要
/// zh/en/null），**再被强制选中文图**（2 把 zh 排在最前）。两条路径同时写死，改
/// 任何一条都修不好。所以这里改成「一次推导、各处消费」：语言这件事只有一个可
/// 改的地方。
///
/// `zh-CN` 派生出的请求参数与修复前逐字相同，中文用户请求端零行为变化。
library;

/// 资料语言未知时的最后兜底。
///
/// 不是又一个凭口味挑的常量：app 侧 `AppModel.appLocale` 的末端兜底就是
/// `locales.values.first`，而 `populateLocales()` 的首项正是 `en-US`。刮削侧沿用
/// 同一个兜底，避免两套「默认语言」各自漂移。
const String kFallbackVideoMetadataLocale = 'en-US';

/// TMDB 用字面量 `null` 在 wire 上表示「无语言的纯图」（无文字的海报/背景）。
/// 本仓内部用空串表达同一概念，[VideoMetadataLanguages.tmdbIncludeImageLanguage]
/// 负责这一次转换。
const String kNoLanguageImageTag = '';

/// 搜索时无条件并入的别名语言。
///
/// 这两个是**领域事实**，不是语言默认值：`en-US` 是跨语言通用名，`ja-JP` 是本仓
/// 主要内容（动画）的原名所在。
///
/// 不按查询串的文字再扩（曾有过一张「含汉字就并入 zh-CN」的表）：TMDB 搜索的
/// **命中**与 `language` 无关，而 resolver 的 exact 门在**详情阶段**再判一次
/// （`video_metadata_resolver.dart` `_searchWithProvider`），详情里的 aliases 已含
/// `translations` + `alternative_titles` 全部语言的名字，搜索阶段投影成哪种语言
/// 不影响判定结果。那张表只会让每个用日文/中文目录名的用户每次搜索多发一次请求。
const List<String> kVideoMetadataAliasLocales = <String>['en-US', 'ja-JP'];

/// [kFallbackVideoMetadataLocale] 的主语言子标签；`primarySubtag` 兜底用它，
/// 而不是整个 `en-US` 串——TMDB 的图片语言只认子标签，整串会让它一张图都不返回。
const String _kFallbackPrimarySubtag = 'en';

/// 由一个 BCP-47 资料语言派生出的各 provider 语言参数。
class VideoMetadataLanguages {
  const VideoMetadataLanguages(this.locale);

  /// 有效资料语言（BCP-47，如 `de-DE` / `ja`）。来源级覆盖 > 全局偏好 > 界面语言。
  final String locale;

  /// 归一化后的资料语言；空白回落到 [kFallbackVideoMetadataLocale]。
  String get normalizedLocale {
    final String trimmed = locale.trim();
    return trimmed.isEmpty ? kFallbackVideoMetadataLocale : trimmed;
  }

  /// 主语言子标签（`de-DE` → `de`）。TMDB 的图片语言只认这一级，地区标签会让
  /// 它一张图都不返回。
  ///
  /// 用户手填的 locale 没有格式校验（设置页与来源级覆盖都是裸文本框），`-DE` /
  /// `_cn` 这种首段为空的串取**第一个非空段**；一个非空段都没有才回落
  /// [_kFallbackPrimarySubtag]。
  String get primarySubtag {
    final Iterable<String> parts = normalizedLocale
        .toLowerCase()
        .split(RegExp(r'[-_]+'))
        .where((String part) => part.isNotEmpty);
    return parts.isEmpty ? _kFallbackPrimarySubtag : parts.first;
  }

  /// 图片语言优先序：本语言 → 英文 → 无语言纯图。
  ///
  /// 纯图排在最后而不是被丢弃：没有本语言海报时，一张无文字的图仍比一张外语
  /// 文字的图更可用。英语用户派生出 `['en','']`（去重后只有两项），不会因为
  /// 「本语言恰好是英语」而少一档兜底。
  List<String> get imageLanguages {
    final List<String> order = <String>[];
    for (final String tag in <String>[
      primarySubtag,
      'en',
      kNoLanguageImageTag
    ]) {
      if (!order.contains(tag)) order.add(tag);
    }
    return List<String>.unmodifiable(order);
  }

  /// TMDB `include_image_language` 参数值；无语言在 wire 上写作 `null` 字面量。
  String get tmdbIncludeImageLanguage =>
      imageLanguages.map((String tag) => tag.isEmpty ? 'null' : tag).join(',');

  /// 搜索时一并请求、用于扩别名的语言序（本语言在前，去重）。
  ///
  /// TMDB 的搜索会命中原名 / 译名 / 别名，但响应只把 title 投影成请求的
  /// language。只看一种语言的响应，会把「靠别名命中」的条目误判成不匹配。
  List<String> get searchLocales {
    final List<String> order = <String>[normalizedLocale];
    for (final String tag in kVideoMetadataAliasLocales) {
      // 去重按**主语言子标签**，不按整 tag：用户设的日语可能是无地区的 `ja`，
      // 与别名表里的 `ja-JP` 整串不等，按整串去重会对同一种语言发两次请求——
      // 正是本文件声讨的那种浪费。
      final String subtag = VideoMetadataLanguages(tag).primarySubtag;
      if (order.every((String value) =>
          VideoMetadataLanguages(value).primarySubtag != subtag)) {
        order.add(tag);
      }
    }
    return List<String>.unmodifiable(order);
  }
}
