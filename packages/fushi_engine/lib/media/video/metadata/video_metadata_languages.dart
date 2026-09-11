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
const List<String> kVideoMetadataAliasLocales = <String>['en-US', 'ja-JP'];

/// 按查询串**自身的文字证据**追加的别名语言。
///
/// 为什么不能只按资料语言决定：TMDB 的**命中**与 `language` 无关，但响应里的
/// title 只投影成请求的那一种语言。上层 exact gate 拿查询串去比 title /
/// originalTitle / aliases，而 aliases 只来自这几次投影。于是「资料语言英语 + 库里
/// 中文目录名」的用户会：TMDB 找得到 → 只投影出 en/ja 标题 → exact 集为空 →
/// 自动应用门不过 → 整批记识别失败。
///
/// 所以扩别名的依据是**查询串里有什么字**，不是用户选了什么语言。多一次带
/// cacheKey 的请求，换回来的是自动识别不掉。
const Map<String, String> kVideoMetadataScriptAliasLocales = <String, String>{
  // 汉字（含日文里的汉字，与假名一起出现时由下面的假名判据兜到 ja-JP）。
  r'\p{Script=Han}': 'zh-CN',
  // 假名只可能是日文，命中即并入日语（ja-JP 已在无条件表里，这里是显式冗余，
  // 保留是为了让「为什么日文查询要请求 ja」有据可查）。
  r'[぀-ヿ]': 'ja-JP',
};

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
  String get primarySubtag {
    final String primary =
        normalizedLocale.toLowerCase().split(RegExp(r'[-_]')).first;
    return primary.isEmpty ? kFallbackVideoMetadataLocale : primary;
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
  ///
  /// [query] 非空时按查询串自身的文字追加语言，见
  /// [kVideoMetadataScriptAliasLocales]——资料语言决定不了用户的文件是用什么文字
  /// 命名的。
  List<String> searchLocalesForQuery([String query = '']) {
    final List<String> order = <String>[normalizedLocale];
    void add(String tag) {
      // 去重按**主语言子标签**，不按整 tag：用户设的日语可能是无地区的 `ja`，
      // 与别名表里的 `ja-JP` 整串不等，按整串去重会对同一种语言发两次请求——
      // 正是本文件声讨的那种浪费。
      final String subtag = VideoMetadataLanguages(tag).primarySubtag;
      if (order.every((String value) =>
          VideoMetadataLanguages(value).primarySubtag != subtag)) {
        order.add(tag);
      }
    }

    for (final MapEntry<String, String> entry
        in kVideoMetadataScriptAliasLocales.entries) {
      if (RegExp(entry.key, unicode: true).hasMatch(query)) add(entry.value);
    }
    kVideoMetadataAliasLocales.forEach(add);
    return List<String>.unmodifiable(order);
  }

  /// 不带查询串证据的语言序（详情/分集等非搜索请求）。
  List<String> get searchLocales => searchLocalesForQuery();
}
