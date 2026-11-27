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
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
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
  bool _storeFailed = false;

  /// 预览（复习数 / 卡片数 / 词表）。没到之前页面照常显示：说明卡不依赖它，统计行显示「正在统计」。
  SrsDonationPreview? _preview;
  bool _previewFailed = false;

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

  /// 打开复习库，然后算预览（后台 isolate 读全库）。捐赠状态由 [srsDonationStatusProvider] 自己取（网络），
  /// 与预览互不等待。
  Future<void> _load() async {
    setState(() => _storeFailed = false);
    final SrsDbStore? store;
    try {
      store = await readSrsStore(ref);
      if (store == null) throw StateError('srs store unavailable');
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsDonationPage.load', e, stack);
      if (!mounted) return;
      setState(() => _storeFailed = true);
      return;
    }
    if (!mounted) return;
    setState(() => _store = store);
    await _loadPreview(store);
  }

  /// 预览：库内容没变（同 profile、同 [SrsDbStore.contentFingerprint]）就用上次的结果，否则放后台 isolate 重算。
  Future<void> _loadPreview(SrsDbStore store) async {
    final String fingerprint = store.contentFingerprint;
    final SrsDonationPreviewSnapshot? cached = ref.read(
      srsDonationPreviewCacheProvider,
    );
    if (cached != null &&
        cached.profileUid == store.profileUid &&
        cached.fingerprint == fingerprint) {
      setState(() {
        _preview = cached.preview;
        _previewFailed = false;
      });
      return;
    }
    setState(() => _previewFailed = false);
    // 统计要等约 20 秒，用户期间离开页面时 ref 已失效：缓存的写入口在 await 前取好，
    // 页面没了也照样把结果记进缓存，再进页不用重算。
    final StateController<SrsDonationPreviewSnapshot?> cache = ref.read(
      srsDonationPreviewCacheProvider.notifier,
    );
    try {
      final SrsDonationPreview preview = await previewSrsDonationInBackground(
        store: store,
      );
      cache.state = (
        profileUid: store.profileUid,
        fingerprint: fingerprint,
        preview: preview,
      );
      if (!mounted) return;
      setState(() => _preview = preview);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsDonationPage.preview', e, stack);
      if (!mounted) return;
      setState(() => _previewFailed = true);
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
      ref.read(srsDonationStatusProvider.notifier).set(status);
      await updateSrsDonationPrefs(
        ref,
        (SrsDonationPrefs p) => p.clearSnooze(),
      );
      if (!mounted) return;
      setState(() => _busy = _Busy.none);
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
      ref
          .read(srsDonationStatusProvider.notifier)
          .set(const SrsDonationStatus.none());
      await updateSrsDonationPrefs(
        ref,
        (SrsDonationPrefs p) => p.clearExcluded(),
      );
      if (!mounted) return;
      setState(() {
        _busy = _Busy.none;
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

  /// 服务端说捐过（状态没到 / 失败时按没捐过显示「捐赠」，上传本身同一 donorId 覆盖，不会重复）。
  bool get _donated =>
      ref.watch(srsDonationStatusProvider).valueOrNull?.donated ?? false;

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
    if (_storeFailed) {
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
      // 说明与同意文案不依赖库，进页即显示；统计 / 词表 / 按钮在同一张卡里等预览。
      child = KeyedSubtree(
        key: const ValueKey<String>('srs-donation-content'),
        child: SrsAdaptiveSections(
          sections: <SrsSection>[
            SrsSection(_aboutCard(context)),
            SrsSection(_consentCard(context)),
            SrsSection(pane: SrsPane.secondary, _donateCard(context)),
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

  /// 右栏唯一一张卡：统计 → 状态 → 单词开关 → 词表 → 操作区。各行同一套 [FushiListItem] 几何（左栏图标、
  /// 文字左缘对齐），操作区贴在卡底，不再单独占一张只放一颗按钮的卡。
  Widget _donateCard(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsDonationPreview? preview = _preview;
    return FushiCard(
      key: const ValueKey<String>('srs-donation-card'),
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _statsRow(context, preview),
          _statusRow(context),
          _includeWordsRow(context),
          if (_includeWords && preview != null && preview.words.isNotEmpty)
            _wordsRow(context, preview),
          Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              tokens.spacing.gap,
              tokens.spacing.card,
              tokens.spacing.card,
            ),
            child: _actionArea(context, preview),
          ),
        ],
      ),
    );
  }

  Widget _statsRow(BuildContext context, SrsDonationPreview? preview) {
    final String? donorId = _identity?.donorId;
    final Widget? trailing;
    final String title;
    if (preview != null) {
      title = t.srs_donation_stats(
        reviews: preview.reviewCount,
        cards: preview.cardCount,
      );
      trailing = null;
    } else if (_previewFailed) {
      title = t.error_load_failed;
      trailing = const FushiIcon(FushiIcons.refresh);
    } else {
      title = t.srs_donation_stats_counting;
      trailing = const SizedBox.square(
        dimension: 20,
        child: FushiCircularProgressIndicator(strokeWidth: 2),
      );
    }
    final SrsDbStore? store = _store;
    return FushiListItem(
      key: const ValueKey<String>('srs-donation-stats'),
      leading: const FushiListLeadingIcon(
        FushiIcons.history,
        tone: FushiCardTone.primary,
      ),
      title: Text(title),
      subtitle: donorId == null
          ? null
          : Text(t.srs_donation_donor_id(id: donorId.substring(0, 8))),
      trailing: trailing,
      onTap: _previewFailed && store != null
          ? () => srsRunLogged(
              'SrsDonationPage.preview',
              () => _loadPreview(store),
            )
          : null,
    );
  }

  Widget _statusRow(BuildContext context) {
    final AsyncValue<SrsDonationStatus?> remote = ref.watch(
      srsDonationStatusProvider,
    );
    final bool failed = remote.hasError && !remote.isLoading;
    final SrsDonationRecord? donation = remote.valueOrNull?.donation;
    final String statusText;
    if (failed) {
      statusText = t.srs_donation_status_unknown;
    } else if (remote.isLoading || remote.valueOrNull == null) {
      statusText = '…';
    } else if (donation == null) {
      statusText = t.srs_donation_status_none;
    } else {
      statusText = t.srs_donation_status_donated(
        reviews: donation.reviews,
        date: MaterialLocalizations.of(
          context,
        ).formatMediumDate(donation.updatedAt.toLocal()),
      );
    }
    return FushiListItem(
      key: const ValueKey<String>('srs-donation-status'),
      leading: const FushiListLeadingIcon(FushiIcons.cloudSync),
      title: Text(statusText),
      onTap: failed
          ? () => srsRunLogged(
              'SrsDonationPage.status',
              () async => ref.invalidate(srsDonationStatusProvider),
            )
          : null,
      trailing: failed ? const FushiIcon(FushiIcons.refresh) : null,
    );
  }

  Widget _includeWordsRow(BuildContext context) {
    final ValueChanged<bool>? onChanged = _busy != _Busy.none
        ? null
        : (bool v) => srsRunLogged(
            'SrsDonationPage.includeWords',
            () => _setIncludeWords(v),
          );
    return FushiListItem(
      key: const ValueKey<String>('srs-donation-include-words'),
      leading: const FushiListLeadingIcon(FushiIcons.dictionary),
      title: Text(t.srs_donation_include_words),
      subtitle: Text(t.srs_donation_include_words_hint),
      trailing: FushiSwitch.adaptive(
        value: _includeWords,
        onChanged: onChanged,
      ),
      onTap: onChanged == null ? null : () => onChanged(!_includeWords),
    );
  }

  Widget _wordsRow(BuildContext context, SrsDonationPreview preview) {
    return FushiListItem(
      key: const ValueKey<String>('srs-donation-words-open'),
      leading: const FushiListLeadingIcon(FushiIcons.search),
      title: Text(t.srs_donation_words_preview),
      subtitle: Text(
        t.srs_donation_words_summary(
          n: preview.words.length,
          excluded: preview.words
              .where((SrsDonationWord w) => _excluded.contains(w.noteId))
              .length,
        ),
      ),
      trailing: const FushiIcon(FushiIcons.chevronRight),
      onTap: _busy != _Busy.none
          ? null
          : () => srsRunLogged('SrsDonationPage.words', _openWords),
    );
  }

  Widget _actionArea(BuildContext context, SrsDonationPreview? preview) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 预览没到时不知道够不够门槛：按钮先禁用，也不提前说「不够」。
    final bool eligible =
        preview != null &&
        srsDonationPreviewEligible(
          preview,
          ref.read(srsDonationClockProvider)(),
        );
    final bool donated = _donated;
    final String? error = _error;
    final bool idle = _busy == _Busy.none;
    return Column(
      key: const ValueKey<String>('srs-donation-action'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tokens.spacing.gap,
      children: <Widget>[
        if (preview != null && !eligible)
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
                      ? () =>
                            srsRunLogged('SrsDonationPage.withdraw', _withdraw)
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
    );
  }
}
