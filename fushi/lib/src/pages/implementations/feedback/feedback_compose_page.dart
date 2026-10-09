// 提交反馈：分类 / 标题 / 描述 / 联系方式 + 截图（默认带上打开反馈前的画面；可从
// 相册选、也可直接粘贴剪贴板里的截图——桌面 Ctrl/Cmd+V、描述框长按菜单「粘贴图片」、
// 显式「粘贴图片」按钮、Android 输入法插入的图片）+
// 附带日志与设备信息开关 + 已登录排行榜账户时「以 xx 身份提交」。成功后
// `pop(FeedbackSubmitResult)`，失败就地显示原因（不靠 toast，用户要一直看得到）。

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_common.dart';
import 'package:fushi/src/utils/misc/clipboard_image.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';

class FeedbackComposePage extends ConsumerStatefulWidget {
  const FeedbackComposePage({this.initialScreenshot, super.key});

  final Uint8List? initialScreenshot;

  @override
  ConsumerState<FeedbackComposePage> createState() =>
      _FeedbackComposePageState();
}

class _FeedbackComposePageState extends ConsumerState<FeedbackComposePage> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _body = TextEditingController();
  final TextEditingController _contact = TextEditingController();
  FeedbackCategory _category = FeedbackCategory.bug;
  late final List<Uint8List> _shots = <Uint8List>[?widget.initialScreenshot];
  bool _includeLogs = true;
  bool _includeDevice = true;
  bool _linkAccount = true;
  FeedbackSubmitStage? _stage;
  String? _error;

  /// 正在读剪贴板：Ctrl+V 与菜单 / 按钮同时触发时只读一次，避免同一张图加两遍。
  bool _pasting = false;

  bool get _busy => _stage != null;

  int get _room => FeedbackLimits.screenshots - _shots.length;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _title.dispose();
    _body.dispose();
    _contact.dispose();
    super.dispose();
  }

  Future<void> _addImage() async {
    final File? file;
    try {
      file = await pickGalleryImageFile();
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.pick_image', e, st);
      return;
    }
    if (file == null) return;
    await _addRawImage(await file.readAsBytes());
  }

  /// 原始图片字节 → 按反馈上限处理 → 加进附件（满了就不加）。
  Future<void> _addRawImage(Uint8List raw) async {
    try {
      final Uint8List bytes = await prepareFeedbackImage(raw);
      if (!mounted || _room <= 0) return;
      setState(() => _shots.add(bytes));
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.prepare_image', e, st);
    }
  }

  /// 桌面 Ctrl+V（macOS Cmd+V）：不论焦点在不在输入框都看一眼剪贴板，有图就收。
  /// 不吃掉按键——输入框里照常粘贴文字（剪贴板里只有图时那一步什么也不贴）。
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.keyV) {
      return false;
    }
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    final bool primary = Platform.isMacOS
        ? keyboard.isMetaPressed
        : keyboard.isControlPressed;
    if (!primary || keyboard.isAltPressed || keyboard.isShiftPressed) {
      return false;
    }
    // 只认最上层：提交页上面又压了别的页面 / 弹窗时不抢。
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return false;
    unawaited(_pasteFromClipboard(explicit: false));
    return false;
  }

  /// 把剪贴板里的图片加进附件。[explicit]（按钮 / 菜单）时没图、满了、读失败都给
  /// 一句提示；Ctrl+V 粘的多半是文字，没图时不打扰。
  Future<void> _pasteFromClipboard({required bool explicit}) async {
    if (_busy || _pasting) return;
    _pasting = true;
    try {
      if (_room <= 0) {
        // 满了：剪贴板里确实有图才提示（Ctrl+V 粘文字不该冒出「图片满了」）。
        if (explicit || await readClipboardImage() != null) {
          _notice(
            t.feedback_compose_paste_full(max: FeedbackLimits.screenshots),
          );
        }
        return;
      }
      final List<Uint8List> images = await readFeedbackImagesFromClipboard(
        limit: _room,
      );
      if (!mounted) return;
      if (images.isEmpty) {
        if (explicit) _notice(t.feedback_compose_paste_none);
        return;
      }
      setState(() {
        for (final Uint8List image in images) {
          if (_room <= 0) break;
          _shots.add(image);
        }
      });
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.paste_image', e, st);
      if (explicit) _notice(t.feedback_compose_paste_failed);
    } finally {
      _pasting = false;
    }
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(FushiSnackBar(content: Text(message)));
  }

  /// 描述框的长按 / 右键菜单：系统默认项 + 「粘贴图片」（剪贴板里只有图时系统的
  /// 「粘贴」不出现，这一项总在，没图就提示）。
  Widget _bodyContextMenu(BuildContext context, EditableTextState state) {
    final List<ContextMenuButtonItem> items = <ContextMenuButtonItem>[
      ...state.contextMenuButtonItems,
      if (_room > 0 && !_busy)
        ContextMenuButtonItem(
          label: t.feedback_compose_paste_image,
          onPressed: () {
            state.hideToolbar();
            unawaited(_pasteFromClipboard(explicit: true));
          },
        ),
    ];
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: items,
    );
  }

  /// Android 输入法（如 Gboard 的剪贴板 / 贴图）直接插入的图片。
  static const List<String> _kInsertMimeTypes = <String>[
    'image/png',
    'image/jpeg',
    'image/webp',
    'image/gif',
  ];

  void _onContentInserted(KeyboardInsertedContent content) {
    final Uint8List? data = content.data;
    if (data == null || data.isEmpty || _busy || _room <= 0) return;
    unawaited(_addRawImage(data));
  }

  /// 桌面提示 Ctrl+V / ⌘V 粘贴截图；移动端提示长按菜单。
  String get _pasteHint {
    if (Platform.isMacOS) {
      return t.feedback_compose_paste_hint_desktop(key: '⌘V');
    }
    if (Platform.isWindows || Platform.isLinux) {
      return t.feedback_compose_paste_hint_desktop(key: 'Ctrl+V');
    }
    return t.feedback_compose_paste_hint_mobile;
  }

  Future<void> _submit() async {
    final String title = _title.text.trim();
    final String body = _body.text.trim();
    if (title.isEmpty || body.isEmpty) {
      setState(() => _error = t.feedback_compose_missing);
      return;
    }
    setState(() {
      _error = null;
      _stage = FeedbackSubmitStage.sending;
    });
    try {
      final FeedbackSubmitResult result = await ref
          .read(feedbackServiceProvider)
          .submit(
            FeedbackDraft(
              category: _category,
              title: title,
              body: body,
              contact: _contact.text.trim(),
              includeLogs: _includeLogs,
              includeDeviceInfo: _includeDevice,
              linkAccount: _linkAccount,
              screenshots: List<Uint8List>.of(_shots),
            ),
            onStage: (FeedbackSubmitStage s) {
              if (mounted) setState(() => _stage = s);
            },
          );
      if (mounted) Navigator.of(context).pop(result);
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.submit', e, st);
      if (!mounted) return;
      setState(() {
        _stage = null;
        _error = t.feedback_submit_failed(reason: feedbackErrorReason(e));
      });
    }
  }

  String _stageLabel(FeedbackSubmitStage stage) => switch (stage) {
    FeedbackSubmitStage.sending => t.feedback_stage_sending,
    FeedbackSubmitStage.screenshots => t.feedback_stage_screenshots,
    FeedbackSubmitStage.logs => t.feedback_stage_logs,
  };

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final LeaderboardSelf? self = ref.watch(
      leaderboardServiceProvider.select((LeaderboardService s) => s.self),
    );
    final FeedbackSubmitStage? stage = _stage;
    return FushiPageScaffold(
      title: t.feedback_new,
      body: Builder(
        builder: (BuildContext context) => ListView(
          padding: withBottomSafeInset(
            context,
            EdgeInsets.fromLTRB(
              tokens.spacing.card,
              tokens.spacing.card + MediaQuery.paddingOf(context).top,
              tokens.spacing.card,
              tokens.spacing.card,
            ),
          ),
          children: <Widget>[
            Wrap(
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap,
              children: <Widget>[
                for (final FeedbackCategory c in FeedbackCategory.values)
                  FushiChoiceChip(
                    key: ValueKey<String>('feedback-category-${c.wire}'),
                    avatar: FushiIcon(feedbackCategoryIcon(c)),
                    label: Text(feedbackCategoryLabel(c)),
                    selected: _category == c,
                    onSelected: _busy
                        ? null
                        : (bool _) => setState(() => _category = c),
                  ),
              ],
            ),
            SizedBox(height: tokens.spacing.card),
            FushiTextField(
              key: const ValueKey<String>('feedback-title'),
              controller: _title,
              enabled: !_busy,
              labelText: t.feedback_compose_title_field,
              hintText: t.feedback_compose_title_hint,
              maxLength: FeedbackLimits.titleMax,
              textInputAction: TextInputAction.next,
            ),
            SizedBox(height: tokens.spacing.gap),
            FushiTextField(
              key: const ValueKey<String>('feedback-body'),
              controller: _body,
              enabled: !_busy,
              labelText: t.feedback_compose_body_field,
              hintText: t.feedback_compose_body_hint,
              keyboardType: TextInputType.multiline,
              minLines: 5,
              maxLines: 12,
              maxLength: FeedbackLimits.bodyMax,
              contextMenuBuilder: _bodyContextMenu,
              contentInsertionConfiguration: ContentInsertionConfiguration(
                allowedMimeTypes: _kInsertMimeTypes,
                onContentInserted: _onContentInserted,
              ),
            ),
            SizedBox(height: tokens.spacing.gap),
            FushiTextField(
              key: const ValueKey<String>('feedback-contact'),
              controller: _contact,
              enabled: !_busy,
              labelText: t.feedback_compose_contact_field,
              hintText: t.feedback_compose_contact_hint,
              maxLength: FeedbackLimits.contactMax,
            ),
            SizedBox(height: tokens.spacing.card),
            Text(
              t.feedback_compose_screenshots(
                n: _shots.length,
                max: FeedbackLimits.screenshots,
              ),
              style: tokens.type.listSubtitle,
            ),
            if (_room > 0) ...<Widget>[
              const SizedBox(height: 2),
              Text(
                _pasteHint,
                key: const ValueKey<String>('feedback-paste-hint'),
                style: tokens.type.metadata,
              ),
            ],
            SizedBox(height: tokens.spacing.gap),
            Wrap(
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap,
              children: <Widget>[
                for (int i = 0; i < _shots.length; i++)
                  _Thumb(
                    key: ValueKey<String>('feedback-shot-$i'),
                    bytes: _shots[i],
                    onRemove: _busy
                        ? null
                        : () => setState(() => _shots.removeAt(i)),
                  ),
                if (_room > 0) ...<Widget>[
                  _AddTile(
                    key: const ValueKey<String>('feedback-add-image'),
                    icon: FushiIcons.addCircle,
                    label: t.feedback_compose_add_image,
                    onTap: _busy ? null : () => unawaited(_addImage()),
                  ),
                  _AddTile(
                    key: const ValueKey<String>('feedback-paste-image'),
                    icon: FushiIcons.paste,
                    label: t.feedback_compose_paste_image,
                    onTap: _busy
                        ? null
                        : () => unawaited(_pasteFromClipboard(explicit: true)),
                  ),
                ],
              ],
            ),
            SizedBox(height: tokens.spacing.card),
            FushiSwitchListTile(
              key: const ValueKey<String>('feedback-include-logs'),
              value: _includeLogs,
              onChanged: _busy
                  ? null
                  : (bool v) => setState(() => _includeLogs = v),
              title: Text(t.feedback_compose_attach_logs),
              subtitle: Text(t.feedback_compose_attach_logs_hint),
            ),
            FushiSwitchListTile(
              key: const ValueKey<String>('feedback-include-device'),
              value: _includeDevice,
              onChanged: _busy
                  ? null
                  : (bool v) => setState(() => _includeDevice = v),
              title: Text(t.feedback_compose_attach_device),
              subtitle: Text(t.feedback_compose_attach_device_hint),
            ),
            if (self != null)
              FushiSwitchListTile(
                key: const ValueKey<String>('feedback-link-account'),
                value: _linkAccount,
                onChanged: _busy
                    ? null
                    : (bool v) => setState(() => _linkAccount = v),
                title: Text(
                  t.feedback_compose_link_account(name: self.account.nickname),
                ),
                subtitle: Text(t.feedback_compose_link_account_hint),
              ),
            SizedBox(height: tokens.spacing.gap),
            Text(t.feedback_compose_privacy, style: tokens.type.metadata),
            if (_error != null) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              Text(
                _error!,
                key: const ValueKey<String>('feedback-compose-error'),
                style: tokens.type.listSubtitle.copyWith(color: colors.error),
              ),
            ],
            SizedBox(height: tokens.spacing.card),
            FushiPressScale(
              enabled: !_busy,
              child: FushiFilledButton.icon(
                key: const ValueKey<String>('feedback-submit'),
                onPressed: _busy ? null : () => unawaited(_submit()),
                icon: stage == null
                    ? const FushiIcon(FushiIcons.upload)
                    : const SizedBox.square(
                        dimension: 18,
                        child: FushiCircularProgressIndicator(strokeWidth: 2),
                      ),
                label: Text(
                  stage == null
                      ? t.feedback_compose_submit
                      : _stageLabel(stage),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 附件区方块的统一尺寸：缩略图与「添加图片」/「粘贴图片」同宽同高同圆角，`Wrap`
/// 放不下就换行（窄屏 360dp 下一行两三个）。
const double _kTileWidth = 96;
const double _kTileHeight = 128;

/// 附件区的「添加图片」/「粘贴图片」方块：图标 + 一行小字。
class _AddTile extends StatelessWidget {
  const _AddTile({
    required this.icon,
    required this.label,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return SizedBox(
      width: _kTileWidth,
      height: _kTileHeight,
      child: FushiCard(
        onTap: onTap,
        padding: EdgeInsets.zero,
        margin: EdgeInsets.zero,
        borderRadius: FushiM3eShape.smallRadius,
        child: FushiTooltip(
          message: label,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                FushiIcon(icon),
                const SizedBox(height: 6),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.metadata,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 已添加的截图：cover 填满方块，删除钮在右上角。
class _Thumb extends StatelessWidget {
  const _Thumb({required this.bytes, required this.onRemove, super.key});

  final Uint8List bytes;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: _kTileWidth,
      height: _kTileHeight,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          ClipRRect(
            borderRadius: FushiM3eShape.smallRadius,
            child: DecoratedBox(
              decoration: BoxDecoration(color: colors.surfaceContainerHighest),
              child: Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
                    const Center(child: FushiIcon(FushiIcons.brokenImage)),
              ),
            ),
          ),
          // 浅色截图上也看得清边界。
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: FushiM3eShape.smallRadius,
              border: Border.all(color: colors.outlineVariant),
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: FushiIconButton(
              icon: FushiIcons.close,
              tooltip: t.feedback_compose_remove_image,
              enabled: onRemove != null,
              onTap: onRemove ?? () {},
              size: 16,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              padding: EdgeInsets.zero,
              backgroundColor: colors.surface.withValues(alpha: 0.85),
            ),
          ),
        ],
      ),
    );
  }
}
