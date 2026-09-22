import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fushi/src/pages/implementations/game_stream_page.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi/src/sync/game_stream_receiver.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

/// Android receiver entry point. The page intentionally accepts a repository
/// instead of discovering hosts globally, so only already-paired candidates
/// and their pinned transport are used.
class GameStreamJoinPage extends StatefulWidget {
  const GameStreamJoinPage({required this.repository, super.key});

  final SyncRepository repository;

  @override
  State<GameStreamJoinPage> createState() => _GameStreamJoinPageState();
}

class _GameStreamJoinPageState extends State<GameStreamJoinPage> {
  final List<_GameStreamHost> _hosts = <_GameStreamHost>[];
  bool _loading = true;
  String? _error;
  late final String _clientId =
      'android-${Platform.localHostname}-${DateTime.now().microsecondsSinceEpoch}';

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
          _error = '游戏串流接收端仅支持 Android。';
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
          _error ??= '无法连接 ${peer.deviceName ?? peer.url}：$error';
        }
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _join(_GameStreamHost host, GameStreamSession session) async {
    final GameStreamSession? joined = await host.client.join(
      sessionId: session.sessionId,
      clientId: _clientId,
      clientName: Platform.localHostname,
    );
    if (joined == null || !mounted) return;
    final NavigatorState navigator = Navigator.of(context);
    final String activeClientId = host.client.effectiveClientId(_clientId);
    final GameStreamLookupController lookup = GameStreamLookupController(
      lookupClient: InterconnectGameStreamDictionaryLookup(
        repo: widget.repository,
        peer: host.peer,
      ),
      streamClient: host.client,
      clientId: activeClientId,
    );
    late final FushiGameStreamReceiver receiver;
    late final GameStreamInputComposer input;
    receiver = FushiGameStreamReceiver(
      client: host.client,
      onTextEvent: lookup.applyTextEvent,
      onInputAck: (GameStreamInputAck ack) => input.applyAck(ack),
    );
    await receiver.connect(
      sessionId: session.sessionId,
      clientId: activeClientId,
    );
    input = GameStreamInputComposer(
      sessionId: session.sessionId,
      clientId: activeClientId,
      sender: receiver.sendInput,
    );
    try {
      await navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => GameStreamPage(
            sessionId: session.sessionId,
            clientId: activeClientId,
            inputComposer: input,
            lookupController: lookup,
            receiver: receiver,
          ),
        ),
      );
    } finally {
      await receiver.disconnect();
      await host.client.stop(
        sessionId: session.sessionId,
        clientId: activeClientId,
        reason: 'receiver_left',
      );
      input.dispose();
      lookup.dispose();
      receiver.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('加入游戏串流'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _loadHosts,
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
            _error ?? '没有已开启串流的已配对主机。请先在 Windows 游戏页开始串流。',
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
            Card(
              child: ListTile(
                leading: const Icon(Icons.cast),
                title: Text(host.peer.deviceName ?? host.peer.url),
                subtitle: Text('窗口：${session.windowId ?? '游戏'}'),
                trailing: FilledButton(
                  onPressed: () => unawaited(_join(host, session)),
                  child: const Text('加入'),
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
