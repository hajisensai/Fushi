/// 下载前的一次性说明框（2026-10-09 所有者 / 用户）。同一个组件，按
/// [DownloadNoticeKind] 换文案：
/// - [DownloadNoticeKind.p2p]：BT / 磁力下载前。海外用户不知道浏览页的下载是
///   BT 还是直链、要不要挂 VPN。说明只讲技术事实：内容来自其他用户、IP 对同
///   种子的人可见、开了上传才会上传（内置引擎默认关上传）、请遵守当地法律。
/// - [DownloadNoticeKind.gameResource]：从第三方游戏资源站（真红小站、内置
///   AList 等）下载前。资源不是 Fushi 提供的；压缩包 / 安装程序可能含恶意软件，
///   建议先查毒再解压运行；请遵守当地法律与版权规定。
///
/// 每种各自记「不再提示」，勾选框默认**不勾**：首次说明的作用是让用户真的读到，
/// 用户主动勾了以后才不再弹。取消 = 这次不下载。
///
/// 与「上传 / 做种」首用提示（`TorrentUploadConsentDialog`）是两件事：那个只管
/// 内置引擎的上传配置；P2P 说明对所有 BT 后端（内置 / 外接 qBittorrent / 交给
/// 互联 host）都成立，所以先弹这个。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/downloads/download_source_method.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 说明的种类。
enum DownloadNoticeKind {
  /// BT / 磁力（P2P）。
  p2p,

  /// 第三方游戏资源站的下载。
  gameResource;

  String get title => switch (this) {
    DownloadNoticeKind.p2p => t.download_p2p_notice_title,
    DownloadNoticeKind.gameResource => t.download_game_notice_title,
  };

  String get body => switch (this) {
    DownloadNoticeKind.p2p => t.download_p2p_notice_body,
    DownloadNoticeKind.gameResource => t.download_game_notice_body,
  };

  IconData get icon => switch (this) {
    DownloadNoticeKind.p2p => DownloadTransferMethod.torrent.icon,
    DownloadNoticeKind.gameResource => kExternalSourceIcon,
  };
}

/// 用户在说明框里的选择。
@immutable
class DownloadNoticeResult {
  const DownloadNoticeResult({
    required this.proceed,
    required this.dontShowAgain,
  });

  /// 继续这次下载。
  final bool proceed;

  /// 勾了「不再提示」（只在继续时生效）。
  final bool dontShowAgain;
}

/// 说明对话框本体：纯 UI，结果经 pop 返回 [DownloadNoticeResult]。
class DownloadNoticeDialog extends StatefulWidget {
  const DownloadNoticeDialog({required this.kind, this.method, super.key});

  final DownloadNoticeKind kind;

  /// 顶部标签显示的下载方式；null 时 P2P 说明显示 BT、游戏资源说明只显示
  /// 「外部来源」。
  final DownloadTransferMethod? method;

  @override
  State<DownloadNoticeDialog> createState() => _DownloadNoticeDialogState();
}

class _DownloadNoticeDialogState extends State<DownloadNoticeDialog> {
  bool _dontShowAgain = false;

  void _close({required bool proceed}) {
    Navigator.of(context).pop(
      DownloadNoticeResult(proceed: proceed, dontShowAgain: _dontShowAgain),
    );
  }

  Widget _tags() {
    final DownloadTransferMethod? method =
        widget.method ??
        (widget.kind == DownloadNoticeKind.p2p
            ? DownloadTransferMethod.torrent
            : null);
    if (method != null) return DownloadSourceTags(method: method);
    return const DownloadExternalSourceTag();
  }

  @override
  Widget build(BuildContext context) {
    final DownloadNoticeKind kind = widget.kind;
    return FushiAlertDialog(
      key: ValueKey<String>('download-notice-${kind.name}'),
      icon: FushiDialogHeroIcon(icon: kind.icon, tone: FushiHeroTone.tertiary),
      title: Text(kind.title),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Align(alignment: AlignmentDirectional.centerStart, child: _tags()),
          const SizedBox(height: 12),
          Text(kind.body),
          const SizedBox(height: 8),
          FushiCheckboxListTile(
            key: const ValueKey<String>('download-notice-dont-show'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _dontShowAgain,
            title: Text(t.download_notice_dont_show),
            onChanged: (bool? value) =>
                setState(() => _dontShowAgain = value ?? false),
          ),
        ],
      ),
      actions: <Widget>[
        FushiTextButton(
          key: const ValueKey<String>('download-notice-cancel'),
          onPressed: () => _close(proceed: false),
          child: Text(t.cancel),
        ),
        FushiFilledButton(
          key: const ValueKey<String>('download-notice-continue'),
          onPressed: () => _close(proceed: true),
          child: Text(t.download_notice_continue),
        ),
      ],
    );
  }
}

bool _dismissed(AppModel appModel, DownloadNoticeKind kind) => switch (kind) {
  DownloadNoticeKind.p2p => appModel.p2pDownloadNoticeDismissed,
  DownloadNoticeKind.gameResource => appModel.gameResourceNoticeDismissed,
};

Future<void> _dismiss(AppModel appModel, DownloadNoticeKind kind) =>
    switch (kind) {
      DownloadNoticeKind.p2p => appModel.setP2pDownloadNoticeDismissed(),
      DownloadNoticeKind.gameResource =>
        appModel.setGameResourceNoticeDismissed(),
    };

/// 发起下载前调用：需要说明就弹框，返回这次是否继续。
///
/// 已勾过「不再提示」直接返回 true。拿不到 AppModel（没有 `ProviderScope` 的
/// widget 测试树）时同样放行——说明是给用户看的，不是下载的前置条件。
Future<bool> confirmDownloadNotice(
  BuildContext context,
  DownloadNoticeKind kind, {
  DownloadTransferMethod? method,
}) async {
  AppModel? appModel;
  try {
    appModel = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appProvider);
  } on StateError {
    appModel = null;
  }
  if (appModel == null || _dismissed(appModel, kind)) return true;
  if (!context.mounted) return false;
  final DownloadNoticeResult? result =
      await showAppDialog<DownloadNoticeResult>(
        context: context,
        builder: (_) => DownloadNoticeDialog(kind: kind, method: method),
      );
  if (result == null || !result.proceed) return false;
  if (result.dontShowAgain) await _dismiss(appModel, kind);
  return true;
}

/// BT / 磁力下载前的 P2P 说明（[confirmDownloadNotice] 的简写）。
Future<bool> confirmP2pDownloadNotice(BuildContext context) =>
    confirmDownloadNotice(context, DownloadNoticeKind.p2p);
