import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/desktop_oauth.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 桌面 loopback 授权的等待对话框（BUG-2120）。
///
/// 浏览器那半程在 app 之外，app 唯一能给用户的就是那条授权链接本身。对话框只有三个动作
/// ——复制链接、重新拉起浏览器、取消——每个都直接落到 [DesktopOAuthLaunch] 的同名句柄。
/// 它的生命周期钉在 [done] 上：授权成功、失败、超时、取消，哪种收场都由调用方完成
/// [done]，对话框随之关闭；它自己从不猜测流程状态。
///
/// 遮罩不可点关、Esc 视为取消：对话框消失而流程仍在后台等 5 分钟，用户就又回到「登录
/// 按钮转圈、什么都做不了」的老路上。
Future<void> showDesktopOAuthWaitDialog({
  required BuildContext context,
  required DesktopOAuthLaunch launch,
  required Future<void> done,
}) {
  return showAppDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext _) =>
        DesktopOAuthWaitDialog(launch: launch, done: done),
  );
}

class DesktopOAuthWaitDialog extends StatefulWidget {
  const DesktopOAuthWaitDialog({
    super.key,
    required this.launch,
    required this.done,
  });

  final DesktopOAuthLaunch launch;

  /// 本次登录流程的终点；完成即关闭对话框。调用方保证它**总会**完成且不抛错。
  final Future<void> done;

  @override
  State<DesktopOAuthWaitDialog> createState() => _DesktopOAuthWaitDialogState();
}

class _DesktopOAuthWaitDialogState extends State<DesktopOAuthWaitDialog> {
  bool _popped = false;

  @override
  void initState() {
    super.initState();
    unawaited(
      widget.done.then((_) {
        _popSelf();
      }),
    );
  }

  void _popSelf() {
    if (_popped || !mounted) return;
    _popped = true;
    Navigator.of(context).pop();
  }

  Future<void> _copyLink() async {
    await Clipboard.setData(
      ClipboardData(text: widget.launch.authUrl.toString()),
    );
    FushiToast.show(msg: t.copied_to_clipboard);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        // Esc / 系统返回：等价于取消。流程随之以 cancelled 收场并完成 [done]，
        // 对话框在那时才真正关闭。
        if (!didPop) widget.launch.cancel();
      },
      child: AlertDialog(
        title: Text(t.sync_desktop_oauth_waiting_title),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(t.sync_desktop_oauth_waiting_body),
              const SizedBox(height: 12),
              // 链接本身也直接露出来：剪贴板在某些环境（远程桌面 / 受限会话）会失灵，
              // 可选中文本是最后一道兜底。
              SelectableText(
                widget.launch.authUrl.toString(),
                maxLines: 3,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  fontFamilyFallback: const <String>[
                    'Courier New',
                    'monospace',
                  ],
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: widget.launch.cancel, child: Text(t.cancel)),
          TextButton(
            onPressed: () => unawaited(widget.launch.reopenBrowser()),
            child: Text(t.sync_desktop_oauth_browser_reopen),
          ),
          FilledButton.tonal(
            onPressed: () => unawaited(_copyLink()),
            child: Text(t.sync_desktop_oauth_link_copy),
          ),
        ],
      ),
    );
  }
}
