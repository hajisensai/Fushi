/// 让 AI 按自然语言描述生成 galgame 文本处理步骤。
///
/// 这是本仓第一个 AI 功能，边界刻意划得很窄：**AI 只产出配置，不参与运行期文本处理**。
/// 也就是说 hook 文本的热路径永远是本地纯函数
/// （`galgame_text_process.dart`），AI 只在用户点「让 AI 帮我写规则」时被调用一次，
/// 产物是可读、可改、可删的步骤列表。这样断网、没配 AI、AI 抽风都不影响抓文本。
///
/// 产出一律经 [parseAiTextProcessSuggestion] 校验后才落地：正则编译不过的直接丢，
/// 不把一条编译不过的规则塞进用户管线（那会在预览里表现成「这步什么也没做」）。
library;

import 'dart:convert';

import 'package:fushi/src/ai/ai_chat_client.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_reply_json.dart';
import 'package:fushi/src/mining/galgame_text_process.dart';

/// AI 给出的一组建议步骤。
class AiTextProcessSuggestion {
  const AiTextProcessSuggestion({required this.steps, this.explanation = ''});

  final List<GalTextProcessStep> steps;

  /// AI 对自己这组规则的一句话说明，直接显示给用户。
  final String explanation;

  bool get isEmpty => steps.isEmpty;
}

/// 系统提示：把可用步骤的**真实语义**交代清楚，否则模型只会一律用正则。
///
/// 清单从 [GalTextProcessKind] 推导而不是手抄，这样加一种处理项时提示词自动跟上。
String buildAiTextProcessSystemPrompt() {
  final StringBuffer kinds = StringBuffer();
  for (final GalTextProcessKind kind in GalTextProcessKind.values) {
    kinds.writeln('- ${kind.storageKey}: ${_kindSemantics(kind)}');
  }
  return '''
You configure a text-cleanup pipeline for Japanese visual-novel text captured by a
text hook. The pipeline runs locally; you only emit its configuration.

Available step kinds:
$kinds
Rules:
- Answer with a single JSON object and nothing else: {"explanation": "...", "steps": [...]}.
- Each step is {"kind": "<one of the kinds above>", ...parameters}.
- For "replace" also give "pattern" (a Dart/JavaScript-flavoured regular expression),
  "replacement", and "isRegex": true (or false for a literal string replacement).
- For "takeLines" give "lineCount" (int) and optionally "fromEnd" (bool).
- For "dedupeChars" / "dedupeBlockFixed" give "repeatCount" (int) only when the user
  states an exact repeat count; omit it to let the app analyse it automatically.
- Prefer a dedicated kind over a hand-written regex when one fits.
- Keep the pipeline minimal: only steps the user actually asked for.
- "explanation" must be written in the same language the user wrote in.
''';
}

String _kindSemantics(GalTextProcessKind kind) => switch (kind) {
  GalTextProcessKind.filterNonJapanese =>
    'drop characters not representable in the Japanese charset (CP932)',
  GalTextProcessKind.filterControlChars =>
    'drop ASCII control characters (newlines and tabs are left alone)',
  GalTextProcessKind.filterAsciiPunctuation =>
    'drop half-width ASCII punctuation',
  GalTextProcessKind.keepJapaneseQuotes =>
    'keep only text inside 「」 quotes; a line with no quotes becomes empty and is dropped',
  GalTextProcessKind.stripCurlyBraces =>
    'remove furigana braces: {漢字/かんじ} keeps 漢字, a {…} without a slash is removed entirely',
  GalTextProcessKind.normalizeWidth =>
    'full-width ASCII to half-width, half-width katakana to full-width (voiced marks composed)',
  GalTextProcessKind.takeLines => 'keep only the first (or last) N lines',
  GalTextProcessKind.dedupeChars =>
    'collapse repeated characters: AAAABBBBCCCC -> ABC',
  GalTextProcessKind.dedupeBlockFixed =>
    'collapse a whole repeated block: ABCDABCDABCD -> ABCD',
  GalTextProcessKind.dedupeLinesAuto =>
    'collapse consecutive duplicate lines: S1S1S1S2S2S2 -> S1S2',
  GalTextProcessKind.dedupeDescending =>
    'collapse a shrinking-suffix redraw: ABCDBCDCDD -> ABCD',
  GalTextProcessKind.dedupeAscending =>
    'collapse a growing-prefix redraw (typewriter effect): AABABCABCD -> ABCD',
  GalTextProcessKind.stripAngleBrackets => 'remove <…> tags',
  GalTextProcessKind.filterLineBreaks =>
    'remove line breaks, or replace them with "replacement"',
  GalTextProcessKind.filterDigits => 'remove digits (half and full width)',
  GalTextProcessKind.filterLatinLetters =>
    'remove Latin letters (half and full width)',
  GalTextProcessKind.replace => 'user-defined regex or literal replacement',
};

/// 组装用户侧的提示。[sampleText] 是当前线程抓到的真实一行，给了模型才有的放矢。
String buildAiTextProcessUserPrompt({
  required String request,
  String sampleText = '',
  String currentOutput = '',
}) {
  final StringBuffer buffer = StringBuffer()..writeln('Request: $request');
  if (sampleText.trim().isNotEmpty) {
    buffer.writeln('Sample captured line: ${jsonEncode(sampleText)}');
  }
  if (currentOutput.trim().isNotEmpty && currentOutput != sampleText) {
    buffer.writeln(
      'What the current pipeline already produces: ${jsonEncode(currentOutput)}',
    );
  }
  return buffer.toString();
}

/// 解析模型回复。
///
/// 容忍两种常见的不听话：整段裹在 ```json 围栏里、JSON 前后带解释性散文。
/// 解析不出结构就返回空建议——宁可让用户重试，也不把半截垃圾塞进管线。
AiTextProcessSuggestion parseAiTextProcessSuggestion(
  String reply, {
  required GalTextProcessPipeline into,
}) {
  final String? jsonText = extractAiJsonObject(reply);
  if (jsonText == null) {
    return const AiTextProcessSuggestion(steps: <GalTextProcessStep>[]);
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(jsonText);
  } on FormatException {
    return const AiTextProcessSuggestion(steps: <GalTextProcessStep>[]);
  }
  if (decoded is! Map) {
    return const AiTextProcessSuggestion(steps: <GalTextProcessStep>[]);
  }
  final Object? rawSteps = decoded['steps'];
  if (rawSteps is! List) {
    return const AiTextProcessSuggestion(steps: <GalTextProcessStep>[]);
  }
  final List<GalTextProcessStep> steps = <GalTextProcessStep>[];
  // id 要在「已有管线 + 本批新加的」里都唯一，所以边生成边把新步骤并进去算。
  GalTextProcessPipeline scratch = into;
  for (final Object? raw in rawSteps) {
    if (raw is! Map) {
      continue;
    }
    final GalTextProcessKind? kind = GalTextProcessKind.fromStorageKey(
      raw['kind'] as String?,
    );
    if (kind == null) {
      continue;
    }
    // 模型给的正则编译不过就整步丢掉：留着只会在预览里表现成「这步什么也没做」，
    // 比直接告诉用户「这条没生成出来」更难排查。
    if (kind == GalTextProcessKind.replace) {
      final String pattern = raw['pattern'] as String? ?? '';
      final bool isRegex = raw['isRegex'] as bool? ?? true;
      if (pattern.isEmpty ||
          (isRegex && tryCompileGalTextPattern(pattern) == null)) {
        continue;
      }
    }
    final Map<Object?, Object?> withId = <Object?, Object?>{
      ...raw.cast<Object?, Object?>(),
      'id': scratch.nextIdFor(kind),
      'kind': kind.storageKey,
    };
    final GalTextProcessStep step = GalTextProcessStep.fromJson(withId);
    steps.add(step);
    scratch = scratch.withSteps(<GalTextProcessStep>[...scratch.steps, step]);
  }
  final Object? explanation = decoded['explanation'];
  return AiTextProcessSuggestion(
    steps: List<GalTextProcessStep>.unmodifiable(steps),
    explanation: explanation is String ? explanation.trim() : '',
  );
}

/// 跑一次「让 AI 写规则」。
///
/// 失败原样抛 [AiChatFailure]（文案已脱敏），由 UI 转成提示。
Future<AiTextProcessSuggestion> requestAiTextProcessSteps({
  required AiChatClient client,
  required AiProviderConfig provider,
  required String request,
  required GalTextProcessPipeline into,
  String sampleText = '',
  String currentOutput = '',
}) async {
  final String reply = await client.complete(
    provider: provider,
    messages: <AiChatMessage>[
      AiChatMessage.system(buildAiTextProcessSystemPrompt()),
      AiChatMessage.user(
        buildAiTextProcessUserPrompt(
          request: request,
          sampleText: sampleText,
          currentOutput: currentOutput,
        ),
      ),
    ],
  );
  return parseAiTextProcessSuggestion(reply, into: into);
}
