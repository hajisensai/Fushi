import 'package:flutter/material.dart';

import 'package:fushi/src/media/manga/extension_management_tile.dart';
import 'package:fushi/src/media/manga/mihon/mihon_download_counts.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_details_dialog.dart';
import 'package:fushi/utils.dart';

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

/// 祖先页头已经挂着「刷新仓库」动作时由页面提供（库页「扩展」子标签）：扩展目录
/// 据此不在正文顶部再画一枚刷新按钮。没有这个 scope 的宿主（浏览模块、独立页、
/// 测试）照旧在目录顶部给刷新入口——入口只挪位置，不会丢。
class ExtensionCatalogHeaderScope extends InheritedWidget {
  const ExtensionCatalogHeaderScope({
    required super.child,
    super.key,
    this.refreshInHeader = true,
  });

  /// 页头里已经有「刷新仓库」。
  final bool refreshInHeader;

  /// [context] 所在页面的页头是否已经挂了「刷新仓库」。
  static bool refreshInHeaderOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ExtensionCatalogHeaderScope>()
          ?.refreshInHeader ??
      false;

  @override
  bool updateShouldNotify(ExtensionCatalogHeaderScope oldWidget) =>
      oldWidget.refreshInHeader != refreshInHeader;
}

/// 扩展目录的动作区：最低下载量 chip 行 + 批量安装 + 一键更新（M3E）。
///
/// 下载量门槛是一排单选 chip（[ExtensionFilterChipRow]，与仓库 / 语言筛选同一
/// 形态）；批量安装是 outlined（装进来的是会执行的代码，不给主色），一键更新是
/// tonal 强调。键名按 [keyPrefix] 生成（`<prefix>_min_downloads`（chip 行）/
/// `<prefix>_min_downloads_<档位>`（chip）/ `<prefix>_bulk_install` /
/// `<prefix>_update_all`），测试按它定位。
class ExtensionCatalogActions extends StatelessWidget {
  const ExtensionCatalogActions({
    required this.keyPrefix,
    required this.minDownloads,
    required this.onMinDownloadsChanged,
    required this.onBulkInstall,
    required this.onUpdateAll,
    this.minDownloadOptions = kExtensionMinDownloadOptions,
    super.key,
  });

  final String keyPrefix;
  final int minDownloads;
  final ValueChanged<int> onMinDownloadsChanged;

  /// null = 置灰（批量动作进行中 / 目录加载中）。
  final VoidCallback? onBulkInstall;
  final VoidCallback? onUpdateAll;
  final List<int> minDownloadOptions;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ExtensionFilterChipRow<int>(
          key: ValueKey<String>('${keyPrefix}_min_downloads'),
          icon: FushiIcons.download,
          label: t.mihon_extension_min_downloads,
          chipKeyPrefix: '${keyPrefix}_min_downloads_',
          selected: minDownloads,
          options: <ExtensionFilterOption<int>>[
            for (final int option in minDownloadOptions)
              (
                value: option,
                label: option == 0
                    ? t.mihon_extension_language_all
                    : '≥ ${formatMihonDownloadCount(option)}',
              ),
          ],
          onSelected: onMinDownloadsChanged,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            FushiOutlinedButton.icon(
              key: ValueKey<String>('${keyPrefix}_bulk_install'),
              size: FushiButtonSize.s,
              onPressed: onBulkInstall,
              icon: const FushiIcon(FushiIcons.libraryAdd),
              label: Text(t.mihon_extension_bulk_install),
            ),
            FushiFilledButton.tonalIcon(
              key: ValueKey<String>('${keyPrefix}_update_all'),
              size: FushiButtonSize.s,
              onPressed: onUpdateAll,
              icon: const FushiIcon(FushiIcons.sync),
              label: Text(t.mihon_extension_update_all),
            ),
          ],
        ),
      ],
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
    content: SingleChildScrollView(
      child: SelectableText(
        <String>[
          summary,
          ...failures.entries.map(
            (MapEntry<String, String> entry) => '${entry.key}: ${entry.value}',
          ),
        ].join('\n'),
      ),
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
