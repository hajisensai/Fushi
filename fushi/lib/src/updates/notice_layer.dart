// 服务端通知（notice_feed.dart）的展示层，挂在 MaterialApp.builder 里、包住整个 navigator
// （main.dart），所以压栈出去的页面（阅读器、播放器……）同样被覆盖：
//   - banner：顶部的常驻横幅，不可关闭，有链接时整条可点；
//   - dialog：同一 id 只弹一次（已弹过的 id 记在设备本地偏好）；
//   - block：盖住全部路由的全屏层，不可关闭。
// 服务端通知的文字都来自服务端，客户端只提供按钮标签。另可接一条本地对话框
// （[NoticeLayer.localDialog]，见 build_listing.dart），与服务端对话框同一套展示、同一个队列。
//
// 本层在 navigator 之上，没有 Navigator 祖先：对话框经 [NoticeLayer.navigatorKey] 弹到
// navigator 里。结构恒定：无论有没有通知都是同一棵 Stack / Column，navigator 子树
// 不会因为通知出现 / 消失而重挂。

import 'dart:async';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/updates/notice_feed.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

/// 用外部应用打开通知链接。
Future<void> openNoticeUrl(Uri url) async {
  try {
    await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (error) {
    debugPrint('NoticeLayer: cannot open $url. $error');
  }
}

/// 把 [feed] 的通知画在 [child]（整个 navigator）上。
class NoticeLayer extends StatefulWidget {
  const NoticeLayer({
    required this.feed,
    required this.child,
    this.navigatorKey,
    this.localDialog,
    super.key,
  });

  final NoticeFeed feed;
  final Widget child;

  /// 对话框弹到这个 navigator 里；为 null 时用本层自己的 context（本层在 navigator 之内时）。
  final GlobalKey<NavigatorState>? navigatorKey;

  /// 首帧后取一次的本地对话框（null 表示没有）；排在服务端对话框之前弹，不记「已弹过」。
  final Future<RemoteNotice?> Function()? localDialog;

  @override
  State<NoticeLayer> createState() => _NoticeLayerState();
}

class _NoticeLayerState extends State<NoticeLayer> {
  bool _dialogOpen = false;

  /// 已取到、还没弹的本地对话框。
  RemoteNotice? _localPending;

  @override
  void initState() {
    super.initState();
    widget.feed.notices.addListener(_onNoticesChanged);
    _onNoticesChanged();
    final Future<RemoteNotice?> Function()? local = widget.localDialog;
    if (local != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_loadLocalDialog(local));
      });
    }
  }

  Future<void> _loadLocalDialog(Future<RemoteNotice?> Function() load) async {
    final RemoteNotice? notice = await load();
    if (notice == null || !mounted) return;
    _localPending = notice;
    unawaited(_showPendingDialogs());
  }

  @override
  void didUpdateWidget(NoticeLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.feed, widget.feed)) {
      oldWidget.feed.notices.removeListener(_onNoticesChanged);
      widget.feed.notices.addListener(_onNoticesChanged);
      _onNoticesChanged();
    }
  }

  @override
  void dispose() {
    widget.feed.notices.removeListener(_onNoticesChanged);
    super.dispose();
  }

  void _onNoticesChanged() {
    if (_dialogOpen ||
        (_localPending == null && widget.feed.pendingDialogs.isEmpty)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_showPendingDialogs());
    });
  }

  /// 弹对话框用的 context：navigator 里的，拿不到时退回本层（本层在 navigator 之内）。
  BuildContext? get _dialogContext {
    final GlobalKey<NavigatorState>? key = widget.navigatorKey;
    return key == null ? context : key.currentContext;
  }

  /// 逐条弹对话框：先本地对话框，再还没弹过的服务端对话框（弹出即记为已弹过）。
  Future<void> _showPendingDialogs() async {
    if (_dialogOpen) return;
    _dialogOpen = true;
    try {
      while (mounted) {
        // 先确认弹得出来再出队，免得服务端对话框被记成已弹过却没弹。
        final BuildContext? dialogContext = _dialogContext;
        if (dialogContext == null || !dialogContext.mounted) break;
        final RemoteNotice notice;
        final RemoteNotice? local = _localPending;
        if (local != null) {
          notice = local;
          _localPending = null;
        } else {
          final List<RemoteNotice> pending = widget.feed.pendingDialogs;
          if (pending.isEmpty) break;
          notice = pending.first;
          await widget.feed.markDialogSeen(notice.id);
        }
        if (!mounted || !dialogContext.mounted) break;
        await showAppDialog<void>(
          context: dialogContext,
          builder: (BuildContext dialogContext) =>
              _NoticeDialog(notice: notice),
        );
      }
    } finally {
      _dialogOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<RemoteNotice>>(
      valueListenable: widget.feed.notices,
      child: widget.child,
      builder:
          (BuildContext context, List<RemoteNotice> notices, Widget? child) {
            final List<RemoteNotice> banners = notices
                .where((RemoteNotice n) => n.level == RemoteNoticeLevel.banner)
                .toList(growable: false);
            RemoteNotice? block;
            for (final RemoteNotice notice in notices) {
              if (notice.level == RemoteNoticeLevel.block) {
                block = notice;
                break;
              }
            }
            final bool hasBanner = banners.isNotEmpty;
            return Stack(
              children: <Widget>[
                Positioned.fill(
                  child: Column(
                    children: <Widget>[
                      FushiAnimatedSize(
                        duration: fushiMotionDuration(
                          context,
                          FushiMotion.medium,
                        ),
                        curve: FushiMotion.standard,
                        alignment: Alignment.topCenter,
                        child: _NoticeBannerStack(notices: banners),
                      ),
                      Expanded(
                        child: MediaQuery.removePadding(
                          context: context,
                          removeTop: hasBanner,
                          child: ExcludeFocus(
                            excluding: block != null,
                            child: child!,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (block != null)
                  Positioned.fill(child: _NoticeFullScreen(notice: block)),
              ],
            );
          },
    );
  }
}

/// 顶部横幅（可能多条，竖排）。没有横幅时是零高度。
class _NoticeBannerStack extends StatelessWidget {
  const _NoticeBannerStack({required this.notices});

  final List<RemoteNotice> notices;

  @override
  Widget build(BuildContext context) {
    if (notices.isEmpty) return const SizedBox(width: double.infinity);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.tertiaryContainer,
      child: SafeArea(
        bottom: false,
        child: FushiEntranceScope(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (int i = 0; i < notices.length; i++)
                FushiStaggeredEntrance(
                  key: ValueKey<String>(notices[i].id),
                  index: i,
                  child: _NoticeBanner(notice: notices[i]),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoticeBanner extends StatelessWidget {
  const _NoticeBanner({required this.notice});

  final RemoteNotice notice;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color fg = theme.colorScheme.onTertiaryContainer;
    final Uri? url = notice.url;
    return Semantics(
      container: true,
      liveRegion: true,
      child: FushiPressScale(
        enabled: url != null,
        child: InkWell(
          onTap: url == null ? null : () => unawaited(openNoticeUrl(url)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: <Widget>[
                  FushiIcon(FushiIcons.info, color: fg),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        if (notice.title.isNotEmpty)
                          Text(
                            notice.title,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: fg,
                            ),
                          ),
                        if (notice.body.isNotEmpty)
                          Text(
                            notice.body,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: fg,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (url != null) ...<Widget>[
                    const SizedBox(width: 12),
                    FushiTooltip(
                      message: t.notice_open_link,
                      child: FushiIcon(FushiIcons.openInNew, color: fg),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NoticeDialog extends StatelessWidget {
  const _NoticeDialog({required this.notice});

  final RemoteNotice notice;

  @override
  Widget build(BuildContext context) {
    final Uri? url = notice.url;
    return FushiAlertDialog(
      title: notice.title.isEmpty ? null : Text(notice.title),
      content: notice.body.isEmpty ? null : Text(notice.body),
      actions: <Widget>[
        FushiDialogAction(
          label: t.notice_close,
          autofocus: url == null,
          onPressed: () => Navigator.of(context).pop(),
        ),
        if (url != null)
          FushiDialogAction(
            label: t.notice_open_link,
            kind: FushiDialogActionKind.primary,
            autofocus: true,
            onPressed: () {
              unawaited(openNoticeUrl(url));
              Navigator.of(context).pop();
            },
          ),
      ],
    );
  }
}

/// 全屏层：盖住外壳，不可关闭；吞掉下层的指针与焦点。
class _NoticeFullScreen extends StatelessWidget {
  const _NoticeFullScreen({required this.notice});

  final RemoteNotice notice;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Uri? url = notice.url;
    return BlockSemantics(
      child: FocusScope(
        autofocus: true,
        child: Material(
          color: theme.colorScheme.surface,
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: FushiEntranceScope(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        FushiStaggeredEntrance(
                          index: 0,
                          child: FushiIcon(
                            FushiIcons.info,
                            size: 48,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        if (notice.title.isNotEmpty)
                          FushiStaggeredEntrance(
                            index: 1,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: Text(
                                notice.title,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.headlineSmall,
                              ),
                            ),
                          ),
                        if (notice.body.isNotEmpty)
                          FushiStaggeredEntrance(
                            index: 2,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                notice.body,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyLarge,
                              ),
                            ),
                          ),
                        if (url != null)
                          FushiStaggeredEntrance(
                            index: 3,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 24),
                              child: FushiPressScale(
                                child: FushiFilledButton(
                                  autofocus: true,
                                  onPressed: () =>
                                      unawaited(openNoticeUrl(url)),
                                  child: Text(t.notice_open_link),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
