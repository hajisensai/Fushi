/// 发布标题里**明说了**的音轨 / 字幕形态（BUG-3066）。
///
/// `anime_release_descriptor.dart` 刻意不猜音轨语言——标题不写就是不知道。这里只认
/// 标题里明写的两类事实，它们在发布圈的写法相当固定：
///
/// * 配音：`English Dub` / `Dubbed` / `国语` / `國語` / `粤语` / `中配` / `台配`…；
///   同时写了双音轨（`Dual-Audio` / `MULTi` / `国日双语` / `双音轨`）的不算「只有配音」。
/// * 硬字幕：`内嵌` / `內嵌` / `硬字幕` / `HardSub`；中文圈的 `中字` 也是烧进画面的
///   （外挂 / 内封才是软字幕，与 `中字` 同写时按软字幕算）。
///
/// 两条判定都要知道**作品原语言**（`workLanguage`）：「国语」对日本动画是配音，
/// 对国产片就是原音轨；「中字」烧进日本动画是外语硬字幕，烧进国产片就是同语言字幕。
/// 不传作品语言（判不出）时按外语作品判。
///
/// 不写的一律按「原语音 / 无硬字幕」放行：标题没写是常态，判成不合格等于没资源。
library;

final RegExp _dub = RegExp(
  r'(?<![a-z])(?:eng(?:lish)?[ ._-]?)?dub(?:bed|s)?(?![a-z])'
  r'|国语|國語|国配|國配|中配|台配|粤语|粵語|粤配|粵配|普通话|普通話',
  caseSensitive: false,
);

/// 普通话音轨的标记。`国配` / `中配` / `台配` 字面是「中文配音」，对外语片是配音；
/// 对中文作品它们只说明是哪一条中文音轨（港片历来国粤两条都是后期配的）。
final RegExp _mandarinTrack = RegExp(r'^(?:国语|國語|国配|國配|中配|台配|普通话|普通話)$');

/// 粤语音轨的标记。
final RegExp _cantoneseTrack = RegExp(r'^(?:粤语|粵語|粤配|粵配)$');

final RegExp _dualAudio = RegExp(
  r'dual[ ._-]?audio|multi[ ._-]?audio|(?<![a-z])multi(?![a-z])'
  r'|[国國粤粵]日双|日[国國粤粵]双|[国國粤粵]日雙|日[国國粤粵]雙'
  r'|双音轨|雙音軌|多音轨|多音軌',
  caseSensitive: false,
);

final RegExp _hardSubtitle = RegExp(
  r'内嵌|內嵌|硬字幕|hard[ ._-]?sub(?:s|bed)?(?![a-z])',
  caseSensitive: false,
);

final RegExp _softSubtitle = RegExp(r'外挂|外掛|内封|內封');

/// 标题明写的中文字幕（`中字` / `中文字幕` / `简中` / `繁中` / `简体` / `繁体` /
/// `简繁` / `中英` / `简日`…）。
final RegExp _chineseSubtitle = RegExp(
  r'中字|中文字幕|[简簡繁]中|[简簡]体|[简簡]體|繁体|繁體|[简簡]繁|中英|[简簡繁]日',
);

/// 作品语言里的中文变体。
enum _ChineseVariant {
  /// 普通话（`cmn` / `zh-CN` / `zh-TW` / `zh-Hans`…）。
  mandarin,

  /// 粤语（`yue` / `zh-HK` / `zh-MO`，以及 TMDB 用来标粤语片的 `cn`）。
  cantonese,

  /// 只知道是中文（`zh`）。app 里的作品语言码经 `normalizeSubtitleLanguageCode`
  /// 归一后 `yue` 也成了 `zh`、制作国 HK 也判成 `zh`——分不出国语片还是粤语片，
  /// 两条中文音轨都可能是原音，一律不算配音。
  unspecified,
}

/// [code] 是不是中文、哪种中文；不是中文（或没给）返回 null。
_ChineseVariant? _chineseVariantOf(String? code) {
  final String tag = (code ?? '').trim().toLowerCase().replaceAll('_', '-');
  if (tag.isEmpty) return null;
  final List<String> parts = tag.split('-');
  final String base = parts.first;
  final Set<String> subtags = parts.skip(1).toSet();
  if (base == 'yue' || base == 'cn') return _ChineseVariant.cantonese;
  if (base == 'cmn') return _ChineseVariant.mandarin;
  if (base != 'zh' && base != 'zho' && base != 'chi') return null;
  if (subtags.contains('yue') ||
      subtags.contains('hk') ||
      subtags.contains('mo')) {
    return _ChineseVariant.cantonese;
  }
  if (subtags.contains('cmn') ||
      subtags.contains('cn') ||
      subtags.contains('sg') ||
      subtags.contains('tw') ||
      subtags.contains('hans')) {
    return _ChineseVariant.mandarin;
  }
  return _ChineseVariant.unspecified;
}

/// 音轨标记 [marker] 对 [variant] 语言的作品是不是原音轨。
bool _isOriginalTrack(String marker, _ChineseVariant? variant) {
  if (variant == null) return false;
  final bool mandarin = _mandarinTrack.hasMatch(marker);
  final bool cantonese = _cantoneseTrack.hasMatch(marker);
  return switch (variant) {
    _ChineseVariant.mandarin => mandarin,
    _ChineseVariant.cantonese => cantonese,
    _ChineseVariant.unspecified => mandarin || cantonese,
  };
}

/// 标题明写了配音、且没写保留原音轨（双音轨 / 多音轨）。
///
/// [workLanguage] 是作品原语言码：作品自己语言的音轨标记不算配音（国产片的
/// `国语`、粤语片的 `粤语`）；至少有一个配音标记是**别的语言**才算只有配音。
bool releaseIsDubOnly(String title, {String? workLanguage}) {
  if (_dualAudio.hasMatch(title)) return false;
  final _ChineseVariant? variant = _chineseVariantOf(workLanguage);
  return _dub
      .allMatches(title)
      .any((RegExpMatch match) => !_isOriginalTrack(match.group(0)!, variant));
}

/// 标题明写了字幕烧进画面，且烧的不是作品自己的语言。
///
/// [workLanguage] 是中文时，明写了中文字幕的硬字幕（`国语中字` / `内嵌简中`）是
/// 同语言字幕，不算不合格；没写字幕语言的 `内嵌` / `HardSub` 仍按「不知道烧了
/// 什么」处理。
bool releaseHasBurnedInSubtitles(String title, {String? workLanguage}) {
  final bool burned =
      _hardSubtitle.hasMatch(title) ||
      (title.contains('中字') && !_softSubtitle.hasMatch(title));
  if (!burned) return false;
  return !(_chineseVariantOf(workLanguage) != null &&
      _chineseSubtitle.hasMatch(title));
}
