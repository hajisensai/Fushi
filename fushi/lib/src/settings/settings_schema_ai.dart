import 'package:flutter/material.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/pages/implementations/ai_provider_settings_section.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/video/jimaku_client.dart'
    show jimakuLanguageLabel;

/// 「AI」一级设置分类：用户自配的大模型提供商 + 每个功能用哪家。
///
/// 归在「在线服务」模块（`ModuleId.services`）而不是另开一个 ModuleId：这一页的
/// 内容就是第三方在线服务的端点与凭据，与 Jimaku / OpenSubtitles / Torznab 同类，
/// 判据表见 `module_registry.dart`，别在此另写一份。
///
/// 提供商与功能指派走 [SettingsDestination.body] 逃生口：提供商是一份**可增删的
/// 记录列表**（每条还带自己的探测状态与模型下拉），schema 的声明式 item 树表达
/// 不了；与 OPDS / Torznab 段同一条切法。body 之后再挂声明式 section（`AI 下视频`
/// 的两个默认值），`bodyBeforeSections` 让 body 排在前面。
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
    body: (SettingsContext settingsContext) =>
        const AiProviderSettingsSection(),
    bodyBeforeSections: true,
    sections: <SettingsSection>[
      SettingsSection(
        id: 'ai.video_download',
        title: t.ai_video_download_section,
        // 「AI 下视频」= 在线发现 + 下载中心两条能力都在才有意义：iOS 合规砍掉任一
        // 条（判据只在 store_compliance.dart 写一次）或用户关了下载模块，这一段
        // 整个不渲染、不进搜索索引。
        visible: (SettingsContext c) =>
            StoreRestrictedCapability.downloads.isAvailable &&
            StoreRestrictedCapability.externalDiscovery.isAvailable &&
            c.appModel.moduleVisibility.isEnabled(ModuleId.downloads),
        items: <SettingsItem>[
          SettingsSegmentedItem<String>(
            id: 'ai.video_download_quality',
            dropdown: true,
            title: t.ai_video_download_quality,
            subtitle: t.ai_video_download_quality_hint,
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: '',
                label: t.ai_video_download_quality_unset,
              ),
              SettingsSegmentOption<String>(
                value: kVideoAcquisitionPrefAsk,
                label: t.ai_video_download_quality_ask,
              ),
              // 档位字面量（`2160p` …）是分辨率事实，不翻译；`any` 才有文案。
              for (final VideoAcquisitionQuality quality
                  in VideoAcquisitionQuality.values)
                SettingsSegmentOption<String>(
                  value: quality.storageKey,
                  label: quality == VideoAcquisitionQuality.any
                      ? t.ai_video_download_quality_any
                      : quality.storageKey,
                ),
            ],
            selected: (SettingsContext c) =>
                c.appModel.prefsRepo.aiVideoDownloadQuality,
            onChanged: (SettingsContext c, String value) =>
                c.appModel.prefsRepo.setAiVideoDownloadQuality(value),
          ),
          SettingsSegmentedItem<String>(
            id: 'ai.video_download_subtitle_language',
            dropdown: true,
            title: t.ai_video_download_subtitle_language,
            subtitle: t.ai_video_download_subtitle_language_hint,
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: '',
                label: t.ai_video_download_subtitle_language_unset,
              ),
              SettingsSegmentOption<String>(
                value: kVideoAcquisitionPrefAsk,
                label: t.ai_video_download_subtitle_language_ask,
              ),
              SettingsSegmentOption<String>(
                value: kVideoAcquisitionSubtitleOriginal,
                label: t.ai_video_download_subtitle_language_original,
              ),
              // 语言名用母语写法（与字幕面板同一函数），不随界面语言变。
              for (final String code in kVideoAcquisitionSubtitleLanguageCodes)
                SettingsSegmentOption<String>(
                  value: code,
                  label: jimakuLanguageLabel(code),
                ),
              SettingsSegmentOption<String>(
                value: kVideoAcquisitionSubtitleNone,
                label: t.ai_video_download_subtitle_language_none,
              ),
            ],
            selected: (SettingsContext c) =>
                c.appModel.prefsRepo.aiVideoDownloadSubtitleLanguage,
            onChanged: (SettingsContext c, String value) =>
                c.appModel.prefsRepo.setAiVideoDownloadSubtitleLanguage(value),
          ),
        ],
      ),
    ],
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
