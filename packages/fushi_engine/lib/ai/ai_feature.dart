/// 「哪个功能用哪家 AI」的映射。
///
/// 与提供商清单分开存：一家提供商可以被多个功能选中，删掉一家提供商时映射要能
/// 优雅退化成「未指派」而不是指向一个不存在的 id（[AiFeatureAssignments.resolve]
/// 负责这层校验）。
library;

import 'dart:convert';

import 'package:fushi_engine/ai/ai_provider_config.dart';

/// 可以指派 AI 提供商的功能。
///
/// 枚举而不是裸字符串，是为了让「新增一个 AI 功能」必须同时面对映射 UI、默认值
/// 和持久化三处，不会漏。所有功能共守一条边界：**AI 只产出配置或在已取回的候选里
/// 做排序/选择，热路径永远是本地确定性代码**；没指派提供商时行为与没有 AI 完全一致。
///
/// 已删除的「查词按句意挑词条」（`lookupContext`，2026-10-09 所有者拍板移除）不再
/// 是枚举值：存量 JSON 里的 `lookupContext` 键由 [fromStorageKey] 认不出、读取时
/// 忽略，下次保存自然消失。
enum AiFeature {
  /// galgame 文本处理：让 AI 按自然语言描述生成正则替换规则。
  galgameTextProcess,

  /// 词典弹窗样式：按自然语言描述生成可视化规则 + 补充 CSS（进草稿，不直接保存）。
  dictStyle,

  /// Lapis 卡片样式：按自然语言描述生成可视化规则 + 用户区段 CSS（进编辑器草稿）。
  lapisStyle,

  /// 复习卡片模板（`ai_srs_template_assistant.dart`）：按一句话生成 / 修改 Fushi 复习的
  /// 可视化卡片布局，并给字段写说明。AI 只产出块列表与说明文字（字段只能引用已有字段、
  /// 种类与样式只能取固定枚举），一律进模板编辑器草稿，用户看过预览、点保存才落库。
  srsTemplate,

  /// 复习笔记字段（`ai_srs_field_assistant.dart`）：在笔记编辑页按单个字段写释义 / 翻译 /
  /// 改写。与 [srsTemplate] 分开指派：模板是一次性的布局配置，字段是逐条高频生成的内容，
  /// 用户常想给它配更便宜 / 更快的模型。**「AI 只产出配置」边界的显式例外**（所有者
  /// 2026-10-23 同意）：产物是字段内容，只进编辑页草稿，回复里的 HTML 只留排版标签，
  /// 用户点保存才落库；未指派不发任何请求。
  srsNoteField,

  /// 视频刮削身份消解：在线源给出多个候选时由 AI 在候选里选唯一命中，低置信仍进
  /// 「待确认」。
  videoIdentify,

  /// 视频搜索辅助：后台补字幕重排（`aiSubtitleBackfillReorder`）；页面上的排序 /
  /// 补词按钮已于 2026-09-22 移除。
  videoSearch,

  /// 自定义主题：按自然语言描述生成一组角色配色（进编辑页草稿，不直接应用）。
  customTheme,

  /// AI 下载：视频（一句话 → 结构化意图 + 多义作品选择 + 版本 tie-break）与
  /// 浏览 › 发现的小说 / 漫画 / 游戏（一句话 → 搜索词 + 在已取回的候选里挑推荐项）
  /// 共用这一个指派——同一件事「跟 AI 说想要什么，由它帮着下」，设置里只列一行。
  /// 热路径（搜作品 / 搜资源 / 选版本 / 入队 / 建订阅 / 入库）仍是本地确定性代码，
  /// AI 输出里没有自由文本字段。
  ///
  /// 持久化键沿用合并前视频那一行的 `videoAcquire`（见 [storageKey]），已有指派
  /// 原样生效；只指派过旧「AI 下载（小说 / 漫画 / 游戏）」行的用户由
  /// [AiFeatureAssignments.fromJson] 把 [_kLegacyMediaAcquireKey] 迁过来。
  acquire,

  /// 漫画 OCR 大模型识别（`manga_ai_ocr_refiner.dart`）：本地检测出框，框里的字
  /// 交视觉模型重读（只读低置信度块 / 全部块）。
  ///
  /// **「AI 只产出配置」边界的显式例外**（2026-10-03 所有者在群里点名要这个选项：
  /// 「遇到置信度不高的丢给 AI」「有钱的干脆 AI 全干了」）：这里模型的输出就是
  /// 页面上的文字，没有「草稿 / 待确认」可走。补偿措施——默认关，**只有**在漫画
  /// OCR 设置里显式选了档位才会发请求（配了默认提供商也不会自动生效：上传整卷
  /// 漫画、按量计费，绝不能静默开启）；回复须过本地校验（JSON 形状、编号、长度）
  /// 才替换本地文字，失败一律保留本地结果；框与排版始终是本地的。
  mangaOcr,

  /// 有声书选角（`tts_cast_annotator.dart`）：让 AI 给整书每句标「谁在说话」，供
  /// 多声优配音分派声音。AI 只产出说话人标签（进选角表，用户可逐句改、可合并
  /// 改名，重新标注不覆盖手改）；角色配哪份声音始终由用户决定；合成的文本永远是
  /// 书里的原文，不合成任何 AI 生成的文字。
  audiobookCast,

  /// 合集成员顺序（`ai_collection_order_assistant.dart`）：规则（集号 / 卷号）判不出
  /// 位置的成员——SP / OVA / 特别篇 / 总集篇、汉字卷号 / 上下卷 / 外传——由 AI 在
  /// 已有成员里决定插在哪。AI 只给下标排列，规则排得出的成员相对序由本地钉死；
  /// 自动路径只在用户没手动排过（`orderUpdatedAt == 0`）时落盘，绝不覆盖手动序。
  collectionOrder,

  /// AI 整理库（`ai_library_organize_assistant.dart`，spec
  /// `docs/specs/2026-10-20-ai-library-organize-design.md`，所有者 2026-10-20 拍板直接
  /// 改库、可自动运行）：把书架 / 漫画库 / 视频库 / 游戏库里规则认不出的「该在一起」的
  /// 条目归进合集（新建 / 并入 / 合并 / 移出自己上次放错的）。AI 只给分组建议（局部
  /// 下标 + 原语言正式名），落盘前本地逐条校验：不跨域、不碰用户的合集（只能往里加）、
  /// 不复活用户拒绝过的分组、刮削 id 冲突降级；每处改动写进本机整理记录，可撤销。
  /// 多端各自整理靠分组键收敛（`organize_convergence.dart`），不靠互斥。
  libraryOrganize,

  /// 视频日语字幕 AI 校对（`media/video/subtitle/asr_proofread/`，spec
  /// `2026-10-19-video-asr-llm-subtitle-pipeline`）：作品专名表（S0）、逐批校对
  /// 语音识别稿（S3）、整作写法统一（S4）、短片段是否纯歌曲（S5）。
  ///
  /// 与 [mangaOcr] 同属「AI 只产出配置」边界的显式例外：模型输出就是字幕正文。
  /// 补偿措施——只发 ASR 文本与专名表（不发音频 / 画面）；时间轴永远是本地识别
  /// 的，AI 只改文字；回复必须覆盖整批全部 id 才落盘，缺 id / 解析失败重试，
  /// 最终失败报错停下而不是静默保留原稿；已有同名字幕绝不覆盖。
  ///
  /// 同一指派也服务语音转录弹层的「AI 校对」（`asr/asr_transcript_proofreader.dart`，
  /// 有声书 / 视频转录稿通用）：只改文字、补标点，cue 数量与时间轴不变，回复缺条
  /// 的那一块整块放弃；校对前的原稿留备份、可还原。只在用户点「AI 校对」时发请求。
  subtitleProofread,

  /// 云端语音转录（`asr/cloud_whisper_transcription_service.dart`）：把音频交给
  /// OpenAI 兼容的 `/audio/transcriptions`（Groq / OpenAI Whisper 等）转字幕。这家
  /// 提供商的「模型」填 Whisper 模型名（如 Groq 的 `whisper-large-v3`）。
  ///
  /// 与 [mangaOcr] 同属上传用户内容、按量计费的一类，所以**不跟随默认提供商**
  /// （[followsDefaultProvider]）：默认提供商多半是聊天模型，跟过来只会在转录时
  /// 报错，也不该在用户没点名的情况下把整本有声书传出去。只有显式指派了一家、并在
  /// 转录弹层里选了「云端」引擎才会发请求；产物与设备端转录同构（单时间轴 SRT +
  /// 逐 token 时间 sidecar），时间轴来自服务端的逐词 / 逐段时间。
  cloudTranscription,

  /// 作品图谱裁决（`ai_media_link_assistant.dart`，spec
  /// `docs/specs/2026-10-24-cross-media-links.md`「AI 辅助判断」）：确定性规则缩出的
  /// 候选（标题对得上但没有共享 id 的跨模块条目）交 AI 判是否同一作品、关系与方向。
  /// AI 只按候选下标回结论，不产生任何 id；结论一律写成建议，用户确认后才算事实。
  /// 只在用户点「查找相关作品」时发请求。
  mediaLinks,

  /// AI 助手（spec `docs/specs/2026-10-26-ai-operations-agent-design.md`）：用户用一句
  /// 话让 AI 代办 app 里的操作（下扩展 / 视频 / 字幕、调设置、处理刮削与冲突）。
  /// AI 只能调用操作目录里的操作（与 UI 按钮、`fushi_cli` 同一个 handler）。规则是
  /// **写操作必须可回滚**（`fushi/CLAUDE.md` §13，所有者 2026-10-26 拍板）：可撤销的
  /// 直接执行并记进本机操作记录，不可逆的与装扩展（D9）先出确认卡片，表态参数模型
  /// 填不出来。只在用户在 AI 页 / 浮层里说话时发请求；没指派提供商时入口可见、点了
  /// 引导去设置。
  agent;

  /// 没显式指派时是否跟随默认提供商（见 [cloudTranscription]）。
  bool get followsDefaultProvider => this != AiFeature.cloudTranscription;

  /// 持久化键。[acquire] 钉在合并前的 `videoAcquire`，其余与枚举名一致；
  /// 改枚举名不能改这里，否则存量指派静默失效。
  String get storageKey => switch (this) {
    AiFeature.acquire => 'videoAcquire',
    _ => name,
  };

  static AiFeature? fromStorageKey(String? key) {
    if (key == null) {
      return null;
    }
    for (final AiFeature feature in AiFeature.values) {
      if (feature.storageKey == key) {
        return feature;
      }
    }
    return null;
  }
}

/// 功能行显式选「不使用 AI」时存的值：压过默认提供商。
///
/// 提供商 id 形如 `ai-<微秒>`（见设置区 `_pickPresetAndAdd`），不会撞上这个串。
const String kAiFeatureDisabled = 'off';

/// JSON 里默认提供商的键。`_` 前缀不是任何 [AiFeature.storageKey]，旧版本读到时
/// 按「认不出的功能」忽略——降级回旧版只是默认失效，不会误指派。
const String _kDefaultKey = '_default';

/// 合并进 [AiFeature.acquire] 之前「AI 下载（小说 / 漫画 / 游戏）」单独那一行的
/// 持久化键。读到它且没有 `videoAcquire` 指派时迁给 [AiFeature.acquire]；两者都有
/// 时以视频那行为准（它是先有的那一行）。下次保存时这个键自然消失。
const String _kLegacyMediaAcquireKey = 'mediaAcquire';

/// 功能 → 提供商 id 的映射 + 一个默认提供商。不可变。
///
/// 解析顺序（[resolve] 一处）：功能显式指派 > [kAiFeatureDisabled] 关掉 > 默认提供商。
/// 默认提供商是用户**自己选**的那一家，不是「列表里第一家可用的」——后者才是
/// 静默换人。有了它，配一家提供商只要选一次，不必把七个功能逐个指一遍。
class AiFeatureAssignments {
  const AiFeatureAssignments({
    this.providerIdByFeature = const <AiFeature, String>{},
    this.defaultProviderId,
  });

  factory AiFeatureAssignments.fromJson(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const AiFeatureAssignments();
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const AiFeatureAssignments();
    }
    if (decoded is! Map) {
      return const AiFeatureAssignments();
    }
    final Map<AiFeature, String> map = <AiFeature, String>{};
    decoded.forEach((Object? key, Object? value) {
      final AiFeature? feature = AiFeature.fromStorageKey(
        key is String ? key : null,
      );
      if (feature != null && value is String && value.trim().isNotEmpty) {
        map[feature] = value;
      }
    });
    final Object? legacyMedia = decoded[_kLegacyMediaAcquireKey];
    if (legacyMedia is String && legacyMedia.trim().isNotEmpty) {
      map.putIfAbsent(AiFeature.acquire, () => legacyMedia);
    }
    final Object? rawDefault = decoded[_kDefaultKey];
    return AiFeatureAssignments(
      providerIdByFeature: Map<AiFeature, String>.unmodifiable(map),
      defaultProviderId: rawDefault is String && rawDefault.trim().isNotEmpty
          ? rawDefault
          : null,
    );
  }

  /// 功能的显式指派；值为 [kAiFeatureDisabled] 表示这个功能不用 AI。
  final Map<AiFeature, String> providerIdByFeature;

  /// 没有显式指派的功能都用这一家；null = 没选默认。
  final String? defaultProviderId;

  /// 功能的**显式**指派（含 [kAiFeatureDisabled]）；null = 跟随默认。
  String? providerIdFor(AiFeature feature) => providerIdByFeature[feature];

  /// 功能实际要用的提供商 id（显式 > 关掉 > 默认），不校验这家是否还在。
  String? effectiveProviderIdFor(AiFeature feature) {
    final String? explicit = providerIdByFeature[feature];
    if (explicit == kAiFeatureDisabled) {
      return null;
    }
    return explicit ??
        (feature.followsDefaultProvider ? defaultProviderId : null);
  }

  /// 解析出这个功能**当前真能用**的提供商。
  ///
  /// 三种情况都退化成 null，由调用方统一提示「先去设置里配一家 AI」：
  /// 没指派（也没默认或被显式关掉）、指派的那家已被删掉、指派的那家没配全
  /// （[AiProviderConfig.isUsable]）。显式指派的那家失效时**不**回退到默认——
  /// 用户点名要这一家，静默换一家跑，结果变了也没法解释。
  AiProviderConfig? resolve(
    AiFeature feature,
    Iterable<AiProviderConfig> providers,
  ) {
    final String? id = effectiveProviderIdFor(feature);
    if (id == null) {
      return null;
    }
    for (final AiProviderConfig provider in providers) {
      if (provider.id == id) {
        return provider.isUsable ? provider : null;
      }
    }
    return null;
  }

  /// [providerId] 为 null / 空 = 跟随默认；[kAiFeatureDisabled] = 不用 AI。
  AiFeatureAssignments withAssignment(AiFeature feature, String? providerId) {
    final Map<AiFeature, String> next = Map<AiFeature, String>.of(
      providerIdByFeature,
    );
    if (providerId == null || providerId.trim().isEmpty) {
      next.remove(feature);
    } else {
      next[feature] = providerId;
    }
    return AiFeatureAssignments(
      providerIdByFeature: Map<AiFeature, String>.unmodifiable(next),
      defaultProviderId: defaultProviderId,
    );
  }

  AiFeatureAssignments withDefault(String? providerId) => AiFeatureAssignments(
    providerIdByFeature: providerIdByFeature,
    defaultProviderId: providerId == null || providerId.trim().isEmpty
        ? null
        : providerId,
  );

  /// 删掉一家提供商后清理指向它的映射（含默认）。
  AiFeatureAssignments withoutProvider(String providerId) {
    final Map<AiFeature, String> next = <AiFeature, String>{
      for (final MapEntry<AiFeature, String> e in providerIdByFeature.entries)
        if (e.value != providerId) e.key: e.value,
    };
    return AiFeatureAssignments(
      providerIdByFeature: Map<AiFeature, String>.unmodifiable(next),
      defaultProviderId: defaultProviderId == providerId
          ? null
          : defaultProviderId,
    );
  }

  String toJson() => jsonEncode(<String, String>{
    for (final MapEntry<AiFeature, String> e in providerIdByFeature.entries)
      e.key.storageKey: e.value,
    if (defaultProviderId != null) _kDefaultKey: defaultProviderId!,
  });
}
