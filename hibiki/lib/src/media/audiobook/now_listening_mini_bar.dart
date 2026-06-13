import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/audiobook/audiobook_session.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// 首页「正在听书」迷你条（TODO-291 阶段2）。
///
/// 退出书籍后台听书时的常驻入口：显示当前书名 + 当前句字幕 + 播放/暂停 + 停止 +
/// 点击回到书。无活动会话时收起（[SizedBox.shrink]）。监听 [appProvider]（会话起停
/// 经 AppModel.notifyListeners）与会话自身（cue/播放态变化经 [AudiobookSession]
/// notifyListeners）。
///
/// reader 在场时也会显示——但 reader 在前台时迷你条挂在首页背后看不到，所以无害；
/// 真正可见的场景是退书回到首页。
class NowListeningMiniBar extends ConsumerStatefulWidget {
  const NowListeningMiniBar({super.key});

  @override
  ConsumerState<NowListeningMiniBar> createState() =>
      _NowListeningMiniBarState();
}

class _NowListeningMiniBarState extends ConsumerState<NowListeningMiniBar> {
  AudiobookSession? _session;

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  void _bindSession(AudiobookSession session) {
    if (identical(_session, session)) return;
    _session?.removeListener(_onSessionChanged);
    _session = session;
    _session!.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    _session?.removeListener(_onSessionChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppModel appModel = ref.watch(appProvider);
    final AudiobookSession session = appModel.audiobookSession;
    _bindSession(session);

    final SessionBookInfo? book = session.book;
    final AudiobookPlayerController? controller = session.controller;
    if (book == null || controller == null) {
      return const SizedBox.shrink();
    }

    final ColorScheme scheme = Theme.of(context).colorScheme;
    final AudioCue? cue = controller.currentCue;
    final bool playing = controller.isPlaying;

    return Material(
      color: scheme.surfaceContainerHighest,
      child: InkWell(
        onTap: () => appModel.openBackgroundListeningBook(ref),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: <Widget>[
              _cover(book, scheme),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      cue?.text.trim().isNotEmpty == true
                          ? cue!.text.trim()
                          : t.now_listening_label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                tooltip: t.floating_lyric_play_pause,
                onPressed: () => controller.togglePlayPause(),
              ),
              IconButton(
                icon: const Icon(Icons.stop),
                tooltip: t.stop,
                onPressed: () => appModel.stopBackgroundListening(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cover(SessionBookInfo book, ColorScheme scheme) {
    final String? coverPath = book.coverPath;
    Widget child;
    if (coverPath != null && File(coverPath).existsSync()) {
      child = Image.file(
        File(coverPath),
        width: 36,
        height: 36,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _coverFallback(scheme),
      );
    } else {
      child = _coverFallback(scheme);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(width: 36, height: 36, child: child),
    );
  }

  Widget _coverFallback(ColorScheme scheme) => ColoredBox(
        color: scheme.primaryContainer,
        child: Icon(
          Icons.headphones,
          size: 20,
          color: scheme.onPrimaryContainer,
        ),
      );
}
