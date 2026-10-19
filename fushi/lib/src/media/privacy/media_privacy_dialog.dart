/// 作品级「私密」开关对话框：书 / 视频 / 合集 / 游戏四个库页菜单共用一份。
///
/// 菜单项本身不带状态（游戏卡的菜单项与溢出菜单同步生成，开菜单前没法先读库），
/// 所以菜单只放一个固定的「私密」入口，当前状态在这里读、拨动即落库。私密的效果
/// （不上传排行榜、不推 Bangumi）由 `fushi_engine/privacy/media_privacy.dart` 的
/// 读取口径统一实现，这里只写 `media_privacy_flags`。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 打开 [kind] / [entryKey] 宿主的私密开关。[title] 写进标题，认得出在改哪部作品。
Future<void> showMediaPrivacyDialog(
  BuildContext context, {
  required FushiDatabase db,
  required TagHostKind kind,
  required String entryKey,
  required String title,
}) => showAppDialog<void>(
  context: context,
  builder: (BuildContext dialogContext) =>
      MediaPrivacyDialog(db: db, kind: kind, entryKey: entryKey, title: title),
);

class MediaPrivacyDialog extends StatefulWidget {
  const MediaPrivacyDialog({
    super.key,
    required this.db,
    required this.kind,
    required this.entryKey,
    required this.title,
  });

  final FushiDatabase db;
  final TagHostKind kind;
  final String entryKey;
  final String title;

  @override
  State<MediaPrivacyDialog> createState() => _MediaPrivacyDialogState();
}

class _MediaPrivacyDialogState extends State<MediaPrivacyDialog> {
  /// null = 还在读当前状态（开关禁用，不让用户在未知状态上拨）。
  bool? _private;
  bool _writing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final bool private = await widget.db.isMediaPrivate(
      widget.kind,
      widget.entryKey,
    );
    if (mounted) setState(() => _private = private);
  }

  Future<void> _set(bool private) async {
    setState(() => _writing = true);
    try {
      await widget.db.setMediaPrivate(widget.kind, widget.entryKey, private);
      if (!mounted) return;
      setState(() => _private = private);
      FushiToast.show(
        msg: private
            ? t.media_privacy_marked_toast
            : t.media_privacy_cleared_toast,
        severity: ToastSeverity.success,
      );
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool? private = _private;
    return FushiAlertDialog(
      title: Text('${t.media_privacy_action} · ${widget.title}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              FushiSwitchListTile(
                key: const ValueKey<String>('media-privacy-switch'),
                value: private ?? false,
                onChanged: private == null || _writing
                    ? null
                    : (bool v) => unawaited(_set(v)),
                contentPadding: EdgeInsets.zero,
                secondary: FushiIcon(
                  private ?? false ? FushiIcons.lock : FushiIcons.lockOpen,
                ),
                title: Text(t.media_privacy_switch),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  t.media_privacy_hint,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        adaptiveDialogAction(
          context: context,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.dialog_close),
        ),
      ],
    );
  }
}
