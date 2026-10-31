/// Galgame 台词浮窗的 TTS 朗读：设置模型 + 纯函数裁决（读不读、用哪个声音、读什么）。
///
/// 「抢话」（TTS 与游戏原声同时响）分两层解决，与 LunaTranslator 的「语音指定 /
/// 语音修正」同构，但多一层 Fushi 独有的证据：
///  1. **配对证据**（[GalLineTtsAutoPlay.unvoicedOnly]）：会话本来就在给每行配游戏
///     原声。配上了 = 有配音 → 不读；判定无配音 / 本会话没有音源 → 读；还在配 → 等。
///     能抓到语音的游戏里不写任何规则就不抢话。
///  2. **规则**（[GalLineTtsRule]，顺序匹配、首条命中生效）：给抓不到语音的引擎兜底，
///     以及「有配音角色名单」「主角名开头照读」这类按文本特征的判断。规则裁决优先于
///     配对证据——用户明确说「这个人跳过」/「这个人照读」就照办。
///
/// 送进 TTS 的文本：拆出人名后只读台词本体（[GalLineTtsSettings.stripSpeaker]），
/// 再依次过 [GalLineTtsTextFix]（正则替换，如去掉「」）。浮窗显示的文本不受影响。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/sync/texthooker_service.dart';

/// String：整份 [GalLineTtsSettings] JSON。含本机声音预设 id，设备本地（不进备份 /
/// 同步 / Profile 快照，与 `tts_active_preset_id` 同族）。
const String kGalLineTtsSettingsPrefKey = 'gal_line_tts_settings';

/// 自动朗读档位。手动点浮窗「朗读」按钮不受档位限制（有原声的句子也照读）。
enum GalLineTtsAutoPlay {
  off,

  /// 只读没有游戏原声的句子（旁白 / 无配音的主角）。
  unvoicedOnly,

  /// 每句都读（游戏关了语音、只想听 TTS 时）。
  all;

  static GalLineTtsAutoPlay fromWire(Object? raw) {
    for (final GalLineTtsAutoPlay value in values) {
      if (value.name == raw) return value;
    }
    return GalLineTtsAutoPlay.unvoicedOnly;
  }
}

/// 规则的匹配对象与方式。
enum GalLineTtsRuleMatch {
  /// 拆出的人名等于其中任一个（[GalLineTtsRule.pattern] 按换行 / 逗号分隔多个名字）。
  speakerIs,

  /// 原始台词以其中任一个开头（多个用换行 / 逗号分隔）。
  startsWith,

  /// 原始台词包含其中任一个。
  contains,

  /// 原始台词匹配正则。
  regex;

  static GalLineTtsRuleMatch? fromWire(Object? raw) {
    for (final GalLineTtsRuleMatch value in values) {
      if (value.name == raw) return value;
    }
    return null;
  }
}

/// 规则命中后怎么做。
enum GalLineTtsRuleAction {
  /// 不读这句（有配音的角色）。
  skip,

  /// 照读，用默认声音（且不再看配对证据：主角台词常被引擎误配上别人的声音）。
  read,

  /// 照读，换成指定声音（[GalLineTtsRule.presetId]）。
  voice;

  static GalLineTtsRuleAction? fromWire(Object? raw) {
    for (final GalLineTtsRuleAction value in values) {
      if (value.name == raw) return value;
    }
    return null;
  }
}

@immutable
class GalLineTtsRule {
  const GalLineTtsRule({
    required this.match,
    required this.pattern,
    required this.action,
    this.presetId,
    this.enabled = true,
  });

  final GalLineTtsRuleMatch match;
  final String pattern;
  final GalLineTtsRuleAction action;

  /// 仅 [GalLineTtsRuleAction.voice] 用：TTS 声音预设 id。
  final String? presetId;
  final bool enabled;

  /// 多值字段（名字表 / 前缀表）按换行、半角 / 全角逗号、顿号切开。
  List<String> get terms => <String>[
    for (final String part in pattern.split(RegExp(r'[\n,，、]')))
      if (part.trim().isNotEmpty) part.trim(),
  ];

  /// 正则编译失败返回 null（编辑页据此标红，裁决时视为不命中）。
  RegExp? get compiledRegex {
    if (match != GalLineTtsRuleMatch.regex || pattern.isEmpty) return null;
    try {
      return RegExp(pattern, multiLine: true);
    } on FormatException {
      return null;
    }
  }

  bool matches({required String rawText, required String? speaker}) {
    if (!enabled) return false;
    switch (match) {
      case GalLineTtsRuleMatch.speakerIs:
        return speaker != null && terms.contains(speaker);
      case GalLineTtsRuleMatch.startsWith:
        return terms.any(rawText.startsWith);
      case GalLineTtsRuleMatch.contains:
        return terms.any(rawText.contains);
      case GalLineTtsRuleMatch.regex:
        return compiledRegex?.hasMatch(rawText) ?? false;
    }
  }

  GalLineTtsRule copyWith({
    GalLineTtsRuleMatch? match,
    String? pattern,
    GalLineTtsRuleAction? action,
    String? presetId,
    bool? enabled,
  }) => GalLineTtsRule(
    match: match ?? this.match,
    pattern: pattern ?? this.pattern,
    action: action ?? this.action,
    presetId: presetId ?? this.presetId,
    enabled: enabled ?? this.enabled,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'match': match.name,
    'pattern': pattern,
    'action': action.name,
    if (presetId != null) 'presetId': presetId,
    'enabled': enabled,
  };

  /// 字段缺失 / 类型不对整条判无效返回 null（不让一条坏规则拖垮整张表）。
  static GalLineTtsRule? fromJson(Map<Object?, Object?> json) {
    final GalLineTtsRuleMatch? match = GalLineTtsRuleMatch.fromWire(
      json['match'],
    );
    final GalLineTtsRuleAction? action = GalLineTtsRuleAction.fromWire(
      json['action'],
    );
    final Object? pattern = json['pattern'];
    if (match == null || action == null || pattern is! String) return null;
    final Object? presetId = json['presetId'];
    final Object? enabled = json['enabled'];
    return GalLineTtsRule(
      match: match,
      pattern: pattern,
      action: action,
      presetId: presetId is String && presetId.isNotEmpty ? presetId : null,
      enabled: enabled is bool ? enabled : true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GalLineTtsRule &&
      other.match == match &&
      other.pattern == pattern &&
      other.action == action &&
      other.presetId == presetId &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(match, pattern, action, presetId, enabled);
}

/// 送进 TTS 前的正则替换（LunaTranslator 的「语音修正」）。
@immutable
class GalLineTtsTextFix {
  const GalLineTtsTextFix({
    required this.pattern,
    this.replacement = '',
    this.enabled = true,
  });

  final String pattern;
  final String replacement;
  final bool enabled;

  RegExp? get compiled {
    if (pattern.isEmpty) return null;
    try {
      return RegExp(pattern, multiLine: true);
    } on FormatException {
      return null;
    }
  }

  String apply(String text) {
    final RegExp? re = enabled ? compiled : null;
    if (re == null) return text;
    // 支持 $1 / ${name} 引用捕获组。
    return text.replaceAllMapped(re, (Match m) {
      return replacement.replaceAllMapped(RegExp(r'\$(?:\{(\w+)\}|(\d+))'), (
        Match ref,
      ) {
        final String? named = ref.group(1);
        if (named != null && m is RegExpMatch) {
          try {
            return m.namedGroup(named) ?? '';
          } on ArgumentError {
            return '';
          }
        }
        final int? index = int.tryParse(ref.group(2) ?? '');
        if (index == null || index > m.groupCount) return '';
        return m.group(index) ?? '';
      });
    });
  }

  GalLineTtsTextFix copyWith({
    String? pattern,
    String? replacement,
    bool? enabled,
  }) => GalLineTtsTextFix(
    pattern: pattern ?? this.pattern,
    replacement: replacement ?? this.replacement,
    enabled: enabled ?? this.enabled,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'pattern': pattern,
    'replacement': replacement,
    'enabled': enabled,
  };

  static GalLineTtsTextFix? fromJson(Map<Object?, Object?> json) {
    final Object? pattern = json['pattern'];
    if (pattern is! String) return null;
    final Object? replacement = json['replacement'];
    final Object? enabled = json['enabled'];
    return GalLineTtsTextFix(
      pattern: pattern,
      replacement: replacement is String ? replacement : '',
      enabled: enabled is bool ? enabled : true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GalLineTtsTextFix &&
      other.pattern == pattern &&
      other.replacement == replacement &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(pattern, replacement, enabled);
}

/// 拆人名的结果。[speaker] 为 null = 没认出人名（旁白，或没有人名牌的引擎）。
typedef GalLineSpeakerSplit = ({String? speaker, String body});

/// 内置人名格式（顺序尝试，首个命中生效）：
///  - `【名】台词` / `[名]台词`
///  - `名「台词」` / `名『台词』` / `名（台词）`（名字 ≤16 字、不含空白与标点）
///  - `名\n台词`（人名线程与正文线程拼在一起，LunaTranslator 教程「情形二」）
///  - `名：台词` / `名:台词`
final List<RegExp> _kBuiltinSpeakerPatterns = <RegExp>[
  RegExp(r'^\s*[【\[]([^】\]\n]{1,16})[】\]]\s*(?<text>[\s\S]+)$'),
  RegExp(r'^\s*([^\s「『（(【\[\]】。、！？!?…]{1,16})\s*(?<text>[「『（(][\s\S]+)$'),
  RegExp(r'^\s*([^\s「『（(【\[\]】。、！？!?…：:]{1,16})\n(?<text>[\s\S]+)$'),
  RegExp(r'^\s*([^\s「『（(【\[\]】。、！？!?…：:]{1,16})[：:]\s*(?<text>[\s\S]+)$'),
];

/// 用户自定义人名正则：须含命名组 `name`，可选命名组 `text`（缺省 = 人名之后的全部）。
/// 编译失败 / 缺 `name` 组返回 null。
RegExp? compileGalSpeakerPattern(String pattern) {
  if (pattern.trim().isEmpty) return null;
  try {
    final RegExp re = RegExp(pattern, multiLine: false);
    if (!pattern.contains('?<name>')) return null;
    return re;
  } on FormatException {
    return null;
  }
}

/// 从原始台词里拆出人名与台词本体。[customPattern] 非空时只用它（不再回落内置格式，
/// 免得用户的精确规则被内置的宽松格式抢先）。
GalLineSpeakerSplit splitGalLineSpeaker(
  String raw, {
  String customPattern = '',
}) {
  final String text = raw.trim();
  if (customPattern.trim().isNotEmpty) {
    final RegExp? re = compileGalSpeakerPattern(customPattern);
    final RegExpMatch? m = re?.firstMatch(text);
    if (m == null) return (speaker: null, body: text);
    final String name = (m.namedGroup('name') ?? '').trim();
    String body;
    try {
      body = m.namedGroup('text') ?? text.substring(m.end);
    } on ArgumentError {
      body = text.substring(m.end);
    }
    return (speaker: name.isEmpty ? null : name, body: body.trim());
  }
  for (final RegExp re in _kBuiltinSpeakerPatterns) {
    final RegExpMatch? m = re.firstMatch(text);
    if (m == null) continue;
    final String name = (m.group(1) ?? '').trim();
    final String body = (m.namedGroup('text') ?? '').trim();
    if (name.isEmpty || body.isEmpty) continue;
    return (speaker: name, body: body);
  }
  return (speaker: null, body: text);
}

/// 一键添加的预设（设置页「添加预设规则」）。
enum GalLineTtsRulePreset {
  /// 台词带「」『』的跳过（有配音角色说话一般带括号，旁白不带）。
  skipBracketed,

  /// 以主角名开头的照读（主角台词同样带括号，要排在 [skipBracketed] 前面）。
  readProtagonist,

  /// 有配音角色名单：人名命中就跳过。
  skipVoicedCast,
}

/// 预设对应的规则。[names] 只对需要名字的预设有意义（主角名 / 配音角色名单）。
GalLineTtsRule galLineTtsRuleFromPreset(
  GalLineTtsRulePreset preset, {
  String names = '',
}) => switch (preset) {
  GalLineTtsRulePreset.skipBracketed => const GalLineTtsRule(
    match: GalLineTtsRuleMatch.regex,
    pattern: r'^[^「『\n]{0,16}\n?[「『]',
    action: GalLineTtsRuleAction.skip,
  ),
  GalLineTtsRulePreset.readProtagonist => GalLineTtsRule(
    match: GalLineTtsRuleMatch.startsWith,
    pattern: names,
    action: GalLineTtsRuleAction.read,
  ),
  GalLineTtsRulePreset.skipVoicedCast => GalLineTtsRule(
    match: GalLineTtsRuleMatch.speakerIs,
    pattern: names,
    action: GalLineTtsRuleAction.skip,
  ),
};

/// 预设的「语音修正」：去掉台词两端的括号（人名由 [GalLineTtsSettings.stripSpeaker] 去）。
const GalLineTtsTextFix kGalLineTtsStripBracketsFix = GalLineTtsTextFix(
  pattern: r'^[「『（(]|[」』）)]$',
);

/// 把预设规则插进规则表：「照读主角」必须排在「跳过括号」前面才不会被误伤，
/// 所以 [GalLineTtsRuleAction.read] / [GalLineTtsRuleAction.voice] 插到所有
/// skip 规则之前，skip 规则追加到末尾。
List<GalLineTtsRule> insertGalLineTtsRule(
  List<GalLineTtsRule> rules,
  GalLineTtsRule rule,
) {
  if (rule.action == GalLineTtsRuleAction.skip) {
    return <GalLineTtsRule>[...rules, rule];
  }
  final int firstSkip = rules.indexWhere(
    (GalLineTtsRule r) => r.action == GalLineTtsRuleAction.skip,
  );
  if (firstSkip < 0) return <GalLineTtsRule>[...rules, rule];
  return <GalLineTtsRule>[
    ...rules.sublist(0, firstSkip),
    rule,
    ...rules.sublist(firstSkip),
  ];
}

@immutable
class GalLineTtsSettings {
  const GalLineTtsSettings({
    this.autoPlay = GalLineTtsAutoPlay.unvoicedOnly,
    this.autoPlayEnabled = false,
    this.presetId,
    this.stripSpeaker = true,
    this.speakerPattern = '',
    this.rules = const <GalLineTtsRule>[],
    this.textFixes = const <GalLineTtsTextFix>[],
    this.volume = 1.0,
  });

  /// 自动朗读总开关（浮窗工具条上的「自动朗读」键就是它）。默认关：TTS 要先配声音。
  final bool autoPlayEnabled;

  /// 自动朗读的范围（总开关打开时生效）。
  final GalLineTtsAutoPlay autoPlay;

  /// 默认声音（TTS 声音预设 id）。null = 跟随「朗读声音」里的当前声音。
  final String? presetId;

  /// 送进 TTS 前去掉人名。
  final bool stripSpeaker;

  /// 自定义人名正则（空 = 内置格式）。
  final String speakerPattern;
  final List<GalLineTtsRule> rules;
  final List<GalLineTtsTextFix> textFixes;

  /// TTS 播放音量（0..1），方便压在游戏音量下面。
  final double volume;

  /// 实际生效的档位（总开关关 = off）。
  GalLineTtsAutoPlay get effectiveAutoPlay =>
      autoPlayEnabled ? autoPlay : GalLineTtsAutoPlay.off;

  GalLineTtsSettings copyWith({
    bool? autoPlayEnabled,
    GalLineTtsAutoPlay? autoPlay,
    String? presetId,
    bool clearPresetId = false,
    bool? stripSpeaker,
    String? speakerPattern,
    List<GalLineTtsRule>? rules,
    List<GalLineTtsTextFix>? textFixes,
    double? volume,
  }) => GalLineTtsSettings(
    autoPlayEnabled: autoPlayEnabled ?? this.autoPlayEnabled,
    autoPlay: autoPlay ?? this.autoPlay,
    presetId: clearPresetId ? null : (presetId ?? this.presetId),
    stripSpeaker: stripSpeaker ?? this.stripSpeaker,
    speakerPattern: speakerPattern ?? this.speakerPattern,
    rules: rules ?? this.rules,
    textFixes: textFixes ?? this.textFixes,
    volume: volume ?? this.volume,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'autoPlayEnabled': autoPlayEnabled,
    'autoPlay': autoPlay.name,
    if (presetId != null) 'presetId': presetId,
    'stripSpeaker': stripSpeaker,
    'speakerPattern': speakerPattern,
    'rules': <Object?>[for (final GalLineTtsRule r in rules) r.toJson()],
    'textFixes': <Object?>[
      for (final GalLineTtsTextFix f in textFixes) f.toJson(),
    ],
    'volume': volume,
  };

  String encode() => jsonEncode(toJson());

  /// 解析失败的字段回落默认值，坏掉的单条规则丢弃。
  static GalLineTtsSettings decode(Object? raw) {
    if (raw is! String || raw.isEmpty) return const GalLineTtsSettings();
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const GalLineTtsSettings();
    }
    if (decoded is! Map) return const GalLineTtsSettings();
    final Map<Object?, Object?> json = decoded.cast<Object?, Object?>();
    final Object? rules = json['rules'];
    final Object? fixes = json['textFixes'];
    final Object? presetId = json['presetId'];
    final Object? strip = json['stripSpeaker'];
    final Object? speakerPattern = json['speakerPattern'];
    final Object? volume = json['volume'];
    final Object? enabled = json['autoPlayEnabled'];
    return GalLineTtsSettings(
      autoPlayEnabled: enabled is bool && enabled,
      autoPlay: GalLineTtsAutoPlay.fromWire(json['autoPlay']),
      presetId: presetId is String && presetId.isNotEmpty ? presetId : null,
      stripSpeaker: strip is! bool || strip,
      speakerPattern: speakerPattern is String ? speakerPattern : '',
      rules: <GalLineTtsRule>[
        if (rules is List)
          for (final Object? r in rules)
            if (r is Map)
              if (GalLineTtsRule.fromJson(r.cast<Object?, Object?>())
                  case final GalLineTtsRule rule)
                rule,
      ],
      textFixes: <GalLineTtsTextFix>[
        if (fixes is List)
          for (final Object? f in fixes)
            if (f is Map)
              if (GalLineTtsTextFix.fromJson(f.cast<Object?, Object?>())
                  case final GalLineTtsTextFix fix)
                fix,
      ],
      volume: volume is num ? volume.toDouble().clamp(0.0, 1.0) : 1.0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GalLineTtsSettings &&
      other.autoPlayEnabled == autoPlayEnabled &&
      other.autoPlay == autoPlay &&
      other.presetId == presetId &&
      other.stripSpeaker == stripSpeaker &&
      other.speakerPattern == speakerPattern &&
      listEquals(other.rules, rules) &&
      listEquals(other.textFixes, textFixes) &&
      other.volume == volume;

  @override
  int get hashCode => Object.hash(
    autoPlayEnabled,
    autoPlay,
    presetId,
    stripSpeaker,
    speakerPattern,
    Object.hashAll(rules),
    Object.hashAll(textFixes),
    volume,
  );
}

/// 这一行的游戏原声配对证据。
enum GalLineVoiceEvidence {
  /// 配上了原声（资源原件 / 引擎 PCM / 兜底切片）。
  voiced,

  /// 有证据没配音，或本会话根本没有音源（读）。
  unvoiced,

  /// 还在配（等状态落定再裁决，不按时间猜）。
  pending,
}

GalLineVoiceEvidence galLineVoiceEvidenceOf(TexthookerLineEntry line) =>
    switch (line.audioStatus) {
      TexthookerLineAudioStatus.pending => GalLineVoiceEvidence.pending,
      TexthookerLineAudioStatus.matched ||
      TexthookerLineAudioStatus.encoded => GalLineVoiceEvidence.voiced,
      // 兜底切片只有在「判定这句没配音」时才算无配音；其余兜底是真录到了声音。
      TexthookerLineAudioStatus.fallback =>
        line.fallbackReason == kGalLineNoVoiceReason
            ? GalLineVoiceEvidence.unvoiced
            : GalLineVoiceEvidence.voiced,
      TexthookerLineAudioStatus.missing ||
      TexthookerLineAudioStatus.unavailable => GalLineVoiceEvidence.unvoiced,
    };

/// 裁决结果。
sealed class GalLineTtsDecision {
  const GalLineTtsDecision();
}

/// 不读。[reason] 只用于诊断日志。
class GalLineTtsSkip extends GalLineTtsDecision {
  const GalLineTtsSkip(this.reason);
  final String reason;
}

/// 还要等配对证据落定（只在自动朗读 + [GalLineTtsAutoPlay.unvoicedOnly] 下出现）。
class GalLineTtsWait extends GalLineTtsDecision {
  const GalLineTtsWait();
}

/// 读。[presetId] 为 null = 跟随「朗读声音」当前声音。
class GalLineTtsSpeak extends GalLineTtsDecision {
  const GalLineTtsSpeak({required this.text, required this.presetId});
  final String text;
  final String? presetId;
}

/// 送进 TTS 的文本（拆人名 + 语音修正），与裁决无关、可提前算（预合成用）。
String galLineTtsText(GalLineTtsSettings settings, String rawText) {
  final GalLineSpeakerSplit split = splitGalLineSpeaker(
    rawText,
    customPattern: settings.speakerPattern,
  );
  String text = settings.stripSpeaker ? split.body : rawText.trim();
  for (final GalLineTtsTextFix fix in settings.textFixes) {
    text = fix.apply(text);
  }
  return text.trim();
}

/// 裁决一行读不读。[manual] = 用户点了浮窗「朗读」键：规则里的 skip 与配对证据都
/// 不拦（用户就是想听这句），只保留声音选择。
GalLineTtsDecision decideGalLineTts({
  required GalLineTtsSettings settings,
  required String rawText,
  required GalLineVoiceEvidence evidence,
  required bool manual,
}) {
  final GalLineTtsAutoPlay mode = settings.effectiveAutoPlay;
  if (!manual && mode == GalLineTtsAutoPlay.off) {
    return const GalLineTtsSkip('auto_play_off');
  }
  final String text = galLineTtsText(settings, rawText);
  if (text.isEmpty || !RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(text)) {
    return const GalLineTtsSkip('empty_text');
  }
  final GalLineSpeakerSplit split = splitGalLineSpeaker(
    rawText,
    customPattern: settings.speakerPattern,
  );
  final String raw = rawText.trim();
  for (final GalLineTtsRule rule in settings.rules) {
    if (!rule.matches(rawText: raw, speaker: split.speaker)) continue;
    switch (rule.action) {
      case GalLineTtsRuleAction.skip:
        if (manual) {
          return GalLineTtsSpeak(text: text, presetId: settings.presetId);
        }
        return const GalLineTtsSkip('rule_skip');
      case GalLineTtsRuleAction.read:
        return GalLineTtsSpeak(text: text, presetId: settings.presetId);
      case GalLineTtsRuleAction.voice:
        return GalLineTtsSpeak(
          text: text,
          presetId: rule.presetId ?? settings.presetId,
        );
    }
  }
  if (!manual && mode == GalLineTtsAutoPlay.unvoicedOnly) {
    switch (evidence) {
      case GalLineVoiceEvidence.voiced:
        return const GalLineTtsSkip('game_voice');
      case GalLineVoiceEvidence.pending:
        return const GalLineTtsWait();
      case GalLineVoiceEvidence.unvoiced:
        break;
    }
  }
  return GalLineTtsSpeak(text: text, presetId: settings.presetId);
}
