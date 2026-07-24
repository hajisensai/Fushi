import 'package:hibiki/src/media/manga/manga_ocr_provider.dart';
import 'package:hibiki/src/media/manga/manga_ocr_settings_section.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/utils.dart';

/// 「漫画 OCR」设置组（内联进阅读设置分类，默认折叠）。
///
/// 仅桌面显示：内置 ONNX OCR 引擎 P2 先桌面，外部 mokuro CLI 亦桌面工具。正文经
/// [SettingsCustomItem] 逃生口渲染 [MangaOcrSettingsSection]，服务从
/// [mangaOcrServiceProvider] 取（本文件是 UI 侧少数几个直接经 provider 触达
/// `MangaOcrServiceImpl` 的接线点之一，impl 落地前 analyze 会报缺文件——见 provider 注释）。
SettingsSection buildMangaOcrSection() {
  return SettingsSection(
    title: t.manga_ocr_section,
    footer: t.manga_ocr_section_summary,
    collapsedByDefault: true,
    visible: (SettingsContext c) => isDesktopPlatform,
    items: <SettingsItem>[
      SettingsCustomItem(
        id: 'reading.manga_ocr',
        searchTitle: t.manga_ocr_section,
        builder: (SettingsContext c) => MangaOcrSettingsSection(
          service: c.ref.read(mangaOcrServiceProvider),
        ),
      ),
    ],
  );
}
