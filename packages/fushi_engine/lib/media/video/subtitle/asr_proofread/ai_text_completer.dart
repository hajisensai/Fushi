/// 字幕管线调 AI 的唯一出口：可注入接口（测试用 fake）+ 生产实现（[AiChatClient]）。
///
/// 失败只有一种对外形状 [SubtitleAiRequestFailure]：额度用尽、鉴权被拒、网络、
/// 限流到放弃、回复反复不合格……上层一律进入「暂停：AI 请求失败（原因）」，缓存
/// 保留，用户处理后重跑即续。**绝不**把失败当成「AI 说不用改」——基准里踩过：额度
/// 耗尽时的报错被当成空修改写进缓存，30 段静默通过。
library;

import 'dart:convert';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';

/// AI 请求失败（或回复多次不合格），管线必须停下。
///
/// [reason] 是脱敏短码，可直接进 UI 文案：
/// - `AiChatClient` 的失败码原样带过：`quota_exhausted` / `unauthorized` /
///   `rate_limited` / `network_error` / `http_<状态码>` / `provider_not_configured` /
///   `bad_response` / `empty_response`；
/// - 管线自己的：[kSubtitleAiReplyIncomplete]（重试 3 次回复仍没覆盖全部 id 或解析
///   不出）、[kSubtitleAiNotConfigured]（开了 AI 却没解析出提供商）。
class SubtitleAiRequestFailure implements Exception {
  const SubtitleAiRequestFailure(this.reason, {this.detail, this.usage});

  final String reason;

  /// 排查用的补充（哪一批、缺哪些 id）；不含 AI 回复原文。
  final String? detail;

  /// 失败之前这次运行已经花掉的 AI 用量（管线在抛出前补上，见
  /// `VideoSubtitlePipeline.run`）；null = 抛出点不知道（单个阶段直接抛的）。失败不等于
  /// 没花钱：S0 重做两次后才判失败时，三次请求的 token 都已计费。
  final SubtitleAiUsageTally? usage;

  /// 带上 [usage] 的副本。
  SubtitleAiRequestFailure withUsage(SubtitleAiUsageTally usage) =>
      SubtitleAiRequestFailure(reason, detail: detail, usage: usage);

  @override
  String toString() =>
      'SubtitleAiRequestFailure($reason${detail == null ? '' : ': $detail'})';
}

/// 回复反复不合格（缺 id / 不是 JSON）。
const String kSubtitleAiReplyIncomplete = 'reply_incomplete';

/// 开了 AI 校对，但「字幕校对」功能解析不出可用的提供商。
const String kSubtitleAiNotConfigured = 'provider_not_configured';

/// 单轮问答。实现必须：成功返回正文与用量（取不到用量就是 null，不是 0）；
/// 模型回了空正文时返回空 `text`（由调用方当一次不合格回复重试）；其余失败抛
/// [SubtitleAiRequestFailure]，取消抛 [SubtitlePipelineCancelled]。
///
/// [stablePrefix]：提示词里**同一作品各批逐字相同**的那一段（规则 + 作品名 + 专名表），
/// [prompt] 是本批内容。两段拼起来（[joinAiTextPrompt]）就是完整提示词——拆开只为
/// 提示缓存：生产实现把前缀放 system（Anthropic 挂 `cache_control`），本批放 user。
/// 空前缀 = 整段都是本批内容。
abstract interface class AiTextCompleter {
  Future<AiChatCompletion> complete(String prompt, {String stablePrefix = ''});
}

/// 前缀与本批内容之间的分隔：拼回去与拆之前的整段提示词逐字相同（各阶段的拆法都
/// 落在原提示词的一个换行上）。
const String kAiTextPromptSeparator = '\n';

/// [AiTextCompleter.complete] 两段的完整提示词（测试替身与费用预估按它算）。
String joinAiTextPrompt(String stablePrefix, String prompt) =>
    stablePrefix.isEmpty
    ? prompt
    : '$stablePrefix$kAiTextPromptSeparator$prompt';

/// 记账包装：每次成功应答的用量都记进 [spent]（应答没带用量的记成未知调用），
/// 不改变被包装者的任何行为。管线用它在失败时上报「这次运行已经花了多少」——
/// 各阶段自己的用量账在失败时随异常一起丢掉了。
class SubtitleAiSpendingCompleter implements AiTextCompleter {
  SubtitleAiSpendingCompleter(this.inner);

  final AiTextCompleter inner;
  final SubtitleAiUsageTally spent = SubtitleAiUsageTally();

  @override
  Future<AiChatCompletion> complete(
    String prompt, {
    String stablePrefix = '',
  }) async {
    final AiChatCompletion reply = await inner.complete(
      prompt,
      stablePrefix: stablePrefix,
    );
    spent.addCall(reply.usage);
    return reply;
  }
}

/// 生产实现：[AiTextCompleter.complete] 的稳定前缀作一条可缓存的 system 消息、本批
/// 内容作 user 消息发给 [provider]。限频（`requestsPerMinute`）、key 轮换、临时性
/// 失败的退避重试都在 [AiChatClient] 里，这里不再重试。
///
/// 缓存：Anthropic 不加标记就完全不缓存（基准实跑的费用大头是缓存读写，直连
/// Anthropic 时没有它费用高出数倍），所以 system 标 [AiChatMessage.cacheable]；
/// OpenAI 兼容 / DeepSeek / Gemini 按前缀自动缓存，前缀稳定即命中。
class AiChatTextCompleter implements AiTextCompleter {
  AiChatTextCompleter({
    required this.client,
    required this.provider,
    this.maxTokens = kSubtitleAiMaxOutputTokens,
  });

  final AiChatClient client;
  final AiProviderConfig provider;
  final int maxTokens;

  @override
  Future<AiChatCompletion> complete(
    String prompt, {
    String stablePrefix = '',
  }) async {
    try {
      return await client.completeWithUsage(
        provider: provider,
        messages: <AiChatMessage>[
          if (stablePrefix.isNotEmpty)
            AiChatMessage.system(stablePrefix, cacheable: true),
          AiChatMessage.user(prompt),
        ],
        maxTokens: maxTokens,
      );
    } on AiChatFailure catch (failure) {
      if (failure.message == 'cancelled') {
        throw const SubtitlePipelineCancelled();
      }
      // 模型回了空正文：请求本身成功、token 也花了（用量未知），是「回复不合格」
      // 而不是「请求失败」——交给各阶段的重试循环当一次解析失败，3 次仍不行才报
      // reply_incomplete。
      if (failure.message == 'empty_response') {
        return const AiChatCompletion(text: '');
      }
      throw SubtitleAiRequestFailure(failure.message);
    }
  }
}

/// 一次校对请求的输出上限：30 句的修正 JSON 实测 ~1.5k token；专名表 60 条 ~5k。
/// 给推理模型的思考留余量。
const int kSubtitleAiMaxOutputTokens = 8192;

/// 累计的 AI 用量。缺用量的调用单独记 [callsWithoutUsage]，**不按 0 计**。
class SubtitleAiUsageTally {
  SubtitleAiUsageTally();

  factory SubtitleAiUsageTally.fromJson(Map<String, Object?> json) =>
      SubtitleAiUsageTally()
        ..calls = (json['calls'] as num?)?.round() ?? 0
        ..callsWithoutUsage = (json['callsWithoutUsage'] as num?)?.round() ?? 0
        ..inputTokens = (json['input'] as num?)?.round() ?? 0
        ..outputTokens = (json['output'] as num?)?.round() ?? 0
        ..cacheReadTokens = (json['cacheRead'] as num?)?.round() ?? 0
        ..cacheWriteTokens = (json['cacheWrite'] as num?)?.round() ?? 0;

  /// 发出且拿到回复的调用数（含回复不合格、被重试的那几次）。
  int calls = 0;

  /// 其中应答没带用量的调用数：它们的 token 未知，不在下面四项里。
  int callsWithoutUsage = 0;

  /// 已知的用量之和（各家没报的单项不计入；见 [AiChatUsage]）。
  int inputTokens = 0;
  int outputTokens = 0;
  int cacheReadTokens = 0;
  int cacheWriteTokens = 0;

  bool get hasUnknown => callsWithoutUsage > 0;

  void addCall(AiChatUsage? usage) {
    calls++;
    if (usage == null) {
      callsWithoutUsage++;
      return;
    }
    inputTokens += usage.inputTokens ?? 0;
    outputTokens += usage.outputTokens ?? 0;
    cacheReadTokens += usage.cacheReadTokens ?? 0;
    cacheWriteTokens += usage.cacheWriteTokens ?? 0;
  }

  void addTally(SubtitleAiUsageTally other) {
    calls += other.calls;
    callsWithoutUsage += other.callsWithoutUsage;
    inputTokens += other.inputTokens;
    outputTokens += other.outputTokens;
    cacheReadTokens += other.cacheReadTokens;
    cacheWriteTokens += other.cacheWriteTokens;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'calls': calls,
    'callsWithoutUsage': callsWithoutUsage,
    'input': inputTokens,
    'output': outputTokens,
    'cacheRead': cacheReadTokens,
    'cacheWrite': cacheWriteTokens,
  };

  @override
  String toString() => 'SubtitleAiUsageTally(${toJson()})';
}

/// 按 JSON 对象 / 数组「最外层括号」宽松抠出回复里的 JSON（同基准 `parse_obj` 的
/// 贪婪正则 `[\[{].*[\]}]`）：模型常在 JSON 外包 ```json 围栏或一句说明。
/// 解析不出返回 null。
Object? decodeLooseAiJson(String reply) {
  final int start = reply.indexOf(RegExp(r'[\[{]'));
  final int end = reply.lastIndexOf(RegExp(r'[\]}]'));
  if (start < 0 || end < start) return null;
  try {
    return jsonDecode(reply.substring(start, end + 1));
  } on FormatException {
    return null;
  }
}
