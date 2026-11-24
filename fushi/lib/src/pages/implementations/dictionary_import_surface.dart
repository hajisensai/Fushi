/// 查词「一本词典都没有」的导入面（导入稿 v2 第二节 6，IM23）：查词主页与词典管理页
/// 的空态共用这一块，换成和库页导入面同一套引导首块 + 方式块（[ImportPageLayout]），
/// 不再是居中占位 + 两个按钮。
///
/// - 引导首块文案全用现有 key：`dictionaries_menu_empty`、`dict_empty_hint`，桌面三端
///   再拼上 `dict_empty_drop_hint`（同改前 `showDropHint`）；
/// - 方式块对应词典管理页现有动作：导入词典 · 导入文件夹词典（非 iOS，判据与管理页
///   页头同一处 `!Platform.isIOS`）· 下载推荐词典（不属于 `StoreRestrictedCapability`，
///   iOS 照常显示）；
/// - 两个宿主页的整页本来就挂着 `FushiFileDropTarget`（落下走各自现有的分发），这里
///   **不再装第二层落点**（desktop_drop 全局广播，嵌套两层会把一次拖放处理两遍），
///   spec 不给 onDrop。
library;

import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart'
    show kDictionarySurfaceDropExtensions;
import 'package:fushi/src/media/import/import_page_layout.dart';
import 'package:fushi/src/media/import/import_surface_spec.dart';
import 'package:fushi/src/pages/implementations/dictionary_import_action.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

export 'package:fushi/src/pages/implementations/dictionary_import_action.dart';

/// 只有选文件时另外认的词典格式：词典管理页文件选择器在拖放集合
/// （[kDictionarySurfaceDropExtensions]）之外还收 StarDict 的 `.ifo`（`.css` 是随词典的
/// 样式附件，不算格式）。气泡里按格式名写作 STARDICT（稿「气泡 · 查词」）。
const List<String> kDictionaryPickOnlyFormatLabels = <String>['STARDICT'];

/// 查词空态的 spec（纯函数，便于单测：方式顺序 / iOS 门 / 拖放说明）。
///
/// [folderImportAvailable] = 改前页头「导入文件夹词典」的同一判据（非 iOS）；
/// [desktopDrop] = 宿主页的整页落点在桌面端生效，说明里拼上拖放提示。
ImportSurfaceSpec dictionaryImportSurfaceSpec({
  required Future<void> Function(DictionaryImportAction action) onAction,
  required bool folderImportAvailable,
  required bool desktopDrop,
}) => ImportSurfaceSpec(
  id: 'dictionary',
  tone: ImportTone.indigo,
  guideIcon: FushiIcons.dictionary,
  guideTitle: t.dictionaries_menu_empty,
  guideDescription: desktopDrop
      ? '${t.dict_empty_hint} ${t.dict_empty_drop_hint}'
      : t.dict_empty_hint,
  methods: <ImportMethod>[
    ImportMethod(
      id: 'dict-import-files',
      kind: ImportMethodKind.primary,
      icon: FushiIcons.dictionary,
      label: t.dialog_import_dictionary,
      description: t.import_method_dict_files_desc,
      destination: ImportDestination.pickFile,
      onTap: () => onAction(DictionaryImportAction.files),
    ),
    if (folderImportAvailable)
      ImportMethod(
        id: 'dict-import-folder',
        kind: ImportMethodKind.folder,
        icon: FushiIcons.folder,
        label: t.dialog_import_folder,
        description: t.import_method_dict_folder_desc,
        destination: ImportDestination.pickFolder,
        onTap: () => onAction(DictionaryImportAction.folder),
      ),
    ImportMethod(
      id: 'dict-download',
      kind: ImportMethodKind.recommendedDictionary,
      icon: FushiIcons.cloudDownload,
      label: t.dict_download_browse,
      description: t.import_method_dict_download_desc,
      destination: ImportDestination.list,
      onTap: () => onAction(DictionaryImportAction.download),
    ),
  ],
  formatGroups: <ImportFormatGroup>[
    ImportFormatGroup(
      title: desktopDrop ? t.import_format_group_droppable : t.nav_lookup,
      labels: importFormatLabels(<Iterable<String>>[
        kDictionarySurfaceDropExtensions,
      ]),
    ),
  ],
  pickOnlyFormatGroups: <ImportFormatGroup>[
    ImportFormatGroup(
      title: t.import_format_group_pick_only,
      labels: kDictionaryPickOnlyFormatLabels,
    ),
  ],
);

/// 本机这一端的整页拖放是否生效（桌面三端）。
bool get dictionaryDesktopDropAvailable =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// 改前「导入文件夹词典」的可用判据（iOS 没有文件夹导入）。
bool get dictionaryFolderImportAvailable => !Platform.isIOS;

/// 查词空态导入面：[scrollable] = false 时嵌进宿主页自己的滚动视图（查词主页要保住
/// 下拉同步），true 时自带滚动（词典管理页正文）。
class DictionaryImportEmptySurface extends StatelessWidget {
  const DictionaryImportEmptySurface({
    required this.onAction,
    this.scrollable = false,
    super.key,
  });

  final Future<void> Function(DictionaryImportAction action) onAction;
  final bool scrollable;

  @override
  Widget build(BuildContext context) => ImportPageLayout(
    spec: dictionaryImportSurfaceSpec(
      onAction: onAction,
      folderImportAvailable: dictionaryFolderImportAvailable,
      desktopDrop: dictionaryDesktopDropAvailable,
    ),
    scrollable: scrollable,
  );
}
