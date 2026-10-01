import 'dart:async' show unawaited;

import 'package:flutter/widgets.dart';

import 'package:fushi/src/ai/ai_media_acquisition_assistant.dart'
    show AiMediaAcquisitionDomain;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/pages/implementations/ai_media_acquisition_page.dart';
import 'package:fushi/src/pages/implementations/browse_online_sources_view.dart';
import 'package:fushi/src/settings/settings_destination.dart';

/// 发现页搜索行的「AI 下载」入口（小说 / 漫画 / 游戏；视频域是首页注入的
/// 「AI 下视频」）。「浏览 › 发现」与各库页的「发现」子标签共用这一处。
///
/// 门：偏好就绪 + 下载 / 外部发现两项合规能力 + 「设置 › AI」未被模块开关藏起
/// （点击时要能引导去配置提供商）。不满足时回 null，按钮整颗不渲染。
///
/// [onlineDomain] 非空时，在线来源是否参与搜索与「来源」页签同一门
/// （[visibleOnlineSourcesDomains]），在点击那一刻求值。
ValueChanged<String>? discoveryAiAcquireAction({
  required BuildContext context,
  required AppModel Function() readAppModel,
  required AiMediaAcquisitionDomain domain,
  required String domainLabel,
  OnlineSourcesDomain? onlineDomain,
}) {
  final AppModel appModel = readAppModel();
  final bool gates = appModel.isPreferencesReady &&
      StoreRestrictedCapability.downloads.isAvailable &&
      StoreRestrictedCapability.externalDiscovery.isAvailable &&
      isSettingsDestinationVisible(
        SettingsDestinationId.ai,
        appModel.moduleVisibility,
      );
  if (!gates) return null;
  return (String query) {
    final AppModel current = readAppModel();
    unawaited(
      openAiMediaAcquisition(
        context,
        appModel: current,
        domain: domain,
        domainLabel: domainLabel,
        includeOnlineSources: onlineDomain != null &&
            visibleOnlineSourcesDomains(current.moduleVisibility)
                .contains(onlineDomain),
        initialQuery: query,
      ),
    );
  };
}
