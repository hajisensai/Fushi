import 'dart:async';

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi_engine/media/tracking/bangumi_api_client.dart';
import 'package:fushi/src/media/tracking/tracking_token_paste_button.dart';
import 'package:fushi/src/media/tracking/plugin/plugin_tracking_provider.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_manager.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugins_section.dart';
import 'package:fushi/src/media/tracking/tracking_sites_section.dart';
import 'package:fushi/src/media/tracking/bangumi_watched_dialog.dart';
import 'package:fushi/src/media/tracking/media_tracking_labels.dart';
import 'package:fushi/src/media/tracking/page/tracking_page.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart'
    show kTrackingProviderBangumi;
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:url_launcher/url_launcher.dart';

// The control channel reads the local-target helpers from here.
export 'package:fushi/src/media/tracking/page/tracking_local_targets.dart';

class MediaTrackingSettingsBody extends StatefulWidget {
  const MediaTrackingSettingsBody({required this.appModel, super.key});

  final AppModel appModel;

  @override
  State<MediaTrackingSettingsBody> createState() =>
      _MediaTrackingSettingsBodyState();
}

class _MediaTrackingSettingsBodyState extends State<MediaTrackingSettingsBody> {
  late final TextEditingController _tokenController = TextEditingController(
    text: widget.appModel.mediaTrackingService.accessToken,
  );

  /// 最近一次载入的状态快照（自动匹配退避等全局状态）。
  MediaTrackingStatus? _status;

  /// Every signed-in site's own sync state (last sync, pending, failures,
  /// sign-in), the same per-site status the Tracking page header reads.
  List<MediaTrackingProviderStatus> _sites =
      const <MediaTrackingProviderStatus>[];

  /// 已连接账号名。取自持久化偏好而非仅本次会话的连接结果——否则重开设置页
  /// 就只剩一个填了令牌的输入框，用户无法确认连的是哪个账号。
  String? _connectedAccount;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final String stored = widget.appModel.mediaTrackingService.accountName;
    if (stored.isNotEmpty) _connectedAccount = stored;
    _reload();
  }

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    // 映射列表 / 待办数 / 上次同步结果 / 失败原因统一走服务层快照，与首页卡片同源
    // （含「隐藏 bookChapter 伴随映射」这条口径），不再各查一遍各滤一遍。
    final MediaTrackingService service = widget.appModel.mediaTrackingService;
    final MediaTrackingStatus status = await service.loadStatus();
    final List<MediaTrackingProviderStatus> sites = await service
        .loadProviderStatuses();
    if (!mounted) return;
    setState(() {
      _status = status;
      _sites = <MediaTrackingProviderStatus>[
        for (final MediaTrackingProviderStatus site in sites)
          if (site.enabled && site.configured) site,
      ];
    });
  }

  Future<void> _connect() async {
    final String token = _tokenController.text.trim();
    if (token.isEmpty) {
      _message(t.media_tracking_token_required);
      return;
    }
    setState(() => _busy = true);
    try {
      // 校验 + 落令牌 + 记账号名是一次原子的「连接」，交给服务层，避免设置页与
      // 首页各写一份半状态。
      final BangumiUser user = await widget.appModel.mediaTrackingService
          .connect(token);
      if (!mounted) return;
      setState(
        () => _connectedAccount = user.nickname.isEmpty
            ? user.username
            : user.nickname,
      );
      _message(t.media_tracking_sync_success);
      await _sync();
    } catch (_) {
      _message(t.media_tracking_sync_failed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Retries automatic matching and says plainly what came of it: no match,
  /// matched and sent, or matched but the send failed.
  Future<void> _retryMappings() async {
    setState(() => _busy = true);
    try {
      final MediaTrackingMappingRetryResult result = await widget
          .appModel
          .mediaTrackingService
          .retryAutomaticMappings();
      if (!mounted) return;
      _message(
        !result.matchedAny
            ? t.media_tracking_retry_no_match
            : (result.syncResult?.isSuccess ?? false)
            ? t.media_tracking_retry_matched
            : t.media_tracking_sync_failed,
      );
      await _reload();
    } catch (_) {
      _message(t.media_tracking_sync_failed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sync() async {
    if (!widget.appModel.mediaTrackingService.providers.all.any(
      (TrackingProvider provider) => provider.isConfigured,
    )) {
      _message(t.media_tracking_token_required);
      return;
    }
    setState(() => _busy = true);
    final MediaTrackingSyncResult result = await widget
        .appModel
        .mediaTrackingService
        .syncNow(force: true);
    if (!mounted) return;
    _message(
      result.isSuccess
          ? t.media_tracking_sync_success
          : t.media_tracking_sync_failed,
    );
    await _reload();
    if (mounted) setState(() => _busy = false);
  }

  /// The Tracking page (links, items to link, failed sends). Its "Settings"
  /// button comes back here.
  void _openTrackingPage() {
    final NavigatorState navigator = Navigator.of(context);
    unawaited(
      openTrackingPage(
        context,
        service: widget.appModel.mediaTrackingService,
        database: widget.appModel.database,
        onOpenSettings: navigator.pop,
      ),
    );
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(FushiSnackBar(content: Text(value)));
  }

  /// "Tracking plugins", where the platform has plugins: the sites besides
  /// Bangumi are plugins only.
  List<Widget> _trackingSiteSections() {
    final AppModel appModel = widget.appModel;
    final TrackingPluginManager? manager = appModel.trackingPluginManager;
    final PluginTrackingProviders? providers = appModel.trackingPluginProviders;
    if (manager == null || providers == null) return const <Widget>[];
    return <Widget>[
      TrackingPluginsSection(
        manager: manager,
        providers: providers,
        service: appModel.mediaTrackingService,
      ),
    ];
  }

  String _siteName(String providerId) =>
      widget.appModel.mediaTrackingService.providers
          .byId(providerId)
          ?.displayName ??
      providerId;

  @override
  Widget build(BuildContext context) {
    final MediaTrackingStatus? status = _status;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AdaptiveSettingsSection(
          children: <Widget>[
            AdaptiveSettingsRow(
              key: const ValueKey<String>('media-tracking-open-page'),
              title: t.media_tracking_page_open_title,
              subtitle: t.media_tracking_page_open_hint,
              subtitleMaxLines: 3,
              icon: FushiIcons.tracking,
              showIcon: true,
              trailing: const FushiIcon(FushiIcons.chevronRight),
              onTap: _openTrackingPage,
            ),
          ],
        ),
        // The built-in Bangumi's token block; where the bundled Bangumi plugin
        // serves the site, its row in "Tracking plugins" is the one place.
        if (widget.appModel.mediaTrackingService.usesBuiltInBangumi)
          AdaptiveSettingsSection(
            key: const ValueKey<String>('media-tracking-bangumi-account'),
            title: t.media_tracking_account,
            children: <Widget>[
              AdaptiveSettingsRow(
                title: t.media_tracking_access_token,
                subtitle: t.media_tracking_access_token_hint,
                controlBelow: true,
                trailing: FushiTextFieldControl(
                  controller: _tokenController,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        TrackingTokenPasteButton(
                          key: const ValueKey<String>('bangumi-token-paste'),
                          controller: _tokenController,
                        ),
                        FushiIconButtonControl(
                          tooltip: t.media_tracking_access_token_hint,
                          icon: const FushiIcon(FushiIcons.openInNew),
                          onPressed: () => launchUrl(
                            Uri.parse(BangumiApiClient.accessTokenUrl),
                            mode: LaunchMode.externalApplication,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              AdaptiveSettingsRow(
                title: t.media_tracking_signup,
                trailing: FushiTextButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse(BangumiApiClient.signupUrl),
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const FushiIcon(FushiIcons.personAdd),
                  label: Text(t.media_tracking_signup),
                ),
              ),
              if (_connectedAccount != null)
                AdaptiveSettingsRow(
                  title: t.media_tracking_connected_as,
                  trailing: Text(_connectedAccount!),
                ),
              // The account's watched anime, read from Bangumi (moved here from
              // the home page's old sync card).
              if (_connectedAccount != null)
                AdaptiveSettingsRow(
                  title: t.media_tracking_watched_show,
                  trailing: const FushiIcon(FushiIcons.chevronRight),
                  onTap: () => showTrackingWatchedDialog(
                    context,
                    widget.appModel.mediaTrackingService,
                    providerId: kTrackingProviderBangumi,
                  ),
                ),
              AdaptiveSettingsRow(
                title: t.media_tracking_connect,
                trailing: _busy
                    ? const SizedBox.square(
                        dimension: 22,
                        child: FushiCircularProgressIndicator(strokeWidth: 2),
                      )
                    : FushiFilledButton.tonalIcon(
                        onPressed: _connect,
                        icon: const FushiIcon(FushiIcons.link),
                        label: Text(t.media_tracking_connect),
                      ),
              ),
            ],
          ),
        ..._trackingSiteSections(),
        TrackingSitesSection(service: widget.appModel.mediaTrackingService),
        AdaptiveSettingsSection(
          title: t.media_tracking_sync_section,
          children: <Widget>[
            // 每个已登录站点各自的「上次同步」+ 待发送 + 失败 / 登录失效：同步成功
            // 即删 outbox 行，没有这些的话「跑过但没有待办」与「从没跑过」同形。
            if (_sites.isEmpty)
              AdaptiveSettingsRow(
                key: const ValueKey<String>('media-tracking-sync-no-site'),
                title: t.media_tracking_sync_no_site,
              ),
            for (final MediaTrackingProviderStatus site in _sites)
              AdaptiveSettingsRow(
                key: ValueKey<String>('media-tracking-sync-${site.providerId}'),
                title: _siteName(site.providerId),
                subtitle: trackingSiteSyncSummary(site, DateTime.now()),
                subtitleMaxLines: 4,
                icon: site.unauthorized || site.failures.isNotEmpty
                    ? FushiIcons.error
                    : FushiIcons.sync,
                showIcon: true,
              ),
            AdaptiveSettingsRow(
              title: t.media_tracking_sync_now,
              trailing: FushiFilledButton.tonalIcon(
                onPressed: _busy ? null : _sync,
                icon: const FushiIcon(FushiIcons.sync),
                label: Text(t.media_tracking_sync_now),
              ),
            ),
            // Automatic matching backs off for 10 minutes after a miss; this
            // clears the back-off and tries again (moved here from the home
            // page's old sync card).
            if (status != null && status.automaticMappingMissCount > 0)
              AdaptiveSettingsRow(
                title: t.media_tracking_retry_mapping,
                trailing: FushiFilledButton.tonalIcon(
                  onPressed: _busy ? null : _retryMappings,
                  icon: const FushiIcon(FushiIcons.refresh),
                  label: Text(t.media_tracking_retry_mapping),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
