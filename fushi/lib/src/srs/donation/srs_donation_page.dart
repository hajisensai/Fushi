/// 复习历史捐赠页：说明、同意文案、统计、单词开关 + 词表预览、捐赠 / 更新 / 撤回。
///
/// 首页横幅「了解并捐赠」「更新捐赠」与复习页「⋯」里的「复习历史捐赠」都进这一页；
/// 状态（GET）、更新捐赠与撤回（DELETE）也都在这里（设计 `docs/specs/2026-11-26-srs-review-donation.md`）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/apkg/srs_donation_export.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/donation/srs_donation_client.dart';
import 'package:fushi/src/srs/donation/srs_donation_eligibility.dart';
import 'package:fushi/src/srs/donation/srs_donation_flow.dart';
import 'package:fushi/src/srs/donation/srs_donation_providers.dart';
import 'package:fushi/src/srs/donation/srs_donation_words_page.dart';
import 'package:fushi/src/srs/srs_navigation.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart'
    show AdaptiveSettingsSwitchRow;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/build_version.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 打开捐赠页。
Future<void> openSrsDonationPage(BuildContext context) =>
    srsPushPage<void>(context, (_) => const SrsDonationPage());

/// 预览数是否够捐（与首页横幅同一门槛：1000 次 / 14 天）。
bool srsDonationPreviewEligible(SrsDonationPreview preview, DateTime now) {
  final DateTime? first = preview.firstReviewAt;
  return preview.reviewCount >= kSrsDonationMinReviews &&
      first != null &&
      now.difference(first).inDays >= kSrsDonationMinDays;
}

class SrsDonationPage extends ConsumerStatefulWidget {
  const SrsDonationPage({super.key});

  @override
  ConsumerState<SrsDonationPage> createState() => _SrsDonationPageState();
}

enum _Busy { none, exporting, uploading, withdrawing }

class _SrsDonationPageState extends ConsumerState<SrsDonationPage> {
  SrsDbStore? _store;
  SrsDonationPreview? _preview;
  bool _loading = true;
  bool _loadFailed = false;

  SrsDonationStatus? _status;
  bool _statusFailed = false;

  late bool _includeWords;
  late Set<String> _excluded;

  _Busy _busy = _Busy.none;
  double? _progress;
  String? _error;

  @override
  void initState() {
    super.initState();
    final SrsDonationPrefsState prefs = ref.read(srsDonationPrefsProvider);
    _includeWords = prefs.includeWords;
    _excluded = <String>{...prefs.excludedNoteIds};
    unawaited(_load());
  }

  ({String donorId, String donorKey})? get _identity {
    final SrsDbStore? store = _store;
    return store == null ? null : srsDonationIdentity(store.profileUid);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final SrsDbStore? store = await readSrsStore(ref);
      if (store == null) throw StateError('srs store unavailable');
      final SrsDonationPreview preview = await previewSrsDonationInBackground(
        store: store,
      );
      if (!mounted) return;
      setState(() {
        _store = store;
        _preview = preview;
        _loading = false;
      });
      unawaited(_loadStatus());
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsDonationPage.load', e, stack);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  Future<void> _loadStatus() async {
    final ({String donorId, String donorKey})? id = _identity;
    if (id == null) return;
    setState(() => _statusFailed = false);
    try {
      final SrsDonationStatus status = await ref
          .read(srsDonationClientProvider)
          .status(donorId: id.donorId, donorKey: id.donorKey);
      if (!mounted) return;
      setState(() => _status = status);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsDonationPage.status', e, stack);
      if (!mounted) return;
      setState(() => _statusFailed = true);
    }
  }

  Future<void> _setIncludeWords(bool value) async {
    setState(() => _includeWords = value);
    await updateSrsDonationPrefs(
      ref,
      (SrsDonationPrefs p) => p.setIncludeWords(value),
    );
  }

  Future<void> _setExcluded(Set<String> excluded) async {
    setState(() => _excluded = excluded);
    await updateSrsDonationPrefs(
      ref,
      (SrsDonationPrefs p) => p.setExcluded(excluded),
    );
  }

  Future<void> _openWords() async {
    final SrsDonationPreview? preview = _preview;
    if (preview == null) return;
    await openSrsDonationWordsPage(
      context,
      words: preview.words,
      excluded: _excluded,
      onChanged: (Set<String> next) =>
          srsRunLogged('SrsDonationPage.exclude', () => _setExcluded(next)),
    );
  }

  Future<void> _donate() async {
    final SrsDbStore? store = _store;
    final SrsDonationPreview? preview = _preview;
    if (store == null || preview == null || _busy != _Busy.none) return;
    setState(() {
      _busy = _Busy.exporting;
      _progress = null;
      _error = null;
    });
    final AppModel app = ref.read(appProvider);
    try {
      final SrsDonationStatus status = await runSrsDonation(
        store: store,
        client: ref.read(srsDonationClientProvider),
        preview: preview,
        appVersion: resolveCurrentAppVersion(app.packageInfo.version),
        includeWords: _includeWords,
        excludedNoteIds: _excluded,
        onPhase: (SrsDonationPhase phase) {
          if (!mounted) return;
          setState(
            () => _busy = phase == SrsDonationPhase.exporting
                ? _Busy.exporting
                : _Busy.uploading,
          );
        },
        onProgress: (int sent, int total) {
          if (!mounted || total <= 0) return;
          setState(() => _progress = sent / total);
        },
      );
      await updateSrsDonationPrefs(
        ref,
        (SrsDonationPrefs p) => p.recordDonation(
          at: ref.read(srsDonationClockProvider)(),
          reviews: preview.reviewCount,
        ),
      );
      if (!mounted) return;
      setState(() {
        _busy = _Busy.none;
        _status = status;
      });
      FushiToast.show(
        msg: t.srs_donation_done,
        severity: ToastSeverity.success,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsDonationPage.donate', e, stack);
      if (!mounted) return;
      setState(() {
        _busy = _Busy.none;
        _error = _errorText(e);
      });
    }
  }

  Future<void> _withdraw() async {
    final ({String donorId, String donorKey})? id = _identity;
    if (id == null || _busy != _Busy.none) return;
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.srs_donation_withdraw,
      message: t.srs_donation_withdraw_confirm,
      icon: FushiIcons.delete,
      confirmLabel: t.srs_donation_withdraw,
      cancelLabel: t.cancel,
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = _Busy.withdrawing);
    try {
      await ref
          .read(srsDonationClientProvider)
          .withdraw(donorId: id.donorId, donorKey: id.donorKey);
      await updateSrsDonationPrefs(
        ref,
        (SrsDonationPrefs p) => p.clearDonation(),
      );
      if (!mounted) return;
      setState(() {
        _busy = _Busy.none;
        _status = const SrsDonationStatus(donated: false);
        _excluded = <String>{};
      });
      FushiToast.show(
        msg: t.srs_donation_withdrawn,
        severity: ToastSeverity.success,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsDonationPage.withdraw', e, stack);
      if (!mounted) return;
      setState(() => _busy = _Busy.none);
      FushiToast.show(
        msg: t.srs_donation_withdraw_failed(error: _errorText(e)),
        severity: ToastSeverity.error,
      );
    }
  }

  static String _errorText(Object e) => e is SrsDonationHttpException
      ? (e.statusCode == null ? e.message : 'HTTP ${e.statusCode}')
      : '$e';

  /// 本机记得捐过、或服务端说捐过。
  bool get _donated =>
      _status?.donated ?? ref.read(srsDonationPrefsProvider).donated;

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    return FushiPageScaffold(
      title: t.srs_donation_title,
      masthead: true,
      header: apple ? null : _buildTopBar(context),
      body: Builder(builder: _buildBody),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final NavigatorState? navigator = Navigator.maybeOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: FushiFloatingTopBar(
        title: t.srs_donation_title,
        leading: <FushiToolbarItem>[
          if (navigator != null && navigator.canPop())
            FushiToolbarItem(
              icon: FushiIcons.back,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(navigator.maybePop()),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final Widget child;
    final SrsDonationPreview? preview = _preview;
    if (_loading) {
      child = const SafeArea(
        key: ValueKey<String>('srs-donation-loading'),
        bottom: false,
        child: FushiLoadingView(),
      );
    } else if (_loadFailed || preview == null) {
      child = SafeArea(
        key: const ValueKey<String>('srs-donation-unavailable'),
        bottom: false,
        child: Center(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.error,
            tone: FushiPlaceholderTone.error,
            message: t.error_load_failed,
            action: FushiFilledButton.tonalIcon(
              key: const ValueKey<String>('srs-donation-retry-load'),
              onPressed: () => srsRunLogged('SrsDonationPage.reload', _load),
              icon: const FushiIcon(FushiIcons.refresh),
              label: Text(t.retry),
            ),
          ),
        ),
      );
    } else {
      child = KeyedSubtree(
        key: const ValueKey<String>('srs-donation-content'),
        child: SrsAdaptiveSections(
          sections: <SrsSection>[
            SrsSection(_aboutCard(context)),
            SrsSection(_consentCard(context)),
            SrsSection(pane: SrsPane.secondary, _statsCard(context, preview)),
            SrsSection(pane: SrsPane.secondary, _wordsCard(context, preview)),
            SrsSection(pane: SrsPane.secondary, _actionCard(context, preview)),
          ],
        ),
      );
    }
    return AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.medium),
      child: child,
    );
  }

  Widget _heading(BuildContext context, IconData icon, String text) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Row(
      spacing: tokens.spacing.gap * 1.5,
      children: <Widget>[
        FushiIcon(icon),
        Expanded(
          child: Text(text, style: context.fushiType.titleMediumEmphasized),
        ),
      ],
    );
  }

  Widget _aboutCard(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiCard(
      key: const ValueKey<String>('srs-donation-about'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          _heading(context, FushiIcons.check, t.srs_donation_includes_title),
          Text(t.srs_donation_includes_body),
          SizedBox(height: tokens.spacing.gap / 2),
          _heading(context, FushiIcons.close, t.srs_donation_excludes_title),
          Text(t.srs_donation_excludes_body),
        ],
      ),
    );
  }

  Widget _consentCard(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiCard(
      key: const ValueKey<String>('srs-donation-consent'),
      tone: FushiCardTone.primary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          _heading(context, FushiIcons.info, t.srs_donation_consent_title),
          Text(t.srs_donation_consent),
        ],
      ),
    );
  }

  Widget _statsCard(BuildContext context, SrsDonationPreview preview) {
    final String? donorId = _identity?.donorId;
    final SrsDonationStatus? status = _status;
    final String statusText;
    if (status == null) {
      statusText = _statusFailed ? t.srs_donation_status_unknown : '…';
    } else if (!status.donated) {
      statusText = t.srs_donation_status_none;
    } else {
      final DateTime? at = status.updatedAt;
      statusText = t.srs_donation_status_donated(
        reviews: status.reviews ?? 0,
        date: at == null
            ? '-'
            : MaterialLocalizations.of(context).formatMediumDate(at.toLocal()),
      );
    }
    return FushiCard(
      key: const ValueKey<String>('srs-donation-stats'),
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiListItem(
            leading: const FushiListLeadingIcon(
              FushiIcons.history,
              tone: FushiCardTone.primary,
            ),
            title: Text(
              t.srs_donation_stats(
                reviews: preview.reviewCount,
                cards: preview.cardCount,
              ),
            ),
            subtitle: donorId == null
                ? null
                : Text(t.srs_donation_donor_id(id: donorId.substring(0, 8))),
          ),
          FushiListItem(
            key: const ValueKey<String>('srs-donation-status'),
            leading: const FushiListLeadingIcon(FushiIcons.cloudSync),
            title: Text(statusText),
            onTap: _statusFailed
                ? () => srsRunLogged('SrsDonationPage.status', _loadStatus)
                : null,
            trailing: _statusFailed
                ? const FushiIcon(FushiIcons.refresh)
                : null,
          ),
        ],
      ),
    );
  }

  Widget _wordsCard(BuildContext context, SrsDonationPreview preview) {
    return FushiCard(
      key: const ValueKey<String>('srs-donation-words'),
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AdaptiveSettingsSwitchRow(
            key: const ValueKey<String>('srs-donation-include-words'),
            title: t.srs_donation_include_words,
            subtitle: t.srs_donation_include_words_hint,
            value: _includeWords,
            onChanged: _busy != _Busy.none
                ? null
                : (bool v) => srsRunLogged(
                    'SrsDonationPage.includeWords',
                    () => _setIncludeWords(v),
                  ),
          ),
          if (_includeWords && preview.words.isNotEmpty)
            FushiListItem(
              key: const ValueKey<String>('srs-donation-words-open'),
              leading: const FushiListLeadingIcon(FushiIcons.search),
              title: Text(t.srs_donation_words_preview),
              subtitle: Text(
                t.srs_donation_words_summary(
                  n: preview.words.length,
                  excluded: preview.words
                      .where(
                        (SrsDonationWord w) => _excluded.contains(w.noteId),
                      )
                      .length,
                ),
              ),
              trailing: const FushiIcon(FushiIcons.chevronRight),
              onTap: _busy != _Busy.none
                  ? null
                  : () => srsRunLogged('SrsDonationPage.words', _openWords),
            ),
        ],
      ),
    );
  }

  Widget _actionCard(BuildContext context, SrsDonationPreview preview) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool eligible = srsDonationPreviewEligible(
      preview,
      ref.read(srsDonationClockProvider)(),
    );
    final bool donated = _donated;
    final String? error = _error;
    final bool idle = _busy == _Busy.none;
    return FushiCard(
      key: const ValueKey<String>('srs-donation-action'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          if (!eligible)
            Text(
              t.srs_donation_below_threshold(
                reviews: kSrsDonationMinReviews,
                days: kSrsDonationMinDays,
              ),
              key: const ValueKey<String>('srs-donation-below-threshold'),
              style: context.fushiType.bodySmall,
            ),
          if (_busy == _Busy.exporting || _busy == _Busy.uploading) ...<Widget>[
            Text(
              _busy == _Busy.exporting
                  ? t.srs_donation_exporting
                  : t.srs_donation_uploading(
                      percent: ((_progress ?? 0) * 100).round(),
                    ),
            ),
            FushiLinearProgressIndicator(
              key: const ValueKey<String>('srs-donation-progress'),
              value: _busy == _Busy.uploading ? _progress : null,
            ),
          ],
          if (error != null)
            Text(
              t.srs_donation_failed(error: error),
              key: const ValueKey<String>('srs-donation-error'),
              style: context.fushiType.bodySmall.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              if (donated)
                FushiPressScale(
                  child: FushiTextButton(
                    key: const ValueKey<String>('srs-donation-withdraw'),
                    onPressed: idle
                        ? () => srsRunLogged(
                            'SrsDonationPage.withdraw',
                            _withdraw,
                          )
                        : null,
                    child: Text(t.srs_donation_withdraw),
                  ),
                ),
              FushiPressScale(
                child: FushiFilledButton.icon(
                  key: const ValueKey<String>('srs-donation-submit'),
                  onPressed: idle && eligible
                      ? () => srsRunLogged('SrsDonationPage.donate', _donate)
                      : null,
                  icon: FushiIcon(
                    error != null ? FushiIcons.refresh : FushiIcons.upload,
                  ),
                  label: Text(
                    error != null
                        ? t.retry
                        : donated
                        ? t.srs_donation_update
                        : t.srs_donation_donate,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
