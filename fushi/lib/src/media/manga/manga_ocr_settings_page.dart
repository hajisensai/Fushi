import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/manga/manga_ocr_settings_section.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/utils.dart';

/// 「漫画 OCR」设置的独立页：引擎偏好 / 内置模型下载 / Lens 语言 / 外部 mokuro。
///
/// 正文与设置分类里的同名子页是**同一个** [MangaOcrSettingsSection]，只是外壳换成
/// 可 push 的整页。作品页「识别本章 / 识别全部」与 OCR 向导都是在阅读器外触发 OCR
/// 的入口（BUG-2461），它们此前解析不到引擎时只给一行红字，用户得自己去设置里翻
/// 「漫画 → 漫画 OCR」；现在一颗按钮直达，返回后调用方按需重探引擎。
class MangaOcrSettingsPage extends ConsumerWidget {
  const MangaOcrSettingsPage({super.key});

  /// push 本页并等待返回。返回后调用方通常要重探引擎可用性（模型可能刚下完）。
  static Future<void> push(BuildContext context) {
    return Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => const MangaOcrSettingsPage(),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppModel appModel = ref.watch(appProvider);
    return FushiPageScaffold(
      title: t.manga_ocr_section,
      subtitle: t.manga_ocr_section_summary,
      body: SingleChildScrollView(
        key: const ValueKey<String>('manga_ocr_settings_page'),
        child: MangaOcrSettingsSection(
          service: ref.read(mangaOcrServiceProvider),
          enginePreferenceGetter: () => appModel.mangaOcrEnginePreference,
          enginePreferenceSetter: appModel.setMangaOcrEnginePreference,
          lensLanguageGetter: () => appModel.mangaOcrLensLanguage,
          lensLanguageSetter: appModel.setMangaOcrLensLanguage,
        ),
      ),
    );
  }
}
