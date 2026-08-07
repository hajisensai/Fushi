import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fushi/src/mining/gal_audio_tracks_panel.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/pages/implementations/game_shared.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/utils/misc/desktop_audio_playback.dart';
import 'package:fushi/utils.dart';

typedef GalTextThreadSelector = Future<bool> Function(
  TexthookerTextThread thread,
);

/// 游戏启动/附着后首次出现候选线程时的捕获设置大弹窗。
///
/// 左侧先选台词线程，右侧明确区分「音频采集源已就绪」与「本句已有音频」；引擎 PCM
/// 模式还可在同一处试听、选语音轨和排除 BGM。选中线程后自动关闭，也保留显式关闭。
class GalCaptureSetupDialog extends StatefulWidget {
  const GalCaptureSetupDialog({
    required this.session,
    required this.onSelectThread,
    super.key,
  });

  final GalHookSessionController session;
  final GalTextThreadSelector onSelectThread;

  @override
  State<GalCaptureSetupDialog> createState() => _GalCaptureSetupDialogState();
}

class _GalCaptureSetupDialogState extends State<GalCaptureSetupDialog> {
  String? _selectingThreadKey;
  int? _previewingSourcePtr;
  Timer? _previewResetTimer;
  Future<void> _previewQueue = Future<void>.value();
  int _previewGeneration = 0;
  bool _autoCloseScheduled = false;
  bool _dismissRequested = false;

  @override
  void initState() {
    super.initState();
    unawaited(widget.session.refreshAudioTracks());
  }

  @override
  void dispose() {
    _previewGeneration++;
    _previewResetTimer?.cancel();
    unawaited(DesktopAudioPlayback.stop());
    super.dispose();
  }

  Future<void> _selectThread(TexthookerTextThread thread) async {
    if (_selectingThreadKey != null) return;
    setState(() => _selectingThreadKey = thread.key);
    final bool selected = await widget.onSelectThread(thread);
    if (!mounted) return;
    if (selected) {
      _dismissOnce();
      return;
    }
    setState(() => _selectingThreadKey = null);
  }

  void _requestPreview(GalAudioTrack track) {
    final int generation = ++_previewGeneration;
    _previewQueue = _previewQueue.then(
      (_) => _togglePreview(track, generation),
    );
    unawaited(_previewQueue);
  }

  Future<void> _togglePreview(GalAudioTrack track, int generation) async {
    if (!mounted || generation != _previewGeneration) return;
    if (_previewingSourcePtr == track.sourcePtr) {
      _previewResetTimer?.cancel();
      setState(() => _previewingSourcePtr = null);
      await DesktopAudioPlayback.stop();
      return;
    }
    final GalTrackPreview? preview =
        await widget.session.exportTrackPreview(track.sourcePtr);
    if (!mounted || generation != _previewGeneration) return;
    if (preview == null) {
      FushiToast.show(msg: t.game_track_preview_failed);
      return;
    }
    final bool started = await DesktopAudioPlayback.playFile(preview.filePath);
    if (!mounted) return;
    if (generation != _previewGeneration) {
      await DesktopAudioPlayback.stop();
      return;
    }
    if (!started) {
      FushiToast.show(msg: t.game_track_preview_failed);
      return;
    }
    _previewResetTimer?.cancel();
    setState(() => _previewingSourcePtr = track.sourcePtr);
    _previewResetTimer = Timer(
      Duration(milliseconds: preview.durationMs + 300),
      () {
        if (mounted) setState(() => _previewingSourcePtr = null);
      },
    );
  }

  void _scheduleAutoClose() {
    if (_autoCloseScheduled || _dismissRequested) return;
    _autoCloseScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoCloseScheduled = false;
      if (mounted) _dismissOnce();
    });
  }

  void _dismissOnce() {
    if (_dismissRequested) return;
    _dismissRequested = true;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    final double dialogHeight = (screen.height * 0.72).clamp(420.0, 680.0);
    return AlertDialog(
      title: Text(t.game_capture_setup_title),
      content: SizedBox(
        width: 900,
        height: dialogHeight,
        child: ListenableBuilder(
          listenable: widget.session,
          builder: (BuildContext context, Widget? child) {
            if (widget.session.selectedTextThreadKey != null) {
              _scheduleAutoClose();
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  t.game_capture_setup_hint,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints box) {
                      final Widget threads = _buildThreadPane(context);
                      final Widget audio = _buildAudioPane(context);
                      if (box.maxWidth >= 760) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Expanded(flex: 6, child: threads),
                            const SizedBox(width: 12),
                            Expanded(flex: 5, child: audio),
                          ],
                        );
                      }
                      return Column(
                        children: <Widget>[
                          Expanded(flex: 6, child: threads),
                          const SizedBox(height: 12),
                          Expanded(flex: 5, child: audio),
                        ],
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _dismissOnce,
          child: Text(t.dialog_close),
        ),
      ],
    );
  }

  Widget _buildThreadPane(BuildContext context) {
    final List<TexthookerTextThread> threads = widget.session.textThreads;
    final Map<String, String> labels = assignThreadDisplayLabels(threads);
    return FushiCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Text(
              t.game_text_thread,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: threads.isEmpty
                ? Center(child: Text(t.game_waiting_for_text))
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: threads.length,
                    itemBuilder: (BuildContext context, int index) {
                      final TexthookerTextThread thread = threads[index];
                      final bool selecting = _selectingThreadKey == thread.key;
                      return FushiListItem(
                        leading: const Icon(Icons.forum_outlined),
                        title: Text(
                          '${labels[thread.key] ?? thread.label} · '
                          '${thread.observedLineCount}',
                        ),
                        subtitle: Text(
                          texthookerThreadSubtitle(
                                audioLineCount: thread.audioLineCount,
                                latestText: thread.displayPreviewText,
                                audioLabel: t.game_text_thread_audio_count(
                                  count: thread.audioLineCount,
                                ),
                              ) ??
                              t.game_waiting_for_text,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: selecting
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.chevron_right),
                        onTap: selecting
                            ? null
                            : () => unawaited(_selectThread(thread)),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildAudioPane(BuildContext context) {
    final GalHookSessionState state = widget.session.state;
    final String source = galHookAudioBackendLabel(state.audioBackend);
    final String? format = state.audioFormat == null
        ? null
        : '${state.audioFormat!.sampleRate} Hz · '
            '${state.audioFormat!.channels} ch · '
            '${state.audioFormat!.bitsPerSample} bit';
    return FushiCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Text(
              t.game_audio_tracks,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _AudioSourceSummary(source: source, format: format),
                  const SizedBox(height: 12),
                  Text(
                    t.game_audio_requires_thread,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 8),
                  GalAudioTracksPanel(
                    state: state,
                    onSelectVoice: widget.session.selectVoiceTrack,
                    onToggleExcluded: widget.session.setTrackExcluded,
                    onPreviewTrack: _requestPreview,
                    previewingSourcePtr: _previewingSourcePtr,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AudioSourceSummary extends StatelessWidget {
  const _AudioSourceSummary({required this.source, required this.format});

  final String source;
  final String? format;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Icon(Icons.graphic_eq_outlined),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(source, style: Theme.of(context).textTheme.labelLarge),
              if (format != null)
                Text(format!, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}
