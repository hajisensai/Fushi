/// 打开视频时**自动挑字幕**用的「目标语言」：基础语言码 + 中文书写系统（繁 / 简）。
///
/// 自动挑字幕有两条路：同目录外挂字幕（`video_sidecar.dart` 的 [pickSidecar] 系列）
/// 与内封轨（`loadDefaultTextEmbeddedSubtitleCues`）。两条路此前各认一套语言：外挂
/// 恒按日语（`JapaneseLanguage` 硬编码，BUG 见 docs/bugs），内封不看语言、取第一条
/// 文本轨。本文件是两条路共用的唯一判据：
///
/// * 目标语言从哪来：[resolveSubtitleLanguageTarget]，与自动下字幕同一条链（显式
///   字幕语言 > 本视频语言 > 刮削原语言 > 全局默认内容语言），只是**保留书写系统**
///   ——`zh-Hant` 的视频要挑繁体字幕，而下载链只需要 `zh`。
/// * 一条候选算不算目标语言：[matchSubtitleTarget]。中文分三档：书写系统对上 >
///   没标书写系统 > 书写系统相反（同一种语言，读得懂，排最后但仍可用）。
///
/// 语言未知时一律返回 null，**不猜**——尤其不许兜底成日语（本 app 没有全局学习语言）。
library;

import 'package:fushi_engine/media/video/subtitle/subtitle_language_preference.dart'
    show normalizeSubtitleLanguageCode, trackPreferenceLanguageCode;
import 'package:fushi_engine/media/video/video_subtitle_source.dart'
    show SubtitleSource;
import 'package:fushi_engine/models/content_language.dart';

/// 中文书写系统。
enum ChineseScript { simplified, traditional }

/// 字幕自动加载的目标语言。[script] 只对中文（[code] == `zh`）有意义，null = 不限。
final class SubtitleLanguageTarget {
  const SubtitleLanguageTarget(this.code, {this.script});

  /// 基础语言码（[normalizeSubtitleLanguageCode] 的值域：`ja` / `zh` / `en` …）。
  final String code;

  /// 中文的书写系统；非中文恒 null。
  final ChineseScript? script;

  /// 解析一个语言标签（`ja-JP` / `zh-Hant` / `zh_TW` / `cht` / `yue` …）；认不出返回 null。
  static SubtitleLanguageTarget? parse(String? tag) {
    final String? code =
        subtitleTokenLanguageCode(tag) ?? normalizeSubtitleLanguageCode(tag);
    if (code == null) return null;
    return SubtitleLanguageTarget(
      code,
      script: code == 'zh' ? chineseScriptOfLanguageTag(tag) : null,
    );
  }

  /// 规范标签：`ja`、`zh`、`zh-Hant`、`zh-Hans`。可原样再 [parse] 回来，也是合法的
  /// sidecar 语言标记（`<stem>.zh-Hant.srt`）。
  String get tag => switch (script) {
    null => code,
    ChineseScript.traditional => '$code-Hant',
    ChineseScript.simplified => '$code-Hans',
  };

  @override
  bool operator ==(Object other) =>
      other is SubtitleLanguageTarget &&
      other.code == code &&
      other.script == script;

  @override
  int get hashCode => Object.hash(code, script);

  @override
  String toString() => 'SubtitleLanguageTarget($tag)';
}

/// 字幕域里**单独一个词**就能表明繁 / 简的写法（文件名语言标记、轨标题里的词）。
/// 键已小写。
const Map<String, ChineseScript> _chineseScriptWords = <String, ChineseScript>{
  'cht': ChineseScript.traditional,
  'tc': ChineseScript.traditional,
  'zht': ChineseScript.traditional,
  'big5': ChineseScript.traditional,
  'hant': ChineseScript.traditional,
  'trad': ChineseScript.traditional,
  'traditional': ChineseScript.traditional,
  'taiwan': ChineseScript.traditional,
  'hongkong': ChineseScript.traditional,
  '繁': ChineseScript.traditional,
  '繁體': ChineseScript.traditional,
  '繁体': ChineseScript.traditional,
  '繁中': ChineseScript.traditional,
  '正體': ChineseScript.traditional,
  'chs': ChineseScript.simplified,
  'sc': ChineseScript.simplified,
  'zhs': ChineseScript.simplified,
  'gb': ChineseScript.simplified,
  'gbk': ChineseScript.simplified,
  'hans': ChineseScript.simplified,
  'simp': ChineseScript.simplified,
  'simplified': ChineseScript.simplified,
  '简': ChineseScript.simplified,
  '簡': ChineseScript.simplified,
  '简体': ChineseScript.simplified,
  '簡體': ChineseScript.simplified,
  '簡体': ChineseScript.simplified,
  '简中': ChineseScript.simplified,
  '簡中': ChineseScript.simplified,
};

const Set<String> _chineseBases = <String>{'zh', 'zho', 'chi', 'cmn', 'yue'};

/// 语言标签 / 单个标记词 → 中文书写系统；不是中文或没表明书写系统返回 null。
///
/// 显式 script 子标签优先（`zh-Hant` / `zh-Hans`），其次地区（`TW` / `HK` / `MO` →
/// 繁，`CN` / `SG` / `MY` → 简），再次单词写法（`cht` / `chs` / `big5` / `繁體`）。
/// 粤语（`yue`）没写书写系统时按繁体（书面粤语以繁体为主，与字体链同判据）。
/// 纯 `zh` / `chi` 返回 null——**不是**简体：字体链为了出字可以默认简体，挑字幕不能。
ChineseScript? chineseScriptOfLanguageTag(String? tag) {
  final String normalized = (tag ?? '').trim().toLowerCase().replaceAll(
    '_',
    '-',
  );
  if (normalized.isEmpty) return null;
  final ChineseScript? word = _chineseScriptWords[normalized];
  if (word != null) return word;
  final List<String> parts = normalized.split('-');
  if (!_chineseBases.contains(parts.first)) return null;
  for (final String sub in parts.skip(1)) {
    switch (sub) {
      case 'hant' || 'tw' || 'hk' || 'mo':
        return ChineseScript.traditional;
      case 'hans' || 'cn' || 'sg' || 'my':
        return ChineseScript.simplified;
    }
  }
  return parts.first == 'yue' ? ChineseScript.traditional : null;
}

/// 字幕标记词（文件名语言标记 / 轨语言 tag / 轨标题里的一个词）→ 基础语言码。
///
/// 在 [trackPreferenceLanguageCode] 之上补认只表明繁简的写法（`big5` / `繁體` 等，
/// 它们一定是中文）。不是语言写法（`forced` / `sdh` / `srt`）返回 null。
String? subtitleTokenLanguageCode(String? token) {
  final String? code = trackPreferenceLanguageCode(token);
  if (code != null) return code;
  return chineseScriptOfLanguageTag(token) != null ? 'zh' : null;
}

Iterable<String> _labelWords(String label) => label
    .toLowerCase()
    .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
    .where((String w) => w.isNotEmpty);

/// 轨标题 / 标签里表明的中文书写系统（`繁體中文` / `Simplified Chinese` / `CHT` /
/// `中文 (Taiwan)`）。两种都出现（`简繁双语`）或都没有时返回 null。
ChineseScript? chineseScriptOfLabel(String? label) {
  final String text = label ?? '';
  if (text.trim().isEmpty) return null;
  final Set<ChineseScript> seen = <ChineseScript>{};
  for (final String word in _labelWords(text)) {
    final ChineseScript? script = chineseScriptOfLanguageTag(word);
    if (script != null) seen.add(script);
  }
  // 「繁體中文」「简体中文」是一个词，按字认。
  if (text.contains('繁') || text.contains('正體')) {
    seen.add(ChineseScript.traditional);
  }
  if (text.contains('简') || text.contains('簡')) {
    seen.add(ChineseScript.simplified);
  }
  return seen.length == 1 ? seen.single : null;
}

String? _labelLanguageCode(String? label) {
  final String text = label ?? '';
  for (final String word in _labelWords(text)) {
    final String? code = subtitleTokenLanguageCode(word);
    if (code != null) return code;
  }
  if (chineseScriptOfLabel(text) != null || text.contains('中文')) return 'zh';
  return null;
}

/// 一条候选字幕相对目标语言的匹配档次，按枚举顺序从好到差。
enum SubtitleTargetMatch {
  /// 语言对上（中文还要书写系统对上）。
  exact,

  /// 中文，但候选没表明繁 / 简。
  scriptUnknown,

  /// 中文，书写系统与目标相反。
  otherScript,

  /// 不是目标语言（或认不出语言）。
  none,
}

/// [target] 下一条候选的匹配档次。
///
/// [languageTag] 是候选声明的语言（外挂的文件名语言标记、内封轨的语言 tag），
/// [label] 是附带的可读标签（内封轨标题）；语言先看 [languageTag]，没有才看 [label]。
/// [contentScript] 是读正文判出的繁 / 简（只在标记没表明时作数）。
SubtitleTargetMatch matchSubtitleTarget(
  SubtitleLanguageTarget target, {
  String? languageTag,
  String? label,
  ChineseScript? contentScript,
}) {
  final String? code =
      subtitleTokenLanguageCode(languageTag) ?? _labelLanguageCode(label);
  if (code == null || code != target.code) return SubtitleTargetMatch.none;
  final ChineseScript? want = target.script;
  if (want == null || code != 'zh') return SubtitleTargetMatch.exact;
  final ChineseScript? script =
      chineseScriptOfLanguageTag(languageTag) ??
      chineseScriptOfLabel(label) ??
      contentScript;
  if (script == null) return SubtitleTargetMatch.scriptUnknown;
  return script == want
      ? SubtitleTargetMatch.exact
      : SubtitleTargetMatch.otherScript;
}

/// 解析自动挑字幕的目标语言；无法确定返回 null（不猜）。
///
/// 与 `resolveSubtitleDownloadLanguage` 同一条链、同一优先级：
/// 1. [explicitSubtitlePreference]：用户显式表过态的字幕语言（合集的系列字幕语言 /
///    字幕工作台默认语言）。
/// 2. 视频内容语言（[resolveContentLanguage]）：[videoContentLanguage]（本视频手动
///    指定）> [contentMetadataLanguage]（刮削原语言）> [globalDefaultContentLanguage]。
///
/// 显式语言只写了 `zh`、而内容语言同为中文且写明了繁 / 简时，补上内容语言的书写
/// 系统：「字幕要中文」+「这部是繁体内容」= 要繁体字幕。
SubtitleLanguageTarget? resolveSubtitleLanguageTarget({
  String? explicitSubtitlePreference,
  String? videoContentLanguage,
  String? contentMetadataLanguage,
  String? globalDefaultContentLanguage,
}) {
  final SubtitleLanguageTarget? content = SubtitleLanguageTarget.parse(
    resolveContentLanguage(
      explicit: videoContentLanguage,
      metadata: contentMetadataLanguage,
      globalDefault: globalDefaultContentLanguage,
    ),
  );
  final String explicit = explicitSubtitlePreference?.trim() ?? '';
  if (explicit.isEmpty) return content;
  final SubtitleLanguageTarget? stated = SubtitleLanguageTarget.parse(explicit);
  if (stated == null) return null;
  if (stated.script == null &&
      content != null &&
      content.code == stated.code &&
      content.script != null) {
    return content;
  }
  return stated;
}

/// 从 [sources] 里挑最符合 [target] 的一条（[matchSubtitleTarget] 档次最好、同档取
/// 原序第一条）；[accept] 过滤不可用的源。[target] 为 null 或没有任何一条是目标语言
/// 时返回 null（调用方保持原有兜底）。
SubtitleSource? pickSubtitleSourceForTarget(
  Iterable<SubtitleSource> sources,
  SubtitleLanguageTarget? target, {
  bool Function(SubtitleSource source)? accept,
}) {
  if (target == null) return null;
  SubtitleSource? best;
  SubtitleTargetMatch bestMatch = SubtitleTargetMatch.none;
  for (final SubtitleSource s in sources) {
    if (accept != null && !accept(s)) continue;
    final SubtitleTargetMatch match = matchSubtitleTarget(
      target,
      languageTag: s.language,
      label: s.label,
    );
    if (match.index < bestMatch.index) {
      best = s;
      bestMatch = match;
      if (match == SubtitleTargetMatch.exact) break;
    }
  }
  return best;
}
