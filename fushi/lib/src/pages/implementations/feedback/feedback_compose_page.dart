// 提交反馈：分类 / 标题 / 描述 / 联系方式 + 截图（默认带上打开反馈前的画面）+
// 附带日志与设备信息开关 + 已登录排行榜账户时「以 xx 身份提交」。成功后
// `pop(FeedbackSubmitResult)`，失败就地显示原因（不靠 toast，用户要一直看得到）。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_common.dart';
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

  bool get _busy => _stage != null;

  @override
  void dispose() {
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
    try {
      final Uint8List bytes = await prepareFeedbackImage(
        await file.readAsBytes(),
      );
      if (!mounted || _shots.length >= FeedbackLimits.screenshots) return;
      setState(() => _shots.add(bytes));
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.prepare_image', e, st);
    }
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
                if (_shots.length < FeedbackLimits.screenshots)
                  FushiPressScale(
                    child: FushiCard(
                      key: const ValueKey<String>('feedback-add-image'),
                      onTap: _busy ? null : () => unawaited(_addImage()),
                      child: SizedBox(
                        width: 96,
                        height: 128,
                        child: FushiTooltip(
                          message: t.feedback_compose_add_image,
                          child: const Center(
                            child: FushiIcon(FushiIcons.addCircle),
                          ),
                        ),
                      ),
                    ),
                  ),
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

class _Thumb extends StatelessWidget {
  const _Thumb({required this.bytes, required this.onRemove, super.key});

  final Uint8List bytes;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 96,
      height: 128,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          ClipRRect(
            borderRadius: FushiM3eShape.smallRadius,
            child: Image.memory(
              bytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
                  const Center(child: FushiIcon(FushiIcons.brokenImage)),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: FushiIconButton(
              icon: FushiIcons.close,
              tooltip: t.feedback_compose_remove_image,
              enabled: onRemove != null,
              onTap: onRemove ?? () {},
            ),
          ),
        ],
      ),
    );
  }
}
