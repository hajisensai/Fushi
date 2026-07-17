import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/models.dart';
import 'package:hibiki/src/mining/galgame_audio_capture_controller.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/utils.dart';

class GalgameAudioCapturePage extends ConsumerStatefulWidget {
  const GalgameAudioCapturePage({super.key});

  @override
  ConsumerState<GalgameAudioCapturePage> createState() =>
      _GalgameAudioCapturePageState();
}

class _GalgameAudioCapturePageState
    extends ConsumerState<GalgameAudioCapturePage> {
  final GalgameAudioCaptureController _capture =
      GalgameAudioCaptureController.instance;
  List<ExternalWindowInfo> _windows = const <ExternalWindowInfo>[];
  bool _loading = true;
  int? _startingPid;

  @override
  void initState() {
    super.initState();
    _capture.addListener(_onCaptureChanged);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _capture.removeListener(_onCaptureChanged);
    super.dispose();
  }

  void _onCaptureChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _loading = true);
    final List<ExternalWindowInfo> windows =
        await WindowCaptureChannel.listWindows();
    if (!mounted) return;
    setState(() {
      _windows = windows.where((ExternalWindowInfo w) => w.pid > 0).toList();
      _loading = false;
    });
  }

  Future<void> _select(ExternalWindowInfo window) async {
    if (_startingPid != null) return;
    setState(() => _startingPid = window.pid);
    try {
      await ref.read(appProvider).selectGalgameAudioTarget(window);
    } finally {
      if (mounted) setState(() => _startingPid = null);
    }
  }

  String _statusText(AppModel model) {
    switch (_capture.state) {
      case GalgameAudioCaptureState.running:
        final ExternalWindowInfo? target = _capture.target;
        return t.galgame_audio_capture_running(
          name: target?.title ?? model.galgameAudioWindowTitle,
        );
      case GalgameAudioCaptureState.starting:
        return t.galgame_audio_capture_starting;
      case GalgameAudioCaptureState.unavailable:
        return t.galgame_audio_capture_unavailable;
      case GalgameAudioCaptureState.stopped:
        return t.galgame_audio_capture_stopped;
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppModel model = ref.watch(appProvider);
    final ExternalWindowInfo? target = _capture.target;
    return HibikiPageScaffold(
      title: t.galgame_audio_capture,
      subtitle: _statusText(model),
      actions: <Widget>[
        IconButton(
          tooltip: t.refresh,
          onPressed: _loading ? null : _refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: <Widget>[
          AdaptiveSettingsSection(
            children: <Widget>[
              AdaptiveSettingsSwitchRow(
                title: t.galgame_audio_capture_enabled,
                subtitle: t.galgame_audio_capture_enabled_hint,
                icon: Icons.graphic_eq,
                value: model.galgameAudioCaptureEnabled,
                onChanged: (bool value) async {
                  await ref
                      .read(appProvider)
                      .setGalgameAudioCaptureEnabled(value);
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          AdaptiveSettingsSection(
            title: t.galgame_audio_capture_process,
            children: <Widget>[
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_windows.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    t.galgame_audio_capture_no_windows,
                    textAlign: TextAlign.center,
                  ),
                )
              else
                for (final ExternalWindowInfo window in _windows)
                  HibikiListTile(
                    title: window.title,
                    subtitle: window.executablePath.isEmpty
                        ? 'PID ${window.pid}'
                        : p.basename(window.executablePath),
                    icon: Icons.window_outlined,
                    selected: target?.pid == window.pid,
                    onTap: _startingPid == null ? () => _select(window) : null,
                    trailing: _startingPid == window.pid
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check, size: 18),
                  ),
            ],
          ),
        ],
      ),
    );
  }
}
