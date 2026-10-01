/// AI 指派的只读来源：提供商清单、「哪个功能用哪家」、联网资料站。
///
/// AI 调用层（`ai_video_*_assistant.dart`）只认这个接口，不认宿主的偏好实现：app
/// 由 `PreferencesRepository` 实现（设备本地偏好，设置页即时生效），无头服务端由
/// 配置文件的 `ai:` 段实现。调用层**每次被问时现取**，所以宿主改了配置立即生效。
library;

import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';

abstract interface class AiSettingsSource {
  /// 用户配置的提供商（含未启用 / 没配全的；可用性由 [AiFeatureAssignments.resolve] 判）。
  List<AiProviderConfig> get aiProviders;

  /// 功能 → 提供商的指派。
  AiFeatureAssignments get aiFeatureAssignments;

  /// 实际要查的联网资料站；空 = 不联网查资料。
  List<WebKnowledgeSite> get aiWebKnowledgeSites;
}
