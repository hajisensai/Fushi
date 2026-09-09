import 'package:flutter/material.dart';

import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/manga/manga_ocr_settings_section.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_client.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';

/// 「漫画 OCR」设置组（隶属**漫画**设置分类，入口始终可见）。
///
/// 全平台显示（P4）：模型下载/状态行移动端也需要（单框补扫用识别三件套）；
/// 整卷 OCR 向导仍桌面/远程，外部 mokuro CLI 块在 section 正文内自行按桌面
/// gating。模型管理子页复用 [MangaOcrSettingsSection]，
/// 服务从 [mangaOcrServiceProvider] 取（本文件是 UI 侧少数几个直接经 provider
/// 触达 `MangaOcrServiceImpl` 的接线点之一——见 provider 注释）。
SettingsSection buildMangaOcrSection() {
  return SettingsSection(
    id: 'manga.section.ocr',
    presentation: SettingsSectionPresentation.alwaysExpanded,
    title: t.manga_ocr_section,
    items: <SettingsItem>[
      SettingsNavigationItem(
        id: 'manga.ocr',
        title: t.manga_ocr_section,
        subtitle: t.manga_ocr_section_summary,
        icon: Icons.document_scanner_outlined,
        child: _buildMangaOcrDestination,
      ),
      // 「点一下没识别的对话框就地开跑」。默认开——这条路径存在的全部意义就是
      // 让用户不必先去点识别模式；关掉即回到旧行为（空白点只回收焦点），给不
      // 希望被动触发联网/耗电的人留后路。
      SettingsSwitchItem(
        id: 'manga.tap_to_ocr',
        title: t.manga_tap_to_ocr,
        subtitle: t.manga_tap_to_ocr_desc,
        icon: Icons.touch_app_outlined,
        value: (SettingsContext c) => c.appModel.mangaTapToOcr,
        onChanged: (SettingsContext c, bool value) =>
            c.appModel.setMangaTapToOcr(value),
      ),
    ],
  );
}

SettingsDestination _buildMangaOcrDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.manga,
    title: t.manga_ocr_section,
    icon: Icons.document_scanner_outlined,
    sections: const <SettingsSection>[],
    body: (SettingsContext c) => MangaOcrSettingsSection(
      service: c.ref.read(mangaOcrServiceProvider),
      enginePreferenceGetter: () => c.appModel.mangaOcrEnginePreference,
      enginePreferenceSetter: c.appModel.setMangaOcrEnginePreference,
      lensLanguageGetter: () => c.appModel.mangaOcrLensLanguage,
      lensLanguageSetter: c.appModel.setMangaOcrLensLanguage,
    ),
  );
}

/// Online catalog connectivity is separate from local OCR configuration.
SettingsSection buildMangaCatalogSection() {
  return SettingsSection(
    id: 'manga.section.catalog',
    presentation: SettingsSectionPresentation.collapsed,
    title: t.manga_online_catalog_title,
    items: <SettingsItem>[
      // 漫画「在线目录」站点根 URL（O1 mokuro.moe 目录源）。空串/尾斜杠由
      // MokuroMoeClient 的 normalizeMokuroMoeBaseUrl 归一回默认站点，故这里
      // 只 trim 存原值、不做格式校验。
      SettingsTextItem(
        id: 'manga.online_catalog_base_url',
        title: t.manga_online_base_url_label,
        icon: Icons.cloud_outlined,
        keyboardType: TextInputType.url,
        placeholder: kMokuroMoeDefaultBaseUrl,
        value: (SettingsContext settingsContext) =>
            settingsContext.appModel.mangaOnlineCatalogBaseUrl,
        onChanged: (SettingsContext settingsContext, String value) =>
            settingsContext.appModel.setMangaOnlineCatalogBaseUrl(value.trim()),
      ),
    ],
  );
}
