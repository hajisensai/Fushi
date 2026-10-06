// 排行榜 UI 的共用件：错误码 → 人话、日期格式、头像 / 封面、分页尾、举报与恢复码
// 两个小对话框。数据一律经 [leaderboardServiceProvider]（及其 `client`）取，不另开通道。

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_sync.dart';
import 'package:http/http.dart' as http;

import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/utils.dart';

/// 服务端 / 网络 / 本地错误 → 给人看的一句话。未知服务端码带上原码，便于用户报告。
String leaderboardErrorText(Object error) {
  if (error is LeaderboardApiException) return _apiErrorText(error);
  if (error is LeaderboardUploadOwnedElsewhere) {
    return t.leaderboard_sync_owned_elsewhere;
  }
  if (error is LeaderboardConsentRequired) {
    return t.leaderboard_error_consent_required;
  }
  if (error is ArgumentError) return t.leaderboard_error_bad_email;
  if (error is FormatException) return t.leaderboard_error_bad_recovery;
  if (error is StateError) return t.leaderboard_error_not_enabled;
  if (error is SocketException ||
      error is http.ClientException ||
      error is TimeoutException ||
      error is HandshakeException) {
    return t.leaderboard_error_network;
  }
  return t.leaderboard_error_unknown(detail: error.toString());
}

String _apiErrorText(LeaderboardApiException e) {
  switch (e.code) {
    case 'bad_code':
      return t.leaderboard_error_bad_code;
    case 'code_expired':
      return t.leaderboard_error_code_expired;
    case 'too_many_attempts':
      return t.leaderboard_error_too_many_attempts;
    case 'email_taken':
      return t.leaderboard_error_email_taken;
    case 'rate_limited':
      return t.leaderboard_error_rate_limited;
    case 'daily_budget':
    case 'media_quota':
      return t.leaderboard_error_daily_budget;
    case 'email_not_configured':
      return t.leaderboard_error_email_not_configured;
    case 'email_failed':
      return t.leaderboard_error_email_failed;
    case 'nickname_rejected':
      return t.leaderboard_error_nickname_rejected;
    case 'nickname_crowded':
      return t.leaderboard_error_nickname_crowded;
    case 'bad_nickname':
      return t.leaderboard_error_bad_nickname;
    case 'bad_email':
      return t.leaderboard_error_bad_email;
    case 'no_account':
      return t.leaderboard_error_no_account;
    case 'too_many_devices':
      return t.leaderboard_error_too_many_devices;
    case kLeaderboardAccountGoneCode:
      return t.leaderboard_error_unknown_account;
    case 'cannot_remove_current':
      return t.leaderboard_error_cannot_remove_current;
    case 'retry':
      return t.leaderboard_error_nickname_retry;
    case kLeaderboardNotConfiguredCode:
      return t.leaderboard_error_not_configured;
    case 'bad_time':
    case 'stale_time':
      return t.leaderboard_error_clock;
    case 'shelf_private':
      return t.leaderboard_user_shelf_private;
    case 'not_found':
    case 'blocked':
      return t.leaderboard_error_not_found;
    case 'not_an_image':
      return t.leaderboard_error_not_an_image;
    case 'self_target':
      return t.leaderboard_error_self_target;
    case 'upload_owned_by_other_device':
      return t.leaderboard_sync_owned_elsewhere;
  }
  if (e.status == 429) return t.leaderboard_error_rate_limited;
  if (e.status == 503) return t.leaderboard_error_daily_budget;
  return t.leaderboard_error_unknown(detail: '${e.status} ${e.code}');
}

/// 服务端缺配置（503 `not_configured`：排行服务还没部署好）——不是额度问题。
const String kLeaderboardNotConfiguredCode = 'not_configured';

/// 同步失败的提示：429 / 503 是「今天的额度用完了」（服务端日预算熔断 / 每小时上传
/// 次数），同步会在下次自动续上，不必让用户以为坏了；503 `not_configured`（服务还没
/// 部署）除外，照实说。
String leaderboardSyncErrorText(Object error) {
  if (error is LeaderboardApiException &&
      error.code != kLeaderboardNotConfiguredCode &&
      (error.status == 429 || error.status == 503)) {
    return t.leaderboard_sync_quota;
  }
  return leaderboardErrorText(error);
}

/// 「会公开」清单（说明卡、注册 / 登录页、恢复码导入、打开上传的确认框共用
/// 同一份，文案与实际上传内容一一对应：见 engine `ShelfEntryUpload` / `DailyCharsUpload`）。
class LeaderboardPublicDataList extends StatelessWidget {
  const LeaderboardPublicDataList({super.key});

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    Widget bullets(String title, List<String> items, IconData icon) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: tokens.type.listTitle),
        SizedBox(height: tokens.spacing.gap / 2),
        for (final String item in items)
          Padding(
            padding: EdgeInsets.only(bottom: tokens.spacing.gap / 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                FushiIcon(icon, size: 18),
                SizedBox(width: tokens.spacing.gap),
                Expanded(child: Text(item, style: tokens.type.listSubtitle)),
              ],
            ),
          ),
      ],
    );
    return Column(
      key: const ValueKey<String>('leaderboard-public-data'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        bullets(t.leaderboard_intro_public_title, <String>[
          t.leaderboard_intro_public_profile,
          t.leaderboard_intro_public_works,
          t.leaderboard_intro_public_work_stats,
          t.leaderboard_intro_public_chars,
        ], FushiIcons.globe),
        SizedBox(height: tokens.spacing.gap),
        Text(t.leaderboard_intro_email_note, style: tokens.type.metadata),
      ],
    );
  }
}

/// 同意勾选行：整行是**一个**可聚焦控件（Enter / 手柄 A / 点击都切换）；复选框只是
/// 状态显示，不单独占焦点位。
class LeaderboardConsentTile extends StatelessWidget {
  const LeaderboardConsentTile({
    required this.value,
    required this.label,
    required this.onChanged,
    super.key,
  });

  final bool value;
  final String label;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return FushiListItem(
      leading: ExcludeFocus(
        child: FushiCheckbox(
          value: value,
          onChanged: (bool? v) => onChanged(v ?? false),
        ),
      ),
      title: Text(label),
      titleMaxLines: null,
      onTap: () => onChanged(!value),
    );
  }
}

/// 打开上传前的同意确认（本机账户还没同意过时）：列出公开清单，确认返回 true。
Future<bool> showLeaderboardUploadConsentDialog(BuildContext context) async =>
    await showAppDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        final FushiDesignTokens tokens = FushiDesignTokens.of(dialogContext);
        return FushiDialogFrame(
          child: FushiModalSheetFrame(
            title: t.leaderboard_upload_consent_title,
            leadingIcon: FushiIcons.globe,
            bodyPadding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              0,
              tokens.spacing.card,
              tokens.spacing.gap,
            ),
            body: const LeaderboardPublicDataList(),
            footer: Wrap(
              alignment: WrapAlignment.end,
              spacing: tokens.spacing.gap,
              children: <Widget>[
                FushiDialogAction(
                  label: t.dialog_cancel,
                  onPressed: () => Navigator.pop(dialogContext, false),
                ),
                KeyedSubtree(
                  key: const ValueKey<String>('leaderboard-upload-consent-ok'),
                  child: FushiDialogAction(
                    label: t.leaderboard_upload_consent_action,
                    kind: FushiDialogActionKind.primary,
                    onPressed: () => Navigator.pop(dialogContext, true),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ) ??
    false;

/// 跑一个需要「已同意公开」的上传操作：本机账户没同意过时先弹确认框，确认后带
/// `consent: true` 调 [op]；取消返回 false 且不调。
Future<bool> runWithLeaderboardUploadConsent(
  BuildContext context,
  LeaderboardService service,
  Future<void> Function(bool consent) op,
) async {
  bool consent = false;
  if (!service.hasConsent) {
    consent = await showLeaderboardUploadConsentDialog(context);
    if (!consent) return false;
  }
  await op(consent);
  return true;
}

String _two(int v) => v.toString().padLeft(2, '0');

/// 毫秒时刻 → 本地 `YYYY-MM-DD`。
String leaderboardDate(int ms) {
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.year}-${_two(d.month)}-${_two(d.day)}';
}

/// 毫秒时刻 → 本地 `YYYY-MM-DD HH:mm`。
/// 服务端榜单快照的刷新周期（`services/leaderboard/wrangler.toml` 的 `*/30` cron）。
const Duration kLeaderboardSnapshotInterval = Duration(minutes: 30);

String leaderboardDateTime(int ms) {
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${leaderboardDate(ms)} ${_two(d.hour)}:${_two(d.minute)}';
}

/// 读完日期展示：优先服务端给的本地日 `finishedDate`，其次时刻，都没有 = 日期未知。
String leaderboardFinishedLabel(String? finishedDate, int? finishedAt) {
  if (finishedDate != null) return finishedDate;
  if (finishedAt != null) return leaderboardDate(finishedAt);
  return t.leaderboard_date_unknown;
}

String leaderboardKindLabel(LeaderboardKind kind) => switch (kind) {
  LeaderboardKind.book => t.leaderboard_kind_book,
  LeaderboardKind.manga => t.leaderboard_kind_manga,
  LeaderboardKind.video => t.leaderboard_kind_video,
  LeaderboardKind.game => t.leaderboard_kind_game,
};

String leaderboardMetricLabel(LeaderboardMetric metric) => switch (metric) {
  LeaderboardMetric.book => t.leaderboard_kind_book,
  LeaderboardMetric.manga => t.leaderboard_kind_manga,
  LeaderboardMetric.video => t.leaderboard_kind_video,
  LeaderboardMetric.game => t.leaderboard_kind_game,
  LeaderboardMetric.chars => t.leaderboard_metric_chars,
};

String leaderboardWindowLabel(LeaderboardWindow window) => switch (window) {
  LeaderboardWindow.week => t.leaderboard_window_week,
  LeaderboardWindow.month => t.leaderboard_window_month,
  LeaderboardWindow.all => t.leaderboard_window_all,
};

/// 指标数值带单位：字数 = 「N 字」，其余 = 「N 部」。
String leaderboardMetricValue(LeaderboardMetric metric, int value) =>
    metric == LeaderboardMetric.chars
    ? t.leaderboard_value_chars(n: value)
    : t.leaderboard_value_works(n: value);

/// 相对路径（`/img/...`）或绝对地址 → 可加载的 URL；未开启（没有 client）或空时 null。
String? leaderboardMediaUrl(WidgetRef ref, String? path) {
  if (path == null || path.isEmpty) return null;
  final LeaderboardClient? client = ref.read(leaderboardServiceProvider).client;
  if (client == null) return null;
  try {
    return client.resolveMedia(path).toString();
  } on FormatException {
    return null;
  }
}

/// 可分享链接的服务地址前缀。
Uri? leaderboardShareBase(WidgetRef ref) {
  final LeaderboardClient? client = ref.read(leaderboardServiceProvider).client;
  return client?.baseUrl;
}

/// 圆形头像：有图走应用代理的磁盘缓存图片，没图 / 加载失败退回昵称首字。
/// [onTap] 非空时可聚焦、可用 Enter / 手柄 A 触发。
class LeaderboardAvatar extends ConsumerWidget {
  const LeaderboardAvatar({
    required this.account,
    this.size = 40,
    this.onTap,
    super.key,
  });

  final LeaderboardAccount account;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String? url = leaderboardMediaUrl(ref, account.avatar);
    final String initial = account.nickname.isEmpty
        ? '?'
        : String.fromCharCodes(account.nickname.runes.take(1));
    // 无头像时的首字占位：中性底（MD3 surfaceContainerHigh / Apple fill），
    // 不再是 primaryContainer 彩色圆。
    final bool glass = isGlassDesign(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget fallback = ColoredBox(
      color: glass ? appleColorsOf(context).fill : tokens.surfaces.search,
      child: Center(
        child: Text(
          initial,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: glass
                ? appleColorsOf(context).secondaryLabel
                : colors.onSurfaceVariant,
          ),
        ),
      ),
    );
    final Widget circle = SizedBox.square(
      dimension: size,
      child: ClipOval(
        child: url == null
            ? fallback
            : Image(
                image: AppCachedHttpImage(url),
                fit: BoxFit.cover,
                errorBuilder: (BuildContext _, Object __, StackTrace? ___) =>
                    fallback,
              ),
      ),
    );
    final Widget labelled = FushiTooltip(message: account.tag, child: circle);
    if (onTap == null) return labelled;
    return FushiFocusable(
      onTap: onTap,
      borderRadius: BorderRadius.all(Radius.circular(size / 2)),
      child: labelled,
    );
  }
}

/// 作品封面。[nsfw] 时先模糊，点一下（或 Enter）才显示；没有封面画种类图标占位。
class LeaderboardCover extends ConsumerStatefulWidget {
  const LeaderboardCover({required this.work, this.width = 56, super.key});

  final LeaderboardWork work;
  final double width;

  @override
  ConsumerState<LeaderboardCover> createState() => _LeaderboardCoverState();
}

class _LeaderboardCoverState extends ConsumerState<LeaderboardCover> {
  bool _revealed = false;

  IconData get _kindIcon => switch (widget.work.kind) {
    LeaderboardKind.book => FushiIcons.books,
    LeaderboardKind.manga => FushiIcons.books,
    LeaderboardKind.video => FushiIcons.video,
    LeaderboardKind.game => FushiIcons.game,
  };

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final double width = widget.width;
    final double height = width * 1.42;
    // 无封面占位：中性填充 + 单色种类图标（不再是 secondaryContainer 色块）。
    final Widget placeholder = ColoredBox(
      color: fushiNeutralBlockColor(context),
      child: Center(
        child: FushiIcon(
          _kindIcon,
          size: width * 0.42,
          color: fushiNeutralSecondaryForeground(context),
        ),
      ),
    );
    final String? url = leaderboardMediaUrl(ref, widget.work.cover);
    Widget image = url == null
        ? placeholder
        : Image(
            image: AppCachedHttpImage(url),
            fit: BoxFit.cover,
            width: width,
            height: height,
            errorBuilder: (BuildContext _, Object __, StackTrace? ___) =>
                placeholder,
          );
    final bool hidden = widget.work.nsfw && !_revealed && url != null;
    if (hidden) {
      image = Stack(
        fit: StackFit.expand,
        children: <Widget>[
          ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: image,
          ),
          Center(
            child: FushiIcon(FushiIcons.visibilityOff, color: colors.onSurface),
          ),
        ],
      );
    }
    final Widget box = SizedBox(
      width: width,
      height: height,
      child: ClipRRect(borderRadius: tokens.radii.chipRadius, child: image),
    );
    if (!hidden) return box;
    return FushiTooltip(
      message: t.leaderboard_cover_reveal,
      child: FushiFocusable(
        onTap: () => setState(() => _revealed = true),
        borderRadius: tokens.radii.chipRadius,
        child: box,
      ),
    );
  }
}

/// 列表尾：还有下一页时是「加载更多」按钮（可聚焦），加载中是转圈。
class LeaderboardLoadMore extends StatelessWidget {
  const LeaderboardLoadMore({
    required this.hasMore,
    required this.loading,
    required this.onLoadMore,
    super.key,
  });

  final bool hasMore;
  final bool loading;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    if (!hasMore && !loading) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.all(tokens.spacing.card),
      child: Center(
        child: loading
            ? const FushiCircularProgressIndicator()
            : FushiOutlinedButton.icon(
                onPressed: onLoadMore,
                icon: const FushiIcon(FushiIcons.expandMore),
                label: Text(t.leaderboard_load_more),
              ),
      ),
    );
  }
}

/// 整块加载失败：错误文案 + 重试按钮。
class LeaderboardErrorView extends StatelessWidget {
  const LeaderboardErrorView({
    required this.error,
    required this.onRetry,
    super.key,
  });

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return FushiPlaceholderMessage(
      icon: FushiIcons.cloudOff,
      message: leaderboardErrorText(error),
      action: FushiFilledButton.tonal(
        onPressed: onRetry,
        child: Text(t.leaderboard_retry),
      ),
    );
  }
}

/// 页内小标题（区块名）：委托共享 [FushiSectionTitle.group]。
class LeaderboardSectionTitle extends StatelessWidget {
  const LeaderboardSectionTitle(this.text, {this.trailing, super.key});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiSectionTitle.group(
      text,
      trailing: trailing,
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.card,
        tokens.spacing.section,
        tokens.spacing.card,
        tokens.spacing.gap,
      ),
    );
  }
}

/// 一排互斥选项（FushiSelectableChip，Wrap 换行，不做横向滚动）。
class LeaderboardChoiceRow<T> extends StatelessWidget {
  const LeaderboardChoiceRow({
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
    this.keyPrefix,
    super.key,
  });

  final List<T> values;
  final T selected;
  final String Function(T value) labelOf;
  final ValueChanged<T> onSelected;
  final String? keyPrefix;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Wrap(
      spacing: tokens.spacing.gap,
      runSpacing: tokens.spacing.gap,
      children: <Widget>[
        for (final T v in values)
          FushiSelectableChip(
            key: keyPrefix == null
                ? null
                : ValueKey<String>('$keyPrefix-${labelOf(v)}'),
            label: labelOf(v),
            selected: v == selected,
            onSelected: (bool _) => onSelected(v),
          ),
      ],
    );
  }
}

/// 复制到剪贴板 + 提示。
Future<void> leaderboardCopy(String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  FushiToast.show(msg: t.leaderboard_copied);
}

/// 举报对话框：可选填理由（≤ 500 字，服务端上限）。确认返回理由（可为空串），取消 null。
Future<String?> showLeaderboardReportDialog(
  BuildContext context, {
  required String targetLabel,
}) => showAppDialog<String>(
  context: context,
  builder: (BuildContext _) => _ReportDialog(targetLabel: targetLabel),
);

class _ReportDialog extends StatefulWidget {
  const _ReportDialog({required this.targetLabel});

  final String targetLabel;

  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  final TextEditingController _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiDialogFrame(
      child: FushiModalSheetFrame(
        title: t.leaderboard_report_title,
        leadingIcon: FushiIcons.flag,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              t.leaderboard_report_message(target: widget.targetLabel),
              style: tokens.type.listSubtitle,
            ),
            SizedBox(height: tokens.spacing.gap),
            FushiTextField(
              controller: _reason,
              autofocus: true,
              maxLines: 3,
              minLines: 2,
              hintText: t.leaderboard_report_reason_hint,
            ),
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          children: <Widget>[
            FushiDialogAction(
              label: t.dialog_cancel,
              onPressed: () => Navigator.pop(context),
            ),
            FushiDialogAction(
              label: t.leaderboard_report_submit,
              kind: FushiDialogActionKind.primary,
              onPressed: () {
                final String reason = _reason.text.trim();
                Navigator.pop(
                  context,
                  reason.length > 500 ? reason.substring(0, 500) : reason,
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 导入恢复码（换设备的备用方式）。成功返回 true。错误就地显示，不关对话框。
Future<bool> showLeaderboardRecoveryImportDialog(BuildContext context) async =>
    await showAppDialog<bool>(
      context: context,
      builder: (BuildContext _) => const _RecoveryImportDialog(),
    ) ??
    false;

class _RecoveryImportDialog extends ConsumerStatefulWidget {
  const _RecoveryImportDialog();

  @override
  ConsumerState<_RecoveryImportDialog> createState() =>
      _RecoveryImportDialogState();
}

class _RecoveryImportDialogState extends ConsumerState<_RecoveryImportDialog> {
  final TextEditingController _code = TextEditingController();
  bool _busy = false;
  bool _consent = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String code = _code.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(leaderboardServiceProvider)
          .importRecoveryCode(code, consent: _consent);
      if (mounted) Navigator.pop(context, true);
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.importRecoveryCode', e, st);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = leaderboardErrorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    return FushiDialogFrame(
      child: FushiModalSheetFrame(
        title: t.leaderboard_recovery_import_title,
        leadingIcon: FushiIcons.key,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              t.leaderboard_recovery_import_message,
              style: tokens.type.listSubtitle,
            ),
            SizedBox(height: tokens.spacing.gap),
            FushiTextField(
              key: const ValueKey<String>('leaderboard-recovery-field'),
              controller: _code,
              autofocus: true,
              hintText: 'FUSHI1-…',
              onSubmitted: (String _) => unawaited(_submit()),
            ),
            SizedBox(height: tokens.spacing.gap),
            const LeaderboardPublicDataList(),
            LeaderboardConsentTile(
              key: const ValueKey<String>('leaderboard-recovery-consent'),
              value: _consent,
              label: t.leaderboard_signin_consent_login,
              onChanged: (bool v) => setState(() => _consent = v),
            ),
            if (_error != null) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              Text(
                _error!,
                key: const ValueKey<String>('leaderboard-recovery-error'),
                style: tokens.type.metadata.copyWith(color: colors.error),
              ),
            ],
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          children: <Widget>[
            FushiDialogAction(
              label: t.dialog_cancel,
              onPressed: _busy ? null : () => Navigator.pop(context, false),
            ),
            FushiDialogAction(
              label: t.leaderboard_recovery_import_action,
              kind: FushiDialogActionKind.primary,
              onPressed: _busy ? null : () => unawaited(_submit()),
            ),
          ],
        ),
      ),
    );
  }
}
