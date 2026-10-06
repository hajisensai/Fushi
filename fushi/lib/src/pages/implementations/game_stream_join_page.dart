import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/pages/implementations/game_stream_session_opener.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// Android receiver entry point. The page intentionally accepts a repository
/// instead of discovering hosts globally, so only already-paired candidates
/// and their pinned transport are used.
class GameStreamJoinPage extends StatefulWidget {
  const GameStreamJoinPage({
    required this.repository,
    required this.readSettings,
    required this.writeSettings,
    super.key,
  });

  final SyncRepository repository;

  /// 串流参数的读写（生产接 `PreferencesRepository.gameStreamVideoSettings`）。
  final GameStreamVideoSettings Function() readSettings;
  final Future<void> Function(GameStreamVideoSettings settings) writeSettings;

  @override
  State<GameStreamJoinPage> createState() => _GameStreamJoinPageState();
}

class _GameStreamJoinPageState extends State<GameStreamJoinPage> {
  final List<_GameStreamHost> _hosts = <_GameStreamHost>[];
  bool _loading = true;
  bool _joining = false;
  String? _error;
  String get _clientId => gameStreamReceiverClientId;

  @override
  void initState() {
    super.initState();
    unawaited(_loadHosts());
  }

  Future<void> _loadHosts() async {
    if (!Platform.isAndroid) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = t.game_stream_android_only;
        });
      }
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _hosts.clear();
    });
    try {
      // 每台 host 一次：同一台机器的多条地址只取组内最先可达的那条。
      final List<FushiClientUrl> peers =
          await resolveInterconnectPeerConnections(
        (await widget.repository.getFushiClientUrls())
            .where((FushiClientUrl peer) => peer.enabled)
            .toList(),
      );
      for (final FushiClientUrl peer in peers) {
        final FushiGameStreamClient client = FushiGameStreamClient(
          transport: InterconnectGameStreamTransport(repo: widget.repository),
        );
        client.bindPeer(peer);
        try {
          final List<GameStreamSession> sessions = await client.listSessions(
            clientId: _clientId,
          );
          _hosts.add(
            _GameStreamHost(
              peer: peer,
              client: client,
              sessions: sessions
                  .where(
                    (GameStreamSession session) =>
                        session.state == GameStreamSessionState.waiting ||
                        session.state == GameStreamSessionState.connecting,
                  )
                  .toList(),
            ),
          );
        } on Object catch (error) {
          _error ??=
              '${t.game_stream_unreachable}: ${peer.deviceName ?? peer.url} ($error)';
        }
      }
    } catch (error) {
      _error = '${t.game_stream_unreachable}: $error';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _join(_GameStreamHost host, GameStreamSession session) async {
    if (_joining || !Platform.isAndroid) return;
    setState(() {
      _joining = true;
      _error = null;
    });
    try {
      // 与游戏库页同一条加入路径：串流参数、查词、制卡的行为一致。
      await openGameStreamSession(
        context: context,
        repository: widget.repository,
        client: host.client,
        peer: host.peer,
        session: session,
        settings: widget.readSettings(),
        clientId: _clientId,
        onSettingsChanged: (GameStreamVideoSettings next) =>
            unawaited(widget.writeSettings(next)),
      );
    } on GameStreamLeaveError catch (error) {
      if (mounted) {
        setState(() => _error = '${t.game_stream_leave_failed}: $error');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = '${t.game_stream_join_failed}: $error');
      }
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FushiAppBar(
        title: Text(t.game_stream_join),
        actions: <Widget>[
          FushiIconButtonControl(
            tooltip: t.refresh,
            onPressed: _loading || _joining ? null : _loadHosts,
            icon: const FushiIcon(FushiIcons.refresh),
          ),
        ],
      ),
      body: _loading ? _buildSkeleton() : _buildBody(context),
    );
  }

  /// 加载骨架：与最终版面同轮廓（分组标题 + 三行分段列表），共享一层闪光。
  Widget _buildSkeleton() {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: FushiSkeletonShimmer(
          child: ListView(
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              FushiSkeleton.line(widthFactor: 0.4, height: 20),
              const SizedBox(height: 14),
              for (int i = 0; i < 3; i++)
                const Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: FushiSkeleton(
                    height: 72,
                    borderRadius: FushiM3eShape.smallRadius,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_hosts.every((_GameStreamHost host) => host.sessions.isEmpty)) {
      // 空态 / 失败态走共享占位件（M3E 色块图标 + 弹入；失败态 error 色块）。
      return FushiPlaceholderMessage(
        icon: _error == null ? FushiIcons.cast : FushiIcons.error,
        message: _error ?? t.game_stream_none,
        tone: _error == null
            ? FushiPlaceholderTone.neutral
            : FushiPlaceholderTone.error,
      );
    }
    final List<Widget> sections = <Widget>[
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: FushiInlineNotice(
            message: _error!,
            severity: FushiNoticeSeverity.error,
          ),
        ),
      for (final _GameStreamHost host in _hosts)
        if (host.sessions.isNotEmpty) _buildHostSection(host),
    ];
    // 宽屏不把行拉满整窗：限宽居中，行尾的「加入」不至于离标题一整屏远。
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: FushiEntranceScope(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: sections.length,
            itemBuilder: fushiStaggeredItemBuilder(
              (BuildContext context, int index) => sections[index],
            ),
          ),
        ),
      ),
    );
  }

  /// 一台主机一组：主机名作分组标题，下面是 M3E 分段列表（行首 primary 色块
  /// 图标、行尾中号主按钮「加入」）。
  Widget _buildHostSection(_GameStreamHost host) {
    final String hostName = host.peer.deviceName ?? host.peer.url;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FushiSectionTitle(
          hostName,
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
        ),
        FushiGroupedList(
          padding: const EdgeInsets.only(bottom: 16),
          children: <Widget>[
            for (final GameStreamSession session in host.sessions)
              FushiListItem(
                leading: const FushiListLeadingIcon(
                  FushiIcons.cast,
                  shape: FushiLeadingShape.cookie,
                  tone: FushiCardTone.primary,
                ),
                title: Text(session.gameTitle ?? hostName),
                subtitle: Text(t.game_stream_available),
                trailing: FushiFilledButton.icon(
                  size: FushiButtonSize.m,
                  onPressed: _joining
                      ? null
                      : () => unawaited(_join(host, session)),
                  icon: const FushiIcon(FushiIcons.play),
                  label: Text(
                    _joining ? t.game_stream_busy : t.game_stream_join_action,
                  ),
                ),
                onTap: _joining ? null : () => unawaited(_join(host, session)),
              ),
          ],
        ),
      ],
    );
  }
}

class _GameStreamHost {
  const _GameStreamHost({
    required this.peer,
    required this.client,
    required this.sessions,
  });

  final FushiClientUrl peer;
  final FushiGameStreamClient client;
  final List<GameStreamSession> sessions;
}
