import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
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
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/cover_badge.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

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
      // 每台 host 一次：同一台机器的多条地址只取组内最先可达的那条。
      loadPeers: () async =>
          resolveInterconnectPeerConnections(<FushiClientUrl>[
            for (final FushiClientUrl peer
                in await repository.getFushiClientUrls())
              if (peer.enabled) peer,
          ]),
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
            child: ModuleSettingsView.route(
              destinationId: SettingsDestinationId.interconnect,
              title: t.settings_destination_interconnect,
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
  const GameStreamLibraryPage({
    required this.services,
    this.navigation,
    super.key,
  });

  final GameStreamLibraryServices services;

  /// Section tabs of the page that embeds this one (Windows games module).
  /// Null where this page is the whole games module.
  final Widget? navigation;

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

enum _HostPhase { loading, ready, unreachable, rejected }

class _StreamHost {
  _StreamHost({required this.key, required this.peers}) : peer = peers.first;

  /// 同一台主机的多个地址（备用地址）按证书指纹 / 设备名归并成一台。
  final String key;
  final List<FushiClientUrl> peers;

  FushiClientUrl peer;
  FushiGameStreamClient? client;
  _HostPhase phase = _HostPhase.loading;

  /// Host's reason code when [phase] is [_HostPhase.rejected]; null when the
  /// refusal carried none we understand.
  String? rejection;
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
    String? rejection;
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
        phase = _HostPhase.rejected;
        rejection = error.code;
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
        // 没有游戏库（旧主机 404 → http_rejected，或主机回 library_off）时
        // 已有的串流会话仍可加入。
        phase = _HostPhase.rejected;
        rejection = error.code;
      } catch (_) {
        phase = _HostPhase.rejected;
      }
      break;
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      host
        ..phase = phase
        ..rejection = rejection;
    });
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
      session = await showAppDialog<GameStreamSession>(
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
    final FushiMotionScheme motion = context.fushiMotion;
    final List<Widget> actions = <Widget>[
      FushiIconButton(
        key: GameStreamLibraryPage.refreshKey,
        icon: FushiIcons.refresh,
        tooltip: t.refresh,
        onTap: loading || _busy ? null : () => unawaited(_reload()),
      ),
      FushiIconButton(
        key: GameStreamLibraryPage.settingsKey,
        icon: FushiIcons.settings,
        tooltip: t.game_stream_settings_title,
        onTap: _busy ? null : () => unawaited(_openSettings()),
      ),
    ];
    final Widget? navigation = widget.navigation;
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (navigation == null)
            FushiPageHeader(
              title: t.nav_game,
              subtitle: t.game_stream_library_subtitle,
              actions: actions,
            )
          else
            FushiPageHeader.customTitle(title: navigation, actions: actions),
          Expanded(
            // 骨架 → 内容交叉淡入（effects 弹簧，不过冲；减弱动态效果下瞬切）。
            child: AnimatedSwitcher(
              duration: motion.effectsDefault.duration,
              switchInCurve: motion.effectsDefault.curve,
              switchOutCurve: motion.effectsDefault.curve,
              child: loading
                  ? KeyedSubtree(
                      key: const ValueKey<String>('game-stream-skeleton'),
                      child: _buildLoadingSkeleton(context),
                    )
                  : KeyedSubtree(
                      key: const ValueKey<String>('game-stream-body'),
                      child: _buildBody(context),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// 网格列宽：窄屏（手机竖屏）两到三列海报，宽屏放大海报而不是挤出很多列。
  static double _gridExtent(double width) => width >= 840 ? 220 : 180;

  SliverGridDelegate _gridDelegate(double width) {
    final bool wide = width >= 600;
    return SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: _gridExtent(width),
      mainAxisSpacing: wide ? 24 : 16,
      crossAxisSpacing: wide ? 20 : 12,
      childAspectRatio: 0.6,
    );
  }

  /// 首次加载主机列表时的骨架：与最终版面同轮廓（状态 hero + 海报网格），
  /// 共享一层有界闪光。
  Widget _buildLoadingSkeleton(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double page = tokens.spacing.page;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return FushiSkeletonShimmer(
          child: CustomScrollView(
            physics: const NeverScrollableScrollPhysics(),
            slivers: <Widget>[
              SliverPadding(
                padding: EdgeInsets.fromLTRB(page, 0, page, tokens.spacing.gap),
                sliver: const SliverToBoxAdapter(
                  child: FushiSkeleton(
                    height: 120,
                    borderRadius: FushiM3eShape.cardRadius,
                  ),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(page, 16, page, 10),
                sliver: SliverToBoxAdapter(
                  child: FushiSkeleton.line(widthFactor: 0.32, height: 20),
                ),
              ),
              _buildSkeletonGrid(context, constraints.maxWidth, shimmer: false),
            ],
          ),
        );
      },
    );
  }

  /// 海报网格骨架。[shimmer] = 每格自带闪光（外层没有共享闪光时；闪光是
  /// box widget，包不住 sliver，只能逐格包）。
  Widget _buildSkeletonGrid(
    BuildContext context,
    double width, {
    bool shimmer = true,
  }) {
    final double page = FushiDesignTokens.of(context).spacing.page;
    const Widget cell = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(child: FushiSkeleton(borderRadius: FushiM3eShape.smallRadius)),
        SizedBox(height: 10),
        FushiSkeleton(height: 14),
        SizedBox(height: 6),
        FractionallySizedBox(
          widthFactor: 0.55,
          alignment: AlignmentDirectional.centerStart,
          child: FushiSkeleton(height: 12),
        ),
      ],
    );
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: page),
      sliver: SliverGrid.builder(
        gridDelegate: _gridDelegate(width),
        itemCount: 6,
        itemBuilder: (BuildContext context, int index) =>
            shimmer ? const FushiSkeletonShimmer(child: cell) : cell,
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
    final List<Widget> header = <Widget>[
      if (_hosts.length > 1) _buildHostSwitcher(tokens),
      _buildHostHeader(context, host),
      if (_notice != null) _buildNotice(context, _notice!),
      if (host.sessions.isNotEmpty) ..._buildSessions(context, host),
      if (host.phase == _HostPhase.ready && games.isNotEmpty)
        _sectionLabel(context, t.game_library),
    ];
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        return FushiEntranceScope(
          // 切主机 = 换一屏内容，重开进场窗口让新主机的卡同样错峰进场。
          replayKey: host.key,
          child: CustomScrollView(
            slivers: <Widget>[
              SliverPadding(
                padding: EdgeInsets.fromLTRB(page, 0, page, tokens.spacing.gap),
                sliver: SliverList.list(
                  children: <Widget>[
                    for (int i = 0; i < header.length; i++)
                      FushiStaggeredEntrance(index: i, child: header[i]),
                  ],
                ),
              ),
              // 主机在线但库是空的：与本机游戏库同一个共享空态（图标 + 文案）。
              if (host.phase == _HostPhase.ready && games.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: page),
                    child: FushiPlaceholderMessage(
                      icon: FushiIcons.games,
                      message: t.game_stream_library_empty,
                    ),
                  ),
                ),
              // 主机还在连：游戏库位置先放同轮廓骨架，连上后整块换成海报。
              if (host.phase == _HostPhase.loading && games.isEmpty)
                SliverPadding(
                  padding: EdgeInsets.only(top: tokens.spacing.gap),
                  sliver: _buildSkeletonGrid(context, width),
                ),
              if (host.phase == _HostPhase.ready && games.isNotEmpty)
                SliverPadding(
                  padding: withBottomSafeInset(
                    context,
                    EdgeInsets.fromLTRB(page, 0, page, tokens.spacing.section),
                  ),
                  sliver: SliverGrid.builder(
                    gridDelegate: _gridDelegate(width),
                    itemCount: games.length,
                    // 首屏错峰进场（与本机游戏库同一套）；滚动带出的卡瞬间出现。
                    itemBuilder: fushiStaggeredItemBuilder(
                      (BuildContext context, int index) =>
                          _buildGameCard(context, host, games[index]),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildNoHosts(BuildContext context) {
    // 空态走共享占位件（M3E 色块图标 + 弹入），行动按钮是 M3E 中号主按钮。
    return FushiPlaceholderMessage(
      icon: FushiIcons.cast,
      message: t.game_stream_no_hosts,
      action: _services.openInterconnectSettings == null
          ? null
          : FushiFilledButton.icon(
              key: GameStreamLibraryPage.interconnectButtonKey,
              autofocus: true,
              size: FushiButtonSize.m,
              onPressed: () => unawaited(_openInterconnect()),
              icon: const FushiIcon(FushiIcons.devices),
              label: Text(t.game_stream_open_interconnect),
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
              leadingIcon: _phaseIcon(host),
              selected: host.key == _selectedHost?.key,
              focusId: FushiFocusId('game-stream-host-${host.key}'),
              onSelected: (bool _) => setState(() => _selectedKey = host.key),
            ),
        ],
      ),
    );
  }

  static IconData _phaseIcon(_StreamHost host) => switch (host.phase) {
    _HostPhase.loading => FushiIcons.sync,
    _HostPhase.ready => FushiIcons.devices,
    _HostPhase.unreachable => FushiIcons.cloudOff,
    _HostPhase.rejected => switch (host.rejection) {
      // 旧主机没有游戏库路由（裸 404）：提示更新。
      'http_rejected' => FushiIcons.warning,
      GameStreamRejection.httpsRequired => FushiIcons.lockOpen,
      // 没有游戏库时已有会话仍可加入，不用「禁止」暗示整台主机不可用。
      GameStreamRejection.libraryOff => FushiIcons.info,
      _ => FushiIcons.block,
    },
  };

  /// 状态 hero 的饱和色块：在线 primary、连接中 secondary、版本过旧 / 没开
  /// 游戏库（已有会话仍可加入）tertiary、连不上 / 被拒 error（Apple 落到强调色
  /// / 系统色淡染，墨水屏不上色）。
  static FushiCardTone _phaseTone(_StreamHost host) => switch (host.phase) {
    _HostPhase.ready => FushiCardTone.primary,
    _HostPhase.loading => FushiCardTone.secondary,
    _HostPhase.unreachable => FushiCardTone.error,
    _HostPhase.rejected => switch (host.rejection) {
      'http_rejected' ||
      GameStreamRejection.libraryOff => FushiCardTone.tertiary,
      _ => FushiCardTone.error,
    },
  };

  String _phaseLabel(_StreamHost host) => switch (host.phase) {
    _HostPhase.loading => t.game_stream_host_connecting,
    _HostPhase.ready => t.game_stream_host_online(
      n: host.library?.games.length ?? 0,
    ),
    _HostPhase.unreachable => t.game_stream_unreachable,
    _HostPhase.rejected =>
      gameStreamRejectionMessage(host.rejection) ?? t.game_stream_host_rejected,
  };

  /// 主机状态 hero：整卡是随状态换色的 M3E 饱和色块，主机名走 headline
  /// 强调字重，连接中给波浪进度，异常时给 tonal 重试按钮。
  Widget _buildHostHeader(BuildContext context, _StreamHost host) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiTypography type = context.fushiType;
    final FushiMotionScheme motion = context.fushiMotion;
    final bool online = host.phase == _HostPhase.ready;
    final bool loading = host.phase == _HostPhase.loading;
    final bool launchOff = online && host.library?.launchEnabled == false;
    final FushiCardTone tone = _phaseTone(host);
    final Color? onTone = fushiCardToneColors(context, tone)?.onContainer;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= 600;
        final Widget retry = FushiFilledButton.tonalIcon(
          size: FushiButtonSize.s,
          onPressed: _busy ? null : () => unawaited(_refreshHost(host)),
          icon: const FushiIcon(FushiIcons.refresh),
          label: Text(t.retry),
        );
        return FushiCard(
          tone: tone,
          margin: EdgeInsets.only(bottom: tokens.spacing.gap),
          padding: EdgeInsets.all(wide ? 24 : 20),
          child: AnimatedSize(
            duration: motion.spatialDefault.duration,
            curve: motion.spatialDefault.curve,
            alignment: AlignmentDirectional.topStart,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    _HostHeroBadge(
                      icon: _phaseIcon(host),
                      tone: tone,
                      online: online,
                      size: wide ? 64 : 52,
                    ),
                    SizedBox(width: wide ? 20 : 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            host.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                (wide
                                        ? type.headlineMediumEmphasized
                                        : type.headlineSmallEmphasized)
                                    .copyWith(color: onTone),
                          ),
                          const SizedBox(height: 4),
                          // 状态文案换状态时淡入淡出（effects 弹簧，不过冲）。
                          AnimatedSwitcher(
                            duration: motion.effectsDefault.duration,
                            switchInCurve: motion.effectsDefault.curve,
                            switchOutCurve: motion.effectsDefault.curve,
                            layoutBuilder: _startAlignedLayout,
                            child: Text(
                              _phaseLabel(host),
                              key: ValueKey<_HostPhase>(host.phase),
                              style: type.titleMedium.copyWith(color: onTone),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!online && !loading && wide) ...<Widget>[
                      const SizedBox(width: 12),
                      retry,
                    ],
                  ],
                ),
                if (loading) ...<Widget>[
                  const SizedBox(height: 16),
                  const FushiLinearProgressIndicator(),
                ],
                if (!online && !loading && !wide) ...<Widget>[
                  const SizedBox(height: 16),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: retry,
                  ),
                ],
                if (launchOff) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(
                    t.game_stream_host_launch_off,
                    style: type.bodyMedium.copyWith(color: onTone),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  static Widget _startAlignedLayout(
    Widget? currentChild,
    List<Widget> previousChildren,
  ) {
    return Stack(
      alignment: AlignmentDirectional.centerStart,
      children: <Widget>[
        ...previousChildren,
        if (currentChild != null) currentChild,
      ],
    );
  }

  /// 加入 / 离开失败的提示：共享内嵌横幅（MD3 中性底 + 错误色图标 / Apple
  /// 分组底），不再是一行裸红字。
  Widget _buildNotice(BuildContext context, String message) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: FushiInlineNotice(
        message: message,
        severity: FushiNoticeSeverity.error,
      ),
    );
  }

  /// 区块标题（「正在串流」「游戏库」）：与本机游戏库「继续游玩 / 全部游戏」
  /// 同一个 [FushiSectionTitle]（MD3 titleLarge / Apple Title 2 粗体）。
  Widget _sectionLabel(BuildContext context, String label) {
    return FushiSectionTitle(
      label,
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 10),
    );
  }

  /// 「正在串流」：M3E 分段列表（组首尾大圆角、行间细缝、悬停 / 按下形变），
  /// 行首 primary 色块图标，行尾是中号主按钮「加入」。
  List<Widget> _buildSessions(BuildContext context, _StreamHost host) {
    return <Widget>[
      _sectionLabel(context, t.game_stream_active_sessions),
      FushiGroupedList(
        padding: const EdgeInsets.only(bottom: 8),
        children: <Widget>[
          for (final GameStreamSession session in host.sessions)
            FushiListItem(
              key: GameStreamLibraryPage.sessionKey(session.sessionId),
              focusId: FushiFocusId('game-stream-session-${session.sessionId}'),
              leading: const FushiListLeadingIcon(
                FushiIcons.cast,
                shape: FushiLeadingShape.cookie,
                tone: FushiCardTone.primary,
              ),
              title: Text(session.gameTitle ?? t.game_stream_available),
              subtitle: Text(host.name),
              trailing: FushiFilledButton.icon(
                size: FushiButtonSize.m,
                onPressed: _busy ? null : () => unawaited(_join(host, session)),
                icon: const FushiIcon(FushiIcons.play),
                label: Text(t.game_stream_join_action),
              ),
              onTap: _busy ? null : () => unawaited(_join(host, session)),
            ),
        ],
      ),
    ];
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
    // 与书架 / 视频卡的封面角标同一形态（深色胶囊；Apple 磨砂），不再铺整块
    // primary 彩色底（角标底随主题反相，语义绿在浅色主题的深底上对比不够，
    // 保持角标前景色）。
    return CoverBadge(icon: FushiIcons.play, label: t.game_stream_running);
  }
}

/// 状态 hero 的行首形状徽标。M3E：在线 = 四瓣 cookie、其余 = 圆，底色取
/// 色块的 onContainer、图标取 container（在饱和底上反相，最醒目）；换状态时
/// spring 弹入。Apple / 墨水屏交给 [FushiListLeadingIcon] 的系统形态。
class _HostHeroBadge extends StatelessWidget {
  const _HostHeroBadge({
    required this.icon,
    required this.tone,
    required this.online,
    required this.size,
  });

  final IconData icon;
  final FushiCardTone tone;
  final bool online;
  final double size;

  @override
  Widget build(BuildContext context) {
    final FushiMotionScheme motion = context.fushiMotion;
    final FushiCardColors? colors = fushiCardToneColors(context, tone);
    final FushiLeadingShape shape = online
        ? FushiLeadingShape.cookie
        : FushiLeadingShape.circle;
    final Widget badge;
    final Color? background = colors?.onContainer;
    if (isGlassDesign(context) || colors == null || background == null) {
      badge = FushiListLeadingIcon(
        icon,
        shape: shape,
        tone: tone,
        size: size,
        iconSize: size * 0.5,
      );
    } else {
      badge = SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: background,
            shape: fushiLeadingShapeBorder(shape),
          ),
          child: Center(
            child: FushiIcon(icon, size: size * 0.5, color: colors.container),
          ),
        ),
      );
    }
    // 切换曲线用 effects（临界阻尼、不过冲）：同一条动画还驱动透明度，
    // 过冲会让 opacity 越界。
    return AnimatedSwitcher(
      duration: motion.effectsDefault.duration,
      switchInCurve: motion.effectsDefault.curve,
      switchOutCurve: motion.effectsDefault.curve,
      transitionBuilder: (Widget child, Animation<double> animation) =>
          ScaleTransition(
            scale: Tween<double>(begin: 0.6, end: 1).animate(animation),
            child: FadeTransition(opacity: animation, child: child),
          ),
      child: KeyedSubtree(
        key: ValueKey<Object>(Object.hash(icon, tone)),
        child: badge,
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
    const Widget placeholder = ShelfCoverPlaceholder(icon: FushiIcons.games);
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
    return FushiAlertDialog(
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
          // M3E：步骤文案走 title 强调字重，下面一条波浪进度（不定进度——
          // 主机启动耗时不可预估，分段百分比会骗人）；失败原地换成错误横幅。
          AnimatedSwitcher(
            duration: context.fushiMotion.effectsDefault.duration,
            switchInCurve: context.fushiMotion.effectsDefault.curve,
            switchOutCurve: context.fushiMotion.effectsDefault.curve,
            child: failure == null
                ? Column(
                    key: const ValueKey<String>('launch-progress'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        _stepLabel,
                        style: context.fushiType.titleMediumEmphasized,
                      ),
                      const SizedBox(height: 16),
                      const FushiLinearProgressIndicator(),
                    ],
                  )
                : FushiInlineNotice(
                    key: const ValueKey<String>('launch-failure'),
                    message: failure,
                    severity: FushiNoticeSeverity.error,
                  ),
          ),
        ],
      ),
      actions: <Widget>[
        FushiTextButton(
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
  _ => gameStreamRejectionMessage(code) ?? t.game_stream_launch_failed,
};

/// 主机在会话 / 游戏库逻辑之前就拒绝的原因 → 告诉主人该改哪里。不认识的码返回
/// null，由调用方给自己的通用文案。`http_rejected` 是不带原因码的裸非 2xx：
/// 只有旧主机才这样回，所以仍提示更新。
String? gameStreamRejectionMessage(String? code) => switch (code) {
  'http_rejected' => t.game_stream_host_outdated,
  GameStreamRejection.httpsRequired => t.game_stream_host_https_required,
  GameStreamRejection.streamOff => t.game_stream_host_stream_off,
  GameStreamRejection.libraryOff => t.game_stream_host_library_off,
  GameStreamRejection.unauthorizedPeer => t.game_stream_host_unauthorized,
  _ => null,
};
