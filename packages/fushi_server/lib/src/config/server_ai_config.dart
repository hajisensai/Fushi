/// 服务端的 AI 提供商配置（配置文件 `ai:` 段 + WebUI / admin API）。
///
/// app 的 AI 配置是**设备本地**的（提供商清单 + 功能指派存进不出设备的偏好键）；
/// 服务端是另一台设备，所以它有自己的一份，而且**只有一家**：无头服务端上用 AI 的
/// 只有「AI 下视频」助手会话（手机把下载执行设备设成服务端时，整场对话在这里跑），
/// 配一家就等于把它指派给这个功能。放在 yaml 而不是 `preferences` 表：API key 与
/// qBittorrent 密码、TMDB key 同一处、同一套「不回显」纪律，也不会被同步带出去。
///
/// ```yaml
/// ai:
///   preset: "openai"          # kAiProviderPresets 的 id；custom = 全部自填
///   protocol: ""              # 空 = 跟随预设（openAiCompatible / anthropicMessages / geminiGenerateContent）
///   base_url: ""              # 空 = 预设地址
///   model: ""                 # 空 = 预设的起点模型
///   api_key: "sk-..."
///   reasoning_effort: "none"  # none / low / medium / high
///   allow_insecure_http: false
///   web_knowledge: true       # 联网资料（内置维基站）辅助识别作品 / 列系列
///   library_organize: false   # 扫描入库后自动 AI 整理库（把该在一起的归进合集）
/// ```
///
/// 没有 `ai:` 段 = 没指派提供商：能力位报 `no_provider`，**一个 AI 请求都不发**。
library;

import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_service.dart';

/// 服务端那一家 AI 在引擎提供商清单里的 id（只在进程内用，不落盘）。
const String kServerAiProviderId = 'server';

class ServerAiConfig {
  const ServerAiConfig({
    required this.preset,
    this.protocol,
    this.baseUrl,
    this.model,
    this.apiKey,
    this.reasoningEffort = AiReasoningEffort.none,
    this.allowInsecureHttp = false,
    this.webKnowledge = true,
    this.libraryOrganize = false,
  });

  /// 预设 id（[kAiProviderPresets]）或 [kAiCustomPresetId]。
  final String preset;

  /// 以下三项 null = 跟随预设。
  final AiWireProtocol? protocol;
  final String? baseUrl;
  final String? model;
  final String? apiKey;
  final AiReasoningEffort reasoningEffort;
  final bool allowInsecureHttp;
  final bool webKnowledge;

  /// 扫描入库后对规则归不了组的新条目跑一次自动 AI 整理（spec
  /// `docs/specs/2026-10-20-ai-library-organize-design.md` §10.2）。默认关：按量计费，
  /// 绝不静默开启。服务端通常就是那台「负责自动整理」的设备。
  final bool libraryOrganize;

  /// yaml `ai:` 段 → 配置；不是 map 或没有 `preset` → null（未配置）。解析保持宽松
  /// （手写的一条坏值不拒绝启动），地址等是否可用由 [problem] / [provider] 判。
  static ServerAiConfig? fromYaml(Object? raw) {
    if (raw is! Map) return null;
    final String preset = _text(raw['preset']) ?? '';
    if (preset.isEmpty) return null;
    final String? protocol = _text(raw['protocol']);
    return ServerAiConfig(
      preset: preset,
      protocol: protocol == null ? null : _protocol(protocol),
      baseUrl: _text(raw['base_url']),
      model: _text(raw['model']),
      apiKey: _text(raw['api_key']),
      reasoningEffort: AiReasoningEffort.fromStorageKey(_text(raw['reasoning_effort'])),
      allowInsecureHttp: raw['allow_insecure_http'] == true || '${raw['allow_insecure_http']}' == 'true',
      webKnowledge: raw['web_knowledge'] != false && '${raw['web_knowledge']}' != 'false',
      libraryOrganize: raw['library_organize'] == true || '${raw['library_organize']}' == 'true',
    );
  }

  static String? _text(Object? v) {
    final String s = '${v ?? ''}'.trim();
    return s.isEmpty ? null : s;
  }

  /// 未知协议名 → null（跟随预设），不静默落成 OpenAI 兼容。
  static AiWireProtocol? _protocol(String key) {
    for (final AiWireProtocol p in AiWireProtocol.values) {
      if (p.storageKey == key) return p;
    }
    return null;
  }

  AiProviderPreset? get _preset => aiProviderPresetById(preset);

  /// 生效的请求地址 / 模型 / 协议（显式配置 > 预设）。
  String get effectiveBaseUrl => baseUrl ?? _preset?.baseUrl ?? '';
  String get effectiveModel => model ?? _preset?.suggestedModel ?? '';
  AiWireProtocol get effectiveProtocol => protocol ?? _preset?.protocol ?? AiWireProtocol.openAiCompatible;

  /// 配置本身写错了（未知预设 / 地址非法 / 非 HTTPS 又没放行明文…）；写入口据此
  /// 拒绝整个请求。没错 → null。
  String? invalidReason() {
    if (preset != kAiCustomPresetId && _preset == null) return '未知预设 "$preset"';
    if (effectiveBaseUrl.isEmpty) return '缺少 base_url';
    try {
      _build();
    } on ArgumentError catch (e) {
      return '${e.message}';
    }
    return null;
  }

  /// 配置哪里不对或没配全（给状态显示用）；能用 → null。只缺 key / 模型的「没配全」
  /// 允许存盘（用户可以分两次填），但能力位照报 no_provider。
  String? problem() {
    final String? invalid = invalidReason();
    if (invalid != null) return invalid;
    if (effectiveModel.isEmpty) return '缺少 model';
    if ((_preset?.requiresApiKey ?? true) && (apiKey ?? '').isEmpty) return '缺少 api_key';
    return null;
  }

  AiProviderConfig _build() => AiProviderConfig(
        id: kServerAiProviderId,
        presetId: _preset == null ? kAiCustomPresetId : preset,
        name: _preset?.displayName ?? 'fushi_server',
        baseUrl: Uri.tryParse(effectiveBaseUrl) ?? Uri(),
        apiKey: apiKey ?? '',
        model: effectiveModel,
        protocol: effectiveProtocol,
        reasoningEffort: reasoningEffort,
        // 本地推理服务（Ollama / LM Studio）的预设地址是 loopback HTTP。
        allowInsecureHttp: allowInsecureHttp || (_preset?.isLocal ?? false),
      );

  /// 能真的发请求的提供商；配错 / 没配全 → null。
  AiProviderConfig? provider() {
    if (problem() != null) return null;
    final AiProviderConfig config = _build();
    return config.isUsable ? config : null;
  }

  ServerAiConfig copyWith({
    String? preset,
    AiWireProtocol? protocol,
    bool clearProtocol = false,
    String? baseUrl,
    bool clearBaseUrl = false,
    String? model,
    bool clearModel = false,
    String? apiKey,
    AiReasoningEffort? reasoningEffort,
    bool? allowInsecureHttp,
    bool? webKnowledge,
    bool? libraryOrganize,
  }) =>
      ServerAiConfig(
        preset: preset ?? this.preset,
        protocol: clearProtocol ? null : protocol ?? this.protocol,
        baseUrl: clearBaseUrl ? null : baseUrl ?? this.baseUrl,
        model: clearModel ? null : model ?? this.model,
        apiKey: apiKey ?? this.apiKey,
        reasoningEffort: reasoningEffort ?? this.reasoningEffort,
        allowInsecureHttp: allowInsecureHttp ?? this.allowInsecureHttp,
        webKnowledge: webKnowledge ?? this.webKnowledge,
        libraryOrganize: libraryOrganize ?? this.libraryOrganize,
      );

  /// 写进 `ai:` 段（[q] 是 ServerConfig 的 yaml 字符串转义）。
  void writeYaml(StringBuffer b, String Function(String) q) {
    b.writeln('ai:');
    b.writeln('  preset: ${q(preset)}');
    if (protocol != null) b.writeln('  protocol: ${q(protocol!.storageKey)}');
    if (baseUrl != null) b.writeln('  base_url: ${q(baseUrl!)}');
    if (model != null) b.writeln('  model: ${q(model!)}');
    if ((apiKey ?? '').isNotEmpty) b.writeln('  api_key: ${q(apiKey!)}');
    b.writeln('  reasoning_effort: ${q(reasoningEffort.storageKey)}');
    b.writeln('  allow_insecure_http: $allowInsecureHttp');
    b.writeln('  web_knowledge: $webKnowledge');
    b.writeln('  library_organize: $libraryOrganize');
  }

  /// 给 admin API 的形状：API key 只报「设过没有」，不回显。
  Map<String, Object?> toAdminJson() {
    final String? issue = problem();
    return <String, Object?>{
      'preset': preset,
      'protocol': protocol?.storageKey,
      'baseUrl': baseUrl,
      'model': model,
      'apiKeySet': (apiKey ?? '').isNotEmpty,
      'reasoningEffort': reasoningEffort.storageKey,
      'allowInsecureHttp': allowInsecureHttp,
      'webKnowledge': webKnowledge,
      'libraryOrganize': libraryOrganize,
      'effectiveBaseUrl': effectiveBaseUrl,
      'effectiveModel': effectiveModel,
      'status': issue == null ? 'ready' : 'incomplete',
      if (issue != null) 'problem': issue,
    };
  }
}

/// 引擎 AI 调用层的读侧：每次被问时现取 [config]（WebUI 改完即生效）。配置里没有
/// `ai:` 段或没配全时提供商清单为空、指派为空 → 调用层解析出 null，不发请求。
class ServerAiSettings implements AiSettingsSource {
  ServerAiSettings(this._config);

  final ServerAiConfig? Function() _config;

  @override
  List<AiProviderConfig> get aiProviders {
    final AiProviderConfig? provider = _config()?.provider();
    return provider == null ? const <AiProviderConfig>[] : <AiProviderConfig>[provider];
  }

  /// 那一家只指派给「AI 下载」「视频字幕 AI 校对」「AI 助手」（远端会话，工具集是
  /// 服务端自己描述的 admin 操作，见 `agent_host.dart`），以及打开了
  /// `library_organize` 时的「AI 整理库」：服务端没有刮削 AI 识别 / 补字幕重排等其它
  /// AI 功能的装配，不设默认提供商，免得以后新接一个功能时被静默带上。
  @override
  AiFeatureAssignments get aiFeatureAssignments {
    final ServerAiConfig? config = _config();
    if (config?.provider() == null) return const AiFeatureAssignments();
    return AiFeatureAssignments(
      providerIdByFeature: <AiFeature, String>{
        AiFeature.acquire: kServerAiProviderId,
        AiFeature.subtitleProofread: kServerAiProviderId,
        AiFeature.agent: kServerAiProviderId,
        if (config!.libraryOrganize) AiFeature.libraryOrganize: kServerAiProviderId,
      },
    );
  }

  @override
  List<WebKnowledgeSite> get aiWebKnowledgeSites =>
      _config()?.webKnowledge ?? false ? kBuiltinWebKnowledgeSites : const <WebKnowledgeSite>[];
}

/// 扫描后自动 AI 整理库的服务（`ai.library_organize` 打开且提供商能用）；否则 null。
///
/// 服务端没有 UI 语言：新合集名用作品原语言（`original`），系列标签前缀用英文。
LibraryOrganizeService? serverLibraryOrganizer(
  FushiDatabase db,
  ServerAiConfig? config,
) {
  if (config == null || !config.libraryOrganize || config.provider() == null) {
    return null;
  }
  return LibraryOrganizeService(
    db: db,
    settings: ServerAiSettings(() => config),
    nameLanguage: 'original',
    videoTagPrefix: 'Series: ',
  );
}
