import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 诊断类错误的呈现通道（BUG-1703）。
///
/// 为什么不能沿用 [FushiToast]：移动端它走的是系统原生 Toast，Android 12+ 强制
/// 「app 图标 + 最多 2 行 + 省略号截断」，既不可复制也不可延长。而扩展加载失败这类
/// 错误里唯一可操作的信息（缺哪个类、哪一层 cause）全在消息尾部，恰好是被截掉的
/// 那一半——用户看到的只有 `Unable to instantiate extension source …`，连转述都做不到。
///
/// 所以短状态提示继续走 toast，**诊断错误走这里**：全文可滚动、可选中、一键复制。
Future<void> showErrorDetails(
  BuildContext context, {
  required String title,
  required Object error,
}) {
  final String details = error.toString();
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) {
      final ThemeData theme = Theme.of(dialogContext);
      return AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: SelectableText(
              details,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
                fontFamilyFallback: const <String>['Courier New', 'monospace'],
              ),
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: details));
              if (!dialogContext.mounted) return;
              Navigator.of(dialogContext).pop();
              FushiToast.show(msg: t.copied_to_clipboard);
            },
            child: Text(t.copy),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(t.dialog_close),
          ),
        ],
      );
    },
  );
}
