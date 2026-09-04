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
///
/// 关闭由两个信号驱动，先到者生效，它自己从不猜测流程状态：
///   * [DesktopOAuthLaunch.finished]：回环等待结束（授权码到 / 拒绝 / 超时 / 取消）。
///     之后是 token 交换，「等浏览器」已经过去，重开会打到已关闭的端口、取消已是空操作，
///     所以对话框此时就该走。
///   * [done]：整个登录流程收场，调用方保证总会完成——兜底。
///
/// 关闭按**自己的路由身份**移除，不弹导航栈顶：等待期间（最长 5 分钟）互联配对审批、
/// 同步冲突等后台弹窗会叠上来，`Navigator.pop()` 会把那些弹窗吞掉而让本框永久卡住。
///
/// 遮罩不可点关、Esc 视为取消：对话框消失而流程仍在后台等 5 分钟，用户就又回到「登录
/// 按钮转圈、什么都做不了」的老路上。Esc 要自己接：`barrierDismissible: false` 会让框架
/// 的 DismissIntent 处理器直接禁用，PopScope 根本收不到。
Future<void> showDesktopOAuthWaitDialog({
  required BuildContext context,
  required DesktopOAuthLaunch launch,
  required Future<void> done,
}) {
  return showAppDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext _) => DesktopOAuthWaitDialog(
      launch: launch,
      done: done,
    ),
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
  bool _closed = false;
  bool _browserOpened = true;

  @override
  void initState() {
    super.initState();
    unawaited(widget.launch.finished.then((_) {
      _close();
    }));
    unawaited(widget.done.then((_) {
      _close();
    }));
    unawaited(widget.launch.browserOpened.then((bool opened) {
      if (opened || !mounted) return;
      setState(() => _browserOpened = false);
    }));
  }

  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    final ModalRoute<Object?>? route = ModalRoute.of(context);
    if (route == null) return;
    final NavigatorState navigator = Navigator.of(context);
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  Future<void> _copyLink() async {
    try {
      await Clipboard.setData(
        ClipboardData(text: widget.launch.authUrl.toString()),
      );
    } on PlatformException {
      // 剪贴板被别的进程独占（BUG-114 同款 errno 5）/ 远程桌面受限会话：明说，让用户
      // 改用下面的可选中文本。
      FushiToast.show(msg: t.sync_desktop_oauth_link_copy_failed);
      return;
    }
    FushiToast.show(msg: t.copied_to_clipboard);
  }

  Future<void> _reopenBrowser() async {
    final bool opened = await widget.launch.reopenBrowser();
    if (opened) return;
    FushiToast.show(msg: t.sync_desktop_oauth_browser_open_failed);
    if (mounted) setState(() => _browserOpened = false);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Actions(
      actions: <Type, Action<Intent>>{
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (DismissIntent _) {
            widget.launch.cancel();
            return null;
          },
        ),
      },
      child: Focus(
        autofocus: true,
        child: PopScope(
          canPop: false,
          onPopInvokedWithResult: (bool didPop, Object? _) {
            // 系统返回：等价于取消。流程随之以 cancelled 收场，对话框在那时关闭。
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
                  if (!_browserOpened) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      t.sync_desktop_oauth_browser_open_failed,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: 12),
                  // 链接全文直接露出：剪贴板在某些环境（远程桌面 / 受限会话）会失灵，
                  // 可选中文本是最后一道兜底——所以不能截断，截断的 URL 贴进浏览器
                  // 得到的正是本 bug 报告里那张 400 页。
                  SelectableText(
                    widget.launch.authUrl.toString(),
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
              TextButton(
                onPressed: widget.launch.cancel,
                child: Text(t.cancel),
              ),
              TextButton(
                onPressed: () => unawaited(_reopenBrowser()),
                child: Text(t.sync_desktop_oauth_browser_reopen),
              ),
              FilledButton.tonal(
                onPressed: () => unawaited(_copyLink()),
                child: Text(t.sync_desktop_oauth_link_copy),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
