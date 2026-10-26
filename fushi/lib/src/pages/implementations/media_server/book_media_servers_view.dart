import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/discovery/audiobookshelf_server_config.dart';
import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/audiobookshelf/audiobookshelf_library_view.dart';
import 'package:fushi/src/pages/implementations/audiobookshelf/audiobookshelf_ui_helpers.dart';
import 'package:fushi/src/pages/implementations/kavita/kavita_books_view.dart';
import 'package:fushi/src/pages/implementations/kavita/kavita_browse_page.dart'
    show KavitaLibrariesPage, usableKavitaServers;
import 'package:fushi/src/pages/implementations/media_server/media_server_server_list_view.dart'
    show MediaServerAddRow;
import 'package:fushi/src/pages/implementations/media_server/media_server_widgets.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_services.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart';

/// 取 Audiobookshelf 服务器的共享协议层实例；未登录返回 null。
typedef AudiobookshelfApiFor =
    AudiobookshelfApi? Function(AudiobookshelfServerConfig server);

/// 「媒体服务器」页签里的一行：一台 Kavita / Audiobookshelf 服务器。
class MediaServerLinkEntry {
  const MediaServerLinkEntry({
    required this.id,
    required this.name,
    required this.url,
    required this.kindLabel,
    required this.icon,
    required this.onOpen,
  });

  final String id;
  final String name;
  final String url;

  /// 类型名（产品名不翻译）。
  final String kindLabel;
  final IconData icon;

  /// 点行：压入这台服务器的浏览页。
  final void Function(BuildContext context) onOpen;
}

/// 书：可用的 Kavita（书籍库）+ 已登录的 Audiobookshelf 服务器。
List<MediaServerLinkEntry> bookMediaServerEntries({
  required List<KavitaServerConfig> kavita,
  required List<AudiobookshelfServerConfig> audiobookshelf,
  required AudiobookshelfApiFor apiFor,
}) => <MediaServerLinkEntry>[
  for (final KavitaServerConfig s in usableKavitaServers(kavita))
    MediaServerLinkEntry(
      id: 'kavita-${s.id}',
      name: s.displayName,
      url: s.serverUrl.toString(),
      kindLabel: t.kavita_source_name,
      icon: FushiIcons.books,
      onOpen: (BuildContext context) => _push(
        context,
        Scaffold(
          body: KavitaBooksView(
            servers: <KavitaServerConfig>[s],
            navigation: Text(
              s.displayName,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            leading: _backButton(context),
          ),
        ),
      ),
    ),
  for (final AudiobookshelfServerConfig s in audiobookshelfTabServers(
    audiobookshelf,
  ))
    MediaServerLinkEntry(
      id: 'abs-${s.id}',
      name: s.displayName,
      url: s.serverUrl.toString(),
      kindLabel: t.library_view_audiobookshelf,
      icon: FushiIcons.server,
      onOpen: (BuildContext context) => _push(
        context,
        FushiPageScaffold(
          title: s.displayName,
          automaticallyImplyLeading: false,
          headerCompact: true,
          leading: _backButton(context),
          body: AudiobookshelfLibraryView(
            servers: <AudiobookshelfServerConfig>[s],
            apiFor: apiFor,
          ),
        ),
      ),
    ),
];

/// 漫画：只有 Kavita（图片归档库）。
List<MediaServerLinkEntry> mangaMediaServerEntries({
  required List<KavitaServerConfig> kavita,
}) => <MediaServerLinkEntry>[
  for (final KavitaServerConfig s in usableKavitaServers(kavita))
    MediaServerLinkEntry(
      id: 'kavita-${s.id}',
      name: s.displayName,
      url: s.serverUrl.toString(),
      kindLabel: t.kavita_source_name,
      icon: FushiIcons.manga,
      onOpen: (BuildContext context) =>
          _push(context, KavitaLibrariesPage(server: s)),
    ),
];

void _push(BuildContext context, Widget page) {
  Navigator.of(
    context,
  ).push<void>(adaptivePageRoute<void>(context: context, builder: (_) => page));
}

Widget _backButton(BuildContext context) => BackButton(
  key: const ValueKey<String>('media-servers-back'),
  onPressed: () => Navigator.of(context).maybePop(),
);

/// 打开「设置 › 服务」。
void openMediaServersSettings(BuildContext context) {
  Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(
      builder: (_) =>
          SettingsDetailPage(destination: buildServicesDestination()),
    ),
  );
}

/// 「媒体服务器」页签正文（书 / 漫画共用）：设置风格分组列表，一台一行，组下方
/// 「去设置添加服务器」。行错峰进场；空态 = 提示 + 去设置。
class MediaServersListView extends StatelessWidget {
  const MediaServersListView({
    required this.entries,
    this.onOpenSettings,
    super.key,
  });

  final List<MediaServerLinkEntry> entries;

  /// null = [openMediaServersSettings]。
  final void Function(BuildContext context)? onOpenSettings;

  void _settings(BuildContext context) =>
      (onOpenSettings ?? openMediaServersSettings)(context);

  @override
  Widget build(BuildContext context) {
    return MediaServerBodyInset(
      builder: (BuildContext context, double top) {
        if (entries.isEmpty) {
          return Padding(
            padding: EdgeInsets.only(top: top),
            child: FushiPlaceholderMessage(
              icon: FushiIcons.server,
              message: t.media_server_servers_empty_hint,
              action: FushiFilledButton.tonalIcon(
                key: const ValueKey<String>('media-servers-go-settings'),
                onPressed: () => _settings(context),
                icon: const FushiIcon(FushiIcons.settingsGear),
                label: Text(t.media_server_servers_go_settings),
              ),
            ),
          );
        }
        final FushiDesignTokens tokens = FushiDesignTokens.of(context);
        final int count = entries.length;
        return FushiEntranceScope(
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.page,
              top + tokens.spacing.gap,
              tokens.spacing.page,
              tokens.spacing.gap,
            ),
            children: <Widget>[
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (int i = 0; i < count; i++)
                        FushiStaggeredEntrance(
                          index: i,
                          child: _LinkRow(
                            key: ValueKey<String>(
                              'media-servers-row-${entries[i].id}',
                            ),
                            entry: entries[i],
                            index: i,
                            count: count,
                          ),
                        ),
                      SizedBox(height: tokens.spacing.section),
                      FushiStaggeredEntrance(
                        index: count,
                        child: FushiGroupedListItem(
                          key: const ValueKey<String>('media-servers-add'),
                          index: 0,
                          count: 1,
                          focusId: const FushiFocusId('media-servers-add'),
                          onTap: () => _settings(context),
                          child: const MediaServerAddRow(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.entry,
    required this.index,
    required this.count,
    super.key,
  });

  final MediaServerLinkEntry entry;
  final int index;
  final int count;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool apple = isGlassDesign(context);
    const double badge = 40;
    final double rowPad = tokens.spacing.rowHorizontal;
    final TextStyle secondary = tokens.type.metadata.copyWith(
      color: apple ? appleColorsOf(context).secondaryLabel : null,
    );
    return FushiPressScale(
      child: FushiGroupedListItem(
        index: index,
        count: count,
        separatorIndent: rowPad + badge + rowPad,
        focusId: FushiFocusId('media-servers-row-${entry.id}'),
        onTap: () => entry.onOpen(context),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: rowPad,
            vertical: tokens.spacing.rowVertical,
          ),
          child: Row(
            children: <Widget>[
              FushiListLeadingIcon(
                entry.icon,
                shape: FushiLeadingShape.square,
                size: badge,
                iconSize: 22,
              ),
              SizedBox(width: rowPad),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.type.listTitle,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: secondary,
                    ),
                    Text(entry.kindLabel, style: secondary),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              if (apple)
                const FushiAppleChevron()
              else
                FushiIcon(
                  FushiIcons.chevronRight,
                  color: tokens.surfaces.onVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 书域「媒体服务器」页签：监听 `prefsRepo`（设置里增删服务器回来即刷新）。
class BookMediaServersView extends ConsumerStatefulWidget {
  const BookMediaServersView({super.key});

  @override
  ConsumerState<BookMediaServersView> createState() =>
      _BookMediaServersViewState();
}

class _BookMediaServersViewState extends ConsumerState<BookMediaServersView> {
  late final AppModel _appModel = ref.read(appProvider);

  @override
  void initState() {
    super.initState();
    _appModel.prefsRepo.addListener(_onChanged);
  }

  @override
  void dispose() {
    _appModel.prefsRepo.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => MediaServersListView(
    entries: bookMediaServerEntries(
      kavita: _appModel.prefsRepo.kavitaServers,
      audiobookshelf: _appModel.prefsRepo.discoveryAudiobookshelfServers,
      apiFor: (AudiobookshelfServerConfig server) =>
          _appModel.audiobookshelfApis.apiFor(server),
    ),
  );
}

/// 漫画域「媒体服务器」页签（只有 Kavita）。
class MangaMediaServersView extends ConsumerStatefulWidget {
  const MangaMediaServersView({super.key});

  @override
  ConsumerState<MangaMediaServersView> createState() =>
      _MangaMediaServersViewState();
}

class _MangaMediaServersViewState extends ConsumerState<MangaMediaServersView> {
  late final AppModel _appModel = ref.read(appProvider);

  @override
  void initState() {
    super.initState();
    _appModel.prefsRepo.addListener(_onChanged);
  }

  @override
  void dispose() {
    _appModel.prefsRepo.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => MediaServersListView(
    entries: mangaMediaServerEntries(kavita: _appModel.prefsRepo.kavitaServers),
  );
}
