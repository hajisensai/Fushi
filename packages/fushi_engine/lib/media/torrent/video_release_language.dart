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
/// 不写的一律按「原语音 / 无硬字幕」放行：标题没写是常态，判成不合格等于没资源。
library;

final RegExp _dub = RegExp(
  r'(?<![a-z])(?:eng(?:lish)?[ ._-]?)?dub(?:bed|s)?(?![a-z])'
  r'|国语|國語|国配|國配|中配|台配|粤语|粵語|粤配|粵配|普通话|普通話',
  caseSensitive: false,
);

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

/// 标题明写了配音、且没写保留原音轨（双音轨 / 多音轨）。
bool releaseIsDubOnly(String title) =>
    _dub.hasMatch(title) && !_dualAudio.hasMatch(title);

/// 标题明写了字幕烧进画面。
bool releaseHasBurnedInSubtitles(String title) {
  if (_hardSubtitle.hasMatch(title)) return true;
  return title.contains('中字') && !_softSubtitle.hasMatch(title);
}
