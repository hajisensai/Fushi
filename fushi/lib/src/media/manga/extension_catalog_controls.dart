import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/library_filter_dropdown.dart';
import 'package:fushi/src/media/manga/mihon/mihon_download_counts.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_details_dialog.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 扩展目录（漫画 / 视频的 Mihon 扩展、小说的 LNReader 插件）共用的「下载量
/// 排行」与批量动作控件。
///
/// 三个域的扩展页必须长得一样、用起来一样：以前只有 Mihon 页有下载量排序、
/// 最低下载量筛选和带确认 / 进度 / 结果的批量动作，小说页是另写的一套简化版
/// （没有下载量、一键更新只弹 toast）。这里收口成一份，两边页面只管接数据。

/// 「最低下载量」筛选的默认档位。0 = 不筛。
///
/// 做成固定档而不是自由输入：用户要表达的是「别给我那些没人用的源」，是个量级
/// 判断，不是精确阈值；自由输入只会让人反复试数。
const List<int> kExtensionMinDownloadOptions = <int>[0, 50, 100, 500, 1000];

/// 一个仓库内的扩展按公开下载量降序；没有下载量数据的排在所有有数据的后面，
/// 同一档内按名字（大小写不敏感）稳定排序。
///
/// **为什么排在组内而不是全局**：分组顺序编码的是用户自己排的仓库顺序，跨仓库
/// 拍平重排会把折叠、表头计数一起打散；而不同仓库的下载量来自不同的统计口径，
/// 横着比没有意义。
///
/// null 排最后而不是当 0：null 是「这个仓库没有公开计数」（自建仓库、限流、断网），
/// 当 0 会让一个完全没有数据的仓库看起来像是「所有扩展都没人下」。
List<T> sortExtensionsByDownloads<T>(
  List<T> extensions, {
  required int? Function(T extension) downloads,
  required String Function(T extension) name,
}) {
  final List<T> sorted = List<T>.of(extensions);
  sorted.sort((T a, T b) {
    final int? left = downloads(a);
    final int? right = downloads(b);
    if (left != right) {
      if (left == null) return 1;
      if (right == null) return -1;
      return right.compareTo(left);
    }
    return name(a).toLowerCase().compareTo(name(b).toLowerCase());
  });
  return sorted;
}

/// 最低下载量筛选的判据。门槛为 0 时全放行；设了门槛时**没有数据的一律排除**，
/// 否则「至少 500 次下载」会把一整个没有计数的仓库全放进来，用户按下批量安装
/// 就装了一堆来路不明的源。
bool passesExtensionMinDownloads(int? downloads, int minDownloads) =>
    minDownloads == 0 || (downloads ?? -1) >= minDownloads;

/// 扩展行里的下载量文案：`1.2k 次下载` / `无下载数据`。
String extensionDownloadCountLabel(int? downloads) => downloads == null
    ? t.mihon_extension_download_count_unknown
    : t.mihon_extension_download_count(
        count: formatMihonDownloadCount(downloads),
      );

/// 扩展目录「最低下载量」筛选：一枚下拉筛选胶囊（[LibraryFilterDropdown]，与
/// 仓库 / 语言筛选同一形态，排在搜索框同一行）。不筛时胶囊显示维度名「最低下载
/// 量」，菜单首项是「不限」；选了门槛后胶囊显示 `≥ 50` 并以选中色强调。
///
/// 键名 `<prefix>_min_downloads`（胶囊）/ `<prefix>_min_downloads_<档位>`（菜单项，
/// 首项「不限」是 `_0`）。
class ExtensionMinDownloadsFilter extends StatelessWidget {
  const ExtensionMinDownloadsFilter({
    required this.keyPrefix,
    required this.minDownloads,
    required this.onMinDownloadsChanged,
    this.minDownloadOptions = kExtensionMinDownloadOptions,
    super.key,
  });

  final String keyPrefix;
  final int minDownloads;
  final ValueChanged<int> onMinDownloadsChanged;
  final List<int> minDownloadOptions;

  @override
  Widget build(BuildContext context) {
    return LibraryFilterDropdown<int>(
      key: ValueKey<String>('${keyPrefix}_min_downloads'),
      value: minDownloads == 0 ? null : minDownloads,
      options: <int>[
        for (final int option in minDownloadOptions)
          if (option != 0) option,
      ],
      labelOf: (int option) => '≥ ${formatMihonDownloadCount(option)}',
      title: t.mihon_extension_min_downloads,
      allLabel: t.mihon_extension_min_downloads_any,
      itemKeyOf: (int? option) =>
          ValueKey<String>('${keyPrefix}_min_downloads_${option ?? 0}'),
      onSelected: (int? option) => onMinDownloadsChanged(option ?? 0),
    );
  }
}

/// 扩展目录动作排里的一个动作（图标 + 文字）。
@immutable
class ExtensionCatalogAction {
  const ExtensionCatalogAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.key,
  });

  /// 平铺按钮与收进「⋯」后的菜单项共用（两者不会同时存在）。
  final Key? key;
  final IconData icon;
  final String label;

  /// null = 置灰。
  final VoidCallback? onPressed;
}

/// 扩展目录的动作排：批量安装 + 一键更新 + [extra]（同一行、靠左）。
///
/// 排在目录最上面、搜索框之上（2026-10-25 用户拍板：四颗按钮同一行放左上角，
/// 页头的仓库 / 刷新图标砍掉）。2026-11-16 拼贴改版：四颗按钮统一成同一种 tonal
/// 带字按钮（不再描边 / 色调混搭）；**默认平铺，宽度放不下时从末尾起收进「⋯」**
/// （与顶栏 `adaptiveOverflow` 同一条规矩：工具栏动作默认展开）。有可更新的扩展时
/// 「一键更新」升成 filled 主色并挂数量角标——这是这一排里唯一需要被注意到的状态。
///
/// 键名 `<prefix>_bulk_install` / `<prefix>_update_all` / `<prefix>_more`，测试按它
/// 定位；[extra] 的 key 由调用方给。
class ExtensionCatalogActions extends StatelessWidget {
  const ExtensionCatalogActions({
    required this.keyPrefix,
    required this.onBulkInstall,
    required this.onUpdateAll,
    this.updateCount = 0,
    this.extra = const <ExtensionCatalogAction>[],
    super.key,
  });

  final String keyPrefix;

  /// null = 置灰（批量动作进行中 / 目录加载中）。
  final VoidCallback? onBulkInstall;
  final VoidCallback? onUpdateAll;

  /// 已装且仓库里有更新的扩展数；>0 时「一键更新」强调并挂角标。
  final int updateCount;

  /// 同一行末尾的其它目录动作（「扩展仓库」「导入本地 APK」）；优先级最低，
  /// 放不下时最先收进「⋯」。
  final List<ExtensionCatalogAction> extra;

  static const double _spacing = 8;

  /// 「⋯」按钮占的宽度（48 命中区）。
  static const double _moreWidth = 48;

  /// 一颗带字按钮的估宽：按钮几何 + 实测文字宽 + 角标余量。玻璃按钮的内边距
  /// 略大，统一多留 8 的余量，宁可早一颗收起也不溢出。
  static double _estimateWidth(
    BuildContext context,
    String label, {
    required bool badge,
  }) {
    final FushiButtonMetrics metrics = FushiButtonMetrics.of(FushiButtonSize.s);
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: label,
        style: FushiButtonMetrics.labelStyleOf(
          FushiButtonSize.s,
          Theme.of(context).textTheme,
        ),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final double width =
        metrics.horizontalPadding * 2 +
        metrics.iconSize +
        metrics.iconGap +
        painter.width +
        (badge ? 12 : 0) +
        8;
    painter.dispose();
    return width;
  }

  Key get _updateKey => ValueKey<String>('${keyPrefix}_update_all');

  List<ExtensionCatalogAction> _actions() => <ExtensionCatalogAction>[
    ExtensionCatalogAction(
      key: ValueKey<String>('${keyPrefix}_bulk_install'),
      icon: FushiIcons.libraryAdd,
      label: t.mihon_extension_bulk_install,
      onPressed: onBulkInstall,
    ),
    ExtensionCatalogAction(
      key: _updateKey,
      icon: FushiIcons.sync,
      label: t.mihon_extension_update_all,
      onPressed: onUpdateAll,
    ),
    ...extra,
  ];

  bool _emphasized(ExtensionCatalogAction action) =>
      updateCount > 0 && action.key == _updateKey;

  Widget _button(ExtensionCatalogAction action) {
    if (_emphasized(action)) {
      // 数量角标挂在整颗按钮的右上角外侧（iOS 的按钮角标位置），不挂在图标上
      // ——挂图标时红色角标会压住紧挨着的按钮文字。
      return FushiBadgeControl.count(
        key: ValueKey<String>('${keyPrefix}_update_count'),
        count: updateCount,
        child: FushiFilledButton.icon(
          key: action.key,
          size: FushiButtonSize.s,
          onPressed: action.onPressed,
          icon: FushiIcon(action.icon),
          label: Text(action.label),
        ),
      );
    }
    return FushiFilledButton.tonalIcon(
      key: action.key,
      size: FushiButtonSize.s,
      onPressed: action.onPressed,
      icon: FushiIcon(action.icon),
      label: Text(action.label),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<ExtensionCatalogAction> actions = _actions();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final List<double> widths = <double>[
          for (final ExtensionCatalogAction action in actions)
            _estimateWidth(context, action.label, badge: _emphasized(action)),
        ];
        // 从前往后尽量平铺；有任何一颗收起时还要给「⋯」留位。至少留一颗。
        int shown = actions.length;
        double total() {
          double sum = 0;
          for (int i = 0; i < shown; i++) {
            sum += widths[i] + (i > 0 ? _spacing : 0);
          }
          if (shown < actions.length) sum += _spacing + _moreWidth;
          return sum;
        }

        if (constraints.maxWidth.isFinite) {
          while (shown > 1 && total() > constraints.maxWidth) {
            shown--;
          }
        }
        final List<ExtensionCatalogAction> folded = actions.sublist(shown);
        return Row(
          children: <Widget>[
            for (int i = 0; i < shown; i++) ...<Widget>[
              if (i > 0) const SizedBox(width: _spacing),
              Flexible(child: _button(actions[i])),
            ],
            if (folded.isNotEmpty) ...<Widget>[
              const SizedBox(width: _spacing),
              FushiPopupMenuButton<VoidCallback>(
                key: ValueKey<String>('${keyPrefix}_more'),
                tooltip: t.common_more_actions,
                icon: const FushiIcon(FushiIcons.more),
                onSelected: (VoidCallback action) => action(),
                itemBuilder: (BuildContext context) =>
                    <PopupMenuEntry<VoidCallback>>[
                      for (final ExtensionCatalogAction action in folded)
                        PopupMenuItem<VoidCallback>(
                          key: action.key,
                          value: action.onPressed,
                          enabled: action.onPressed != null,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              FushiIcon(action.icon, size: 20),
                              const SizedBox(width: 12),
                              Flexible(child: Text(action.label)),
                            ],
                          ),
                        ),
                    ],
              ),
            ],
          ],
        );
      },
    );
  }
}

/// 批量动作「没有可做的」提示框（不是 toast：用户刚点了按钮，要一个明确回应）。
Future<void> showExtensionBulkNothing(
  BuildContext context, {
  required String title,
  required String message,
}) => showAppDialog<void>(
  context: context,
  builder: (BuildContext dialogContext) => FushiAlertDialog.adaptive(
    title: Text(title),
    content: Text(message),
    actions: <Widget>[
      adaptiveDialogAction(
        context: dialogContext,
        isDefaultAction: true,
        onPressed: () => Navigator.pop(dialogContext),
        child: Text(t.dialog_ok),
      ),
    ],
  ),
);

/// 批量动作的确认框。[destructive] 用于「批量安装」（装进来的是会执行的代码），
/// 「一键更新」只是默认动作。
Future<bool> confirmExtensionBulk(
  BuildContext context, {
  required String title,
  required String message,
  required String actionLabel,
  required bool destructive,
}) => showFushiConfirmDialog(
  context: context,
  title: title,
  message: message,
  icon: destructive ? FushiIcons.warning : null,
  confirmLabel: actionLabel,
  destructive: destructive,
);

/// 批量动作执行体：进度框 → [run] → 关进度框。
///
/// [run] 拿到进度回调与取消闸门；用户点「取消」只置位闸门、不 pop——正在处理
/// 的那一条要跑完才收得干净，对话框由这里在 [run] 结束后关。
///
/// [run] 抛错时弹诊断错误框并返回 null；否则返回 [run] 的结果，由调用方出结果框
/// （[showExtensionBulkReport]）。
Future<R?> runExtensionBulkWithProgress<R>(
  BuildContext context, {
  required String title,
  required int total,
  required String firstName,
  required String Function(int current, int total, String name) progressText,
  required Future<R> Function(
    void Function(int done, int total, String name) onProgress,
    bool Function() isCancelled,
  )
  run,
}) async {
  final ValueNotifier<(int, int, String)> progress =
      ValueNotifier<(int, int, String)>((0, total, firstName));
  bool cancelled = false;
  BuildContext? progressContext;
  showAppDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext dialogContext) {
      progressContext = dialogContext;
      return FushiAlertDialog.adaptive(
        title: Text(title),
        content: ValueListenableBuilder<(int, int, String)>(
          valueListenable: progress,
          builder: (BuildContext context, (int, int, String) value, _) {
            final (int done, int total, String name) = value;
            final int current = done + 1 > total ? total : done + 1;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                FushiLinearProgressIndicator(
                  value: total == 0 ? null : done / total,
                ),
                const SizedBox(height: 12),
                Text(progressText(current, total, name)),
              ],
            );
          },
        ),
        actions: <Widget>[
          adaptiveDialogAction(
            context: dialogContext,
            onPressed: () => cancelled = true,
            child: Text(t.dialog_cancel),
          ),
        ],
      );
    },
  ).ignore();
  R? result;
  Object? failure;
  try {
    result = await run(
      (int done, int total, String name) =>
          progress.value = (done, total, name),
      () => cancelled,
    );
  } catch (error) {
    failure = error;
  } finally {
    final BuildContext? dialog = progressContext;
    if (dialog != null && dialog.mounted) Navigator.pop(dialog);
    progress.dispose();
  }
  if (failure != null) {
    if (context.mounted) {
      showErrorDetails(
        context,
        title: t.mihon_extension_error,
        error: failure,
      ).ignore();
    }
    return null;
  }
  return result;
}

/// 批量动作结果框：一行汇总 + 失败原因逐条列出（批量里最常见的失败是上游删了
/// 某个版本或某个源换了签名，只报一个总数用户无从判断要不要重试）。
Future<void> showExtensionBulkReport(
  BuildContext context, {
  required String title,
  required String summary,
  Map<String, String> failures = const <String, String>{},
}) => showAppDialog<void>(
  context: context,
  builder: (BuildContext dialogContext) => FushiAlertDialog.adaptive(
    title: Text(title),
    content: SelectableText(
      <String>[
        summary,
        ...failures.entries.map(
          (MapEntry<String, String> entry) => '${entry.key}: ${entry.value}',
        ),
      ].join('\n'),
    ),
    actions: <Widget>[
      adaptiveDialogAction(
        context: dialogContext,
        isDefaultAction: true,
        onPressed: () => Navigator.pop(dialogContext),
        child: Text(t.dialog_ok),
      ),
    ],
  ),
);
