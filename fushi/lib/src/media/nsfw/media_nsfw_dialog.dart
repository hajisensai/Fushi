/// 作品级「NSFW」开关对话框：书 / 漫画 / 字幕书 / 视频 / 合集 / 音乐专辑的库页菜单共用
/// 一份（拍板台 w04vrhUAaX；音乐专辑见 NCzkl6oLnf-adult-cover）。游戏不走这里——游戏编辑页早有「成人向」开关
/// （`GalgameCustomData.nsfw`），封面模糊同样认它。
///
/// 与私密对话框同一结构：菜单项不带状态，当前状态在这里读、拨动即落库
/// （`media_nsfw_flags`）。开关显示**有效**状态：作品自己没标、但在 NSFW 合集里时
/// 也是 NSFW（封面照样模糊），这时开关显示开且禁用，下面写明是哪个合集。
library;

import 'dart:async';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/privacy/media_nsfw.dart';
import 'package:material_ui/material_ui.dart';

/// 打开 [kind] / [entryKey] 宿主的 NSFW 开关。[title] 写进标题，认得出在改哪部作品。
Future<void> showMediaNsfwDialog(
  BuildContext context, {
  required FushiDatabase db,
  required TagHostKind kind,
  required String entryKey,
  required String title,
}) => showAppDialog<void>(
  context: context,
  builder: (BuildContext dialogContext) =>
      MediaNsfwDialog(db: db, kind: kind, entryKey: entryKey, title: title),
);

/// 菜单开关行读的状态：与对话框同一口径的**有效** NSFW（作品自己 / 所在 NSFW
/// 合集），[locked] = 来自合集继承、在作品这一行拨不掉。
Future<({bool value, bool locked})> loadMediaNsfwToggleState(
  FushiDatabase db,
  TagHostKind kind,
  String entryKey,
) async {
  final bool own = await db.isMediaNsfw(kind, entryKey);
  final List<MediaCollectionRow> collections = await nsfwCollectionsContaining(
    db,
    kind,
    entryKey,
  );
  return (value: own || collections.isNotEmpty, locked: collections.isNotEmpty);
}

/// 写作品自己的 NSFW 标记并给结果提示（对话框与菜单开关行共用）。失败时提示后
/// 重新抛出，调用方把开关拨回去。
Future<void> writeMediaNsfw(
  FushiDatabase db,
  TagHostKind kind,
  String entryKey,
  bool nsfw,
) async {
  try {
    await db.setMediaNsfw(kind, entryKey, nsfw);
  } on Object catch (error) {
    // 写失败必须明说：用户以为封面已经藏起来了、其实没有。
    FushiToast.show(
      msg: t.media_nsfw_save_failed(reason: error.toString()),
      severity: ToastSeverity.error,
    );
    rethrow;
  }
  FushiToast.show(
    msg: nsfw ? t.media_nsfw_marked_toast : t.media_nsfw_cleared_toast,
    severity: ToastSeverity.success,
  );
}

class MediaNsfwDialog extends StatefulWidget {
  const MediaNsfwDialog({
    super.key,
    required this.db,
    required this.kind,
    required this.entryKey,
    required this.title,
  }) : assert(kind != TagHostKind.game, '游戏用编辑页的「成人向」开关');

  final FushiDatabase db;
  final TagHostKind kind;
  final String entryKey;
  final String title;

  @override
  State<MediaNsfwDialog> createState() => _MediaNsfwDialogState();
}

class _MediaNsfwDialogState extends State<MediaNsfwDialog> {
  /// null = 还在读当前状态（开关禁用，不让用户在未知状态上拨）。
  bool? _nsfw;

  /// 收容本作品、且被标成 NSFW 的合集（null = 还在读）。
  List<MediaCollectionRow>? _nsfwCollections;

  /// 读当前状态失败的原因（null = 没失败）。失败时开关保持禁用并给重试。
  Object? _loadError;
  bool _writing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final bool nsfw;
    final List<MediaCollectionRow> collections;
    try {
      nsfw = await widget.db.isMediaNsfw(widget.kind, widget.entryKey);
      collections = await nsfwCollectionsContaining(
        widget.db,
        widget.kind,
        widget.entryKey,
      );
    } on Object catch (error) {
      if (mounted) setState(() => _loadError = error);
      return;
    }
    if (!mounted) return;
    setState(() {
      _nsfw = nsfw;
      _nsfwCollections = collections;
    });
  }

  void _retryLoad() {
    setState(() => _loadError = null);
    unawaited(_load());
  }

  Future<void> _set(bool nsfw) async {
    setState(() => _writing = true);
    try {
      await writeMediaNsfw(widget.db, widget.kind, widget.entryKey, nsfw);
      if (!mounted) return;
      setState(() => _nsfw = nsfw);
    } on Object {
      // writeMediaNsfw 已明说失败；开关保持原状态。
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool? own = _nsfw;
    final List<MediaCollectionRow>? collections = _nsfwCollections;
    final bool loaded = own != null && collections != null;
    final bool inherited = collections != null && collections.isNotEmpty;
    final bool effective = (own ?? false) || inherited;
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme cs = Theme.of(context).colorScheme;
    return FushiAlertDialog(
      title: Text('${t.media_nsfw_action} · ${widget.title}'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            FushiSwitchListTile(
              key: const ValueKey<String>('media-nsfw-switch'),
              value: effective,
              onChanged: !loaded || inherited || _writing
                  ? null
                  : (bool v) => unawaited(_set(v)),
              contentPadding: EdgeInsets.zero,
              secondary: FushiIcon(
                effective ? FushiIcons.visibilityOff : FushiIcons.visibility,
              ),
              title: Text(t.media_nsfw_switch),
            ),
            FushiAnimatedSize(
              duration: fushiMotionDuration(context, FushiMotion.short),
              curve: FushiMotion.standard,
              alignment: Alignment.topCenter,
              child: inherited
                  ? Padding(
                      key: const ValueKey<String>('media-nsfw-inherited-note'),
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        t.media_nsfw_inherited_note(
                          collections: collections
                              .map((MediaCollectionRow c) => c.name)
                              .join(' / '),
                        ),
                        style: text.bodyMedium?.copyWith(color: cs.primary),
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
            FushiAnimatedSize(
              duration: fushiMotionDuration(context, FushiMotion.short),
              curve: FushiMotion.standard,
              alignment: Alignment.topCenter,
              child: _loadError == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      key: const ValueKey<String>('media-nsfw-load-error'),
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        t.media_nsfw_load_failed(reason: _loadError.toString()),
                        style: text.bodyMedium?.copyWith(color: cs.error),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(t.media_nsfw_hint, style: text.bodyMedium),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        if (_loadError != null)
          adaptiveDialogAction(
            context: context,
            onPressed: _retryLoad,
            isDefaultAction: true,
            child: Text(t.retry),
          ),
        adaptiveDialogAction(
          context: context,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.dialog_close),
        ),
      ],
    );
  }
}
