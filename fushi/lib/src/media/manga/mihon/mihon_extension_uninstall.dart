import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/online/online_source_error_text.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 扩展包 [packageName] 提供的、当前登记在 [sources] 里的全部源（保持原顺序）。
///
/// 一个 Mihon / Aniyomi 扩展可以提供多个源（多语言变体最常见）；卸载扩展会把它们
/// 一起从来源列表里移除，确认框必须把这份清单摆出来。
List<MangaOnlineSourceRow> mihonSourcesOfExtension(
  Iterable<MangaOnlineSourceRow> sources,
  String packageName,
) => <MangaOnlineSourceRow>[
  for (final MangaOnlineSourceRow source in sources)
    if (source.extensionPackage == packageName) source,
];

/// 来源页行副标题要显示的扩展名：源名与扩展名不同（忽略大小写与首尾空白）时才
/// 返回扩展名，否则 null。
///
/// 截图里的例子：扩展「Anime Blkom」提供的源叫「أنمي بالكوم」，来源页只写源名，
/// 用户认不出它和扩展页那一行是同一个东西；名字相同时再写一遍扩展名只是噪音。
String? mihonSourceExtensionLabel({
  required String sourceName,
  required String? extensionName,
}) {
  final String extension = extensionName?.trim() ?? '';
  if (extension.isEmpty) return null;
  if (extension.toLowerCase() == sourceName.trim().toLowerCase()) return null;
  return extension;
}

/// 「卸载扩展」的二次确认 + 执行：扩展页与来源页（视频 / 漫画 / 浏览模块三处
/// 入口同一组件）共用这一处，确认文案只写一次。
///
/// 确认框写明扩展名、包名；扩展含多个源时逐条列出会一起移除的源。返回是否真的
/// 卸载成功；失败按在线源统一口径 toast，不吞异常也不让它变成未处理的 Future 错误。
Future<bool> confirmAndUninstallMihonExtension(
  BuildContext context, {
  required MihonManager manager,
  required MangaExtensionRow extension,
}) async {
  final List<MangaOnlineSourceRow> sources = mihonSourcesOfExtension(
    manager.sources,
    extension.packageName,
  );
  final bool confirmed = await showFushiConfirmDialog(
    context: context,
    title: t.mihon_source_uninstall_extension,
    content: MihonExtensionUninstallSummary(
      extension: extension,
      sources: sources,
    ),
    icon: FushiIcons.delete,
    confirmLabel: t.mihon_extension_uninstall,
    destructive: true,
  );
  if (!confirmed) return false;
  try {
    await manager.uninstallExtension(extension);
    return true;
  } on Object catch (error, stack) {
    FushiToast.show(
      msg: describeOnlineSourceError(
        error,
        logTag: 'MihonExtensionUninstall',
        stackTrace: stack,
      ),
      severity: ToastSeverity.error,
    );
    return false;
  }
}

/// 卸载确认框正文：一句说明 +（多源时）会一起移除的源清单 + 包名。
class MihonExtensionUninstallSummary extends StatelessWidget {
  const MihonExtensionUninstallSummary({
    required this.extension,
    required this.sources,
    super.key,
  });

  final MangaExtensionRow extension;
  final List<MangaOnlineSourceRow> sources;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool multiple = sources.length > 1;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            multiple
                ? t.mihon_extension_uninstall_confirm_multi(
                    name: extension.name,
                    count: sources.length,
                  )
                : t.mihon_extension_uninstall_confirm_single(
                    name: extension.name,
                  ),
          ),
          if (multiple) ...<Widget>[
            const SizedBox(height: 8),
            for (final MangaOnlineSourceRow source in sources)
              Text(
                source.language.isEmpty
                    ? '· ${source.name}'
                    : '· ${source.name} (${source.language})',
                key: ValueKey<String>(
                  'mihon_uninstall_source_${source.extensionPackage}_'
                  '${source.sourceId}',
                ),
              ),
          ],
          const SizedBox(height: 12),
          Text(
            t.mihon_extension_package_label(package: extension.packageName),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
