import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/game_stream_session_opener.dart';
import 'package:fushi/src/pages/implementations/game_stream_settings_sheet.dart';
import 'package:fushi/src/pages/implementations/module_settings_view.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart'
    show formatActivityRelativeTime;
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/galgame_poster_card.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

/// 一台已配对主机上一个可用的串流客户端（已绑定到能连通的那个地址）。
class GameStreamHostConnection {
  const GameStreamHostConnection({required this.peer, required this.client});

  final FushiClientUrl peer;
  final FushiGameStreamClient client;
}

/// 加入 [session] 并展示串流页，直到用户离开。生产实现是
/// [openGameStreamSession]；测试注入桩以免拉起 WebRTC 接收端。
typedef GameStreamSessionOpener =
    Future<void> Function(
      BuildContext context,
      GameStreamHostConnection host,
      GameStreamSession session,
      GameStreamVideoSettings settings,
    );

/// [GameStreamLibraryPage] 的全部外部依赖。
///
/// 页面本身不读 Riverpod：首页 tab 在生产里用 [GameStreamLibraryServices.interconnect]
/// 装配，widget 测试直接注入假传输层，不必挂 `ProviderScope` / 数据库。
class GameStreamLibraryServices {
  const GameStreamLibraryServices({
    required this.loadPeers,
    required this.createClient,
    required this.openSession,
    required this.readSettings,
    required this.writeSettings,
    this.openInterconnectSettings,
    this.clientId,
    this.launchPollInterval = const Duration(milliseconds: 700),
    this.launchTimeout = const Duration(seconds: 120),
  });

  /// 生产装配：已启用的配对地址、互联钉扎传输、偏好里的串流参数。
  factory GameStreamLibraryServices.interconnect({required AppModel appModel}) {
    final SyncRepository repository = SyncRepository(appModel.database);
    final PreferencesRepository prefs = appModel.prefsRepo;
    return GameStreamLibraryServices(
      loadPeers: () async => <FushiClientUrl>[
        for (final FushiClientUrl peer in await repository.getFushiClientUrls())
          if (peer.enabled) peer,
      ],
      createClient: (FushiClientUrl peer) => FushiGameStreamClient(
        transport: InterconnectGameStreamTransport(repo: repository),
      )..bindPeer(peer),
      openSession:
          (
            BuildContext context,
            GameStreamHostConnection host,
            GameStreamSession session,
            GameStreamVideoSettings settings,
          ) => openGameStreamSession(
            context: context,
            repository: repository,
            client: host.client,
            peer: host.peer,
            session: session,
            settings: settings,
            onSettingsChanged: (GameStreamVideoSettings next) =>
                unawaited(prefs.setGameStreamVideoSettings(next)),
          ),
      readSettings: () => prefs.gameStreamVideoSettings,
      writeSettings: prefs.setGameStreamVideoSettings,
      openInterconnectSettings: _pushInterconnectSettings,
    );
  }

  final Future<List<FushiClientUrl>> Function() loadPeers;

  /// 为 [FushiClientUrl] 建一个只打这一个地址的客户端。
  final FushiGameStreamClient Function(FushiClientUrl peer) createClient;
  final GameStreamSessionOpener openSession;
  final GameStreamVideoSettings Function() readSettings;
  final Future<void> Function(GameStreamVideoSettings settings) writeSettings;

  /// 空态「去配对」入口；null 时不出按钮。
  final Future<void> Function(BuildContext context)? openInterconnectSettings;

  /// 接收端 id；null 用进程级 [gameStreamReceiverClientId]。
  final String? clientId;
  final Duration launchPollInterval;
  final Duration launchTimeout;

  static Future<void> _pushInterconnectSettings(BuildContext context) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => Scaffold(
          body: SafeArea(
            child: ModuleSettingsView(
              destinationId: SettingsDestinationId.interconnect,
              navigation: Row(
                children: <Widget>[
                  FushiIconButton(
                    icon: Icons.arrow_back,
                    tooltip: t.back,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      t.settings_destination_interconnect,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Android 的「游戏」tab：串流接收端的远端游戏库（Moonlight 式应用网格）。
///
/// 与 Windows 的本机 galgame 库（`HomeGamePage`）共用同一个模块开关与同一张
/// 海报卡（[GalgamePosterCard]），但排版为串流服务：主机页头带连接状态、
/// 「正在串流」行可直接加入，点游戏 = 让主机启动并直接开始串流。
class GameStreamLibraryPage extends StatefulWidget {
  const GameStreamLibraryPage({required this.services, super.key});

  final GameStreamLibraryServices services;

  static const Key interconnectButtonKey = ValueKey<String>(
    'game-stream-open-interconnect',
  );
  static const Key refreshKey = ValueKey<String>('game-stream-refresh');
  static const Key settingsKey = ValueKey<String>('game-stream-settings');

  static Key gameCardKey(String gameId) =>
      ValueKey<String>('game-stream-card-$gameId');

  static Key sessionKey(String sessionId) =>
      ValueKey<String>('game-stream-session-$sessionId');

  @override
  State<GameStreamLibraryPage> createState() => _GameStreamLibraryPageState();
}

enum _HostPhase { loading, ready, outdated, unreachable, rejected }

class _StreamHost {
  _StreamHost({required this.key, required this.peers}) : peer = peers.first;

  /// 同一台主机的多个地址（备用地址）按证书指纹 / 设备名归并成一台。
  final String key;
  final List<FushiClientUrl> peers;

  FushiClientUrl peer;
  FushiGameStreamClient? client;
  _HostPhase phase = _HostPhase.loading;
  GameStreamLibrary? library;
  List<GameStreamSession> sessions = const <GameStreamSession>[];

  String get name {
    final String? device = peer.deviceName;
    if (device != null && device.trim().isNotEmpty) return device;
    return Uri.tryParse(peer.url)?.host ?? peer.url;
  }

  GameStreamHostConnection? get connection {
    final FushiGameStreamClient? active = client;
    if (active == null) return null;
    return GameStreamHostConnection(peer: peer, client: active);
  }
}

/// 封面字节的进程内缓存：切 tab / 刷新都不重复拉取。按插入序淘汰。
final LinkedHashMap<String, Future<Uint8List?>> _coverCache =
    LinkedHashMap<String, Future<Uint8List?>>();
const int _coverCacheCapacity = 256;

class _GameStreamLibraryPageState extends State<GameStreamLibraryPage> {
  List<_StreamHost> _hosts = const <_StreamHost>[];
  bool _loadingPeers = true;
  bool _busy = false;
  String? _selectedKey;
  String? _notice;
  int _generation = 0;

  GameStreamLibraryServices get _services => widget.services;
  String get _clientId => _services.clientId ?? gameStreamReceiverClientId;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final int generation = ++_generation;
    setState(() {
      _loadingPeers = true;
      _notice = null;
    });
    List<FushiClientUrl> peers;
    try {
      peers = await _services.loadPeers();
    } catch (_) {
      peers = const <FushiClientUrl>[];
    }
    if (!mounted || generation != _generation) return;
    final Map<String, List<FushiClientUrl>> grouped =
        <String, List<FushiClientUrl>>{};
    for (final FushiClientUrl peer in peers) {
      final String key =
          _nonEmpty(peer.fingerprintSha256) ??
          _nonEmpty(peer.deviceName) ??
          peer.url;
      grouped.putIfAbsent(key, () => <FushiClientUrl>[]).add(peer);
    }
    final List<_StreamHost> hosts = <_StreamHost>[
      for (final MapEntry<String, List<FushiClientUrl>> entry
          in grouped.entries)
        _StreamHost(key: entry.key, peers: entry.value),
    ];
    setState(() {
      _hosts = hosts;
      _loadingPeers = false;
      if (!hosts.any((_StreamHost h) => h.key == _selectedKey)) {
        _selectedKey = hosts.isEmpty ? null : hosts.first.key;
      }
    });
    await Future.wait(<Future<void>>[
      for (final _StreamHost host in hosts) _loadHost(host, generation),
    ]);
  }

  static String? _nonEmpty(String? value) =>
      value == null || value.trim().isEmpty ? null : value;

  Future<void> _loadHost(_StreamHost host, int generation) async {
    _HostPhase phase = _HostPhase.unreachable;
    for (final FushiClientUrl peer in host.peers) {
      final FushiGameStreamClient client = _services.createClient(peer);
      List<GameStreamSession> sessions;
      try {
        sessions = await client.listSessions(clientId: _clientId);
      } on GameStreamUnreachableError {
        continue;
      } on GameStreamRequestError catch (error) {
        host
          ..peer = peer
          ..client = client;
        phase = error.code == 'http_rejected'
            ? _HostPhase.outdated
            : _HostPhase.rejected;
        break;
      } catch (_) {
        host
          ..peer = peer
          ..client = client;
        phase = _HostPhase.rejected;
        break;
      }
      host
        ..peer = peer
        ..client = client
        ..sessions = _joinable(sessions);
      try {
        host.library = await client.listLibrary();
        phase = _HostPhase.ready;
      } on GameStreamUnreachableError {
        phase = _HostPhase.unreachable;
      } on GameStreamRequestError catch (error) {
        // 旧主机没有游戏库路由：404 → http_rejected。已有的串流会话仍可加入。
        phase = error.code == 'http_rejected'
            ? _HostPhase.outdated
            : _HostPhase.rejected;
      } catch (_) {
        phase = _HostPhase.rejected;
      }
      break;
    }
    if (!mounted || generation != _generation) return;
    setState(() => host.phase = phase);
  }

  static List<GameStreamSession> _joinable(List<GameStreamSession> sessions) =>
      <GameStreamSession>[
        for (final GameStreamSession session in sessions)
          if (session.state == GameStreamSessionState.waiting ||
              session.state == GameStreamSessionState.connecting)
            session,
      ];

  _StreamHost? get _selectedHost {
    for (final _StreamHost host in _hosts) {
      if (host.key == _selectedKey) return host;
    }
    return _hosts.isEmpty ? null : _hosts.first;
  }

  Future<void> _refreshHost(_StreamHost host) async {
    setState(() => host.phase = _HostPhase.loading);
    await _loadHost(host, _generation);
  }

  Future<void> _openSettings() async {
    final GameStreamVideoSettings? next = await showGameStreamSettingsSheet(
      context,
      initial: _services.readSettings(),
    );
    if (next == null) return;
    await _services.writeSettings(next);
  }

  Future<void> _openInterconnect() async {
    final Future<void> Function(BuildContext)? open =
        _services.openInterconnectSettings;
    if (open == null) return;
    await open(context);
    if (mounted) await _reload();
  }

  Future<void> _join(_StreamHost host, GameStreamSession session) async {
    final GameStreamHostConnection? connection = host.connection;
    if (_busy || connection == null) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await _services.openSession(
        context,
        connection,
        session,
        _services.readSettings(),
      );
    } on GameStreamLeaveError {
      if (mounted) setState(() => _notice = t.game_stream_leave_failed);
    } catch (_) {
      if (mounted) setState(() => _notice = t.game_stream_join_failed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) await _refreshHost(host);
  }

  Future<void> _activateGame(
    _StreamHost host,
    GameStreamLibraryGame game,
  ) async {
    final GameStreamHostConnection? connection = host.connection;
    if (_busy || connection == null) return;
    // 这款游戏已经在串流（电脑上开着、等人加入）：直接加入，不再让主机重启一次。
    for (final GameStreamSession session in host.sessions) {
      if (session.gameId == game.id) return _join(host, session);
    }
    final GameStreamVideoSettings settings = _services.readSettings();
    setState(() {
      _busy = true;
      _notice = null;
    });
    GameStreamSession? session;
    try {
      session = await showDialog<GameStreamSession>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) => _GameStreamLaunchDialog(
          client: connection.client,
          game: game,
          hostName: host.name,
          clientId: _clientId,
          settings: settings,
          pollInterval: _services.launchPollInterval,
          timeout: _services.launchTimeout,
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (session == null) {
      // 取消 / 失败：失败文案已在对话框里展示过，这里只刷新运行态。
      await _refreshHost(host);
      return;
    }
    await _join(host, session);
  }

  @override
  Widget build(BuildContext context) {
    final bool loading = _loadingPeers;
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiPageHeader(
            title: t.nav_game,
            subtitle: t.game_stream_library_subtitle,
            actions: <Widget>[
              FushiIconButton(
                key: GameStreamLibraryPage.refreshKey,
                icon: Icons.refresh,
                tooltip: t.refresh,
                onTap: loading || _busy ? null : () => unawaited(_reload()),
              ),
              FushiIconButton(
                key: GameStreamLibraryPage.settingsKey,
                icon: Icons.tune,
                tooltip: t.game_stream_settings_title,
                onTap: _busy ? null : () => unawaited(_openSettings()),
              ),
            ],
          ),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : _buildBody(context),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final _StreamHost? host = _selectedHost;
    if (host == null) return _buildNoHosts(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double page = tokens.spacing.page;
    final List<GameStreamLibraryGame> games =
        host.library?.games ?? const <GameStreamLibraryGame>[];
    return CustomScrollView(
      slivers: <Widget>[
        SliverPadding(
          padding: EdgeInsets.fromLTRB(page, 0, page, tokens.spacing.gap),
          sliver: SliverList.list(
            children: <Widget>[
              if (_hosts.length > 1) _buildHostSwitcher(tokens),
              _buildHostHeader(context, host),
              if (_notice != null) _buildNotice(context, _notice!),
              if (host.sessions.isNotEmpty) ..._buildSessions(context, host),
              if (host.phase == _HostPhase.ready && games.isNotEmpty)
                _sectionLabel(context, t.game_library),
            ],
          ),
        ),
        if (host.phase == _HostPhase.ready && games.isEmpty)
          SliverToBoxAdapter(
            child: _buildMessage(context, t.game_stream_library_empty),
          ),
        if (host.phase == _HostPhase.ready && games.isNotEmpty)
          SliverPadding(
            padding: withBottomSafeInset(
              context,
              EdgeInsets.fromLTRB(page, 0, page, tokens.spacing.section),
            ),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 200,
                mainAxisSpacing: 20,
                crossAxisSpacing: 16,
                childAspectRatio: 0.6,
              ),
              itemCount: games.length,
              itemBuilder: (BuildContext context, int index) =>
                  _buildGameCard(context, host, games[index]),
            ),
          ),
      ],
    );
  }

  Widget _buildNoHosts(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.cast_connected_outlined,
              size: 48,
              color: FushiDesignTokens.of(context).surfaces.onVariant,
            ),
            const SizedBox(height: 16),
            Text(t.game_stream_no_hosts, textAlign: TextAlign.center),
            if (_services.openInterconnectSettings != null) ...<Widget>[
              const SizedBox(height: 16),
              FilledButton.icon(
                key: GameStreamLibraryPage.interconnectButtonKey,
                autofocus: true,
                onPressed: () => unawaited(_openInterconnect()),
                icon: const Icon(Icons.devices_outlined),
                label: Text(t.game_stream_open_interconnect),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHostSwitcher(FushiDesignTokens tokens) {
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap),
      child: Wrap(
        spacing: tokens.spacing.gap,
        runSpacing: tokens.spacing.gap,
        children: <Widget>[
          for (final _StreamHost host in _hosts)
            FushiSelectableChip(
              label: host.name,
              leadingIcon: _phaseIcon(host.phase),
              selected: host.key == _selectedHost?.key,
              focusId: FushiFocusId('game-stream-host-${host.key}'),
              onSelected: (bool _) => setState(() => _selectedKey = host.key),
            ),
        ],
      ),
    );
  }

  static IconData _phaseIcon(_HostPhase phase) => switch (phase) {
    _HostPhase.loading => Icons.more_horiz,
    _HostPhase.ready => Icons.computer,
    _HostPhase.outdated => Icons.system_update_alt,
    _HostPhase.unreachable => Icons.cloud_off_outlined,
    _HostPhase.rejected => Icons.block,
  };

  String _phaseLabel(_StreamHost host) => switch (host.phase) {
    _HostPhase.loading => t.game_stream_host_connecting,
    _HostPhase.ready => t.game_stream_host_online(
      n: host.library?.games.length ?? 0,
    ),
    _HostPhase.outdated => t.game_stream_host_outdated,
    _HostPhase.unreachable => t.game_stream_unreachable,
    _HostPhase.rejected => t.game_stream_host_rejected,
  };

  Widget _buildHostHeader(BuildContext context, _StreamHost host) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool online = host.phase == _HostPhase.ready;
    final bool launchOff = online && host.library?.launchEnabled == false;
    final Color accent = online
        ? theme.colorScheme.primary
        : host.phase == _HostPhase.loading
        ? tokens.surfaces.onVariant
        : theme.colorScheme.error;
    return FushiCard(
      margin: EdgeInsets.only(bottom: tokens.spacing.gap),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.desktop_windows_outlined, color: accent, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      host.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: <Widget>[
                        Icon(_phaseIcon(host.phase), size: 14, color: accent),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            _phaseLabel(host),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: accent,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (host.phase == _HostPhase.loading)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (host.phase != _HostPhase.ready)
                TextButton(
                  onPressed: _busy ? null : () => unawaited(_refreshHost(host)),
                  child: Text(t.retry),
                ),
            ],
          ),
          if (launchOff) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              t.game_stream_host_launch_off,
              style: theme.textTheme.bodySmall?.copyWith(
                color: tokens.surfaces.onVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNotice(BuildContext context, String message) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        message,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String label) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 12),
      child: Text(label, style: tokens.type.sectionLabel),
    );
  }

  List<Widget> _buildSessions(BuildContext context, _StreamHost host) {
    return <Widget>[
      _sectionLabel(context, t.game_stream_active_sessions),
      for (final GameStreamSession session in host.sessions)
        FushiCard(
          key: GameStreamLibraryPage.sessionKey(session.sessionId),
          margin: const EdgeInsets.only(bottom: 8),
          padding: EdgeInsets.zero,
          child: FushiListItem(
            focusId: FushiFocusId('game-stream-session-${session.sessionId}'),
            leading: const Icon(Icons.cast),
            title: Text(session.gameTitle ?? t.game_stream_available),
            subtitle: Text(host.name),
            trailing: FilledButton(
              onPressed: _busy ? null : () => unawaited(_join(host, session)),
              child: Text(t.game_stream_join_action),
            ),
            onTap: _busy ? null : () => unawaited(_join(host, session)),
          ),
        ),
    ];
  }

  Widget _buildMessage(BuildContext context, String message) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: FushiDesignTokens.of(context).surfaces.onVariant,
        ),
      ),
    );
  }

  Widget _buildGameCard(
    BuildContext context,
    _StreamHost host,
    GameStreamLibraryGame game,
  ) {
    final int? lastPlayedAt = game.lastPlayedAt;
    final String? overlay = lastPlayedAt == null
        ? null
        : t.game_stream_last_played(
            time: formatActivityRelativeTime(lastPlayedAt, DateTime.now()),
          );
    return GalgamePosterCard(
      key: GameStreamLibraryPage.gameCardKey(game.id),
      focusId: FushiFocusId('game-stream-card-${host.key}-${game.id}'),
      cover: _GameStreamCover(
        cacheKey: '${host.key}|${game.id}',
        hasCover: game.hasCover,
        load: () => host.client!.libraryCover(game.id),
      ),
      title: game.title,
      overlayText: overlay,
      trailing: game.running ? const _RunningBadge() : null,
      semanticLabel: game.running
          ? '${game.title} · ${t.game_stream_running}'
          : game.title,
      onTap: _busy ? null : () => unawaited(_activateGame(host, game)),
    );
  }
}

class _RunningBadge extends StatelessWidget {
  const _RunningBadge();

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.primary,
        borderRadius: FushiBorderRadius.chip,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.play_arrow, size: 14, color: colors.onPrimary),
            const SizedBox(width: 2),
            Text(
              t.game_stream_running,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: colors.onPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

class _GameStreamCover extends StatelessWidget {
  const _GameStreamCover({
    required this.cacheKey,
    required this.hasCover,
    required this.load,
  });

  final String cacheKey;
  final bool hasCover;
  final Future<GameStreamLibraryCover?> Function() load;

  Future<Uint8List?> _bytes() {
    final Future<Uint8List?>? cached = _coverCache[cacheKey];
    if (cached != null) return cached;
    final Future<Uint8List?> next = load()
        .then((GameStreamLibraryCover? cover) => cover?.bytes)
        .catchError((Object _) => null);
    _coverCache[cacheKey] = next;
    while (_coverCache.length > _coverCacheCapacity) {
      _coverCache.remove(_coverCache.keys.first);
    }
    return next;
  }

  @override
  Widget build(BuildContext context) {
    const Widget placeholder = ShelfCoverPlaceholder(
      icon: Icons.sports_esports_outlined,
    );
    if (!hasCover) return placeholder;
    return FutureBuilder<Uint8List?>(
      future: _bytes(),
      builder: (BuildContext context, AsyncSnapshot<Uint8List?> snapshot) {
        final Uint8List? bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) return placeholder;
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          cacheWidth: 512,
          errorBuilder: (BuildContext context, Object error, StackTrace? _) =>
              placeholder,
        );
      },
    );
  }
}

/// 远程启动进度：请求启动 → 轮询状态 → 串流就绪后返回要加入的会话。
///
/// 失败时对话框原地换成失败文案（不关窗），取消 / 失败关窗都返回 null。
class _GameStreamLaunchDialog extends StatefulWidget {
  const _GameStreamLaunchDialog({
    required this.client,
    required this.game,
    required this.hostName,
    required this.clientId,
    required this.settings,
    required this.pollInterval,
    required this.timeout,
  });

  final FushiGameStreamClient client;
  final GameStreamLibraryGame game;
  final String hostName;
  final String clientId;
  final GameStreamVideoSettings settings;
  final Duration pollInterval;
  final Duration timeout;

  @override
  State<_GameStreamLaunchDialog> createState() =>
      _GameStreamLaunchDialogState();
}

class _GameStreamLaunchDialogState extends State<_GameStreamLaunchDialog> {
  GameStreamLaunchState _state = GameStreamLaunchState.starting;
  bool _connecting = false;
  String? _failure;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }

  Future<void> _run() async {
    try {
      GameStreamLaunchStatus status = await widget.client.launch(
        gameId: widget.game.id,
        clientId: widget.clientId,
        settings: widget.settings,
      );
      final int maxPolls = widget.pollInterval.inMicroseconds <= 0
          ? 1
          : (widget.timeout.inMicroseconds / widget.pollInterval.inMicroseconds)
                .ceil();
      int polls = 0;
      while (!status.state.isTerminal) {
        if (_closed) return;
        setState(() => _state = status.state);
        if (++polls > maxPolls) {
          return _fail(t.game_stream_launch_timeout);
        }
        await Future<void>.delayed(widget.pollInterval);
        if (_closed) return;
        status = await widget.client.launchStatus(status.launchId);
      }
      if (_closed) return;
      if (status.state == GameStreamLaunchState.failed) {
        return _fail(gameStreamLaunchFailureMessage(status.reason));
      }
      final String? sessionId = status.sessionId;
      if (sessionId == null) {
        return _fail(t.game_stream_launch_stream_failed);
      }
      setState(() {
        _state = GameStreamLaunchState.streaming;
        _connecting = true;
      });
      final GameStreamSession session = await _resolveSession(
        sessionId,
        status,
      );
      if (_closed || !mounted) return;
      Navigator.of(context).pop(session);
    } on GameStreamRequestError catch (error) {
      _fail(gameStreamLaunchFailureMessage(error.code));
    } on GameStreamUnreachableError {
      _fail(t.game_stream_unreachable);
    } catch (_) {
      _fail(t.game_stream_launch_failed);
    }
  }

  /// 主机给的会话带 features / settings；列不到时按状态回执造一个最小会话
  /// （不声明 videoSettings 特性，join 时不发参数，主机按自己的默认值）。
  Future<GameStreamSession> _resolveSession(
    String sessionId,
    GameStreamLaunchStatus status,
  ) async {
    try {
      final List<GameStreamSession> sessions = await widget.client.listSessions(
        clientId: widget.clientId,
      );
      for (final GameStreamSession session in sessions) {
        if (session.sessionId == sessionId) return session;
      }
    } on Object {
      // 回落到下面的最小会话；join 本身会给出真实的失败。
    }
    final DateTime now = DateTime.now();
    return GameStreamSession(
      sessionId: sessionId,
      createdAt: now,
      updatedAt: now,
      state: GameStreamSessionState.waiting,
      gameId: status.gameId,
      gameTitle: widget.game.title,
    );
  }

  void _fail(String message) {
    if (_closed || !mounted) return;
    setState(() => _failure = message);
  }

  String get _stepLabel {
    if (_connecting) return t.game_stream_launch_connecting;
    return switch (_state) {
      GameStreamLaunchState.starting => t.game_stream_launch_starting,
      GameStreamLaunchState.waitingWindow =>
        t.game_stream_launch_waiting_window,
      GameStreamLaunchState.streaming ||
      GameStreamLaunchState.failed => t.game_stream_launch_connecting,
    };
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? failure = _failure;
    return AlertDialog(
      title: Text(widget.game.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            widget.hostName,
            style: theme.textTheme.bodySmall?.copyWith(
              color: FushiDesignTokens.of(context).surfaces.onVariant,
            ),
          ),
          const SizedBox(height: 16),
          if (failure == null)
            Row(
              children: <Widget>[
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                const SizedBox(width: 16),
                Expanded(child: Text(_stepLabel)),
              ],
            )
          else
            Text(
              failure,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(failure == null ? t.cancel : t.dialog_ok),
        ),
      ],
    );
  }
}

/// 远程启动失败码 → 用户可读文案（[GameStreamLaunchFailure] + 传输层拒绝码）。
String gameStreamLaunchFailureMessage(String? code) => switch (code) {
  GameStreamLaunchFailure.disabled => t.game_stream_launch_disabled,
  GameStreamLaunchFailure.busy => t.game_stream_launch_busy,
  GameStreamLaunchFailure.exeMissing => t.game_stream_launch_exe_missing,
  GameStreamLaunchFailure.helperMissing => t.game_stream_launch_helper_missing,
  GameStreamLaunchFailure.windowMissing => t.game_stream_launch_window_missing,
  GameStreamLaunchFailure.streamFailed => t.game_stream_launch_stream_failed,
  GameStreamLaunchFailure.unknownGame => t.game_stream_launch_unknown_game,
  GameStreamLaunchFailure.superseded => t.game_stream_launch_superseded,
  'http_rejected' => t.game_stream_host_outdated,
  _ => t.game_stream_launch_failed,
};
