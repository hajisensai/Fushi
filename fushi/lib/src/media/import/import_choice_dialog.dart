/// 二选一选择对话框（导入稿 v2 第二节 7，IM8）：取代「导入文件夹」「添加来源」
/// 里的老式 `FushiSimpleDialog` 列表。2026-11 导入对话框统一后与其它导入对话框
/// 同一套语言：共享 [ImportDialogFrame] 头部 / 按钮区，选项是外层方式块的
/// 缩小版 [ImportPickTile]（钉色底 + 多边形 glyph + 名称 + 说明 + → 圆钮，整块
/// 可点），排成 [ImportPickTileGrid]。文案沿用现有
/// key（标题 `media_import_folder` / `media_source_add`，常驻来源说明
/// `{book,manga,video}_import_folder_as_source_hint`，网络说明从
/// [importNetworkTransportsSummary] 派生）。选项语义与返回值不变。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/glass/fushi_apple_sheet_header.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/import/import_dialog_blocks.dart';
import 'package:fushi/src/media/import/import_dialog_frame.dart';
import 'package:fushi/src/media/import/import_surface_spec.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 二选一里的一个选项。
@immutable
class ImportChoiceOption<T> {
  const ImportChoiceOption({
    required this.value,
    required this.icon,
    required this.title,
    this.hint,
    this.tone,
    this.key,
  });

  final T value;
  final IconData icon;
  final String title;

  /// 选项说明（现状没有副标题的选项不加，保持 null）。
  final String? hint;

  /// 块的钉色；null = 按位置取 [importChoiceTones]（文件夹绿 → 网络蓝 → 光盘橙…）。
  final ImportTone? tone;
  final Key? key;
}

/// 选项块按位置的默认钉色（与外层方式块的钉色同序）。
const List<ImportTone> importChoiceTones = <ImportTone>[
  ImportTone.green,
  ImportTone.indigo,
  ImportTone.coral,
  ImportTone.violet,
  ImportTone.amber,
  ImportTone.cyan,
  ImportTone.rose,
];

/// 弹出二选一选择块对话框；返回选中项的 [ImportChoiceOption.value]，取消为 null。
Future<T?> showImportChoiceDialog<T>({
  required BuildContext context,
  required String title,
  required List<ImportChoiceOption<T>> options,
  String? subtitle,
}) => showAppDialog<T>(
  context: context,
  builder: (BuildContext dialogContext) =>
      ImportChoiceDialog<T>(title: title, subtitle: subtitle, options: options),
);

/// 二选一对话框本体（[showImportChoiceDialog] 用；公开给测试直接挂载）。
class ImportChoiceDialog<T> extends StatelessWidget {
  const ImportChoiceDialog({
    required this.title,
    required this.options,
    this.subtitle,
    super.key,
  });

  final String title;
  final String? subtitle;
  final List<ImportChoiceOption<T>> options;

  @override
  Widget build(BuildContext context) {
    return ImportDialogFrame(
      title: title,
      subtitle: subtitle,
      maxWidth: 520,
      body: FushiEntranceScope(
        child: FushiStaggeredEntrance(
          index: 0,
          child: ImportPickTileGrid(
            children: <Widget>[
              for (int i = 0; i < options.length; i++)
                Semantics(
                  button: true,
                  child: ImportPickTile(
                    key: options[i].key,
                    focusId: FushiFocusId('import-choice-${options[i].title}'),
                    tone:
                        options[i].tone ??
                        importChoiceTones[i % importChoiceTones.length],
                    icon: options[i].icon,
                    title: options[i].title,
                    subtitle: options[i].hint,
                    showGo: true,
                    onTap: () => Navigator.of(context).pop<T>(options[i].value),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        FushiSheetAction.cancel(
          child: adaptiveDialogAction(
            context: context,
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t.cancel),
          ),
        ),
      ],
    );
  }
}
