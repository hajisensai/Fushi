/// 作品「隐私」对话框：书 / 漫画 / 字幕书 / 视频 / 合集 / 游戏 / 音乐专辑的作品菜单
/// 共用**一个**入口（拍板台 qiqSbvdxrk：原先并排的「私密」「NSFW」两行，加上新的
/// 「上锁」，统一成一处）。
///
/// 对话框里两条互不蕴含的轴：
/// - **隐私分级**（单选）：公开 < 私密 < 上锁。私密 = 不上传排行榜、不推 Bangumi
///   （`media_privacy_flags`）；上锁 = 私密 + 本次会话解锁之前在库 / 首页 / 搜索 /
///   合集里都不显示（`media_locked_flags`，显示口径见 `media_visibility.dart`）。字幕书
///   与音乐专辑没有出站路径，只有「公开 / 上锁」两级；
/// - **NSFW**（开关）：封面要不要模糊（`media_nsfw_flags`；游戏写自己的「成人向」覆盖）。
///
/// 两条轴都显示**有效**状态：作品自己没标、但所在合集 / 来源库是私密 / 上锁 / NSFW 时
/// 照样生效，这时低于继承下限的选项禁用，下面写明来自哪个合集 / 来源库——只读作品
/// 自己那一行会把「实际私密」显示成「公开」，用户以为它会被上传。
library;

import 'dart:async';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/privacy/media_lock_dialogs.dart';
import 'package:fushi/src/media/privacy/media_visibility.dart';
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
import 'package:fushi_engine/privacy/media_lock.dart';
import 'package:fushi_engine/privacy/media_nsfw.dart';
import 'package:fushi_engine/privacy/media_privacy.dart';
import 'package:material_ui/material_ui.dart';

/// 作品隐私分级（有序：后者蕴含前者）。
enum MediaPrivacyLevel {
  /// 照常显示、照常上传排行榜 / 推 Bangumi。
  public,

  /// 不上传排行榜、不推 Bangumi。
  private,

  /// 私密 + 未解锁时不显示。
  locked;

  bool operator >=(MediaPrivacyLevel other) => index >= other.index;

  static MediaPrivacyLevel max(MediaPrivacyLevel a, MediaPrivacyLevel b) =>
      a.index >= b.index ? a : b;
}

/// [kind] 有没有「私密」这一级（有出站路径的宿主才有：书 / 视频 / 合集 / 游戏）。
bool mediaKindHasPrivateLevel(TagHostKind kind) => switch (kind) {
  TagHostKind.epub ||
  TagHostKind.video ||
  TagHostKind.collection ||
  TagHostKind.game => true,
  TagHostKind.srt || TagHostKind.musicAlbum => false,
};

/// 一个宿主的隐私分级现状。
@immutable
class MediaPrivacyState {
  const MediaPrivacyState({
    required this.ownPrivate,
    required this.ownLocked,
    required this.privateCollections,
    required this.lockedCollections,
    required this.privateSource,
  });

  /// 作品自己的私密标记。
  final bool ownPrivate;

  /// 作品自己的上锁标记。
  final bool ownLocked;

  /// 让它私密的合集（含上锁合集——上锁蕴含私密）。
  final List<MediaCollectionRow> privateCollections;

  /// 让它上锁的合集。
  final List<MediaCollectionRow> lockedCollections;

  /// 让它私密的来源库（开着隐私开关的扫描根）。
  final MediaSourceRow? privateSource;

  MediaPrivacyLevel get own => ownLocked
      ? MediaPrivacyLevel.locked
      : ownPrivate
      ? MediaPrivacyLevel.private
      : MediaPrivacyLevel.public;

  /// 继承来的下限（作品这一行改不到它以下）。
  MediaPrivacyLevel get floor => lockedCollections.isNotEmpty
      ? MediaPrivacyLevel.locked
      : privateCollections.isNotEmpty || privateSource != null
      ? MediaPrivacyLevel.private
      : MediaPrivacyLevel.public;

  MediaPrivacyLevel get effective => MediaPrivacyLevel.max(own, floor);
}

/// 读 [kind] / [entryKey] 的隐私分级现状。
Future<MediaPrivacyState> loadMediaPrivacyState(
  FushiDatabase db,
  TagHostKind kind,
  String entryKey,
) async => MediaPrivacyState(
  ownPrivate: await db.isMediaPrivate(kind, entryKey),
  ownLocked: await db.isMediaLocked(kind, entryKey),
  privateCollections: await privateCollectionsContaining(db, kind, entryKey),
  lockedCollections: await lockedCollectionsContaining(db, kind, entryKey),
  privateSource: await privateSourceLibraryContaining(db, kind, entryKey),
);

/// 把作品自己的分级改成 [target]：只写变了的那张表（不推进没变的时钟）。上锁只写
/// 上锁标记（读取侧上锁蕴含私密）；从上锁降到私密时补上私密标记。
Future<void> writeMediaPrivacyLevel(
  FushiDatabase db,
  TagHostKind kind,
  String entryKey, {
  required MediaPrivacyState from,
  required MediaPrivacyLevel target,
}) async {
  final bool wantLocked = target == MediaPrivacyLevel.locked;
  final bool wantPrivate = switch (target) {
    MediaPrivacyLevel.public => false,
    MediaPrivacyLevel.private => true,
    // 上锁不动私密标记：解除上锁时回到用户原先的私密选择。
    MediaPrivacyLevel.locked => from.ownPrivate,
  };
  if (from.ownLocked != wantLocked) {
    await db.setMediaLocked(kind, entryKey, wantLocked);
  }
  if (from.ownPrivate != wantPrivate) {
    await db.setMediaPrivate(kind, entryKey, wantPrivate);
  }
}

/// NSFW 开关的读写绑定。缺省（[MediaNsfwBinding.table]）读写 `media_nsfw_flags`；
/// 游戏用自己的「成人向」覆盖（`galgame_item_menu.dart` 的 `galgameNsfwBinding`）。
@immutable
class MediaNsfwBinding {
  const MediaNsfwBinding({required this.load, required this.write});

  /// 作品自己的通用 NSFW 标记 + 合集继承。
  factory MediaNsfwBinding.table(
    FushiDatabase db,
    TagHostKind kind,
    String entryKey,
  ) => MediaNsfwBinding(
    load: () async => (
      own: await db.isMediaNsfw(kind, entryKey),
      collections: await nsfwCollectionsContaining(db, kind, entryKey),
    ),
    write: (bool nsfw) => db.setMediaNsfw(kind, entryKey, nsfw),
  );

  final Future<({bool own, List<MediaCollectionRow> collections})> Function()
  load;
  final Future<void> Function(bool nsfw) write;
}

/// 打开 [kind] / [entryKey] 宿主的隐私对话框。[title] 写进标题，认得出在改哪部作品。
/// [nsfw] 缺省读写通用 NSFW 表；[onChanged] 在任一项落库后调用（游戏库刷新用）。
Future<void> showMediaPrivacyDialog(
  BuildContext context, {
  required FushiDatabase db,
  required TagHostKind kind,
  required String entryKey,
  required String title,
  MediaNsfwBinding? nsfw,
  VoidCallback? onChanged,
}) => showAppDialog<void>(
  context: context,
  builder: (BuildContext dialogContext) => MediaPrivacyDialog(
    db: db,
    kind: kind,
    entryKey: entryKey,
    title: title,
    nsfw: nsfw,
    onChanged: onChanged,
  ),
);

class MediaPrivacyDialog extends StatefulWidget {
  const MediaPrivacyDialog({
    super.key,
    required this.db,
    required this.kind,
    required this.entryKey,
    required this.title,
    this.nsfw,
    this.onChanged,
  });

  final FushiDatabase db;
  final TagHostKind kind;
  final String entryKey;
  final String title;
  final MediaNsfwBinding? nsfw;
  final VoidCallback? onChanged;

  @override
  State<MediaPrivacyDialog> createState() => _MediaPrivacyDialogState();
}

class _MediaPrivacyDialogState extends State<MediaPrivacyDialog> {
  late final MediaNsfwBinding _nsfwBinding =
      widget.nsfw ??
      MediaNsfwBinding.table(widget.db, widget.kind, widget.entryKey);

  /// null = 还在读（控件禁用，不让用户在未知状态上改）。
  MediaPrivacyState? _state;
  ({bool own, List<MediaCollectionRow> collections})? _nsfw;

  /// 读当前状态失败的原因（null = 没失败）。失败时 fail-closed：控件保持禁用，
  /// 明示「读不到」并给重试——绝不当成「公开、可改」显示。
  Object? _loadError;
  bool _writing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final MediaPrivacyState state;
    final ({bool own, List<MediaCollectionRow> collections}) nsfw;
    try {
      state = await loadMediaPrivacyState(
        widget.db,
        widget.kind,
        widget.entryKey,
      );
      nsfw = await _nsfwBinding.load();
    } on Object catch (error) {
      if (mounted) setState(() => _loadError = error);
      return;
    }
    if (!mounted) return;
    setState(() {
      _state = state;
      _nsfw = nsfw;
    });
  }

  void _retryLoad() {
    setState(() => _loadError = null);
    unawaited(_load());
  }

  Future<void> _setLevel(MediaPrivacyLevel target) async {
    final MediaPrivacyState? state = _state;
    if (state == null || target == state.own) return;
    if (target == MediaPrivacyLevel.locked &&
        !await ensureMediaLockMethod(context)) {
      return;
    }
    if (!mounted) return;
    setState(() => _writing = true);
    try {
      await writeMediaPrivacyLevel(
        widget.db,
        widget.kind,
        widget.entryKey,
        from: state,
        target: target,
      );
    } on Object catch (error) {
      // 写失败必须明说：用户以为已经藏起来了、其实下一轮照常上传 / 照常显示。
      FushiToast.show(
        msg: t.media_privacy_save_failed(reason: error.toString()),
        severity: ToastSeverity.error,
      );
      if (mounted) setState(() => _writing = false);
      return;
    }
    FushiToast.show(
      msg: switch (target) {
        MediaPrivacyLevel.public => t.media_privacy_cleared_toast,
        MediaPrivacyLevel.private => t.media_privacy_marked_toast,
        MediaPrivacyLevel.locked =>
          MediaLockSession.instance.isUnlocked
              ? t.media_lock_marked_toast
              : t.media_lock_marked_hidden_toast,
      },
      severity: ToastSeverity.success,
    );
    widget.onChanged?.call();
    if (!mounted) return;
    setState(() => _writing = false);
    await _load();
  }

  Future<void> _setNsfw(bool value) async {
    setState(() => _writing = true);
    try {
      await _nsfwBinding.write(value);
    } on Object catch (error) {
      FushiToast.show(
        msg: t.media_nsfw_save_failed(reason: error.toString()),
        severity: ToastSeverity.error,
      );
      if (mounted) setState(() => _writing = false);
      return;
    }
    FushiToast.show(
      msg: value ? t.media_nsfw_marked_toast : t.media_nsfw_cleared_toast,
      severity: ToastSeverity.success,
    );
    widget.onChanged?.call();
    if (!mounted) return;
    setState(() => _writing = false);
    await _load();
  }

  String _levelLabel(MediaPrivacyLevel level) => switch (level) {
    MediaPrivacyLevel.public => t.media_privacy_level_public,
    MediaPrivacyLevel.private => t.media_privacy_level_private,
    MediaPrivacyLevel.locked => t.media_privacy_level_locked,
  };

  String _levelHint(MediaPrivacyLevel level) => switch (level) {
    MediaPrivacyLevel.public => t.media_privacy_level_public_hint,
    MediaPrivacyLevel.private => t.media_privacy_level_private_hint,
    MediaPrivacyLevel.locked => t.media_privacy_level_locked_hint,
  };

  IconData _levelIcon(MediaPrivacyLevel level) => switch (level) {
    MediaPrivacyLevel.public => FushiIcons.globe,
    MediaPrivacyLevel.private => FushiIcons.shield,
    MediaPrivacyLevel.locked => FushiIcons.lock,
  };

  /// 继承说明（null = 没有继承）。
  String? _inheritedNote(MediaPrivacyState state) {
    if (state.lockedCollections.isNotEmpty) {
      return t.media_lock_inherited_note(
        collections: state.lockedCollections
            .map((MediaCollectionRow c) => c.name)
            .join(' / '),
      );
    }
    if (state.privateSource case final MediaSourceRow source) {
      return t.media_privacy_inherited_source_note(source: source.label);
    }
    if (state.privateCollections.isNotEmpty) {
      return t.media_privacy_inherited_note(
        collections: state.privateCollections
            .map((MediaCollectionRow c) => c.name)
            .join(' / '),
      );
    }
    return null;
  }

  Widget _animatedNote(String? text, Color? color, String key) =>
      FushiAnimatedSize(
        duration: fushiMotionDuration(context, FushiMotion.short),
        curve: FushiMotion.standard,
        alignment: Alignment.topCenter,
        child: text == null
            ? const SizedBox(width: double.infinity)
            : Padding(
                key: ValueKey<String>(key),
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  text,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: color),
                ),
              ),
      );

  @override
  Widget build(BuildContext context) {
    final MediaPrivacyState? state = _state;
    final ({bool own, List<MediaCollectionRow> collections})? nsfw = _nsfw;
    final bool loaded = state != null && nsfw != null;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final MediaPrivacyLevel effective =
        state?.effective ?? MediaPrivacyLevel.public;
    final MediaPrivacyLevel floor = state?.floor ?? MediaPrivacyLevel.public;
    final List<MediaPrivacyLevel> levels = <MediaPrivacyLevel>[
      MediaPrivacyLevel.public,
      if (mediaKindHasPrivateLevel(widget.kind)) MediaPrivacyLevel.private,
      MediaPrivacyLevel.locked,
    ];
    final bool nsfwInherited = nsfw != null && nsfw.collections.isNotEmpty;
    final bool nsfwEffective = nsfw != null && (nsfw.own || nsfwInherited);
    return FushiAlertDialog(
      title: Text('${t.media_privacy_action} · ${widget.title}'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(t.media_privacy_level_title, style: text.titleSmall),
            const SizedBox(height: 8),
            KeyedSubtree(
              key: const ValueKey<String>('media-privacy-level'),
              child: adaptiveSegmentedButton<MediaPrivacyLevel>(
                context: context,
                segments: <ButtonSegment<MediaPrivacyLevel>>[
                  for (final MediaPrivacyLevel level in levels)
                    ButtonSegment<MediaPrivacyLevel>(
                      value: level,
                      // 低于继承下限的选项改不动（要到合集 / 来源库里改）。
                      enabled: loaded && !_writing && level >= floor,
                      icon: FushiIcon(_levelIcon(level), size: 18),
                      label: Text(_levelLabel(level)),
                    ),
                ],
                selected: loaded
                    ? <MediaPrivacyLevel>{effective}
                    : const <MediaPrivacyLevel>{},
                onSelectionChanged: (Set<MediaPrivacyLevel> picked) {
                  if (picked.isEmpty) return;
                  unawaited(_setLevel(picked.first));
                },
              ),
            ),
            const SizedBox(height: 8),
            AnimatedSwitcher(
              duration: fushiMotionDuration(context, FushiMotion.short),
              switchInCurve: FushiMotion.standard,
              switchOutCurve: FushiMotion.standard,
              child: Text(
                _levelHint(effective),
                key: ValueKey<MediaPrivacyLevel>(effective),
                style: text.bodyMedium,
              ),
            ),
            _animatedNote(
              state == null ? null : _inheritedNote(state),
              cs.primary,
              'media-privacy-inherited-note',
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 4),
            FushiSwitchListTile(
              key: const ValueKey<String>('media-nsfw-switch'),
              value: nsfwEffective,
              onChanged: !loaded || nsfwInherited || _writing
                  ? null
                  : (bool v) => unawaited(_setNsfw(v)),
              contentPadding: EdgeInsets.zero,
              secondary: FushiIcon(
                nsfwEffective
                    ? FushiIcons.visibilityOff
                    : FushiIcons.visibility,
              ),
              title: Text(t.media_nsfw_switch),
              subtitle: Text(t.media_nsfw_hint),
            ),
            _animatedNote(
              nsfwInherited
                  ? t.media_nsfw_inherited_note(
                      collections: nsfw.collections
                          .map((MediaCollectionRow c) => c.name)
                          .join(' / '),
                    )
                  : null,
              cs.primary,
              'media-nsfw-inherited-note',
            ),
            _animatedNote(
              _loadError == null
                  ? null
                  : t.media_privacy_load_failed(reason: _loadError.toString()),
              cs.error,
              'media-privacy-load-error',
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
