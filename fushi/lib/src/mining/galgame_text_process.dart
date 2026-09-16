/// galgame 文本 hook 的「所选线程文本处理」管线。
///
/// 背景：LunaHook 抓到的原文常带引擎绘制伪影——逐字重绘（`AABABCABCD`）、整块重复
/// （`ABCDABCDABCD`）、控制符、注音花括号、排版用的半角片假名。native 侧只做了
/// 「伪影行整行丢弃」这一刀（`LunaTextIsArtifact`），**留下来的行内部并不清洗**；
/// Dart 侧此前只有注音剥离（`parseRubyMarkup`）与系统 UI 行剔除
/// （`isGalgameSystemUiLine`）两处定点处理。用户要的是 LunaTranslator 那样一条
/// **用户可编排**的处理链：每步可开关、可调参、可重排顺序。
///
/// 本文件只放纯函数与不可变数据，**不依赖 Flutter**：这样它既能被 poll 热路径直接调用，
/// 也能被可视化预览界面和单测原样复用（同一份实现，避免预览与实际入库文本对不上）。
///
/// 处理项对齐 LunaTranslator 文档 `docs.lunatranslator.org/zh/textprocess.html` 列出的
/// 方法集，**只有「自定义 python 处理」不实现**——本 app 不内嵌脚本运行时，那一项由
/// 「正则替换」加 AI 辅助生成规则来覆盖。
library;

/// 一个处理步骤的种类。
///
/// 枚举名进持久化（`storageKey`），**改名即破坏用户已存的管线**，要改必须带迁移。
enum GalTextProcessKind {
  /// 过滤掉日文字符集（CP932/Shift-JIS）表示不了的字符。
  filterNonJapanese,

  /// 过滤 ASCII 控制符（换行由 [filterLineBreaks] 单管，这里不动）。
  filterControlChars,

  /// 过滤英文（半角）标点。
  filterAsciiPunctuation,

  /// 只保留「」内的内容——用于丢掉旁白只留台词。
  keepJapaneseQuotes,

  /// 去除花括号注音标记：`{漢字/かんじ}` → `漢字`，不含 `/` 的 `{…}` 整体删除。
  stripCurlyBraces,

  /// 全角/半角正规化：全角 ASCII → 半角、半角片假名 → 全角（含浊点合成）。
  normalizeWidth,

  /// 截取指定行数（可从末尾取）。
  takeLines,

  /// 去除重复字符 `AAAABBBBCCCC` → `ABC`。
  dedupeChars,

  /// 去除整块重复 `ABCDABCDABCD` → `ABCD`（重复次数由参数给定）。
  dedupeBlockFixed,

  /// 去除连续重复行 `S1S1S1S2S2S2` → `S1S2`（重复次数程序自动分析）。
  dedupeLinesAuto,

  /// 去除递减子串 `ABCDBCDCDD` → `ABCD`。
  dedupeDescending,

  /// 去除逐字绘制递增子串 `AABABCABCD` → `ABCD`。
  dedupeAscending,

  /// 过滤尖括号标签 `<…>`。
  stripAngleBrackets,

  /// 过滤换行符（可替换成指定字符串）。
  filterLineBreaks,

  /// 过滤数字（半角与全角）。
  filterDigits,

  /// 过滤英文字母（半角与全角）。
  filterLatinLetters,

  /// 字符串 / 正则替换（用户自定义，可在管线里出现多次）。
  replace;

  /// 持久化用的稳定键。
  String get storageKey => name;

  static GalTextProcessKind? fromStorageKey(String? key) {
    if (key == null) {
      return null;
    }
    for (final GalTextProcessKind kind in GalTextProcessKind.values) {
      if (kind.storageKey == key) {
        return kind;
      }
    }
    return null;
  }

  /// 这一步是否带可调参数——UI 据此决定要不要画参数行。
  bool get hasParameters => switch (this) {
    GalTextProcessKind.takeLines ||
    GalTextProcessKind.dedupeChars ||
    GalTextProcessKind.dedupeBlockFixed ||
    GalTextProcessKind.filterLineBreaks ||
    GalTextProcessKind.replace => true,
    _ => false,
  };

  /// 同一种步骤能否在管线里出现多次。只有替换规则可以（一条规则一步）。
  bool get allowsDuplicates => this == GalTextProcessKind.replace;
}

/// 管线里的一步。不可变；改参数用 [copyWith] 产生新实例。
///
/// [id] 是**重排与编辑的稳定标识**：同一 kind 可以有多条（替换规则），拿 index 当 key
/// 会在 ReorderableListView 拖动过程中错位。
class GalTextProcessStep {
  const GalTextProcessStep({
    required this.id,
    required this.kind,
    this.enabled = true,
    this.repeatCount,
    this.lineCount = 1,
    this.fromEnd = false,
    this.pattern = '',
    this.replacement = '',
    this.isRegex = true,
  });

  factory GalTextProcessStep.fromJson(Map<Object?, Object?> json) {
    final GalTextProcessKind kind =
        GalTextProcessKind.fromStorageKey(json['kind'] as String?) ??
        GalTextProcessKind.filterControlChars;
    final Object? rawRepeat = json['repeatCount'];
    final Object? rawLines = json['lineCount'];
    return GalTextProcessStep(
      id: json['id'] as String? ?? kind.storageKey,
      kind: kind,
      enabled: json['enabled'] as bool? ?? true,
      repeatCount: rawRepeat is int && rawRepeat > 0 ? rawRepeat : null,
      lineCount: rawLines is int && rawLines > 0 ? rawLines : 1,
      fromEnd: json['fromEnd'] as bool? ?? false,
      pattern: json['pattern'] as String? ?? '',
      replacement: json['replacement'] as String? ?? '',
      isRegex: json['isRegex'] as bool? ?? true,
    );
  }

  /// 管线内唯一。
  final String id;
  final GalTextProcessKind kind;
  final bool enabled;

  /// [GalTextProcessKind.dedupeChars] / [GalTextProcessKind.dedupeBlockFixed] 的重复次数；
  /// null = 自动分析。
  final int? repeatCount;

  /// [GalTextProcessKind.takeLines] 取几行。
  final int lineCount;

  /// [GalTextProcessKind.takeLines] 是否从末尾取。
  final bool fromEnd;

  /// [GalTextProcessKind.replace] 的匹配式。
  final String pattern;

  /// [GalTextProcessKind.replace] 的替换文本；[GalTextProcessKind.filterLineBreaks] 的换行替换物。
  final String replacement;

  /// [GalTextProcessKind.replace] 是否按正则解释 [pattern]。
  final bool isRegex;

  GalTextProcessStep copyWith({
    bool? enabled,
    int? repeatCount,
    bool clearRepeatCount = false,
    int? lineCount,
    bool? fromEnd,
    String? pattern,
    String? replacement,
    bool? isRegex,
  }) => GalTextProcessStep(
    id: id,
    kind: kind,
    enabled: enabled ?? this.enabled,
    repeatCount: clearRepeatCount ? null : repeatCount ?? this.repeatCount,
    lineCount: lineCount ?? this.lineCount,
    fromEnd: fromEnd ?? this.fromEnd,
    pattern: pattern ?? this.pattern,
    replacement: replacement ?? this.replacement,
    isRegex: isRegex ?? this.isRegex,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind.storageKey,
    if (!enabled) 'enabled': false,
    if (repeatCount != null) 'repeatCount': repeatCount,
    if (kind == GalTextProcessKind.takeLines) ...<String, Object?>{
      'lineCount': lineCount,
      if (fromEnd) 'fromEnd': true,
    },
    if (kind == GalTextProcessKind.replace) ...<String, Object?>{
      'pattern': pattern,
      'replacement': replacement,
      'isRegex': isRegex,
    },
    if (kind == GalTextProcessKind.filterLineBreaks && replacement.isNotEmpty)
      'replacement': replacement,
  };

  @override
  bool operator ==(Object other) =>
      other is GalTextProcessStep &&
      other.id == id &&
      other.kind == kind &&
      other.enabled == enabled &&
      other.repeatCount == repeatCount &&
      other.lineCount == lineCount &&
      other.fromEnd == fromEnd &&
      other.pattern == pattern &&
      other.replacement == replacement &&
      other.isRegex == isRegex;

  @override
  int get hashCode => Object.hash(
    id,
    kind,
    enabled,
    repeatCount,
    lineCount,
    fromEnd,
    pattern,
    replacement,
    isRegex,
  );
}

/// 一步的执行留痕，供可视化界面逐步展示「这一步把什么变成了什么」。
class GalTextProcessStepTrace {
  const GalTextProcessStepTrace({
    required this.step,
    required this.input,
    required this.output,
  });

  final GalTextProcessStep step;
  final String input;
  final String output;

  /// 这一步改变了文本。
  bool get changed => input != output;

  /// 这一步把整行清空了——可视化要显著标出来，因为空行会被后续 poll 路径整行丢弃。
  bool get emptied => output.trim().isEmpty && input.trim().isNotEmpty;
}

/// 整条管线一次执行的留痕。
class GalTextProcessTrace {
  const GalTextProcessTrace({
    required this.input,
    required this.output,
    required this.steps,
  });

  final String input;
  final String output;
  final List<GalTextProcessStepTrace> steps;

  bool get changed => input != output;

  /// 最终结果为空 → 这一行不会进工作台/制卡。
  bool get emptied => output.trim().isEmpty && input.trim().isNotEmpty;
}

/// 用户为「所选文本线程」编排的一条处理链。
///
/// 空管线（[steps] 为空或全部 disabled）是**恒等变换**，热路径会被 [isEmpty] 短路，
/// 不装配时零开销。
class GalTextProcessPipeline {
  const GalTextProcessPipeline({this.steps = const <GalTextProcessStep>[]});

  factory GalTextProcessPipeline.fromJson(Object? json) {
    if (json is! List) {
      return const GalTextProcessPipeline();
    }
    final List<GalTextProcessStep> steps = <GalTextProcessStep>[];
    final Set<String> seenIds = <String>{};
    for (final Object? raw in json) {
      if (raw is! Map) {
        continue;
      }
      final GalTextProcessStep step = GalTextProcessStep.fromJson(
        raw.cast<Object?, Object?>(),
      );
      // 存档被手改坏时 id 可能撞——重排要靠 id 唯一，这里兜住而不是让 UI 崩。
      if (!seenIds.add(step.id)) {
        continue;
      }
      steps.add(step);
    }
    return GalTextProcessPipeline(
      steps: List<GalTextProcessStep>.unmodifiable(steps),
    );
  }

  final List<GalTextProcessStep> steps;

  /// 没有任何生效步骤。
  bool get isEmpty => !steps.any((GalTextProcessStep s) => s.enabled);

  bool get isNotEmpty => !isEmpty;

  List<Object?> toJson() =>
      steps.map((GalTextProcessStep s) => s.toJson()).toList(growable: false);

  /// 为 [kind] 生成一个当前管线内唯一的 step id。
  String nextIdFor(GalTextProcessKind kind) {
    final String base = kind.storageKey;
    if (!steps.any((GalTextProcessStep s) => s.id == base)) {
      return base;
    }
    int n = 2;
    while (steps.any((GalTextProcessStep s) => s.id == '$base#$n')) {
      n += 1;
    }
    return '$base#$n';
  }

  GalTextProcessPipeline withSteps(List<GalTextProcessStep> next) =>
      GalTextProcessPipeline(
        steps: List<GalTextProcessStep>.unmodifiable(next),
      );

  /// 跑完整条链，只要最终文本。热路径用这个。
  String apply(String text) {
    if (isEmpty) {
      return text;
    }
    String current = text;
    for (final GalTextProcessStep step in steps) {
      if (!step.enabled) {
        continue;
      }
      current = applyGalTextProcessStep(current, step);
    }
    return current;
  }

  /// 跑完整条链并逐步留痕。可视化预览用这个——与 [apply] 共用同一份
  /// [applyGalTextProcessStep]，预览结果与真实入库文本不可能分叉。
  GalTextProcessTrace run(String text) {
    final List<GalTextProcessStepTrace> traces = <GalTextProcessStepTrace>[];
    String current = text;
    for (final GalTextProcessStep step in steps) {
      if (!step.enabled) {
        traces.add(
          GalTextProcessStepTrace(step: step, input: current, output: current),
        );
        continue;
      }
      final String output = applyGalTextProcessStep(current, step);
      traces.add(
        GalTextProcessStepTrace(step: step, input: current, output: output),
      );
      current = output;
    }
    return GalTextProcessTrace(
      input: text,
      output: current,
      steps: List<GalTextProcessStepTrace>.unmodifiable(traces),
    );
  }

  /// 值相等。存在的理由是**写盘短路**：可视化界面的拖动重排会连续产生大量中间态，
  /// 没有这个判据每一帧都要往偏好里写一次整份管线。
  @override
  bool operator ==(Object other) {
    if (other is! GalTextProcessPipeline) {
      return false;
    }
    if (other.steps.length != steps.length) {
      return false;
    }
    for (int i = 0; i < steps.length; i += 1) {
      if (other.steps[i] != steps[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(steps);
}

/// 执行单步。所有处理项的唯一实现入口——热路径、预览、单测都只走这里。
String applyGalTextProcessStep(String text, GalTextProcessStep step) {
  return switch (step.kind) {
    GalTextProcessKind.filterNonJapanese => _filterNonJapanese(text),
    GalTextProcessKind.filterControlChars => _filterControlChars(text),
    GalTextProcessKind.filterAsciiPunctuation => _filterAsciiPunctuation(text),
    GalTextProcessKind.keepJapaneseQuotes => _keepJapaneseQuotes(text),
    GalTextProcessKind.stripCurlyBraces => _stripCurlyBraces(text),
    GalTextProcessKind.normalizeWidth => normalizeGalTextWidth(text),
    GalTextProcessKind.takeLines => _takeLines(
      text,
      step.lineCount,
      step.fromEnd,
    ),
    GalTextProcessKind.dedupeChars => dedupeGalTextChars(
      text,
      step.repeatCount,
    ),
    GalTextProcessKind.dedupeBlockFixed => dedupeGalTextBlock(
      text,
      step.repeatCount,
    ),
    GalTextProcessKind.dedupeLinesAuto => dedupeGalTextLines(text),
    GalTextProcessKind.dedupeDescending => dedupeGalTextDescending(text),
    GalTextProcessKind.dedupeAscending => dedupeGalTextAscending(text),
    GalTextProcessKind.stripAngleBrackets => text.replaceAll(
      RegExp(r'<[^<>]*>'),
      '',
    ),
    GalTextProcessKind.filterLineBreaks => text.replaceAll(
      RegExp(r'\r\n|\r|\n'),
      step.replacement,
    ),
    GalTextProcessKind.filterDigits => text.replaceAll(RegExp(r'[0-9０-９]'), ''),
    GalTextProcessKind.filterLatinLetters => text.replaceAll(
      RegExp(r'[A-Za-zＡ-Ｚａ-ｚ]'),
      '',
    ),
    GalTextProcessKind.replace => _replace(text, step),
  };
}

// ---------------------------------------------------------------------------
// 过滤类
// ---------------------------------------------------------------------------

/// 剔除 CP932（Shift-JIS）表示不了的字符。
///
/// 诚实标注：判据是**区段近似**而非逐码位的 CP932 映射表。逐码位表有约 7000 条，
/// 为一个可选的清洗步骤内联一整张表不划算；区段近似在 VN 文本上的差别只体现在
/// JIS X 0208 未收录的生僻汉字（会被放行）——比误删台词安全。
bool _isJapaneseCharsetCodeUnit(int c) {
  if (c == 0x09 || c == 0x0A || c == 0x0D) {
    return true; // 制表/换行交给专门的步骤处理，这里不误删。
  }
  if (c >= 0x20 && c <= 0x7E) {
    return true; // ASCII 可打印
  }
  if (c == 0x00A5 || c == 0x00A7 || c == 0x00B0 || c == 0x00B1 || c == 0x00D7) {
    return true;
  }
  if (c >= 0x0391 && c <= 0x03C9) {
    return true; // 希腊
  }
  if (c == 0x0401 || c == 0x0451 || (c >= 0x0410 && c <= 0x044F)) {
    return true; // 西里尔
  }
  if (c >= 0x2010 && c <= 0x203B) {
    return true; // 连字符/引号/中黑/※ 等常用标点
  }
  if (c >= 0x2160 && c <= 0x217B) {
    return true; // 罗马数字（CP932 扩展）
  }
  if (c >= 0x2190 && c <= 0x2193) {
    return true; // 箭头
  }
  if (c >= 0x2460 && c <= 0x2473) {
    return true; // 丸数字（CP932 扩展）
  }
  if (c >= 0x2500 && c <= 0x254B) {
    return true; // 制表符号
  }
  if (c >= 0x25A0 && c <= 0x25EF) {
    return true; // ■ ● ◆ 等
  }
  if (c >= 0x3000 && c <= 0x30FF) {
    return true; // CJK 标点 + 平假名 + 片假名
  }
  if (c >= 0x4E00 && c <= 0x9FFF) {
    return true; // CJK 统一汉字（近似：JIS X 0208 只收其中约 6355 字）
  }
  if (c >= 0xFF01 && c <= 0xFF9F) {
    return true; // 全角 ASCII + 半角片假名
  }
  if (c >= 0xFFE0 && c <= 0xFFE5) {
    return true; // 全角货币/记号
  }
  return false;
}

String _filterNonJapanese(String text) {
  final StringBuffer out = StringBuffer();
  for (final int c in text.codeUnits) {
    if (_isJapaneseCharsetCodeUnit(c)) {
      out.writeCharCode(c);
    }
  }
  return out.toString();
}

/// 剔除 C0/C1 控制符。换行（LF/CR）与制表符**不动**——它们由
/// [GalTextProcessKind.filterLineBreaks] 单独管，两步职责不重叠。
String _filterControlChars(String text) {
  final StringBuffer out = StringBuffer();
  for (final int c in text.codeUnits) {
    if (c == 0x09 || c == 0x0A || c == 0x0D) {
      out.writeCharCode(c);
      continue;
    }
    if (c < 0x20 || c == 0x7F || (c >= 0x80 && c <= 0x9F)) {
      continue;
    }
    out.writeCharCode(c);
  }
  return out.toString();
}

const String _asciiPunctuation = r"""!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~""";

String _filterAsciiPunctuation(String text) {
  final StringBuffer out = StringBuffer();
  for (final int c in text.codeUnits) {
    if (c < 0x80 && _asciiPunctuation.codeUnits.contains(c)) {
      continue;
    }
    out.writeCharCode(c);
  }
  return out.toString();
}

/// 只留「」内的内容。
///
/// 未出现成对「」时返回**空串**——这正是该步骤的用途（丢掉旁白只留台词），
/// 调用方据此整行丢弃。可视化会把「这一步清空了整行」显著标出，用户能看见代价。
String _keepJapaneseQuotes(String text) {
  final Iterable<RegExpMatch> matches = RegExp(r'「([^「」]*)」').allMatches(text);
  if (matches.isEmpty) {
    return '';
  }
  return matches.map((RegExpMatch m) => m.group(1) ?? '').join();
}

/// `{漢字/かんじ}` → `漢字`；不含 `/` 的 `{…}` 整体删除（引擎控制标记）。
String _stripCurlyBraces(String text) =>
    text.replaceAllMapped(RegExp(r'\{([^{}]*)\}'), (Match m) {
      final String body = m.group(1) ?? '';
      final int slash = body.indexOf('/');
      if (slash < 0) {
        return '';
      }
      return body.substring(0, slash);
    });

String _takeLines(String text, int count, bool fromEnd) {
  if (count <= 0) {
    return text;
  }
  final List<String> lines = text.split(RegExp(r'\r\n|\r|\n'));
  if (lines.length <= count) {
    return text;
  }
  final List<String> taken = fromEnd
      ? lines.sublist(lines.length - count)
      : lines.sublist(0, count);
  return taken.join('\n');
}

String _replace(String text, GalTextProcessStep step) {
  if (step.pattern.isEmpty) {
    return text;
  }
  if (!step.isRegex) {
    return text.replaceAll(step.pattern, step.replacement);
  }
  final RegExp? re = tryCompileGalTextPattern(step.pattern);
  if (re == null) {
    // 用户正则写坏时保持原文——热路径不能因为一条规则语法错就把整行吞掉。
    return text;
  }
  return text.replaceAll(re, step.replacement);
}

/// 编译用户正则；语法错返回 null（UI 据此标红，热路径据此跳过该步）。
RegExp? tryCompileGalTextPattern(String pattern) {
  if (pattern.isEmpty) {
    return null;
  }
  try {
    return RegExp(pattern, multiLine: true);
  } on FormatException {
    return null;
  }
}

// ---------------------------------------------------------------------------
// 全角/半角正规化
// ---------------------------------------------------------------------------

/// 半角片假名 → 全角片假名（清音）。索引 = 码位 - 0xFF61。
const String _halfwidthKatakana =
    '。「」、・ヲァィゥェォャュョッーアイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワン゛゜';

/// 能加浊点的半角片假名 → 浊音全角。
const Map<String, String> _voicedKatakana = <String, String>{
  'カ': 'ガ',
  'キ': 'ギ',
  'ク': 'グ',
  'ケ': 'ゲ',
  'コ': 'ゴ',
  'サ': 'ザ',
  'シ': 'ジ',
  'ス': 'ズ',
  'セ': 'ゼ',
  'ソ': 'ゾ',
  'タ': 'ダ',
  'チ': 'ヂ',
  'ツ': 'ヅ',
  'テ': 'デ',
  'ト': 'ド',
  'ハ': 'バ',
  'ヒ': 'ビ',
  'フ': 'ブ',
  'ヘ': 'ベ',
  'ホ': 'ボ',
  'ウ': 'ヴ',
};

/// 能加半浊点的半角片假名 → 半浊音全角。
const Map<String, String> _semiVoicedKatakana = <String, String>{
  'ハ': 'パ',
  'ヒ': 'ピ',
  'フ': 'プ',
  'ヘ': 'ペ',
  'ホ': 'ポ',
};

/// 全角 ASCII → 半角、全角空格 → 半角空格、半角片假名 → 全角（合成浊点）。
///
/// 不是完整的 Unicode NFKC（Dart 标准库没有，为一步清洗引一个正规化依赖不划算）；
/// 覆盖的是 VN 文本里真正出现的宽度差异。
String normalizeGalTextWidth(String text) {
  final StringBuffer out = StringBuffer();
  final List<int> units = text.codeUnits;
  for (int i = 0; i < units.length; i += 1) {
    final int c = units[i];
    if (c >= 0xFF01 && c <= 0xFF5E) {
      out.writeCharCode(c - 0xFEE0); // 全角 ASCII → 半角
      continue;
    }
    if (c == 0x3000) {
      out.writeCharCode(0x20); // 全角空格
      continue;
    }
    if (c >= 0xFF61 && c <= 0xFF9F) {
      final String base = _halfwidthKatakana[c - 0xFF61];
      final int? next = i + 1 < units.length ? units[i + 1] : null;
      if (next == 0xFF9E && _voicedKatakana.containsKey(base)) {
        out.write(_voicedKatakana[base]);
        i += 1;
        continue;
      }
      if (next == 0xFF9F && _semiVoicedKatakana.containsKey(base)) {
        out.write(_semiVoicedKatakana[base]);
        i += 1;
        continue;
      }
      out.write(base);
      continue;
    }
    out.writeCharCode(c);
  }
  return out.toString();
}

// ---------------------------------------------------------------------------
// 去重复类
// ---------------------------------------------------------------------------

int _gcd(int a, int b) {
  int x = a;
  int y = b;
  while (y != 0) {
    final int t = x % y;
    x = y;
    y = t;
  }
  return x;
}

/// `AAAABBBBCCCC` → `ABC`。
///
/// [repeatCount] 为 null 时自动分析：取所有游程长度的最大公约数 g 作为重复倍数，
/// 每段长度除以 g。**g == 1 时原样返回**——说明各段长度不成统一倍数，不是「每字重复
/// n 次绘制」的伪影，强压会把本来就叠字的台词（「ああ」「うふふ」）写坏。
String dedupeGalTextChars(String text, int? repeatCount) {
  if (text.isEmpty) {
    return text;
  }
  final List<int> units = text.codeUnits;
  final List<int> runLengths = <int>[];
  final List<int> runChars = <int>[];
  int i = 0;
  while (i < units.length) {
    int j = i;
    while (j < units.length && units[j] == units[i]) {
      j += 1;
    }
    runChars.add(units[i]);
    runLengths.add(j - i);
    i = j;
  }
  int factor;
  if (repeatCount != null) {
    if (repeatCount <= 1) {
      return text;
    }
    factor = repeatCount;
  } else {
    factor = runLengths.fold<int>(0, (int acc, int len) => _gcd(acc, len));
    if (factor <= 1) {
      return text;
    }
  }
  final StringBuffer out = StringBuffer();
  for (int k = 0; k < runChars.length; k += 1) {
    final int len = runLengths[k];
    // 除不尽的游程原样保留：宁可少清洗一段，也不猜着截断。
    final int keep = len % factor == 0 ? len ~/ factor : len;
    for (int n = 0; n < keep; n += 1) {
      out.writeCharCode(runChars[k]);
    }
  }
  return out.toString();
}

/// `ABCDABCDABCD` → `ABCD`。
///
/// [repeatCount] 给定则只在「整串恰好由 repeatCount 份相同块拼成」时折叠；
/// null 时自动找最小周期（份数 ≥ 2）。
String dedupeGalTextBlock(String text, int? repeatCount) {
  final int len = text.length;
  if (len < 2) {
    return text;
  }
  if (repeatCount != null) {
    if (repeatCount <= 1 || len % repeatCount != 0) {
      return text;
    }
    final int unit = len ~/ repeatCount;
    return _isRepeatedBy(text, unit) ? text.substring(0, unit) : text;
  }
  for (int unit = 1; unit <= len ~/ 2; unit += 1) {
    if (len % unit != 0) {
      continue;
    }
    if (_isRepeatedBy(text, unit)) {
      return text.substring(0, unit);
    }
  }
  return text;
}

bool _isRepeatedBy(String text, int unit) {
  if (unit <= 0 || text.length % unit != 0) {
    return false;
  }
  final String head = text.substring(0, unit);
  for (int at = unit; at < text.length; at += unit) {
    if (text.substring(at, at + unit) != head) {
      return false;
    }
  }
  return true;
}

/// `S1S1S1S2S2S2` → `S1S2`：折叠**连续重复的行**。
///
/// 行是这里唯一可靠的块边界（native 按行发）。整段只有一行时退化为整串最小周期折叠，
/// 这样单行内的整块重复也能被自动吃掉。
String dedupeGalTextLines(String text) {
  final List<String> lines = text.split(RegExp(r'\r\n|\r|\n'));
  if (lines.length == 1) {
    return dedupeGalTextBlock(text, null);
  }
  final List<String> kept = <String>[];
  for (final String line in lines) {
    if (kept.isNotEmpty && kept.last == line) {
      continue;
    }
    kept.add(line);
  }
  return kept.map((String l) => dedupeGalTextBlock(l, null)).join('\n');
}

/// 由 `n(n+1)/2 == len` 反解逐字绘制的段数；解不出返回 null。
int? _triangularCount(int len) {
  int n = 1;
  int sum = 1;
  while (sum < len) {
    n += 1;
    sum += n;
  }
  return sum == len ? n : null;
}

/// `ABCDBCDCDD` → `ABCD`：递减子串（`P` + `P[1:]` + `P[2:]` + … + `P[n-1:]`）。
///
/// 先试按行切（引擎多半逐次重绘成多行），再试无分隔的整串反解。
String dedupeGalTextDescending(String text) {
  final List<String> lines = text.split(RegExp(r'\r\n|\r|\n'));
  if (lines.length >= 2) {
    final String head = lines.first;
    if (head.length >= lines.length) {
      bool ok = true;
      for (int i = 0; i < lines.length; i += 1) {
        if (i >= head.length || lines[i] != head.substring(i)) {
          ok = false;
          break;
        }
      }
      if (ok) {
        return head;
      }
    }
    return text;
  }
  final int? n = _triangularCount(text.length);
  if (n == null || n < 2) {
    return text;
  }
  final String head = text.substring(0, n);
  final StringBuffer rebuilt = StringBuffer();
  for (int i = 0; i < n; i += 1) {
    rebuilt.write(head.substring(i));
  }
  return rebuilt.toString() == text ? head : text;
}

/// `AABABCABCD` → `ABCD`：逐字绘制递增子串（`P[:1]` + `P[:2]` + … + `P[:n]`）。
String dedupeGalTextAscending(String text) {
  final List<String> lines = text.split(RegExp(r'\r\n|\r|\n'));
  if (lines.length >= 2) {
    final String tail = lines.last;
    if (tail.length >= lines.length) {
      bool ok = true;
      for (int i = 0; i < lines.length; i += 1) {
        if (lines[i] != tail.substring(0, i + 1)) {
          ok = false;
          break;
        }
      }
      if (ok) {
        return tail;
      }
    }
    return text;
  }
  final int? n = _triangularCount(text.length);
  if (n == null || n < 2) {
    return text;
  }
  final String tail = text.substring(text.length - n);
  final StringBuffer rebuilt = StringBuffer();
  for (int i = 1; i <= n; i += 1) {
    rebuilt.write(tail.substring(0, i));
  }
  return rebuilt.toString() == text ? tail : text;
}
