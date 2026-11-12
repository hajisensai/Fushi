/// Settings › Media tracking › Tracking plugins (spec
/// `docs/specs/2026-11-10-tracking-plugins.md` §5): install from a file the
/// user trusts, enable / disable, remove, details and this device's sign-in.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/media/tracking/bangumi_watched_dialog.dart';
import 'package:fushi/src/media/tracking/plugin/plugin_tracking_provider.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_details.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_labels.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_login_dialog.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_manager.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_models.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:material_ui/material_ui.dart';

/// Picks a plugin package and returns its bytes; null when cancelled.
typedef TrackingPluginPackagePicker =
    Future<Uint8List?> Function(BuildContext context);

/// The file picker for `.fushiplug` / `.zip` packages.
Future<Uint8List?> pickTrackingPluginPackage(BuildContext context) async {
  final FilePickerResult? picked = await pickFilesByExtensions(
    context: context,
    allowedExtensions: const <String>['fushiplug', 'zip'],
    withData: true,
  );
  final PlatformFile? file = picked?.files.firstOrNull;
  if (file == null) return null;
  return file.bytes ?? await File(file.path!).readAsBytes();
}

class TrackingPluginsSection extends StatefulWidget {
  const TrackingPluginsSection({
    required this.manager,
    required this.providers,
    required this.service,
    this.pickPackage = pickTrackingPluginPackage,
    this.openUrl,
    super.key,
  });

  final TrackingPluginManager manager;
  final PluginTrackingProviders providers;
  final MediaTrackingService service;
  final TrackingPluginPackagePicker pickPackage;

  /// "Open site" in the sign-in dialog; null = the external browser.
  final TrackingPluginUrlOpener? openUrl;

  @override
  State<TrackingPluginsSection> createState() => _TrackingPluginsSectionState();
}

class _TrackingPluginsSectionState extends State<TrackingPluginsSection> {
  TrackingPluginManager get _manager => widget.manager;

  /// The first [TrackingPluginManager.list] has not finished.
  bool _loading = true;

  /// An install, toggle or remove is running.
  bool _busy = false;

  /// Site ids the tracking service last saw rejected (unauthorized).
  Set<String> _rejectedSites = const <String>{};

  /// Plugin id -> why its account could not be read.
  final Map<String, Object> _accountErrors = <String, Object>{};

  @override
  void initState() {
    super.initState();
    _manager.changes.addListener(_changed);
    widget.service.statusRevision.addListener(_reloadStatuses);
    unawaited(_open());
  }

  @override
  void dispose() {
    _manager.changes.removeListener(_changed);
    widget.service.statusRevision.removeListener(_reloadStatuses);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _open() async {
    try {
      await _manager.list();
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('TrackingPlugins.list', error, stack);
    }
    if (!mounted) return;
    setState(() => _loading = false);
    await Future.wait(<Future<void>>[
      for (final InstalledTrackingPlugin plugin in _manager.registered)
        _refreshAccount(plugin.id),
      _reloadStatuses(),
    ]);
  }

  /// Asks the plugin for its account (stored by the provider on this device).
  Future<void> _refreshAccount(String pluginId) async {
    final PluginTrackingProvider? provider = widget.providers.byPluginId(
      pluginId,
    );
    if (provider == null) return;
    if (_infoOf(pluginId)?.can(TrackingPluginCapability.account) != true) {
      return;
    }
    try {
      await provider.account();
      _accountErrors.remove(pluginId);
    } on Object catch (error) {
      _accountErrors[pluginId] = error;
    }
    if (mounted) setState(() {});
  }

  Future<void> _reloadStatuses() async {
    final List<MediaTrackingProviderStatus> statuses = await widget.service
        .loadProviderStatuses();
    if (!mounted) return;
    setState(() {
      _rejectedSites = <String>{
        for (final MediaTrackingProviderStatus status in statuses)
          if (status.unauthorized) status.providerId,
      };
    });
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(FushiSnackBar(content: Text(text)));
  }

  Future<void> _install() async {
    final Uint8List? bytes = await widget.pickPackage(context);
    if (bytes == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final TrackingPluginInfo info = await _manager.inspect(bytes);
      final bool signerChanged = await _manager.signerChanged(info);
      final InstalledTrackingPlugin? previous = _manager.installed
          .where((InstalledTrackingPlugin p) => p.id == info.id)
          .firstOrNull;
      final bool update = previous != null;
      if (!mounted) return;
      // No spinner behind the (modal) confirmation.
      setState(() => _busy = false);
      final bool ok = await confirmTrackingPluginInstall(
        context,
        info: info,
        update: update,
        signerChanged: signerChanged,
        installedVersion: previous?.info?.version,
      );
      if (!ok || !mounted) return;
      setState(() => _busy = true);
      final TrackingPluginInfo installed = await _manager.install(
        bytes,
        info.digest,
      );
      _message(
        update
            ? t.media_tracking_plugins_updated_done(name: installed.name)
            : t.media_tracking_plugins_installed_done(name: installed.name),
      );
      unawaited(_refreshAccount(installed.id));
    } on TrackingPluginException catch (error) {
      _message(trackingPluginErrorText(error));
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('TrackingPlugins.install', error, stack);
      _message(trackingPluginErrorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run(Future<void> Function() action, String source) async {
    setState(() => _busy = true);
    try {
      await action();
    } on TrackingPluginException catch (error) {
      _message(trackingPluginErrorText(error));
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(source, error, stack);
      _message(trackingPluginErrorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setEnabled(InstalledTrackingPlugin plugin, bool on) async {
    await _run(() async {
      await _manager.setEnabled(plugin.id, on);
      if (on) unawaited(_refreshAccount(plugin.id));
    }, 'TrackingPlugins.setEnabled');
  }

  Future<void> _remove(InstalledTrackingPlugin plugin) async {
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.media_tracking_plugins_remove_title(name: _nameOf(plugin)),
      message: t.media_tracking_plugins_remove_message,
      confirmLabel: t.media_tracking_plugins_remove_action,
      cancelLabel: t.cancel,
      icon: FushiIcons.delete,
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _run(() async {
      await _manager.uninstall(plugin.id);
      _accountErrors.remove(plugin.id);
    }, 'TrackingPlugins.uninstall');
  }

  Future<void> _signIn(InstalledTrackingPlugin plugin) async {
    final PluginTrackingProvider? provider = widget.providers.byPluginId(
      plugin.id,
    );
    if (provider == null) return;
    final TrackingPluginAccount? account = await showTrackingPluginLoginDialog(
      context,
      provider: provider,
      manager: _manager,
      openUrl: widget.openUrl,
    );
    if (account == null || !mounted) return;
    _accountErrors.remove(plugin.id);
    _message(
      t.media_tracking_plugins_signed_in_done(
        name: account.name ?? _nameOf(plugin),
      ),
    );
    // Clears an earlier "rejected" state and sends what waited for the
    // sign-in at once (BUG-4395).
    unawaited(
      widget.service
          .resumeAfterSignIn(provider.id)
          .then<void>(
            (_) {},
            onError: (Object error, StackTrace stack) => ErrorLogService
                .instance
                .log('TrackingPlugins.syncAfterSignIn', error, stack),
          ),
    );
  }

  Future<void> _signOut(InstalledTrackingPlugin plugin) async {
    final PluginTrackingProvider? provider = widget.providers.byPluginId(
      plugin.id,
    );
    if (provider == null) return;
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.media_tracking_plugins_sign_out_title(name: _nameOf(plugin)),
      message: t.media_tracking_plugins_sign_out_message,
      confirmLabel: t.media_tracking_plugins_sign_out_action,
      cancelLabel: t.cancel,
      icon: FushiIcons.logout,
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _run(provider.logout, 'TrackingPlugins.signOut');
  }

  static String _nameOf(InstalledTrackingPlugin plugin) =>
      plugin.info?.name ?? plugin.id;

  TrackingPluginInfo? _infoOf(String id) {
    for (final InstalledTrackingPlugin plugin in _manager.installed) {
      if (plugin.id == id) return plugin.info;
    }
    return null;
  }

  String _nameOfId(String id) {
    for (final InstalledTrackingPlugin plugin in _manager.installed) {
      if (plugin.id == id) return _nameOf(plugin);
    }
    return id;
  }

  /// The state part of a tile's subtitle.
  String _stateOf(InstalledTrackingPlugin plugin) {
    if (!plugin.valid) {
      return t.media_tracking_plugins_state_unusable(
        error: plugin.error ?? '—',
      );
    }
    if (!plugin.enabled) return t.media_tracking_plugins_state_disabled;
    if (plugin.reservedSite) return t.media_tracking_plugins_state_reserved;
    if (plugin.conflictsWith case final String owner) {
      return t.media_tracking_plugins_state_conflict(name: _nameOfId(owner));
    }
    // Nothing is sent before a sign-in (T1 F11 d: the bundled Bangumi said
    // "In use" while signed out).
    if (plugin.registered &&
        (plugin.info?.can(TrackingPluginCapability.login) ?? false) &&
        !_manager.accountOf(plugin.id).loggedIn) {
      return t.media_tracking_plugins_state_signed_out;
    }
    return t.media_tracking_plugins_state_active;
  }

  List<Widget> _pluginRows(InstalledTrackingPlugin plugin) {
    final TrackingPluginInfo? info = plugin.info;
    final String id = plugin.id;
    return <Widget>[
      AdaptiveSettingsSwitchRow(
        key: ValueKey<String>('tracking-plugin-$id'),
        icon: plugin.valid ? FushiIcons.browserExtension : FushiIcons.warning,
        showIcon: true,
        title: _nameOf(plugin),
        subtitle: <String>[
          if (info != null)
            t.media_tracking_plugins_version_label(version: info.version),
          if (info?.site != null) info!.site!.siteHost,
          _stateOf(plugin),
          if (plugin.builtIn) t.media_tracking_plugins_built_in_label,
        ].join(' · '),
        subtitleMaxLines: 3,
        value: plugin.enabled,
        onChanged: _busy
            ? null
            : (bool on) => unawaited(_setEnabled(plugin, on)),
      ),
      if (plugin.registered) _accountRow(plugin),
      _actionsRow(plugin),
    ];
  }

  Widget _accountRow(InstalledTrackingPlugin plugin) {
    final String id = plugin.id;
    final TrackingPluginAccount account = _manager.accountOf(id);
    final bool rejected = _rejectedSites.contains(plugin.info!.site!.siteId);
    final Object? error = _accountErrors[id];
    final bool signedIn = account.loggedIn && !rejected;
    final String title = rejected
        ? t.media_tracking_plugins_account_rejected
        : account.loggedIn
        ? (account.name?.trim().isNotEmpty ?? false)
              ? t.media_tracking_plugins_account_signed_in(
                  name: account.name!.trim(),
                )
              : t.media_tracking_plugins_account_signed_in_no_name
        : t.media_tracking_plugins_account_signed_out;
    return AdaptiveSettingsRow(
      key: ValueKey<String>('tracking-plugin-account-$id'),
      icon: rejected ? FushiIcons.error : FushiIcons.account,
      showIcon: true,
      title: title,
      titleMaxLines: 3,
      subtitle: error == null ? null : trackingPluginErrorText(error),
      subtitleMaxLines: 3,
      // A plugin without a sign-in capability only reports its account.
      trailing: !plugin.info!.can(TrackingPluginCapability.login)
          ? null
          : FushiPressScale(
              child: signedIn
                  ? FushiTextButton.icon(
                      key: ValueKey<String>('tracking-plugin-sign-out-$id'),
                      onPressed: _busy
                          ? null
                          : () => unawaited(_signOut(plugin)),
                      icon: const FushiIcon(FushiIcons.logout),
                      label: Text(t.media_tracking_plugins_sign_out_action),
                    )
                  : FushiFilledButton.tonalIcon(
                      key: ValueKey<String>('tracking-plugin-sign-in-$id'),
                      onPressed: _busy
                          ? null
                          : () => unawaited(_signIn(plugin)),
                      icon: const FushiIcon(FushiIcons.login),
                      label: Text(t.media_tracking_plugins_sign_in_action),
                    ),
            ),
    );
  }

  Widget _actionsRow(InstalledTrackingPlugin plugin) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TrackingPluginInfo? info = plugin.info;
    final String? siteId = plugin.registered ? info?.site?.siteId : null;
    // The account's watched anime, for a signed-in site that lists entries
    // (`trackingList`): the bundled Bangumi plugin's former settings action.
    final bool canListWatched =
        siteId != null &&
        _manager.accountOf(plugin.id).loggedIn &&
        widget.service.canListWatchedAnime(siteId);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.gap),
      child: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: Wrap(
          spacing: tokens.spacing.gap,
          children: <Widget>[
            if (info != null)
              FushiPressScale(
                child: FushiTextButton.icon(
                  key: ValueKey<String>('tracking-plugin-details-${plugin.id}'),
                  onPressed: () => unawaited(
                    showTrackingPluginDetails(
                      context,
                      info: info,
                      builtIn: plugin.builtIn,
                    ),
                  ),
                  icon: const FushiIcon(FushiIcons.info),
                  label: Text(t.media_tracking_plugins_details_action),
                ),
              ),
            if (canListWatched)
              FushiPressScale(
                child: FushiTextButton.icon(
                  key: ValueKey<String>('tracking-plugin-watched-${plugin.id}'),
                  onPressed: () => unawaited(
                    showTrackingWatchedDialog(
                      context,
                      widget.service,
                      providerId: siteId,
                    ),
                  ),
                  icon: const FushiIcon(FushiIcons.visibility),
                  label: Text(t.media_tracking_watched_show),
                ),
              ),
            // Built in: turned off with the switch, never removed.
            if (!plugin.builtIn)
              FushiPressScale(
                child: FushiTextButton.icon(
                  key: ValueKey<String>('tracking-plugin-remove-${plugin.id}'),
                  onPressed: _busy ? null : () => unawaited(_remove(plugin)),
                  icon: const FushiIcon(FushiIcons.delete),
                  label: Text(t.media_tracking_plugins_remove_action),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<InstalledTrackingPlugin> plugins = _manager.installed;
    final List<Widget> rows = <Widget>[
      if (_loading)
        const FushiLinearProgressIndicator()
      else if (plugins.isEmpty)
        AdaptiveSettingsRow(
          key: const ValueKey<String>('tracking-plugins-empty'),
          title: t.media_tracking_plugins_empty_label,
        ),
      for (final InstalledTrackingPlugin plugin in plugins)
        ..._pluginRows(plugin),
      // About installing a file, so it sits with the install button, not
      // above the bundled Bangumi plugin (T1 F11 a).
      AdaptiveSettingsRow(
        key: const ValueKey<String>('tracking-plugins-install-hint'),
        title: t.media_tracking_plugins_intro_hint,
        titleMaxLines: 5,
        icon: FushiIcons.info,
        showIcon: true,
      ),
      AdaptiveSettingsRow(
        title: t.media_tracking_plugins_install_action,
        trailing: _busy
            ? const SizedBox.square(
                dimension: 22,
                child: FushiCircularProgressIndicator(strokeWidth: 2),
              )
            : FushiPressScale(
                child: FushiFilledButton.tonalIcon(
                  key: const ValueKey<String>('tracking-plugins-install'),
                  onPressed: () => unawaited(_install()),
                  icon: const FushiIcon(FushiIcons.importFile),
                  label: Text(t.media_tracking_plugins_install_action),
                ),
              ),
      ),
    ];
    return FushiEntranceScope(
      child: AdaptiveSettingsSection(
        title: t.media_tracking_plugins_title,
        children: <Widget>[
          for (int i = 0; i < rows.length; i++)
            _EntranceRow(index: i, child: rows[i]),
        ],
      ),
    );
  }
}

/// A settings row entering with the list stagger. Reports the row's leading
/// icon so the Apple grouped separators keep their inset.
class _EntranceRow extends StatelessWidget implements SettingsRowIconProbe {
  const _EntranceRow({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  bool get settingsRowHasIcon => settingsRowHasLeadingIcon(child);

  @override
  Widget build(BuildContext context) =>
      FushiStaggeredEntrance(index: index, child: child);
}
