import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/discovery/audiobookshelf_server_config.dart';
import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/audiobookshelf/audiobookshelf_library_view.dart';
import 'package:fushi/src/pages/implementations/audiobookshelf/audiobookshelf_ui_helpers.dart';
import 'package:fushi/src/pages/implementations/kavita/kavita_books_view.dart';
import 'package:fushi/src/pages/implementations/kavita/kavita_browse_page.dart'
    show KavitaLibrariesPage, usableKavitaServers;
import 'package:fushi/src/pages/implementations/media_server/media_server_server_list_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_widgets.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingChromeInset;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart';

/// 取 Audiobookshelf 服务器的共享协议层实例；未登录返回 null。
typedef AudiobookshelfApiFor =
    AudiobookshelfApi? Function(AudiobookshelfServerConfig server);

/// 「媒体服务器」页签所在的库页域。视频域的 Jellyfin / Emby / Plex 走
/// `MediaServerBrowsePage`，与这里共用同一个列表组件（[MediaServerGroupedList]）。
enum UserMediaServersDomain {
  /// 书：Kavita（书籍库）+ Audiobookshelf。
  book,

  /// 漫画：只有 Kavita（图片归档库）。
  manga,
}

/// [domain] 下用户配置了**可用**服务器（Kavita 有地址与 API key；Audiobookshelf
/// 已启用且已登录）才有「媒体服务器」页签：空壳页签只会让人困惑。
bool hasUserMediaServers(
  UserMediaServersDomain domain, {
  required List<KavitaServerConfig> kavita,
  required List<AudiobookshelfServerConfig> audiobookshelf,
}) =>
    usableKavitaServers(kavita).isNotEmpty ||
    (domain == UserMediaServersDomain.book &&
        audiobookshelfTabServers(audiobookshelf).isNotEmpty);

/// 库页壳订阅的「该域有没有媒体服务器」：设置里增删 / 登录登出服务器后
/// （`prefsRepo` 通知经 [AppModel] 转发）页签随之出现 / 消失。
final userMediaServersAvailableProvider =
    Provider.family<bool, UserMediaServersDomain>(
      (Ref ref, UserMediaServersDomain domain) => ref.watch(
        appProvider.select(
          (AppModel app) =>
              app.isPreferencesReady &&
              hasUserMediaServers(
                domain,
                kavita: app.prefsRepo.kavitaServers,
                audiobookshelf: app.prefsRepo.discoveryAudiobookshelfServers,
              ),
        ),
      ),
    );

/// [domain] 的服务器行。点行压入这台服务器的浏览页。
List<MediaServerListRowData> userMediaServerRows(
  BuildContext context,
  UserMediaServersDomain domain, {
  required List<KavitaServerConfig> kavita,
  required List<AudiobookshelfServerConfig> audiobookshelf,
  required AudiobookshelfApiFor apiFor,
}) => <MediaServerListRowData>[
  for (final KavitaServerConfig s in usableKavitaServers(kavita))
    MediaServerListRowData(
      id: 'kavita-${s.id}',
      name: s.displayName,
      url: s.serverUrl.toString(),
      kindLabel: t.kavita_source_name,
      icon: domain == UserMediaServersDomain.book
          ? FushiIcons.books
          : FushiIcons.manga,
      onTap: () => _push(
        context,
        domain == UserMediaServersDomain.book
            ? _ServerPage(
                title: s.displayName,
                body: KavitaBooksView(servers: <KavitaServerConfig>[s]),
              )
            : KavitaLibrariesPage(server: s),
      ),
    ),
  if (domain == UserMediaServersDomain.book)
    for (final AudiobookshelfServerConfig s in audiobookshelfTabServers(
      audiobookshelf,
    ))
      MediaServerListRowData(
        id: 'abs-${s.id}',
        name: s.displayName,
        url: s.serverUrl.toString(),
        kindLabel: t.library_view_audiobookshelf,
        icon: FushiIcons.server,
        onTap: () => _push(
          context,
          _ServerPage(
            title: s.displayName,
            body: AudiobookshelfLibraryView(
              servers: <AudiobookshelfServerConfig>[s],
              apiFor: apiFor,
            ),
          ),
        ),
      ),
];

void _push(BuildContext context, Widget page) {
  Navigator.of(
    context,
  ).push<void>(adaptivePageRoute<void>(context: context, builder: (_) => page));
}

/// 从「媒体服务器」页签点进的一台服务器：设计系统自适应的页面脚手架（返回键
/// 由脚手架按设计系统给），正文铺到页头底下、按页头让位加顶部内边距——与它在
/// 库页壳里时读同一个让位口 [FushiFloatingChromeInset]。
class _ServerPage extends StatelessWidget {
  const _ServerPage({required this.title, required this.body});

  final String title;
  final Widget body;

  @override
  Widget build(BuildContext context) => FushiPageScaffold(
    title: title,
    headerCompact: true,
    body: Builder(
      builder: (BuildContext context) => FushiFloatingChromeInset(
        top: MediaQuery.paddingOf(context).top,
        child: body,
      ),
    ),
  );
}

/// 书 / 漫画「媒体服务器」页签正文：与视频域同一个服务器列表组件。监听
/// `prefsRepo`，设置里增删服务器回来即刷新。
class UserMediaServersView extends ConsumerStatefulWidget {
  const UserMediaServersView({required this.domain, super.key});

  final UserMediaServersDomain domain;

  @override
  ConsumerState<UserMediaServersView> createState() =>
      _UserMediaServersViewState();
}

class _UserMediaServersViewState extends ConsumerState<UserMediaServersView> {
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

  void _openSettings() => openMediaServerSettings(context);

  @override
  Widget build(BuildContext context) {
    final List<MediaServerListRowData> rows = userMediaServerRows(
      context,
      widget.domain,
      kavita: _appModel.prefsRepo.kavitaServers,
      audiobookshelf: _appModel.prefsRepo.discoveryAudiobookshelfServers,
      apiFor: (AudiobookshelfServerConfig server) =>
          _appModel.audiobookshelfApis.apiFor(server),
    );
    return MediaServerBodyInset(
      builder: (BuildContext context, double top) => rows.isEmpty
          // 页签只在有服务器时出现；最后一台刚被删、页签还没随之消失的那一帧
          // 也给出去设置的入口，不画空白。
          ? MediaServerListEmpty(top: top, onOpenSettings: _openSettings)
          : MediaServerGroupedList(
              rows: rows,
              top: top,
              onOpenSettings: _openSettings,
            ),
    );
  }
}
