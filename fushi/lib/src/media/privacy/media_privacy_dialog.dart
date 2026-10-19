/// 作品级「私密」开关对话框：书 / 视频 / 合集 / 游戏四个库页菜单共用一份。
///
/// 菜单项本身不带状态（游戏卡的菜单项与溢出菜单同步生成，开菜单前没法先读库），
/// 所以菜单只放一个固定的「私密」入口，当前状态在这里读、拨动即落库。私密的效果
/// （不上传排行榜、不推 Bangumi）由 `fushi_engine/privacy/media_privacy.dart` 的
/// 读取口径统一实现，这里只写 `media_privacy_flags`。
///
/// 开关显示的是**有效**状态：作品自己没标、但在私密合集里时也是私密的（排行榜 /
/// Bangumi 照样跳过它），这时开关显示开且禁用，下面写明是哪个合集、要到合集里改——
/// 只读作品自己那一行会把「实际私密」显示成「关」，用户以为它会被上传。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/privacy/media_privacy.dart';
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

  /// 收容本作品、且被标成私密的合集（null = 还在读）。非空时作品的私密来自合集，
  /// 作品自己的开关拨不掉它。
  List<MediaCollectionRow>? _privateCollections;
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
    final List<MediaCollectionRow> collections =
        await privateCollectionsContaining(
          widget.db,
          widget.kind,
          widget.entryKey,
        );
    if (!mounted) return;
    setState(() {
      _private = private;
      _privateCollections = collections;
    });
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
    } on Object catch (error) {
      // 写失败时开关保持原状态，但必须明说：用户以为已经藏起来了、其实下一轮照常
      // 上传，正是这个开关要防的事。
      FushiToast.show(
        msg: t.media_privacy_save_failed(reason: error.toString()),
        severity: ToastSeverity.error,
      );
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool? own = _private;
    final List<MediaCollectionRow>? collections = _privateCollections;
    final bool loaded = own != null && collections != null;
    final bool inherited = collections != null && collections.isNotEmpty;
    final bool effective = (own ?? false) || inherited;
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
                value: effective,
                onChanged: !loaded || inherited || _writing
                    ? null
                    : (bool v) => unawaited(_set(v)),
                contentPadding: EdgeInsets.zero,
                secondary: FushiIcon(
                  effective ? FushiIcons.lock : FushiIcons.lockOpen,
                ),
                title: Text(t.media_privacy_switch),
              ),
              AnimatedSize(
                duration: fushiMotionDuration(context, FushiMotion.short),
                curve: FushiMotion.standard,
                alignment: Alignment.topCenter,
                child: inherited
                    ? Padding(
                        key: const ValueKey<String>(
                          'media-privacy-inherited-note',
                        ),
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          t.media_privacy_inherited_note(
                            collections: collections
                                .map((MediaCollectionRow c) => c.name)
                                .join(' / '),
                          ),
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                        ),
                      )
                    : const SizedBox(width: double.infinity),
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
