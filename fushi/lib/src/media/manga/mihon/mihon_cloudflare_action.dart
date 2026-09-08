import 'package:flutter/material.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';

/// Preserve structured challenges across the library's stage/error wrappers.
MihonCloudflareChallengeException? mihonCloudflareChallenge(Object? error) {
  final Set<Object> visited = <Object>{};
  while (error != null && visited.add(error)) {
    if (error is MihonCloudflareChallengeException) return error;
    error = switch (error) {
      OnlineMangaUnavailable(:final cause) => cause,
      MihonRuntimeException(:final cause) => cause,
      _ => null,
    };
  }
  return null;
}

/// A challenge is opened only by this explicit user action, never by a fetch.
class MihonCloudflareAction extends StatefulWidget {
  const MihonCloudflareAction({
    required this.runtime,
    required this.error,
    required this.onVerified,
    this.compact = false,
    super.key,
  });

  final Object? runtime;
  final Object? error;
  final Future<void> Function() onVerified;
  final bool compact;

  @override
  State<MihonCloudflareAction> createState() => _MihonCloudflareActionState();
}

class _MihonCloudflareActionState extends State<MihonCloudflareAction> {
  bool _busy = false;
  Object? _failure;

  Future<void> _verify() async {
    final Object? runtime = widget.runtime;
    final MihonCloudflareChallengeException? challenge =
        mihonCloudflareChallenge(widget.error);
    if (_busy || runtime is! ChallengeMihonRuntime || challenge == null) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await runtime.solveCloudflare(
        challenge.url,
        userAgent: challenge.userAgent,
      );
      if (mounted) await widget.onVerified();
    } on Object catch (error) {
      if (mounted &&
          !(error is MihonRuntimeException &&
              error.code == 'CHALLENGE_CANCELLED')) {
        setState(() => _failure = error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.runtime is! ChallengeMihonRuntime ||
        mihonCloudflareChallenge(widget.error) == null) {
      return const SizedBox.shrink();
    }
    final String label = t.manga_source_cloudflare_verify_title;
    final Widget action = widget.compact
        ? IconButton(
            tooltip: label,
            onPressed: _busy ? null : _verify,
            icon: const Icon(Icons.verified_user_outlined),
          )
        : TextButton.icon(
            onPressed: _busy ? null : _verify,
            icon: const Icon(Icons.verified_user_outlined),
            label: Text(label),
          );
    if (_failure == null) return action;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        action,
        Text('$_failure', maxLines: 3, overflow: TextOverflow.ellipsis),
      ],
    );
  }
}
