import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

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

  /// [error] 里有没有可解的 Cloudflare 挑战（= 这个按钮显不显示）。与别的按钮
  /// 并排进 `Wrap` 时按它决定要不要放进去：零尺寸的子项照样占 `spacing`。
  static bool shows({required Object? runtime, required Object? error}) =>
      runtime is ChallengeMihonRuntime &&
      mihonCloudflareChallenge(error) != null;

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
    if (!MihonCloudflareAction.shows(
      runtime: widget.runtime,
      error: widget.error,
    )) {
      return const SizedBox.shrink();
    }
    final String label = t.manga_source_cloudflare_verify_title;
    final Widget action = widget.compact
        ? FushiIconButtonControl(
            tooltip: label,
            onPressed: _busy ? null : _verify,
            icon: const FushiIcon(Icons.verified_user_outlined),
          )
        : FushiTextButton.icon(
            onPressed: _busy ? null : _verify,
            icon: const FushiIcon(Icons.verified_user_outlined),
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
