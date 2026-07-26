/// Magpie 按需下载的确认对话框。
///
/// 单独成文件是为了让 `MagpieUpscalingService` 保持零 UI 依赖（不持 BuildContext、不引
/// i18n），也让 galgame 会话侧的挂钩点只多一行。
library;

import 'package:flutter/material.dart';
import 'package:hibiki/src/mining/magpie_installer.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/utils.dart';

/// 弹出确认框，返回用户是否同意下载。
///
/// 🔴 **BUG-1076 的时序契约**：本函数**立即** `showDialog`，绝不 `await prompt.sizeProbe`
/// 再弹。「约 N MB」由对话框自己在后台补上（[_MagpieDownloadDialog]）。旧 helper 实现是
/// 先 await HEAD 探测再弹框，弱网下用户点了没反应，正是那个 bug 的表征。
///
/// 拿不到全局 navigator context（App 还没起完 / 已销毁）时返回 false —— **静默不下载**，
/// 绝不在没有用户同意的情况下发起 10MB 下载。
Future<bool> confirmMagpieDownload(
  AppModel appModel,
  MagpieDownloadPrompt prompt,
) async {
  final BuildContext? context = appModel.navigatorKey.currentContext;
  if (context == null) return false;
  final bool? agreed = await showAppDialog<bool>(
    context: context,
    // 🔴 不许点外部关掉：`_downloadDeclined` 是**整个 app 生命周期**的一次性旗子，
    // 误关一次就等于这次运行里再也不问、超分永久不可用。要拒绝必须显式点「取消」。
    barrierDismissible: false,
    builder: (BuildContext dialogContext) =>
        _MagpieDownloadDialog(prompt: prompt),
  );
  return agreed ?? false;
}

class _MagpieDownloadDialog extends StatefulWidget {
  const _MagpieDownloadDialog({required this.prompt});

  final MagpieDownloadPrompt prompt;

  @override
  State<_MagpieDownloadDialog> createState() => _MagpieDownloadDialogState();
}

class _MagpieDownloadDialogState extends State<_MagpieDownloadDialog> {
  int? _sizeBytes;

  @override
  void initState() {
    super.initState();
    // 后台补体积；探测失败/超时就一直不显示具体大小，对话框照常可用。
    widget.prompt.sizeProbe.then((int? bytes) {
      if (!mounted || bytes == null || bytes <= 0) return;
      setState(() => _sizeBytes = bytes);
    }).catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final int? bytes = _sizeBytes;
    final String size = bytes == null
        ? ''
        : '\n\n${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB '
            '(${widget.prompt.arch})';
    return HibikiDialogFrame(
      maxWidth: 440,
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.galgame_upscaling_download_title,
        scrollable: true,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Text(
          '${t.galgame_upscaling_download_body}$size',
          style: tokens.type.listSubtitle,
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDefaultAction: true,
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(t.dialog_ok),
            ),
          ],
        ),
      ),
    );
  }
}
