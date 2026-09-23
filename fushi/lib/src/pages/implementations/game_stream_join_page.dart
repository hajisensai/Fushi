import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/pages/implementations/game_stream_session_opener.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

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
      final List<FushiClientUrl> peers =
          (await widget.repository.getFushiClientUrls())
              .where((FushiClientUrl peer) => peer.enabled)
              .toList();
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
      appBar: AppBar(
        title: Text(t.game_stream_join),
        actions: <Widget>[
          IconButton(
            tooltip: t.refresh,
            onPressed: _loading || _joining ? null : _loadHosts,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_hosts.every((_GameStreamHost host) => host.sessions.isEmpty)) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error ?? t.game_stream_none,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        for (final _GameStreamHost host in _hosts)
          for (final GameStreamSession session in host.sessions)
            FushiCard(
              margin: const EdgeInsets.only(bottom: 8),
              padding: EdgeInsets.zero,
              child: FushiListItem(
                leading: const Icon(Icons.cast),
                title: Text(host.peer.deviceName ?? host.peer.url),
                subtitle: Text(t.game_stream_available),
                trailing: FilledButton(
                  onPressed: _joining
                      ? null
                      : () => unawaited(_join(host, session)),
                  child: Text(
                    _joining ? t.game_stream_busy : t.game_stream_join_action,
                  ),
                ),
              ),
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
