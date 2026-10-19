import 'dart:convert';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';

/// 按提示词作答的假 completer：记下每次提示词，[answer] 返回正文（或抛错）。
class FakeAiCompleter implements AiTextCompleter {
  FakeAiCompleter(this.answer, {this.usage});

  final String Function(String prompt, int call) answer;
  final AiChatUsage? usage;
  final List<String> prompts = <String>[];

  int get calls => prompts.length;

  @override
  Future<AiChatCompletion> complete(String prompt) async {
    prompts.add(prompt);
    return AiChatCompletion(
      text: answer(prompt, prompts.length - 1),
      usage: usage,
    );
  }
}

/// 一调用就失败（用来断言「走了缓存、没发请求」）。
class ExplodingAiCompleter implements AiTextCompleter {
  ExplodingAiCompleter([this.reason = 'should_not_be_called']);

  final String reason;
  int calls = 0;

  @override
  Future<AiChatCompletion> complete(String prompt) async {
    calls++;
    throw SubtitleAiRequestFailure(reason);
  }
}

final RegExp _kTargetId = RegExp(r'^id=(\d+) ', multiLine: true);

/// 提示词里的目标 id（`id=N ` 开头的行）。
List<int> targetIdsOf(String prompt) => <int>[
  for (final RegExpMatch m in _kTargetId.allMatches(prompt))
    int.parse(m.group(1)!),
];

/// 把提示词里每个目标 id 映射成 [fix] 给的正文的 JSON 回复（包一层 ```json 围栏，
/// 顺便覆盖宽松解析）。
String replyForIds(String prompt, String Function(int id) fix) =>
    '```json\n${jsonEncode(<String, String>{for (final int id in targetIdsOf(prompt)) '$id': fix(id)})}\n```';
