/// 「这份内容是什么语言」的选择器——词典与书共用同一份。
///
/// 内容语言决定用哪条字体链渲染（见 `content_font_chain.dart`）。多数内容自带
/// 声明（EPUB OPF 的 `dc:language`、yomitan `index.json` 的 sourceLanguage），
/// 但旧包 / 本地导入包 / 自制 EPUB 常常不带，这时只有用户知道答案——没有这个入口
/// 就只能靠字符检测猜，而中日共用汉字，纯汉字文本任何检测都是赌。
///
/// 词典和书是两套持久化（`Dictionary.languageOverride` / `EpubBooks.language`），
/// 但「选哪个语言」这件事完全一样，所以 UI 只有这一份。
library;

import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';

/// 可选的内容语言。`null` = 自动（用内容自己声明的语言）。
///
/// 语言名用**各语言的自称**而不是按界面语言翻译：用户要认的是「这本是哪国语言
/// 的」，自称在任何界面语言下都认得，也免掉 17 份翻译。BCP-47 标签一并显示，
/// 让手动指定的结果可验证。
const List<({String? tag, String label})> kContentLanguageOptions =
    <({String? tag, String label})>[
  (tag: 'ja', label: '日本語 (ja)'),
  (tag: 'zh-Hans', label: '简体中文 (zh-Hans)'),
  (tag: 'zh-Hant', label: '繁體中文 (zh-Hant)'),
  (tag: 'ko', label: '한국어 (ko)'),
  (tag: 'en', label: 'English (en)'),
];

/// BCP-47 标签 -> 显示名。不认识的标签原样返回（用户可能手动写了别的语言）。
String contentLanguageLabelOf(String tag) {
  for (final ({String? tag, String label}) option in kContentLanguageOptions) {
    if (option.tag == tag) return option.label;
  }
  return tag;
}

/// 弹出内容语言选择框。
///
/// - [current]：当前的**手动指定**值，null = 跟随自动。
/// - [autoDetected]：内容自己声明的语言，显示在「自动」项下面。空串 = 这份内容
///   没有声明（用户由此知道「自动」在这里等于没有信息，需要手动指定）。
/// - [onSelected]：选中回调，参数 null 表示恢复自动。
Future<void> showContentLanguagePicker({
  required BuildContext context,
  required String title,
  required String description,
  required String? current,
  required String autoDetected,
  required ValueChanged<String?> onSelected,

  /// 「跟随自动」那一项的文案。资源级设置里它是「自动」（= 用内容自己声明的
  /// 语言）；全局设置里没有可自动的东西，那一项的语义是「未设置」。
  String? autoLabel,
}) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  final List<({String? tag, String label})> options =
      <({String? tag, String label})>[
    (tag: null, label: autoLabel ?? t.dict_language_auto),
    ...kContentLanguageOptions,
  ];

  return showAppDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => FushiDialogFrame(
      maxWidth: 440,
      maxHeightFactor: 0.78,
      child: FushiModalSheetFrame(
        leadingIcon: Icons.translate,
        bodyPadding: EdgeInsets.all(tokens.spacing.card),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              title,
              style: tokens.type.listTitle.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: tokens.spacing.gap),
            Text(description, style: tokens.type.listSubtitle),
            SizedBox(height: tokens.spacing.gap),
            for (final ({String? tag, String label}) option in options)
              FushiListItem(
                title: Text(option.label),
                // 「自动」项显示内容自己声明了什么，让用户看得见自动值到底对不对；
                // 空白就说明这份内容没声明，只能手动指定。
                subtitle: option.tag == null && autoDetected.isNotEmpty
                    ? Text(autoDetected)
                    : null,
                selected: current == option.tag,
                trailing:
                    current == option.tag ? const Icon(Icons.check) : null,
                onTap: () {
                  onSelected(option.tag);
                  Navigator.pop(dialogContext);
                },
              ),
          ],
        ),
        footer: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            adaptiveDialogAction(
              context: dialogContext,
              child: Text(t.dialog_cancel),
              onPressed: () => Navigator.pop(dialogContext),
            ),
          ],
        ),
      ),
    ),
  );
}
