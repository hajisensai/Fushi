import 'package:flutter/material.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/pages/implementations/ai_provider_settings_section.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';

/// 「AI」一级设置分类：用户自配的大模型提供商 + 每个功能用哪家。
///
/// 归在「在线服务」模块（`ModuleId.services`）而不是另开一个 ModuleId：这一页的
/// 内容就是第三方在线服务的端点与凭据，与 Jimaku / OpenSubtitles / Torznab 同类，
/// 判据表见 `module_registry.dart`，别在此另写一份。
///
/// 整页走 [SettingsDestination.body] 逃生口：提供商是一份**可增删的记录列表**
/// （每条还带自己的探测状态与模型下拉），schema 的声明式 item 树表达不了；与
/// OPDS / Torznab 段同一条切法。
///
/// **必须零参、返回纯字面量树**：schema 按 locale 缓存（见 `settings_schema.dart`
/// 的 `_SettingsSchemaCache`），任何构造期读运行状态的口子都会让缓存发陈旧数据，
/// 守卫 `test/settings/settings_schema_cache_test.dart` 钉死这条。
SettingsDestination buildAiDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.ai,
    // 「功能模块」门控：关掉本模块 = 整条分类不渲染 / 不进搜索索引 / 主从详情不可选
    // （三条渲染路径共用 isVisible）。
    visible: (SettingsContext c) => isSettingsDestinationVisible(
      SettingsDestinationId.ai,
      c.appModel.moduleVisibility,
    ),
    title: t.ai_settings_title,
    summary: t.ai_settings_summary,
    icon: Icons.smart_toy_outlined,
    sections: const <SettingsSection>[],
    body: (SettingsContext settingsContext) =>
        const AiProviderSettingsSection(),
    bodySearchEntries: <SettingsBodySearchEntry>[
      SettingsBodySearchEntry(
        id: 'ai.providers',
        title: t.ai_providers_section,
        subtitle: t.ai_providers_section_summary,
      ),
      SettingsBodySearchEntry(
        id: 'ai.features',
        title: t.ai_features_section,
        subtitle: t.ai_features_section_summary,
      ),
    ],
  );
}
