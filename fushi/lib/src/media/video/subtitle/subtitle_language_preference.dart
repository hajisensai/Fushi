/// 自动下字幕时「**优先要哪个语言**」的唯一判据。
///
/// 默认取**视频自身的语言**：日语番取日语轨、韩剧取韩语轨。对一个沉浸学习 app，
/// 这几乎总是用户想要的那一条，而此前的默认是「不限」——实际效果是拿到搜索结果
/// 里排最前的那条，语言随缘。
///
/// ## 两条铁律
///
/// **① 不猜。** 语言无法确定时返回 null，调用方保持原样（= 旧行为）。理由与
/// `content_font_chain.dart` 的「语言未知必须返回空链」同构：猜错比不猜更糟，
/// 而这里猜错的代价是给用户装上一条他看不懂的字幕。**尤其不许硬编码日语**——
/// 本 app 没有全局学习语言这回事。
///
/// **② 是排序，不是过滤。** [rankByPreferredLanguage] 把首选语言的候选排到前面，
/// **不丢弃**其余候选。如果按语言硬过滤，一部只有英文字幕的日语番就会从「有字幕」
/// 倒退成「没字幕」——那是拿一个改进换一个回归。真正的硬过滤只属于用户在设置里
/// **显式**指定的语言（那是他自己说的），由 `VideoSubtitleSearchRequest.languages`
/// 承担。
///
/// ## 语言从哪来
///
/// 内容那一半**直接复用** `resolveContentLanguage`——全仓内容语言的唯一入口
/// （资源手动指定 > 内容自带元数据 > 全局默认）。这里不另造一条链：字体链和字幕
/// 语言链要是各写一遍「先看这个再看那个」，早晚出现「同一个视频，字体按日文渲染、
/// 字幕却下了中文」。
library;

import 'package:fushi/src/models/content_font_chain.dart';

/// BCP-47 / ISO 639 语言标签 → 字幕域比较用的基础语言码（小写两字母为主）。
///
/// 认不出返回 null。输入来自五花八门的上游（TMDB `original_language`、mkv 音轨
/// tag、`VideoBooks.language`、provider 报的字幕语言），不能假设规范化过。
///
/// 与 `detectSubtitleLanguage`（从**文件名**猜）刻意分开：那个的输入是文件名里的
/// 脏 token（`chs` / `简体` / `ja[cc]`），这个的输入是**声明过的语言标签**。两者
/// 产出同一套码，所以结果可以直接比。
String? normalizeSubtitleLanguageCode(String? tag) {
  final String normalized =
      (tag ?? '').trim().toLowerCase().replaceAll('_', '-');
  if (normalized.isEmpty) return null;
  final String base = normalized.split('-').first;
  if (base.isEmpty) return null;
  // ISO 639-2/T、639-2/B 与常见俗写 → 639-1。只列本 app 真会遇到的，
  // 不搬一整张 ISO 表进来：认不出就返回主标签本身，比错映射安全。
  const Map<String, String> aliases = <String, String>{
    'jpn': 'ja',
    'jp': 'ja',
    'kor': 'ko',
    'zho': 'zh',
    'chi': 'zh',
    'cmn': 'zh',
    'yue': 'zh',
    'chs': 'zh',
    'cht': 'zh',
    'eng': 'en',
    'spa': 'es',
    'fra': 'fr',
    'fre': 'fr',
    'deu': 'de',
    'ger': 'de',
    'por': 'pt',
    'rus': 'ru',
    'ita': 'it',
    'nld': 'nl',
    'dut': 'nl',
    'tha': 'th',
    'vie': 'vi',
    'ind': 'id',
    'ara': 'ar',
    'tur': 'tr',
  };
  final String? alias = aliases[base];
  if (alias != null) return alias;
  // 两字母主标签直接用；三字母且不在别名表里也原样返回（比丢弃信息强）。
  return base;
}

/// 解析自动下字幕的**首选语言**；无法确定返回 null（= 不表态，保持旧行为）。
///
/// 优先级（高到低）：
/// 1. [explicitSubtitlePreference]——用户在设置/对话框里**显式**选的字幕语言。
///    他直接就这件事表过态，压过一切推断。
/// 2. 视频的内容语言，走 [resolveContentLanguage]：
///    [videoContentLanguage]（`VideoBooks.language`，用户对本视频手动指定）
///    > [contentMetadataLanguage]（刮削的 `originalLanguage` / 音轨 tag）
///    > [globalDefaultContentLanguage]（设置·外观·排版里的默认内容语言）。
/// 3. 都没有 → null。
String? resolveSubtitleDownloadLanguage({
  String? explicitSubtitlePreference,
  String? videoContentLanguage,
  String? contentMetadataLanguage,
  String? globalDefaultContentLanguage,
}) {
  final String explicit = explicitSubtitlePreference?.trim() ?? '';
  if (explicit.isNotEmpty) return normalizeSubtitleLanguageCode(explicit);
  return normalizeSubtitleLanguageCode(
    resolveContentLanguage(
      explicit: videoContentLanguage,
      metadata: contentMetadataLanguage,
      globalDefault: globalDefaultContentLanguage,
    ),
  );
}

/// 把候选按「[preferred] 语言在前」**稳定**重排；[preferred] 为 null 时原样返回。
///
/// 稳定排序是必需的，不是讲究：候选进来时已经按 provider 优先级 + 下载量排好
/// （`deduplicateVideoSubtitles`），语言只是再加一层**外层**键。不稳定的排序会把
/// 同语言内部那层已有顺序打乱，于是「同一个视频重跑两次自动匹配拿到不同字幕」。
///
/// [languageOf] 返回候选自报的语言（可为空/未知）；内部按
/// [normalizeSubtitleLanguageCode] 归一后比较，所以 `ja-JP` 与 `jpn` 都能对上 `ja`。
List<T> rankByPreferredLanguage<T>(
  List<T> items,
  String? preferred,
  String? Function(T item) languageOf,
) {
  final String? want = normalizeSubtitleLanguageCode(preferred);
  if (want == null || items.length < 2) return items;
  final List<T> matching = <T>[];
  final List<T> others = <T>[];
  for (final T item in items) {
    if (normalizeSubtitleLanguageCode(languageOf(item)) == want) {
      matching.add(item);
    } else {
      others.add(item);
    }
  }
  if (matching.isEmpty) return items;
  return <T>[...matching, ...others];
}
