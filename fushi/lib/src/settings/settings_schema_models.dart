import 'dart:io';

import 'package:material_ui/material_ui.dart' show BuildContext;

import 'package:fushi/src/asr_host/asr_host.dart';
import 'package:fushi/src/media/audiobook/asr_models_settings_section.dart';
import 'package:fushi_engine/tts/local/gpt_sovits_local_engine.dart';
import 'package:fushi_engine/tts/local/irodori_local_engine.dart';
import 'package:fushi/src/media/audiobook/tts/gpt_sovits_local_page.dart';
import 'package:fushi/src/media/audiobook/tts/irodori_local_page.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/audiobook/tts/tts_voice_settings_page.dart';
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
        visible: (SettingsContext c) =>
            _isMangaOcrLocalSupported ||
            _isLocalTtsSupported(c) ||
            _isLocalIrodoriSupported(c),
        items: <SettingsItem>[
          // 语音合成的「模型文件」：GPT-SoVITS 整合包（约 19 GB）与 OCR 模型并列管理，
          // 点进去是同一个本机部署页（下载 / 删除 / 指向已有整合包）。
          _localGptSovitsItem(
            id: 'models.files.gpt_sovits',
            title: t.audiobook_tts_local_package,
          ),
          // 本机 Irodori-TTS 的环境与模型（Python / PyTorch / v4.1 模型，同一个专属目录）。
          _localIrodoriItem(
            id: 'models.files.irodori',
            title: t.audiobook_tts_irodori_local_package,
          ),
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

/// 本机能不能一键部署 GPT-SoVITS（官方免安装整合包只有 Windows）。
bool _isLocalTtsSupported(SettingsContext _) =>
    GptSovitsLocalEngine.platformSupported;

/// 本机 GPT-SoVITS 的一句话状态（运行期状态只能走 subtitleBuilder）。只读已建好的
/// [TtsServices]：全局资源行求值时不为了一行副标题去碰偏好仓（搜索扁平化也会求值
/// 副标题）；还没建过就回落静态说明。
String? _localTtsStatus(SettingsContext _) {
  final GptSovitsLocalEngine? engine = TtsServices.existing?.localGptSovits;
  if (engine == null) return null;
  if (!engine.isInstalled) return t.audiobook_tts_local_status_not_installed;
  if (engine.server.isRunning) {
    return t.audiobook_tts_local_server_running(endpoint: engine.endpoint);
  }
  return t.audiobook_tts_local_status_installed;
}

/// 「本机 GPT-SoVITS」入口（语音合成子页与模型文件分区共用一份）。在那边新建了
/// 声音就直接带到朗读声音页去选参考音频、试听。
SettingsActionItem _localGptSovitsItem({
  required String id,
  required String title,
}) => SettingsActionItem(
  id: id,
  title: title,
  subtitle: t.audiobook_tts_local_add_hint,
  subtitleBuilder: _localTtsStatus,
  icon: FushiIcons.download,
  visible: _isLocalTtsSupported,
  cli: const SettingsCliAction.unsupported(
    '本机 GPT-SoVITS 用 fushi_cli models download / link / rm gpt-sovits 部署，'
    'models start / stop gpt-sovits 起停服务，voice add gpt_sovits 建声音',
  ),
  onTap: (SettingsContext settingsContext) async {
    final TtsServices tts = TtsServices.of(settingsContext.appModel.prefsRepo);
    final BuildContext context = settingsContext.context;
    final String? created = await openGptSovitsLocalPage(context, tts);
    if (created != null && context.mounted) {
      await openTtsVoiceSettingsPage(context, tts, openPresetId: created);
    }
    settingsContext.refresh();
  },
);

/// 本机能不能一键部署官方 Irodori-TTS-Server（桌面三端，uv 有发行包的架构）。
bool _isLocalIrodoriSupported(SettingsContext _) =>
    IrodoriLocalEngine.platformSupported;

/// 本机 Irodori-TTS 的一句话状态（同 [_localTtsStatus]，只读已建好的服务对象）。
String? _localIrodoriStatus(SettingsContext _) {
  final IrodoriLocalEngine? engine = TtsServices.existing?.localIrodori;
  if (engine == null) return null;
  if (!engine.isInstalled) return t.audiobook_tts_local_status_not_installed;
  if (engine.server.isRunning) {
    return t.audiobook_tts_local_server_running(endpoint: engine.endpoint);
  }
  return t.audiobook_tts_local_status_installed;
}

/// 「本机 Irodori-TTS」入口（语音合成子页与模型文件分区共用一份）。
SettingsActionItem _localIrodoriItem({
  required String id,
  required String title,
}) => SettingsActionItem(
  id: id,
  title: title,
  subtitle: t.audiobook_tts_irodori_local_add_hint,
  subtitleBuilder: _localIrodoriStatus,
  icon: FushiIcons.download,
  visible: _isLocalIrodoriSupported,
  cli: const SettingsCliAction.unsupported(
    '本机 Irodori-TTS 用 fushi_cli models download / rm irodori 部署，'
    'models start / stop irodori 起停服务，voice add irodori_server 建声音',
  ),
  onTap: (SettingsContext settingsContext) async {
    final TtsServices tts = TtsServices.of(settingsContext.appModel.prefsRepo);
    final BuildContext context = settingsContext.context;
    final String? created = await openIrodoriLocalPage(context, tts);
    if (created != null && context.mounted) {
      await openTtsVoiceSettingsPage(context, tts, openPresetId: created);
    }
    settingsContext.refresh();
  },
);

/// 语音合成：朗读声音（GPT-SoVITS / 在线 / 系统，含本机一键部署）是这里的主入口；
/// 制卡发音的系统语音兜底只是如实展示「用的是什么、用在哪」。
SettingsDestination _buildTtsDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.models,
    title: t.models_tts_title,
    icon: FushiIcons.volumeUp,
    sections: <SettingsSection>[
      SettingsSection(
        id: 'models.section.tts_voices',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        items: <SettingsItem>[
          // 与「阅读 › 有声书」里的同一个入口（那里受听书模块门控，这里不受）。
          SettingsActionItem(
            id: 'models.tts_voices',
            title: t.audiobook_tts_voice_settings,
            subtitle: t.audiobook_tts_voice_settings_hint,
            icon: FushiIcons.voice,
            cli: const SettingsCliAction.unsupported(
              '朗读声音的增删改与设默认用 fushi_cli voice ls/add/set/use/rm',
            ),
            onTap: (SettingsContext settingsContext) async {
              await openTtsVoiceSettingsPage(
                settingsContext.context,
                TtsServices.of(settingsContext.appModel.prefsRepo),
              );
              settingsContext.refresh();
            },
          ),
          _localGptSovitsItem(
            id: 'models.tts_local_gpt_sovits',
            title: t.audiobook_tts_local_title,
          ),
          _localIrodoriItem(
            id: 'models.tts_local_irodori',
            title: t.audiobook_tts_irodori_local_title,
          ),
        ],
      ),
      SettingsSection(
        id: 'models.section.tts',
        title: t.models_tts_card_fallback_section,
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
