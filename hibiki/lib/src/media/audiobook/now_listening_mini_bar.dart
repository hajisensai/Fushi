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
    // 书架 mini bar 字幕行同属「显示意图」（TODO-1065, BUG-509）：display cue
    // 消除首句空窗 / gap 内提前显示下一句。
    final AudioCue? cue = controller.displayCueForFloatingLyric;
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
              // TODO-354 ③：书架底栏迷你条上的「悬浮字幕」开关——真启停 app 外悬浮字幕
              // 窗口（复用 toggleFloatingLyricFromControls：拉起/隐藏悬浮窗 + 偏好读写）。
              // 仅 Android/Windows 有 native 悬浮窗后端（floating_lyric_channel），其余桌面
              // 隐藏开关（优雅降级）。开着态用实心高亮图标提示当前已开。
              if (Platform.isAndroid || Platform.isWindows)
                IconButton(
                  icon: Icon(
                    appModel.showFloatingLyric
                        ? Icons.subtitles
                        : Icons.subtitles_outlined,
                    color: appModel.showFloatingLyric ? scheme.primary : null,
                  ),
                  tooltip: t.floating_lyric_toggle_action,
                  onPressed: () => _toggleFloatingLyric(appModel),
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

  /// 翻转 app 外悬浮字幕窗口（委托 [AppModel.toggleFloatingLyricFromControls]：
  /// session 拉起/隐藏 + 偏好读写）。失败（缺 overlay 权限 / 窗口创建失败）按平台
  /// 提示，与 reader 的同名开关一致。
  Future<void> _toggleFloatingLyric(AppModel appModel) async {
    final bool ok = await appModel.toggleFloatingLyricFromControls();
    if (!mounted) return;
    if (!ok) {
      final String hint = Platform.isAndroid
          ? t.floating_lyric_permission_hint
          : t.floating_lyric_unavailable_hint;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(hint),
          duration: const Duration(seconds: 4),
        ),
      );
      return;
    }
    setState(() {});
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
