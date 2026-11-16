import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/game_stream_button_profile.dart';
import 'package:fushi/src/models/game_stream_lookup_layout.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/game_stream_session_opener.dart';
import 'package:fushi/src/pages/implementations/game_stream_settings_sheet.dart';
import 'package:fushi/src/pages/implementations/module_settings_view.dart';
import 'package:fushi/src/second_screen/second_screen_host.dart';
import 'package:fushi/src/pages/implementations/games_library_page.dart'
    show galgamePlayTimeFigure;
import 'package:fushi/src/pages/implementations/stat_shared.dart'
    show formatActivityRelativeTime;
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show ShellContentLayout;
import 'package:fushi/src/utils/components/fushi_continue_blocks.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_cover_block_layout.dart';
import 'package:fushi/src/utils/components/fushi_generated_cover.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingChromeVisiblePadding;
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/galgame_poster_card.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
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
    this.volumeBoostAvailable,
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
            lookupLayout: prefs.gameStreamLookupLayout,
            onLookupLayoutChanged: (GameStreamLookupLayout next) =>
                unawaited(prefs.setGameStreamLookupLayout(next)),
            buttonProfile: prefs.gameStreamButtonProfile,
            onButtonProfileChanged: (GameStreamButtonProfile next) =>
                unawaited(prefs.setGameStreamButtonProfile(next)),
            secondScreen: prefs.gameStreamSecondScreen,
            onSecondScreenChanged: (GameStreamSecondScreen next) =>
                unawaited(prefs.setGameStreamSecondScreen(next)),
          ),
      readSettings: () => prefs.gameStreamVideoSettings,
      writeSettings: prefs.setGameStreamVideoSettings,
      openInterconnectSettings: _pushInterconnectSettings,
      volumeBoostAvailable: SecondScreenHost.forCurrentPlatform()?.available,
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

  /// 本机有可用副屏（[SecondScreenHost.available]）时设置弹层才出「串流音量」；
  /// null 视为单屏。
  final ValueListenable<bool>? volumeBoostAvailable;

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

  /// 一台主机的分组（状态行 + 会话 + 游戏块）。
  static Key hostKey(String hostKey) =>
      ValueKey<String>('game-stream-host-$hostKey');

  /// 主机关着远程启动时的提示条。
  static Key launchOffKey(String hostKey) =>
      ValueKey<String>('game-stream-launch-off-$hostKey');

  /// 本设备被主机拒绝（需重新配对）时状态行的「打开互联设置」。
  static Key hostInterconnectKey(String hostKey) =>
      ValueKey<String>('game-stream-host-interconnect-$hostKey');

  /// 主机连不上 / 版本不符等异常时状态行的「重试」。
  static Key hostRetryKey(String hostKey) =>
      ValueKey<String>('game-stream-host-retry-$hostKey');

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

  Future<void> _refreshHost(_StreamHost host) async {
    setState(() => host.phase = _HostPhase.loading);
    await _loadHost(host, _generation);
  }

  Future<void> _openSettings() async {
    final GameStreamVideoSettings? next = await showGameStreamSettingsSheet(
      context,
      initial: _services.readSettings(),
      volumeAvailable: _services.volumeBoostAvailable,
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
    // 作为首页外壳的顶层 tab（非 Windows 的串流接收端）时，外壳把大标题胶囊
    // 叠在内容上方、经 [FushiFloatingChromeInset] 下发让位高度；这里必须让开，
    // 否则页头（外壳已画标题时只剩副标题一行）整段压在标题胶囊底下
    // （2026-10-09 用户截图：「游戏」胶囊挡住「在电脑上启动游戏并串流到这里」）。
    // 嵌在游戏模块分区里时外层已消费过 inset（这里读到 0），不会重复让位。
    // 库页材质（2026-10-25 用户定版，与本机游戏库同一套）：游戏卡走透明卡盒（材质作用域在 [_buildBody] 的滚动视图上）。
    return Scaffold(
      body: FushiFloatingChromeVisiblePadding(
        child: Column(
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
      ),
    );
  }

  /// 海报网格（封面网格布局）列宽：窄屏（手机竖屏）两到三列卡盒，宽屏放大卡盒
  /// 而不是挤出很多列。
  static double _gridExtent(double width) => width >= 840 ? 220 : 180;

  /// [width] 是视口宽；网格段左右各让一个页边（[FushiSpacingTokens.page]）。卡高 =
  /// 卡盒封面（1:1.6）+ 封面下文字块（[ShelfCardMeta.heightFor]），按
  /// `MaxCrossAxisExtent` 同一列数公式复算卡宽（与本机游戏库同一套几何）。
  SliverGridDelegate _gridDelegate(BuildContext context, double width) {
    final bool wide = width >= 600;
    final double crossSpacing = wide ? 20 : 12;
    final double maxExtent = _gridExtent(width);
    final double page = FushiDesignTokens.of(context).spacing.page;
    final double available = math.max(1, width - page * 2);
    final int columns = (available / (maxExtent + crossSpacing)).ceil().clamp(
      1,
      1 << 10,
    );
    final double cardWidth =
        (available - (columns - 1) * crossSpacing) / columns;
    return SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: maxExtent,
      mainAxisSpacing: wide ? 24 : 16,
      crossAxisSpacing: crossSpacing,
      mainAxisExtent:
          cardWidth / kShelfGameCaseAspectRatio +
          ShelfCardMeta.heightFor(context),
    );
  }

  /// 首次加载主机列表时的骨架：与最终版面同轮廓（一行主机状态 + 一排色块），
  /// 共享一层有界闪光。
  Widget _buildLoadingSkeleton(BuildContext context) {
    final double page = FushiDesignTokens.of(context).spacing.page;
    return FushiSkeletonShimmer(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.symmetric(horizontal: page),
        children: <Widget>[
          const _HostStatusRowSkeleton(),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) =>
                _blockSkeletonRow(gameStreamBlockColumns(c.maxWidth)),
          ),
        ],
      ),
    );
  }

  /// 一排色块骨架（主机正在连接时组内先放它，连上后整组换成真块）。
  static Widget _blockSkeletonRow(int columns) {
    return SizedBox(
      height: kFushiCoverBlockHeight,
      child: Row(
        children: <Widget>[
          for (int i = 0; i < columns; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: kFushiCoverBlockSpacing),
            Expanded(
              child: FushiSkeleton(
                borderRadius: BorderRadius.circular(
                  fushiCoverBlockRadius(
                    FushiCoverBlockSize.regular,
                    kFushiCoverBlockHeight,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 多主机结构（设计稿「游戏 · 串流」）：**每台主机一组**，组首是状态行（在线 ·
  /// n 款游戏 / 正在连接… / 被拒 / 版本过旧 …，异常时带「重试」或被拒时「打开
  /// 互联设置」），下面依次是远程启动关闭的提示、「正在串流」会话块（行尾「加入」）
  /// 与这台主机的游戏块。连接中组内画骨架块；不可达 / 被拒 / 版本问题组内不画
  /// 游戏块。只有**第一台在线主机**的首块加大（运行中优先，否则最近玩），其余组
  /// 全是普通块。
  Widget _buildBody(BuildContext context) {
    if (_hosts.isEmpty) return _buildNoHosts(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double page = tokens.spacing.page;
    final bool blocks = FushiContinueBlocks.active(context);
    String? heroHostKey;
    for (final _StreamHost host in _hosts) {
      if (host.phase == _HostPhase.ready &&
          (host.library?.games.isNotEmpty ?? false)) {
        heroHostKey = host.key;
        break;
      }
    }
    final String? notice = _notice;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final double inner = math.max(1, width - page * 2);
        int entrance = 0;
        final List<Widget> slivers = <Widget>[
          if (notice != null)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(page, 0, page, 0),
              sliver: SliverToBoxAdapter(
                child: FushiStaggeredEntrance(
                  index: entrance++,
                  child: _buildNotice(context, notice),
                ),
              ),
            ),
        ];
        for (int h = 0; h < _hosts.length; h++) {
          final _StreamHost host = _hosts[h];
          final List<GameStreamLibraryGame> games = _orderedGames(
            host,
            hero: host.key == heroHostKey,
          );
          final bool online = host.phase == _HostPhase.ready;
          final bool launchOff = online && host.library?.launchEnabled == false;
          slivers.add(
            SliverPadding(
              key: GameStreamLibraryPage.hostKey(host.key),
              padding: EdgeInsets.fromLTRB(page, h == 0 ? 0 : 28, page, 0),
              sliver: SliverList.list(
                children: <Widget>[
                  FushiStaggeredEntrance(
                    index: entrance++,
                    child: _buildHostStatusRow(context, host),
                  ),
                  if (launchOff)
                    FushiStaggeredEntrance(
                      index: entrance++,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: FushiInlineNotice(
                          key: GameStreamLibraryPage.launchOffKey(host.key),
                          message: t.game_stream_host_launch_off,
                        ),
                      ),
                    ),
                  if (host.sessions.isNotEmpty)
                    FushiStaggeredEntrance(
                      index: entrance++,
                      child: _buildSessions(context, host),
                    ),
                ],
              ),
            ),
          );
          if (host.phase == _HostPhase.loading && games.isEmpty) {
            slivers.add(
              SliverPadding(
                padding: EdgeInsets.fromLTRB(page, 12, page, 0),
                sliver: SliverToBoxAdapter(
                  child: FushiSkeletonShimmer(
                    child: _blockSkeletonRow(gameStreamBlockColumns(width)),
                  ),
                ),
              ),
            );
          } else if (online && games.isEmpty) {
            // 主机在线但库是空的：与本机游戏库同一个共享空态（图标 + 文案）。
            slivers.add(
              SliverPadding(
                padding: EdgeInsets.fromLTRB(page, 12, page, 0),
                sliver: SliverToBoxAdapter(
                  child: FushiPlaceholderMessage(
                    icon: FushiIcons.games,
                    message: t.game_stream_library_empty,
                  ),
                ),
              ),
            );
          } else if (online) {
            slivers.add(
              SliverPadding(
                padding: EdgeInsets.fromLTRB(page, 12, page, 0),
                sliver: blocks
                    ? SliverFushiCoverBlocks(
                        key: ValueKey<String>('game-stream-blocks-${host.key}'),
                        // 第一台在线主机：首块占 2 列（× 2 行），其余等尺寸；其余
                        // 主机：全等尺寸。列数 ≥900dp 4 / ≥600dp 3 / 更窄 2。
                        layout: host.key == heroHostKey
                            ? ShellContentLayout.collage
                            : null,
                        uniformAfterHero: true,
                        // 列数按视口宽定档（设计稿的 900 / 600dp 断点说的是
                        // 窗口宽），块宽按扣掉页边后的实际可用宽反推。
                        targetWidth: gameStreamBlockTargetWidth(
                          inner,
                          columns: gameStreamBlockColumns(width),
                        ),
                        itemCount: games.length,
                        itemBuilder:
                            (
                              BuildContext context,
                              int index,
                              FushiCoverBlockSize size,
                            ) => _buildGameBlock(
                              context,
                              host,
                              games[index],
                              size,
                              launchEnabled: !launchOff,
                            ),
                      )
                    : SliverGrid.builder(
                        gridDelegate: _gridDelegate(context, width),
                        itemCount: games.length,
                        // 首屏错峰进场（与本机游戏库同一套）；滚动带出的卡瞬间
                        // 出现。
                        itemBuilder: fushiStaggeredItemBuilder(
                          (BuildContext context, int index) => _buildGameCard(
                            context,
                            host,
                            games[index],
                            launchEnabled: !launchOff,
                          ),
                        ),
                      ),
              ),
            );
          }
        }
        slivers.add(
          SliverPadding(
            padding: withBottomSafeInset(
              context,
              EdgeInsets.only(bottom: tokens.spacing.section),
            ),
          ),
        );
        return FushiEntranceScope(
          // 刷新 = 换一屏内容，重开进场窗口让新内容同样错峰进场。
          replayKey: _generation,
          child: ShelfCoverMaterialScope(
            material: ShelfCoverMaterial.gameCase,
            child: CustomScrollView(slivers: slivers),
          ),
        );
      },
    );
  }

  /// 组内游戏顺序：主机给的原序；[hero] 组把运行中的（没有则最近玩的）挪到最前，
  /// 它就是加大的首块。
  static List<GameStreamLibraryGame> _orderedGames(
    _StreamHost host, {
    required bool hero,
  }) {
    final List<GameStreamLibraryGame> games =
        host.library?.games ?? const <GameStreamLibraryGame>[];
    if (!hero || games.length < 2) return games;
    final int lead = gameStreamHeroIndex(games);
    if (lead <= 0) return games;
    return <GameStreamLibraryGame>[
      games[lead],
      for (int i = 0; i < games.length; i++)
        if (i != lead) games[i],
    ];
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

  /// 状态行徽标的色块档：在线 primary、连接中 secondary、版本过旧 / 没开游戏库
  /// （已有会话仍可加入）tertiary、连不上 / 被拒 error（Apple 落到强调色 / 系统
  /// 色淡染，墨水屏不上色）。
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

  /// 组首状态行：形状徽标（随状态换图标 / 色块）+ 主机名 + 状态文案（换状态时
  /// 淡入淡出），连接中给一条进度。异常时行尾给动作：本设备被拒（需要重新配对）
  /// =「打开互联设置」，其余（连不上 / 版本 / 未开 HTTPS …）=「重试」。横跨整行。
  Widget _buildHostStatusRow(BuildContext context, _StreamHost host) {
    final FushiTypography type = context.fushiType;
    final FushiMotionScheme motion = context.fushiMotion;
    final bool online = host.phase == _HostPhase.ready;
    final bool loading = host.phase == _HostPhase.loading;
    final bool repair =
        host.phase == _HostPhase.rejected &&
        host.rejection == GameStreamRejection.unauthorizedPeer &&
        _services.openInterconnectSettings != null;
    final Widget? action = online || loading
        ? null
        : repair
        ? FushiFilledButton.tonalIcon(
            key: GameStreamLibraryPage.hostInterconnectKey(host.key),
            size: FushiButtonSize.s,
            onPressed: _busy ? null : () => unawaited(_openInterconnect()),
            icon: const FushiIcon(FushiIcons.devices),
            label: Text(t.game_stream_open_interconnect),
          )
        : FushiFilledButton.tonalIcon(
            key: GameStreamLibraryPage.hostRetryKey(host.key),
            size: FushiButtonSize.s,
            onPressed: _busy ? null : () => unawaited(_refreshHost(host)),
            icon: const FushiIcon(FushiIcons.refresh),
            label: Text(t.retry),
          );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= 600;
        final Widget text = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              host.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: wide
                  ? type.titleLargeEmphasized
                  : type.titleMediumEmphasized,
            ),
            const SizedBox(height: 2),
            // 状态文案换状态时淡入淡出（effects 弹簧，不过冲）。
            AnimatedSwitcher(
              duration: motion.effectsDefault.duration,
              switchInCurve: motion.effectsDefault.curve,
              switchOutCurve: motion.effectsDefault.curve,
              layoutBuilder: _startAlignedLayout,
              child: Text(
                _phaseLabel(host),
                key: ValueKey<_HostPhase>(host.phase),
                style: type.bodyMedium.copyWith(
                  color: FushiDesignTokens.of(context).surfaces.onVariant,
                ),
              ),
            ),
          ],
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                _HostHeroBadge(
                  icon: _phaseIcon(host),
                  tone: _phaseTone(host),
                  online: online,
                  size: 44,
                ),
                const SizedBox(width: 14),
                Expanded(child: text),
                if (action != null && wide) ...<Widget>[
                  const SizedBox(width: 12),
                  action,
                ],
              ],
            ),
            if (loading) ...<Widget>[
              const SizedBox(height: 12),
              const FushiLinearProgressIndicator(),
            ],
            if (action != null && !wide) ...<Widget>[
              const SizedBox(height: 10),
              Align(alignment: AlignmentDirectional.centerEnd, child: action),
            ],
          ],
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
      padding: const EdgeInsets.only(bottom: 12),
      child: FushiInlineNotice(
        message: message,
        severity: FushiNoticeSeverity.error,
      ),
    );
  }

  /// 「正在串流」会话块：小节标题 + M3E 分段列表（组首尾大圆角、行间细缝、悬停
  /// / 按下形变），行首 primary 色块图标，行尾是中号主按钮「加入」。
  Widget _buildSessions(BuildContext context, _StreamHost host) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiSectionTitle(
          t.game_stream_active_sessions,
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
        ),
        FushiGroupedList(
          children: <Widget>[
            for (final GameStreamSession session in host.sessions)
              FushiListItem(
                key: GameStreamLibraryPage.sessionKey(session.sessionId),
                focusId: FushiFocusId(
                  'game-stream-session-${session.sessionId}',
                ),
                leading: const FushiListLeadingIcon(
                  FushiIcons.cast,
                  shape: FushiLeadingShape.cookie,
                  tone: FushiCardTone.primary,
                ),
                title: Text(session.gameTitle ?? t.game_stream_available),
                subtitle: Text(host.name),
                trailing: FushiFilledButton.icon(
                  size: FushiButtonSize.m,
                  onPressed: _busy
                      ? null
                      : () => unawaited(_join(host, session)),
                  icon: const FushiIcon(FushiIcons.play),
                  label: Text(t.game_stream_join_action),
                ),
                onTap: _busy ? null : () => unawaited(_join(host, session)),
              ),
          ],
        ),
      ],
    );
  }

  /// 点一款游戏会做什么：运行中 = 加入它的串流；主机允许远程启动 = 启动并串流；
  /// 都不是（远程启动关着、游戏没在跑）= 无动作（null），只能从运行中的块或会话行
  /// 加入。
  VoidCallback? _gameAction(
    _StreamHost host,
    GameStreamLibraryGame game, {
    required bool launchEnabled,
  }) {
    if (_busy) return null;
    if (!game.running && !launchEnabled) return null;
    return () => unawaited(_activateGame(host, game));
  }

  /// 组内的一块（封面色块）：只用 [GameStreamLibraryGame] 的字段——标题、封面、
  /// 时长（大数字）、最后游玩、是否运行；不放品牌 / 字数 / 进度。无封面按标题
  /// 首字取色（[FushiCoverBlock] 的生成封面）。加大首块顶上 chip「运行中」、主
  /// 按钮外观「▶ 加入」/「▶ 启动游戏」（远程启动关着且没在跑时不画按钮）。
  Widget _buildGameBlock(
    BuildContext context,
    _StreamHost host,
    GameStreamLibraryGame game,
    FushiCoverBlockSize size, {
    required bool launchEnabled,
  }) {
    final VoidCallback? onTap = _gameAction(
      host,
      game,
      launchEnabled: launchEnabled,
    );
    final bool hero = size == FushiCoverBlockSize.hero;
    // 加大首块的「运行中」已在顶上 chip 里，副行改说最近游玩，不重复。
    final String subtitle = gameStreamGameSubtitle(
      game,
      launchEnabled: launchEnabled,
      now: DateTime.now(),
      runningInChip: hero,
    );

    final FushiCoverBlockAction? action = !hero
        ? null
        : game.running
        ? FushiCoverBlockAction(
            icon: FushiIcons.play,
            label: t.game_stream_join_action,
          )
        : launchEnabled
        ? FushiCoverBlockAction(icon: FushiIcons.play, label: t.game_launch)
        : null;
    return _StreamGameBlock(
      key: GameStreamLibraryPage.gameCardKey(game.id),
      focusId: FushiFocusId('game-stream-card-${host.key}-${game.id}'),
      cacheKey: '${host.key}|${game.id}',
      game: game,
      size: size,
      subtitle: subtitle,
      eyebrow: hero && game.running ? t.game_stream_running : null,
      action: action,
      loadCover: () => host.client!.libraryCover(game.id),
      onTap: onTap,
    );
  }

  /// 封面网格布局（[ShellContentLayout.grid] / 墨水屏）下的卡盒海报卡：副行同
  /// [gameStreamGameSubtitle]，点按语义同 [_gameAction]。
  Widget _buildGameCard(
    BuildContext context,
    _StreamHost host,
    GameStreamLibraryGame game, {
    required bool launchEnabled,
  }) {
    final String subtitle = gameStreamGameSubtitle(
      game,
      launchEnabled: launchEnabled,
      now: DateTime.now(),
    );
    return GalgamePosterCard(
      key: GameStreamLibraryPage.gameCardKey(game.id),
      focusId: FushiFocusId('game-stream-card-${host.key}-${game.id}'),
      cover: _GameStreamCover(
        cacheKey: '${host.key}|${game.id}',
        hasCover: game.hasCover,
        title: game.title,
        load: () => host.client!.libraryCover(game.id),
      ),
      title: game.title,
      subtitle: subtitle.isEmpty ? null : subtitle,
      subtitleIcon: game.running ? FushiIcons.play : null,
      semanticLabel: subtitle.isEmpty
          ? game.title
          : '${game.title} · $subtitle',
      onTap: _gameAction(host, game, launchEnabled: launchEnabled),
    );
  }
}

/// 串流接收端游戏块的列数：≥900dp 4 列、≥600dp 3 列、更窄 2 列（设计稿「macOS /
/// 平板宽屏」）。
int gameStreamBlockColumns(double width) => width >= 900
    ? 4
    : width >= 600
    ? 3
    : 2;

/// 让 [computeFushiCoverBlockPlan] 在可用宽 [width] 里恰好排出 [columns] 列（缺省
/// = [gameStreamBlockColumns] 按 [width] 定档）的目标块宽（它按
/// `round((宽 + 间距) / (目标 + 间距))` 定列数）。
double gameStreamBlockTargetWidth(double width, {int? columns}) {
  final int count = math.max(1, columns ?? gameStreamBlockColumns(width));
  return math.max(1, (width - (count - 1) * kFushiCoverBlockSpacing) / count);
}

/// 加大首块取哪一款：运行中的优先，否则最近玩的；都没有（从没玩过、没在跑）时
/// 取第一款（-1 表示列表为空）。
int gameStreamHeroIndex(List<GameStreamLibraryGame> games) {
  if (games.isEmpty) return -1;
  final int running = games.indexWhere((GameStreamLibraryGame g) => g.running);
  if (running >= 0) return running;
  int best = 0;
  int bestAt = games.first.lastPlayedAt ?? 0;
  for (int i = 1; i < games.length; i++) {
    final int at = games[i].lastPlayedAt ?? 0;
    if (at > bestAt) {
      best = i;
      bestAt = at;
    }
  }
  return best;
}

/// 游戏块 / 卡的副行：运行中 =「运行中」（决定点下去是加入）；远程启动关着且
/// 没在跑 =「未运行 · 不可启动」；否则最近游玩的相对时间（没玩过时为空串）。
///
/// [runningInChip]：「运行中」已由加大首块顶上的 chip 说了，运行中的游戏副行就
/// 退回最近游玩。
String gameStreamGameSubtitle(
  GameStreamLibraryGame game, {
  required bool launchEnabled,
  required DateTime now,
  bool runningInChip = false,
}) {
  if (game.running && !runningInChip) return t.game_stream_running;
  if (!game.running && !launchEnabled) {
    return t.game_stream_launch_unavailable;
  }
  final int? lastPlayedAt = game.lastPlayedAt;
  if (lastPlayedAt == null) return '';
  return t.game_stream_last_played(
    time: formatActivityRelativeTime(lastPlayedAt, now),
  );
}

/// 主机状态行的骨架（首次加载主机列表时）。
class _HostStatusRowSkeleton extends StatelessWidget {
  const _HostStatusRowSkeleton();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        const FushiSkeleton(width: 44, height: 44, circle: true),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              FushiSkeleton.line(widthFactor: 0.4, height: 18),
              const SizedBox(height: 8),
              FushiSkeleton.line(widthFactor: 0.25, height: 14),
            ],
          ),
        ),
      ],
    );
  }
}

/// 串流接收端的一块游戏色块：封面字节异步取（进程内缓存），取到后同时作色块
/// 取色图源；没有封面 / 取不到就画按标题生成的封面。卡壳与本机游戏库色块同一套
/// （[shelfCoverCard] + 悬停抬升 + 语义标签）；[onTap] 为 null（远程启动关着且
/// 没在跑）时不可点，读屏照样读出「未运行 · 不可启动」。
class _StreamGameBlock extends StatelessWidget {
  const _StreamGameBlock({
    required this.focusId,
    required this.cacheKey,
    required this.game,
    required this.size,
    required this.subtitle,
    required this.loadCover,
    required this.onTap,
    this.eyebrow,
    this.action,
    super.key,
  });

  final FushiFocusId focusId;
  final String cacheKey;
  final GameStreamLibraryGame game;
  final FushiCoverBlockSize size;
  final String subtitle;
  final String? eyebrow;
  final FushiCoverBlockAction? action;
  final Future<GameStreamLibraryCover?> Function() loadCover;
  final VoidCallback? onTap;

  Widget _block(Uint8List? bytes) {
    final bool hasBytes = bytes != null && bytes.isNotEmpty;
    return FushiCoverBlock(
      size: size,
      art: FushiCoverBlockArt.box,
      title: game.title,
      covers: hasBytes
          ? <Widget>[
              Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                cacheWidth: 512,
                errorBuilder:
                    (BuildContext context, Object error, StackTrace? _) =>
                        FushiGeneratedCover(title: game.title),
              ),
            ]
          : const <Widget>[],
      tintImage: hasBytes ? MemoryImage(bytes) : null,
      eyebrow: eyebrow,
      subtitle: subtitle.isEmpty ? null : subtitle,
      leadingIcon: game.running ? FushiIcons.play : null,
      figure: galgamePlayTimeFigure(game.playSeconds),
      action: action,
      hoverEnabled: onTap != null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget visual = game.hasCover
        ? FutureBuilder<Uint8List?>(
            future: _gameStreamCoverBytes(cacheKey, loadCover),
            builder: (BuildContext context, AsyncSnapshot<Uint8List?> snap) =>
                _block(snap.data),
          )
        : _block(null);
    final Widget card = shelfCoverCard(
      focusId: focusId,
      onTap: onTap,
      child: visual,
    );
    return Semantics(
      label: <String>[
        game.title,
        ?eyebrow,
        if (subtitle.isNotEmpty) subtitle,
      ].join(' · '),
      button: onTap != null,
      child: MouseRegion(
        cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
        child: FushiHoverLift(
          enabled: onTap != null,
          builder: (BuildContext _, bool _) => card,
        ),
      ),
    );
  }
}

/// 封面字节（进程内缓存，切 tab / 刷新都不重复拉取；按插入序淘汰）。
Future<Uint8List?> _gameStreamCoverBytes(
  String cacheKey,
  Future<GameStreamLibraryCover?> Function() load,
) {
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
    required this.title,
    required this.load,
  });

  final String cacheKey;
  final bool hasCover;
  final String title;
  final Future<GameStreamLibraryCover?> Function() load;

  @override
  Widget build(BuildContext context) {
    // 没有封面 / 取不到：按标题生成的封面（与色块同一个色相），不再是灰底图标。
    final Widget placeholder = FushiGeneratedCover(title: title);
    if (!hasCover) return placeholder;
    return FutureBuilder<Uint8List?>(
      future: _gameStreamCoverBytes(cacheKey, load),
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
