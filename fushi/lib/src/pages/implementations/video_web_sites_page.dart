import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/video/web_video_sites.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart' show VideoBookRow;
import 'package:fushi_engine/media/video/video_book_repository.dart';

/// 视频库「在线源 › 网站」：预置的 Netflix / YouTube 加用户自己加的站点，外加一条随手输
/// 网址直接打开的地址栏。点入口在原生播放器页的网页档里打开站点（见 [WebVideoSite]）；
/// 站点本身不进媒体库，看过的每一集才进。
class VideoWebSitesPage extends ConsumerStatefulWidget {
  const VideoWebSitesPage({
    required this.repo,
    required this.navigation,
    super.key,
  });

  final VideoBookRepository repo;

  /// 库页壳交来的分段条，作为页头主位。
  final Widget navigation;

  @override
  ConsumerState<VideoWebSitesPage> createState() => _VideoWebSitesPageState();
}

class _VideoWebSitesPageState extends ConsumerState<VideoWebSitesPage> {
  final TextEditingController _address = TextEditingController();
  String? _addressError;

  AppModel get _appModel => ref.read(appProvider);

  List<WebVideoSite> get _userSites =>
      decodeWebVideoSites(_appModel.prefsRepo.getPref(kWebVideoSitesPrefKey));

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _saveUserSites(List<WebVideoSite> sites) async {
    await _appModel.prefsRepo.setPref(
      kWebVideoSitesPrefKey,
      encodeWebVideoSites(sites),
    );
    if (mounted) setState(() {});
  }

  void _open(WebVideoSite site) {
    final VideoBookRow row = webVideoSiteRow(site);
    unawaited(
      Navigator.of(context).push(
        adaptivePageRoute<void>(
          context: context,
          builder: (_) => VideoFushiPage.neutralized(
            bookUid: row.bookUid,
            repo: widget.repo,
            webSite: site,
          ),
        ),
      ),
    );
  }

  void _openAddress() {
    final String? url = normalizeWebVideoSiteInput(_address.text);
    if (url == null) {
      setState(() => _addressError = t.web_video_site_address_invalid);
      return;
    }
    setState(() => _addressError = null);
    _open(WebVideoSite(title: webVideoSiteDefaultTitle(url), url: url));
  }

  Future<void> _addSite() async {
    final TextEditingController url = TextEditingController(
      text: _address.text.trim(),
    );
    final TextEditingController name = TextEditingController();
    String? error;
    final WebVideoSite? site = await showDialog<WebVideoSite>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setDialogState) {
          void submit() {
            final String? normalized = normalizeWebVideoSiteInput(url.text);
            if (normalized == null) {
              setDialogState(() => error = t.web_video_site_address_invalid);
              return;
            }
            final String title = name.text.trim();
            Navigator.of(context).pop(
              WebVideoSite(
                title: title.isEmpty
                    ? webVideoSiteDefaultTitle(normalized)
                    : title,
                url: normalized,
              ),
            );
          }

          return AlertDialog(
            title: Text(t.web_video_site_add),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  key: const ValueKey<String>('video-web-site-add-url'),
                  controller: url,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: t.web_video_site_address_hint,
                    errorText: error,
                  ),
                  onSubmitted: (_) => submit(),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey<String>('video-web-site-add-name'),
                  controller: name,
                  decoration: InputDecoration(
                    labelText: t.web_video_site_name_hint,
                  ),
                  onSubmitted: (_) => submit(),
                ),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(t.cancel),
              ),
              FilledButton(
                onPressed: submit,
                child: Text(t.web_video_site_add),
              ),
            ],
          );
        },
      ),
    );
    url.dispose();
    name.dispose();
    if (site == null) return;
    await _saveUserSites(<WebVideoSite>[
      for (final WebVideoSite s in _userSites)
        if (s.url != site.url) s,
      site,
    ]);
  }

  Future<void> _removeSite(WebVideoSite site) => _saveUserSites(<WebVideoSite>[
    for (final WebVideoSite s in _userSites)
      if (s != site) s,
  ]);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<WebVideoSite> userSites = _userSites;
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          FushiPageHeader.customTitle(
            title: widget.navigation,
            actions: <Widget>[
              FushiIconButton(
                key: const ValueKey<String>('video-web-site-add'),
                icon: FushiIcons.add,
                tooltip: t.web_video_site_add,
                label: t.web_video_site_add,
                onTap: () => unawaited(_addSite()),
              ),
            ],
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: <Widget>[
                const FushiFloatingChromeInsetSpacer(),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        key: const ValueKey<String>('video-web-site-address'),
                        controller: _address,
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.go,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.public),
                          hintText: t.web_video_site_address_hint,
                          errorText: _addressError,
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                        onSubmitted: (_) => _openAddress(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const ValueKey<String>(
                        'video-web-site-address-open',
                      ),
                      onPressed: _openAddress,
                      child: Text(t.web_video_site_open),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  t.web_video_sites_hint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: <Widget>[
                    for (final WebVideoSite site in kWebVideoPresetSites)
                      _SiteCard(site: site, onOpen: () => _open(site)),
                    for (final WebVideoSite site in userSites)
                      _SiteCard(
                        site: site,
                        onOpen: () => _open(site),
                        onRemove: () => unawaited(_removeSite(site)),
                      ),
                    _AddSiteCard(onTap: () => unawaited(_addSite())),
                  ],
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

const double _kSiteCardWidth = 200;
const double _kSiteCardHeight = 96;

class _SiteCard extends StatelessWidget {
  const _SiteCard({required this.site, required this.onOpen, this.onRemove});

  final WebVideoSite site;
  final VoidCallback onOpen;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String host = webVideoSiteDefaultTitle(site.url);
    return SizedBox(
      width: _kSiteCardWidth,
      height: _kSiteCardHeight,
      child: Card(
        key: ValueKey<String>('video-web-site-${site.url}'),
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: <Widget>[
                CircleAvatar(
                  backgroundColor: theme.colorScheme.primaryContainer,
                  foregroundColor: theme.colorScheme.onPrimaryContainer,
                  child: Text(
                    site.title.isEmpty ? '?' : site.title.characters.first,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        site.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onRemove != null)
                  IconButton(
                    key: ValueKey<String>('video-web-site-remove-${site.url}'),
                    tooltip: t.web_video_site_remove,
                    icon: const Icon(Icons.close),
                    onPressed: onRemove,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AddSiteCard extends StatelessWidget {
  const _AddSiteCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      width: _kSiteCardWidth,
      height: _kSiteCardHeight,
      child: Card.outlined(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey<String>('video-web-site-add-card'),
          onTap: onTap,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.add, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  t.web_video_site_add,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
