import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_channel.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/audio_controller.dart' show MediaSessionOwner;
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show FushiPlaybackClock;
import 'package:fushi/src/utils/components/fushi_now_playing_bar.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/cover_image.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/floating_lyric_hint.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';

/// 首页「正在听书」迷你条（TODO-291 阶段2）。外壳是与音乐迷你条共用的
/// [FushiNowPlayingBar]。
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
  bool _deferredSessionRebuildScheduled = false;

  void _onSessionChanged() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      setState(() {});
      return;
    }
    if (_deferredSessionRebuildScheduled) return;
    _deferredSessionRebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _deferredSessionRebuildScheduled = false;
      if (mounted) setState(() {});
    });
    SchedulerBinding.instance.ensureVisualUpdate();
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
    // 与音乐迷你条互斥（音乐模块 §7.5）：音乐持有媒体会话时让位给音乐条。
    if (appModel.musicSession.isActive &&
        appModel.audioCtrl.sessionOwner.value == MediaSessionOwner.music) {
      return const SizedBox.shrink();
    }

    // 书架 mini bar 字幕行同属「显示意图」（TODO-1065, BUG-509）：display cue
    // 消除首句空窗 / gap 内提前显示下一句。
    final AudioCue? cue = controller.displayCueForFloatingLyric;
    final String cueText = cue?.text.trim() ?? '';
    final String? coverPath = book.coverPath;
    final File? coverFile = coverPath != null && File(coverPath).existsSync()
        ? File(coverPath)
        : null;

    // 外壳与音乐迷你条共用 [FushiNowPlayingBar]（封面取色色块 + 出血书名大字 +
    // 圆环波浪进度 + 形变播放键）；本条只接有声书会话：书名 / 当前句、全书进度、
    // 悬浮字幕开关与停止。点条身回到书。
    return FushiNowPlayingBar(
      barKey: const ValueKey<String>('now_listening_open_book'),
      playButtonKey: const ValueKey<String>('now_listening_play_pause'),
      title: book.title,
      subtitle: cueText.isNotEmpty ? cueText : t.now_listening_label,
      coverBuilder: (BuildContext context, double size) =>
          _cover(context, coverFile),
      tintImage: coverFile == null
          ? null
          : resizedFileImage(coverFile, width: kMiniCoverDecodePixelWidth),
      clock: _AudiobookBookClock(controller),
      isPlaying: controller.isPlaying,
      onPlayPause: () => controller.togglePlayPause(),
      actions: <Widget>[
        // TODO-354 ③：书架底栏迷你条上的「悬浮字幕」开关——真启停 app 外悬浮字幕
        // 窗口（复用 toggleFloatingLyricFromControls：拉起/隐藏悬浮窗 + 偏好读写）。
        // 只有有 native 悬浮窗后端的平台（FloatingLyricChannel.supported：Android /
        // Windows / macOS）显示开关，其余（Linux）隐藏（优雅降级）。开着态用实心
        // 选中态图标提示当前已开。
        if (FloatingLyricChannel.supported)
          FushiIconButtonControl(
            isSelected: appModel.showFloatingLyric,
            icon: FushiIcon(
              appModel.showFloatingLyric
                  ? FushiIcons.filled(FushiIcons.subtitles)
                  : FushiIcons.subtitles,
            ),
            tooltip: t.floating_lyric_toggle_action,
            onPressed: () => _toggleFloatingLyric(appModel),
          ),
        FushiIconButtonControl(
          icon: const FushiIcon(FushiIcons.stop),
          tooltip: t.stop,
          onPressed: () => appModel.stopBackgroundListening(),
        ),
      ],
      onTap: () => appModel.openBackgroundListeningBook(ref),
    );
  }

  /// 翻转 app 外悬浮字幕窗口（委托 [AppModel.toggleFloatingLyricFromControls]：
  /// session 拉起/隐藏 + 偏好读写）。失败（缺 overlay 权限 / 窗口创建失败）按平台
  /// 提示，与 reader 的同名开关一致。
  Future<void> _toggleFloatingLyric(AppModel appModel) async {
    final bool ok = await appModel.toggleFloatingLyricFromControls();
    if (!ok) {
      // TODO-1227: ColorOS OEMs may refuse the overlay permission outright —
      // OPPO-family devices get workaround guidance instead of the plain
      // "grant the permission" hint.
      final String? maker = Platform.isAndroid
          ? await appModel.platformServices.deviceInfo.manufacturer
          : null;
      if (!mounted) return;
      final String hint = floatingLyricFailureHint(
        isAndroid: Platform.isAndroid,
        manufacturer: maker,
      );
      // 2026-10 体验优化：全应用统一走 FushiToast（SnackBar 会被底部播放条 /
      // 导航栏遮住，且与其它入口的同一失败提示样式不一致）。
      FushiToast.show(
        msg: hint,
        severity: ToastSeverity.error,
        toastLength: Toast.LENGTH_LONG,
      );
      return;
    }
    if (!mounted) return;
    setState(() {});
  }

  /// 迷你条封面（[FushiNowPlayingBar] 负责裁形）。在色块配色的主题下构建：
  /// 没封面时是强调色底上的有声书图标。
  Widget _cover(BuildContext context, File? coverFile) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget fallback = ColoredBox(
      color: scheme.primary,
      child: Center(
        child: FushiIcon(
          FushiIcons.audiobook,
          size: 20,
          color: scheme.onPrimary,
        ),
      ),
    );
    if (coverFile == null) return fallback;
    return Image.file(
      coverFile,
      fit: BoxFit.cover,
      // BUG-959: 迷你条封面按物理像素上限解码（约 44 逻辑像素，144 物理已足够），
      // 大幅省解码内存。保留 existsSync 短路（缺失走 fallback），避免对不存在
      // 文件发起无谓异步解码。
      cacheWidth: kMiniCoverDecodePixelWidth,
      cacheHeight: kMiniCoverDecodePixelWidth,
      errorBuilder: (_, __, ___) => fallback,
    );
  }
}

/// 全书时间轴上的进度读口（圆环波浪进度用）。
class _AudiobookBookClock implements FushiPlaybackClock {
  const _AudiobookBookClock(this.controller);

  final AudiobookPlayerController controller;

  @override
  Duration get position => controller.globalPosition;

  @override
  Duration get duration => controller.totalDuration;
}
