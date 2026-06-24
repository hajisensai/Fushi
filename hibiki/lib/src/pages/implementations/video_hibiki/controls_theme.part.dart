// GENERATED-NOTE: extracted from video_hibiki_page.dart (TODO-590 batch11).
part of '../video_hibiki_page.dart';

/// media_kit controls-theme domain methods extracted via part-of (TODO-590
/// batch11); shared private scope. Behaviour-preserving: every body is moved
/// character-for-character. None of these methods call `State.setState` — both
/// theme builders are pure assemblers of `Material*VideoControlsThemeData`, so
/// there is no `setState→_rebuild` normalisation here.
///
/// Two `static const` host fields read by these builders are fully qualified
/// through `_VideoHibikiPageState.` — an extension cannot resolve a host
/// class's `static` member by bare name: [_VideoHibikiPageState._videoBottomChromeBaseline]
/// (mobile bottom-chrome baseline) and
/// [_VideoHibikiPageState._videoVerticalGestureSensitivity] (mobile vertical
/// gesture sensitivity). Every other symbol the builders touch is an instance
/// getter/field/method (`_videoControlsTransitionDuration`,
/// `_videoButtonBarHeight`, `_videoControlIconSize`, `_videoSeekBar*`,
/// `_mediaKitControlsVisible`, `_brightness`, `_enterBrightness`,
/// `_onMediaKitVolumeChanged`, `_onMediaKitBrightnessChanged`,
/// `_videoKeyboardShortcuts`, `_topBarSlotGroup`, `_topBarTitle`,
/// `_centeredBottomControlBar`, `_videoBottomSystemInset`) and stays bare,
/// resolved through the shared private scope.
///
/// Covers the desktop ([_desktopControlsTheme]) and mobile
/// ([_mobileControlsTheme]) `media_kit` controls themes; the
/// [VideoControlsThemePair] wiring, the per-kind builders, the slot/chip
/// renderers and every collaborator above stay in the main shell.
extension _VideoControlsTheme on _VideoHibikiPageState {
  MaterialDesktopVideoControlsThemeData _desktopControlsTheme(
    VideoPlayerController controller,
    VideoControlLayout layout,
  ) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return MaterialDesktopVideoControlsThemeData(
      // 无操作 2 秒后控制条自动隐藏（TODO-056，media_kit 默认 3 秒偏长）。
      controlsHoverDuration: const Duration(seconds: 2),
      // 控制条淡入淡出时长（TODO-435）：与侧边锁按钮 / 浮动 rail 读同一真相源
      // [_videoControlsTransitionDuration]，让三者同速淡入淡出（值等于 media_kit
      // 桌面默认 150ms，显式写出后改一处全部跟随）。
      controlsTransitionDuration: _videoControlsTransitionDuration,
      // TODO-364：media_kit 控制条把它**真实**的 `visible` 推进这个 notifier，字幕避让
      // 唯一消费它（见 [_mediaKitControlsVisible] / [_applyControlsVisibilityFromMediaKit]），
      // 不再另建镜像 + 第二个 Timer（旧实现两套计时相位反 = 本 BUG 根因）。
      visibilityNotifier: _mediaKitControlsVisible,
      // TODO-565：进度条（seek bar）经 media_kit 内部 player.seek 绕过 controller 的
      // seekMs 统一清除点，用户开始拖动时清掉「主动跳转目标」快照——否则点字幕行后
      // 的在途 seek 宽限窗口内拖进度条到更早句，会被误 snap 回旧目标句。fork 的 seek
      // bar 把内部 onSeekStart 与本回调合并调用（third_party/media_kit_video）。
      onSeekStart: () => controller.clearSeekTargetSnap(),
      // 控制条隐藏时一并隐藏鼠标光标（默认 false 会让光标常驻，BUG-106）。
      // BUG-391「管 1」（源头层，机理最硬）：字幕跳转列表侧栏开启时禁用本隐藏。机制——
      // fork material_desktop.dart:746-750 的控制条 MouseRegion 在 `mount=false`（控制条隐藏）
      // 时取 `cursor:none` 分支、否则 `basic`（走 MouseTracker，几何只覆盖视频列 Expanded）；
      // hideMouseOnControlsRemoval 翻 false 后，列表开态视频列 controls MouseRegion 恒走 basic
      // 分支、视频列光标从未隐藏 → 鼠标跨进侧栏前那次 none→basic 转换根本不存在 → 从源头消除
      // #84039 竞态来源（不是缩小窗口）。**这是框架层 MouseRegion，不是 native SetCursor**。
      // ⚠️ 防哑火：本值依赖 [_subtitleListVisible]，但构造本 theme 的 builder（layout.part.dart
      // :_buildVideoControlsInner）必须同时监听 [_subtitleListVisible]、否则其翻转时 theme 不重建
      // = 改了值也白改（见 layout.part.dart 的 ListenableBuilder.merge）。仅桌面 theme，移动端不动。
      hideMouseOnControlsRemoval: !_subtitleListVisible.value,
      // 单击画面 = 播放/暂停（media_kit 桌面默认 false，故此前点画面毫无反应，
      // BUG-130）。字幕字符点击在更上层 [VideoSubtitleOverlay] 的 opaque GestureDetector
      // 独立处理、不会冒泡到这里，故启用后点字幕仍是查词、点空白区才暂停，不冲突。
      playAndPauseOnTap: true,
      toggleFullscreenOnDoublePress: false,
      seekBarPositionColor: cs.primary,
      seekBarThumbColor: cs.primary,
      buttonBarButtonColor: cs.primary,
      buttonBarHeight: _videoButtonBarHeight,
      buttonBarButtonSize: _videoControlIconSize,
      keyboardShortcuts: _videoKeyboardShortcuts(controller),
      primaryButtonBar: const <Widget>[],
      // 视频内顶栏（替代被删的 Scaffold AppBar，BUG-102）：左右按钮和标题均从用户布局
      // slot 渲染；标题仍监听 _titleNotifier。
      topButtonBar: <Widget>[
        _topBarSlotGroup(
          VideoControlSlot.topLeft,
          controller,
          layout: layout,
          desktop: true,
        ),
        _topBarTitle(),
        _topBarSlotGroup(
          VideoControlSlot.topRight,
          controller,
          layout: layout,
          desktop: true,
        ),
      ],
      bottomButtonBar: <Widget>[
        // 三区 Stack 布局把 play 钉在几何中心（BUG-257）：左时间 / 右尾部按钮 / 居中
        // seek 簇。±10s 带可见标注（旧底栏只有 tooltip，用户看不懂图标）。media_kit 把
        // bottomButtonBar 放进 Row，用单个 [Expanded] 占满整宽承接绝对定位布局。
        // 进度/时长文字吃「界面大小」（TODO-128）、5 键带 Tooltip（BUG-247）均在
        // [_centeredBottomControlBar] 内保留。
        Expanded(
          child: _centeredBottomControlBar(controller, desktop: true),
        ),
      ],
    );
  }

  /// media_kit 移动控制主题（Android/iOS）：[AdaptiveVideoControls] 在移动端渲染
  /// [MaterialVideoControls]（读本主题），桌面端渲染 [MaterialDesktopVideoControls]
  /// （读 [MaterialDesktopVideoControlsTheme]），两套互斥，故两层主题都配置安全。
  ///
  /// 手机控制条：顶栏直接暴露截图、字幕、音轨、设置等常用入口，不再依赖右上角「⋮」
  /// 小目标；底栏窄屏时隐藏 10 秒跳转，宽屏/横屏/平板仍保留。
  MaterialVideoControlsThemeData _mobileControlsTheme(
    VideoPlayerController controller,
    VideoControlLayout layout,
  ) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    // 进度条 / 底部按钮条的底部留白（BUG-184）：基线 + 系统导航栏/手势栏 inset，
    // 让进度条回到「底部按钮条同一基线、抬离屏幕物理最底」的控制条惯例位置，而不是
    // 用 media_kit 构造器默认的 `bottom: 0` 贴在屏幕最下面。
    final double bottomChromeInset =
        _VideoHibikiPageState._videoBottomChromeBaseline +
            _videoBottomSystemInset();
    // 进度条抬到底部按钮条上方（TODO-156/BUG-217）：media_kit 把进度条与按钮条放同一
    // 个 bottomCenter Stack、都按 bottom 对齐，进度条 bottom 必须 = 按钮条底部基线 +
    // 按钮条高 + 间距，否则两者落同一基线重叠。保留 [bottomChromeInset]（BUG-184 抬离
    // 系统栏）作为按钮条基线，进度条偏移叠加其上。
    final double seekBarBottom =
        bottomChromeInset + _videoButtonBarHeight + _videoSeekBarButtonGap;
    return MaterialVideoControlsThemeData(
      // 无操作 2 秒后控制条自动隐藏（TODO-056，media_kit 默认 3 秒偏长）。
      controlsHoverDuration: const Duration(seconds: 2),
      // 控制条淡入淡出时长（TODO-435）：与侧边锁按钮 / 浮动 rail 读同一真相源
      // [_videoControlsTransitionDuration]，让三者同速淡入淡出（值等于 media_kit
      // 移动默认 300ms，显式写出后改一处全部跟随）。
      controlsTransitionDuration: _videoControlsTransitionDuration,
      // TODO-364：移动控制条的真实 `visible`（含 onTap toggle）推进同一个 notifier，字幕避让
      // 唯一消费它，移动端不再用 Hibiki 镜像独立 toggle（旧实现并发操作时方向反 = 本 BUG 根因）。
      visibilityNotifier: _mediaKitControlsVisible,
      // TODO-565：进度条（seek bar）经 media_kit 内部 player.seek 绕过 controller 的
      // seekMs 统一清除点，用户开始拖动时清掉「主动跳转目标」快照——否则点字幕行后
      // 的在途 seek 宽限窗口内拖进度条到更早句，会被误 snap 回旧目标句。fork 的 seek
      // bar 把内部 onSeekStart 与本回调合并调用（third_party/media_kit_video）。
      onSeekStart: () => controller.clearSeekTargetSnap(),
      // TODO-057: 启用 media_kit 移动控制条内建的「左半区竖滑调亮度 / 右半区竖滑
      // 调音量」手势，指示器由 Hibiki 的左右百分比 HUD 接管。仅移动端有此控制条；桌面走
      // [_desktopControlsTheme]（无此手势，屏幕亮度本就不可控，诚实降级）。不开
      // seekGesture（横滑 seek 超范围，且与既有 seek 键 085/090 / 双击全屏语义重叠）。
      // 单击暂停 / 字幕点击查词不受影响：media_kit 的竖直 drag 与 tap 同一手势 arena，
      // 纯点击时 drag 不启动。亮度回调经 [ScreenBrightnessController]（桌面 no-op）。
      volumeGesture: true,
      volumeIndicatorBuilder: (BuildContext _, double __) =>
          const SizedBox.shrink(),
      brightnessGesture: _brightness.canControl,
      brightnessIndicatorBuilder: (BuildContext _, double __) =>
          const SizedBox.shrink(),
      // 竖滑灵敏度降到约 1/3（TODO-172/BUG-230）：media_kit 默认 100 太敏感，轻划即
      // 拉满亮度/音量。值越大越不敏感（见 [_videoVerticalGestureSensitivity]）。
      verticalGestureSensitivity:
          _VideoHibikiPageState._videoVerticalGestureSensitivity,
      seekGesture: false,
      onVolumeChanged: _onMediaKitVolumeChanged,
      onBrightnessChanged: _onMediaKitBrightnessChanged,
      initialVolume: (controller.volume / 100.0).clamp(0.0, 1.0).toDouble(),
      initialBrightness: _enterBrightness,
      onBrightnessReset: () =>
          unawaited(_brightness.restore(previous: _enterBrightness)),
      // 进度条抬到按钮条上方（TODO-156）：bottom = 按钮条基线 + 按钮条高 + 间距，
      // 不再与按钮条同基线重叠。
      seekBarMargin: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: seekBarBottom,
      ),
      // 底部按钮条留在系统栏上方基线（沿用 media_kit 默认的左右 16/8）。
      bottomButtonBarMargin: EdgeInsets.only(
        left: 16,
        right: 8,
        bottom: bottomChromeInset,
      ),
      // 进度条触摸热区 / 滑块 / 轨道整体抬高（TODO-157/BUG-218）：media_kit 默认
      // seekBarContainerHeight=36 / seekBarThumbSize=12.8 / seekBarHeight=2.4 在手机上
      // 太细、难命中（手指比默认热区窄，滑不到 / 拖不动）。改用随界面缩放的基线放大
      // 命中区与可视轨道。三者由 [_videoSeekBarButtonGap] 把进度条整体抬到按钮条上方
      // 后才有竖直空间承接更高的热区（向上长，不向下侵入系统边缘手势区）。
      seekBarContainerHeight: _videoSeekBarContainerHeight,
      seekBarThumbSize: _videoSeekBarThumbSize,
      seekBarHeight: _videoSeekBarTrackHeight,
      seekBarPositionColor: cs.primary,
      seekBarThumbColor: cs.primary,
      buttonBarButtonColor: cs.primary,
      buttonBarHeight: _videoButtonBarHeight,
      buttonBarButtonSize: _videoControlIconSize,
      primaryButtonBar: const <Widget>[],
      // 视频内顶栏（替代被删的 Scaffold AppBar，BUG-102）：左右按钮和标题均从用户布局
      // slot 渲染；标题仍监听 _titleNotifier。
      topButtonBar: <Widget>[
        _topBarSlotGroup(
          VideoControlSlot.topLeft,
          controller,
          layout: layout,
          desktop: false,
        ),
        _topBarTitle(),
        _topBarSlotGroup(
          VideoControlSlot.topRight,
          controller,
          layout: layout,
          desktop: false,
        ),
      ],
      bottomButtonBar: <Widget>[
        // 三区 Stack 布局把 play 钉在几何中心（BUG-257）：左时间 / 右尾部按钮 / 居中
        // seek 簇，与桌面同源（[_centeredBottomControlBar]）。±10s 带可见标注、5 键带
        // Tooltip（BUG-247）、上/下一句走动态 cue 导航（无字幕段对称回退/前进，TODO-073/
        // TODO-119/BUG-198，动态 _asbConfig.seekSeconds 不写死）均在 helper 内保留。
        Expanded(
          child: _centeredBottomControlBar(controller, desktop: false),
        ),
      ],
    );
  }
}
