import 'package:flutter/material.dart';
import 'package:fushi/src/media/torrent/anime_download_config.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/pages/implementations/downloads_page.dart';
import 'package:fushi/src/pages/implementations/torrent_settings_section.dart';
import 'package:fushi/src/pages/implementations/video_external_provider_settings_section.dart';
import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_services.dart';
import 'package:fushi/utils.dart';

QbConnectionConfig _config(SettingsContext context) =>
    effectiveTorrentConfig(context.appModel.qbConnectionConfig);

bool _embedded(SettingsContext context) =>
    _config(context).resolveBackend(
      embeddedSupported: context.appModel.supportsEmbeddedTorrent,
    ) ==
    QbConnectionConfig.backendEmbedded;

SettingsBodySearchEntry _entry(
  String key,
  String title, {
  SettingsVisibility? visible,
}) => SettingsBodySearchEntry(
  id: 'downloads.$key',
  title: title,
  visible: visible,
  hasRevealTarget: true,
);

SettingsDestination _torrentPage(
  TorrentSettingsScope scope,
  String title,
  List<SettingsBodySearchEntry> entries,
) => SettingsDestination(
  id: SettingsDestinationId.downloads,
  title: title,
  icon: Icons.download_outlined,
  sections: const <SettingsSection>[],
  bodySearchEntries: entries,
  body: (_) => AdaptiveSettingsSection(
    children: <Widget>[TorrentSettingsSection(scope: scope)],
  ),
);

/// Common download controls stay visible; detailed backend configuration has
/// one reusable page, shared with the download center's settings component.
SettingsDestination buildDownloadsDestination() => SettingsDestination(
  id: SettingsDestinationId.downloads,
  visible: (SettingsContext context) => isSettingsDestinationVisible(
    SettingsDestinationId.downloads,
    context.appModel.moduleVisibility,
  ),
  title: t.nav_downloads,
  summary: t.download_settings,
  icon: Icons.download_outlined,
  bodySearchEntries: <SettingsBodySearchEntry>[
    _entry(
      'backend',
      t.download_settings,
      visible: (SettingsContext c) => c.appModel.supportsEmbeddedTorrent,
    ),
    _entry('save_root', t.download_save_root_title, visible: _embedded),
    _entry(
      'video_setting_torrent_download_limit',
      t.video_setting_torrent_download_limit,
      visible: _embedded,
    ),
    _entry(
      'video_setting_torrent_limit_lan',
      t.video_setting_torrent_limit_lan,
      visible: _embedded,
    ),
    _entry(
      'video_setting_torrent_upload_enabled',
      t.video_setting_torrent_upload_enabled,
      visible: _embedded,
    ),
    _entry(
      'video_setting_torrent_upload_limit',
      t.video_setting_torrent_upload_limit,
      visible: (SettingsContext c) => _embedded(c) && _config(c).uploadEnabled,
    ),
    _entry(
      'video_setting_torrent_seed_time_limit',
      t.video_setting_torrent_seed_time_limit,
      visible: (SettingsContext c) => _embedded(c) && _config(c).uploadEnabled,
    ),
    _entry(
      'video_setting_torrent_seed_ratio_limit',
      t.video_setting_torrent_seed_ratio_limit,
      visible: (SettingsContext c) => _embedded(c) && _config(c).uploadEnabled,
    ),
  ],
  sections: <SettingsSection>[
    SettingsSection(
      id: 'downloads.common',
      items: <SettingsItem>[
        SettingsCustomItem(
          id: 'downloads.common_controls',
          builder: (_) =>
              const TorrentSettingsSection(scope: TorrentSettingsScope.common),
        ),
      ],
    ),
    SettingsSection(
      id: 'downloads.configuration',
      items: <SettingsItem>[
        SettingsNavigationItem(
          id: 'downloads.connection',
          title: t.video_setting_torrent_backend_qb,
          icon: Icons.link,
          visible: (SettingsContext c) => !_embedded(c),
          subtitleBuilder: (SettingsContext c) => _config(c).baseUrl.isEmpty
              ? t.video_setting_qb_url
              : _config(c).baseUrl,
          child: () => _torrentPage(
            TorrentSettingsScope.connection,
            t.video_setting_torrent_backend_qb,
            <SettingsBodySearchEntry>[
              _entry(
                'video_setting_qb_url',
                t.video_setting_qb_url,
                visible: (SettingsContext c) => !_embedded(c),
              ),
              _entry(
                'video_setting_qb_username',
                t.video_setting_qb_username,
                visible: (SettingsContext c) => !_embedded(c),
              ),
              _entry(
                'video_setting_qb_password',
                t.video_setting_qb_password,
                visible: (SettingsContext c) => !_embedded(c),
              ),
            ],
          ),
        ),
        SettingsNavigationItem(
          id: 'downloads.trackers',
          title: t.download_tracker_section,
          subtitle: t.download_tracker_auto_add_hint,
          icon: Icons.hub_outlined,
          child: () => _torrentPage(
            TorrentSettingsScope.trackers,
            t.download_tracker_section,
            <SettingsBodySearchEntry>[
              _entry('download_tracker_auto_add', t.download_tracker_auto_add),
              _entry('download_tracker_url', t.download_tracker_url),
            ],
          ),
        ),
        SettingsNavigationItem(
          id: 'downloads.advanced',
          title: t.settings_downloads_advanced_title,
          subtitle: t.settings_downloads_advanced_hint,
          icon: Icons.tune,
          child: () => _torrentPage(
            TorrentSettingsScope.advanced,
            t.settings_downloads_advanced_title,
            <SettingsBodySearchEntry>[
              _entry('video_setting_qb_category', t.video_setting_qb_category),
              _entry(
                'video_setting_torrent_max_connections',
                t.video_setting_torrent_max_connections,
                visible: _embedded,
              ),
              _entry(
                'video_setting_torrent_memory_limit',
                t.video_setting_torrent_memory_limit,
                visible: _embedded,
              ),
              _entry(
                'video_setting_torrent_listen_port',
                t.video_setting_torrent_listen_port,
                visible: _embedded,
              ),
              _entry(
                'video_setting_torrent_dht',
                t.video_setting_torrent_dht,
                visible: _embedded,
              ),
              _entry(
                'video_setting_torrent_lsd',
                t.video_setting_torrent_lsd,
                visible: _embedded,
              ),
              _entry(
                'video_setting_torrent_upnp',
                t.video_setting_torrent_upnp,
                visible: _embedded,
              ),
              _entry(
                'video_setting_torrent_natpmp',
                t.video_setting_torrent_natpmp,
                visible: _embedded,
              ),
              _entry(
                'video_setting_torrent_anonymous',
                t.video_setting_torrent_anonymous,
                visible: _embedded,
              ),
              _entry(
                'video_setting_torrent_active_downloads',
                t.video_setting_torrent_active_downloads,
                visible: _embedded,
              ),
              _entry(
                'video_setting_torrent_active_seeds',
                t.video_setting_torrent_active_seeds,
                visible: _embedded,
              ),
              _entry(
                'video_setting_torrent_upload_slots',
                t.video_setting_torrent_upload_slots,
                visible: _embedded,
              ),
              _entry(
                'video_setting_torrent_antileech',
                t.video_setting_torrent_antileech,
                visible: _embedded,
              ),
              _entry(
                'video_setting_torrent_ban_progress_cheat',
                t.video_setting_torrent_ban_progress_cheat,
                visible: (SettingsContext c) =>
                    _embedded(c) && _config(c).antiLeechEnabled,
              ),
              _entry(
                'video_setting_torrent_ban_relative_cheat',
                t.video_setting_torrent_ban_relative_cheat,
                visible: (SettingsContext c) =>
                    _embedded(c) && _config(c).antiLeechEnabled,
              ),
              _entry(
                'video_setting_torrent_max_ip_ports',
                t.video_setting_torrent_max_ip_ports,
                visible: (SettingsContext c) =>
                    _embedded(c) && _config(c).antiLeechEnabled,
              ),
              _entry(
                'video_setting_torrent_ban_time',
                t.video_setting_torrent_ban_time,
                visible: (SettingsContext c) =>
                    _embedded(c) && _config(c).antiLeechEnabled,
              ),
              _entry(
                'encryption',
                t.settings_downloads_encryption_title,
                visible: _embedded,
              ),
            ],
          ),
        ),
        SettingsNavigationItem(
          id: 'downloads.routing',
          title: t.settings_downloads_routing_title,
          subtitle: t.settings_downloads_routing_hint,
          icon: Icons.drive_file_move_outline,
          child: () => SettingsDestination(
            id: SettingsDestinationId.downloads,
            title: t.settings_downloads_routing_title,
            icon: Icons.drive_file_move_outline,
            sections: const <SettingsSection>[],
            bodySearchEntries: <SettingsBodySearchEntry>[
              _entry('path_mappings', t.video_download_path_mappings_title),
              _entry('target_source', t.video_download_target_source_title),
            ],
            body: (_) => const AdaptiveSettingsSection(
              children: <Widget>[
                VideoExternalProviderSettingsSection(
                  scope: VideoExternalProviderScope.downloadRouting,
                ),
              ],
            ),
          ),
        ),
      ],
    ),
    SettingsSection(
      id: 'downloads.links',
      items: <SettingsItem>[
        SettingsNavigationItem(
          id: 'downloads.open_page',
          title: t.nav_downloads,
          subtitle: t.settings_downloads_open_page_hint,
          icon: Icons.download_outlined,
          showIcon: true,
          onTap: (SettingsContext context) =>
              pushSettingsPage(context, (_) => const DownloadsPage()),
        ),
        buildOpenServicesItem('downloads.online_services'),
      ],
    ),
  ],
);
