import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/cover_image.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/floating_lyric_hint.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

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

    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 书架 mini bar 字幕行同属「显示意图」（TODO-1065, BUG-509）：display cue
    // 消除首句空窗 / gap 内提前显示下一句。
    final AudioCue? cue = controller.displayCueForFloatingLyric;
    final bool playing = controller.isPlaying;

    final bool eink = isEinkTheme(context);
    final bool glass = isGlassDesign(context);
    final bool expressive = !eink && !glass;
    final Widget content = Row(
      children: <Widget>[
        _cover(book, scheme),
        SizedBox(width: expressive ? 12 : 10),
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
                      color: glass
                          ? appleColorsOf(context).secondaryLabel
                          : scheme.onSurfaceVariant,
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
          FushiIconButtonControl(
            icon: FushiIcon(
              appModel.showFloatingLyric
                  ? FushiIcons.filled(FushiIcons.subtitles)
                  : FushiIcons.subtitles,
              color: appModel.showFloatingLyric ? scheme.primary : null,
            ),
            tooltip: t.floating_lyric_toggle_action,
            onPressed: () => _toggleFloatingLyric(appModel),
          ),
        if (expressive)
          // M3E：播放键是迷你胶囊里唯一的实心主色圆钮（与浮动工具栏的 FAB
          // 同一强调层级），播放中弹簧变形成方圆角——形状即状态。
          FushiIconButtonControl.filled(
            icon: FushiIcon(
              playing
                  ? FushiIcons.filled(FushiIcons.pause)
                  : FushiIcons.filled(FushiIcons.play),
            ),
            shape: playing
                ? FushiIconButtonShape.square
                : FushiIconButtonShape.round,
            tooltip: t.floating_lyric_play_pause,
            onPressed: () => controller.togglePlayPause(),
          )
        else
          FushiIconButtonControl(
            icon: FushiIcon(playing ? FushiIcons.pause : FushiIcons.play),
            tooltip: t.floating_lyric_play_pause,
            onPressed: () => controller.togglePlayPause(),
          ),
        FushiIconButtonControl(
          icon: const FushiIcon(FushiIcons.stop),
          tooltip: t.stop,
          onPressed: () => appModel.stopBackgroundListening(),
        ),
      ],
    );
    void openBook() => appModel.openBackgroundListeningBook(ref);

    // eink：surfaceContainerHighest 塌成页面底色，迷你条与上方正文连成一片；
    // 顶上描一条线切出来（推荐包下载条同款）。墨水屏保持贴边整条（阴影 /
    // 半透明在灰阶下都会糊成脏边）。
    if (eink) {
      return Material(
        color: scheme.surfaceContainerHighest,
        shape: Border(top: BorderSide(color: scheme.outline)),
        child: InkWell(
          onTap: openBook,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: content,
          ),
        ),
      );
    }
    if (glass) {
      // Apple Music 式迷你播放条：离边 14 的浮动液态玻璃全胶囊（导航与控件
      // 层，不是内容层；圆角取足够大让任何高度都是全圆角），点按整条回到书，
      // 按下变淡、无水波。
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
        child: GlassContainer(
          useOwnLayer: true,
          quality: fushiGlassQuality(context, prominent: true),
          settings: fushiClearGlassSettings(context, bar: true),
          shape: const LiquidRoundedSuperellipse(borderRadius: 999),
          child: FushiPlainButton(
            onPressed: openBook,
            borderRadius: BorderRadius.circular(999),
            child: Padding(
              padding: const EdgeInsetsDirectional.only(
                start: 10,
                end: 8,
                top: 6,
                bottom: 6,
              ),
              child: content,
            ),
          ),
        ),
      );
    }
    // M3E：与底部浮动导航 / 浮动工具栏同一套悬浮胶囊（fushiFloatingPillDecoration：
    // 全圆角、surfaceContainer 底、level2 投影），高 64（kFushiFloatingToolbarExtent），
    // 离边 16；宽屏不铺满，封顶 560 居中，读起来是「底栏上方的一颗播放胶囊」而
    // 不是一条贴边横幅。首次出现时弹簧上浮落位（减弱动态 / 墨水屏下时长为零）。
    final FushiMotionScheme motion = context.fushiMotion;
    final Color pillColor = fushiFloatingToolbarPalette(context).container;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        kFushiFloatingToolbarEdgeMargin,
        4,
        kFushiFloatingToolbarEdgeMargin,
        8,
      ),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: 1),
            duration: motion.spatialDefault.duration,
            curve: motion.spatialDefault.curve,
            builder: (BuildContext context, double v, Widget? child) =>
                Transform.translate(
              offset: Offset(0, (1 - v) * 24),
              child: Transform.scale(
                scale: 0.92 + 0.08 * v,
                child: child,
              ),
            ),
            child: SizedBox(
              height: kFushiFloatingToolbarExtent,
              child: DecoratedBox(
                decoration: fushiFloatingPillDecoration(
                  context,
                  color: pillColor,
                ),
                child: Material(
                  type: MaterialType.transparency,
                  shape: const StadiumBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: openBook,
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: 12,
                        end: 8,
                      ),
                      child: content,
                    ),
                  ),
                ),
              ),
            ),
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

  Widget _cover(SessionBookInfo book, ColorScheme scheme) {
    final String? coverPath = book.coverPath;
    Widget child;
    if (coverPath != null && File(coverPath).existsSync()) {
      child = Image.file(
        File(coverPath),
        width: 36,
        height: 36,
        fit: BoxFit.cover,
        // BUG-959: 迷你条封面按物理像素上限解码（36 逻辑像素，144 物理已足够），
        // 大幅省解码内存。保留 existsSync 短路（缺失走 _coverFallback），避免对
        // 不存在文件发起无谓异步解码。
        cacheWidth: kMiniCoverDecodePixelWidth,
        cacheHeight: kMiniCoverDecodePixelWidth,
        errorBuilder: (_, __, ___) => _coverFallback(scheme),
      );
    } else {
      child = _coverFallback(scheme);
    }
    // M3E：胶囊里的封面是 40 的圆（与胶囊同一曲率家族）；Apple 圆角方 8；
    // 墨水屏保持 6 的小圆角方。
    final bool expressive = !isGlassDesign(context) && !isEinkTheme(context);
    final double side = expressive ? 40 : 36;
    return ClipRRect(
      borderRadius: BorderRadius.circular(
        expressive ? side / 2 : (isGlassDesign(context) ? 8 : 6),
      ),
      child: SizedBox(width: side, height: side, child: child),
    );
  }

  // eink：primaryContainer 塌成页面底色，补描边免得只剩一枚悬空耳机图标。
  // Apple：中性 systemFill 底 + label 色单色图标（不要彩色底块）。
  Widget _coverFallback(ColorScheme scheme) => DecoratedBox(
        decoration: BoxDecoration(
          color: isGlassDesign(context)
              ? appleColorsOf(context).fill
              : scheme.primaryContainer,
          border:
              isEinkTheme(context) ? Border.all(color: scheme.outline) : null,
        ),
        child: FushiIcon(
          FushiIcons.audiobook,
          size: 20,
          color: isGlassDesign(context)
              ? appleColorsOf(context).label
              : scheme.onPrimaryContainer,
        ),
      );
}
