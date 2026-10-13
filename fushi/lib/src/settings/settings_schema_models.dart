import 'dart:io';

import 'package:fushi/src/asr_host/asr_host.dart';
import 'package:fushi/src/media/audiobook/asr_models_settings_section.dart';
import 'package:fushi/src/media/manga/manga_ocr_models_storage_section.dart';
import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_ai.dart';
import 'package:fushi/src/settings/settings_schema_manga_ocr.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 「模型」一级设置分类（2026-10-13 用户拍板）：所有「模型」类配置的唯一的家。
///
/// 外层每类只有一行摘要，默认值够用的用户不必点进去；想单独配的进子页。子页都是
/// 既有页面原样挂过来（LLM = 原「AI」分类、OCR = 原漫画 OCR 页、语音转录与 OCR
/// 模型文件 = 原存储页「模型与组件」），持久化键与搜索锚点 id 一律不变。
///
/// LLM 子页仍按 [SettingsDestinationId.ai] 走 AI 模块（[ModuleId.ai]）门控：模块关掉时
/// 这一行与它子页里的设置都不可见、搜不出来；其余各栏是设备级资源，不属任何模块。
///
/// **必须零参、返回纯字面量树**（schema 按 locale 缓存，见 `settings_schema.dart`）。
SettingsDestination buildModelsDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.models,
    title: t.settings_destination_models,
    summary: t.settings_destination_models_summary,
    icon: FushiIcons.modelTraining,
    sections: <SettingsSection>[
      SettingsSection(
        id: 'models.section.kinds',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'models.llm',
            title: t.ai_settings_title,
            subtitle: t.ai_settings_summary,
            icon: FushiIcons.aiAssistant,
            visible: (SettingsContext c) => isSettingsDestinationVisible(
              SettingsDestinationId.ai,
              c.appModel.moduleVisibility,
            ),
            child: buildAiDestination,
          ),
          SettingsNavigationItem(
            id: 'models.ocr',
            title: 'OCR',
            subtitle: t.models_ocr_summary,
            icon: FushiIcons.ocr,
            child: () => buildOcrSettingsPage(SettingsDestinationId.models),
          ),
          SettingsNavigationItem(
            // 搜索锚点沿用存储页时代的 id（深链 / 搜索历史仍指向它）。
            id: 'listening.asr_models',
            title: t.asr_models_section,
            subtitle: t.asr_models_section_summary,
            icon: FushiIcons.voice,
            visible: (_) => isAsrSupported,
            child: _buildAsrModelsDestination,
          ),
          SettingsNavigationItem(
            id: 'models.tts',
            title: t.models_tts_title,
            subtitle: t.models_tts_summary,
            icon: FushiIcons.volumeUp,
            child: _buildTtsDestination,
          ),
        ],
      ),
      SettingsSection(
        id: 'models.section.files',
        title: t.models_section_files,
        visible: (_) => _isMangaOcrLocalSupported,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'storage.ocr_models',
            title: t.manga_ocr_local_model,
            subtitle: t.storage_ocr_models_hint,
            icon: FushiIcons.ocr,
            visible: (_) => _isMangaOcrLocalSupported,
            child: _buildMangaOcrModelsDestination,
          ),
        ],
      ),
    ],
  );
}

/// ASR 模型的选择与下载（全局资源，不受听书模块门控）。
SettingsDestination _buildAsrModelsDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.models,
    visible: (_) => isAsrSupported,
    title: t.asr_models_section,
    icon: FushiIcons.voice,
    sections: const <SettingsSection>[],
    body: (SettingsContext _) =>
        AsrModelsSettingsSection(service: createAsrTranscriptionService()),
  );
}

/// 本机能不能跑本地 ONNX OCR（ORT native 可用性，BUG-1780）。
bool get _isMangaOcrLocalSupported =>
    createMangaOcrService().isSupportedPlatform;

/// 每个本机 OCR 模型的下载 / 删除（OCR 子页里只管「用哪个」）。
SettingsDestination _buildMangaOcrModelsDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.models,
    visible: (_) => _isMangaOcrLocalSupported,
    title: t.manga_ocr_local_model,
    icon: FushiIcons.ocr,
    sections: const <SettingsSection>[],
    body: (SettingsContext _) => MangaOcrModelsStorageSection(
      serviceFor: (model) => createMangaOcrService(localModel: model),
    ),
  );
}

/// 本平台制卡兜底用的系统语音引擎名（专有名词，不翻译）；null = 本平台没有。
///
/// 与 `TtsChannel.ttsToFile` / `ttsToFileDesktop` 的分派同一张表：Android 走原生
/// TextToSpeech，桌面走各 OS 自带引擎，iOS 没有实现。
String? systemTtsEngineName() {
  if (Platform.isAndroid) return 'Android TextToSpeech';
  if (Platform.isWindows) return 'Windows SAPI';
  if (Platform.isMacOS) return 'macOS say';
  if (Platform.isLinux) return 'Open JTalk / espeak-ng';
  return null;
}

/// 语音合成：目前只有系统引擎、不可选，先如实展示「用的是什么、用在哪」。
SettingsDestination _buildTtsDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.models,
    title: t.models_tts_title,
    icon: FushiIcons.volumeUp,
    sections: <SettingsSection>[
      SettingsSection(
        id: 'models.section.tts',
        items: <SettingsItem>[
          SettingsStatusItem(
            id: 'models.tts_engine',
            title: t.models_tts_engine,
            icon: FushiIcons.volumeUp,
            subtitleBuilder: (_) =>
                systemTtsEngineName() ?? t.models_tts_unavailable,
          ),
          SettingsStatusItem(
            id: 'models.tts_usage',
            title: t.models_tts_usage_title,
            subtitle: t.models_tts_usage,
          ),
        ],
      ),
    ],
  );
}
