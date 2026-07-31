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
/// `_centeredBottomControlBar`, `_videoBottomSystemInset`, `_videoTopBarMargin`)
/// and stays bare,
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
      // BUG-796 后续：进度条拖动/点击落点经 media_kit 内部 player.seek 绕过 controller.seekMs
      // 的「权威同步 + 在途抑制」——暂停态拖到无字幕段旧字幕不消失（同 ±秒键根因）。fork 在
      // onSeekEnd 透出落点 target，页面补调 notifyExternalSeek 应用同款保护（不重复 seek）。
      onSeekEnd: (Duration target) =>
          controller.notifyExternalSeek(target.inMilliseconds),
      // TODO-669：进度条 hover 缩略图预览。seek bar hover 时 fork 把 hover 比例
      // （轨道内宽权威值）回调给 [_onSeekBarHover]，桌面转发到取帧调度器、移动端不接
      // （触屏无 hover，故仅桌面 theme 接线）。null 时 fork 零行为变化。
      onHoverPosition: _onSeekBarHover,
      // 控制条隐藏时一并隐藏鼠标光标（默认 false 会让光标常驻，BUG-106）。
      // BUG-391「管 1」（源头层，机理最硬）：字幕跳转列表侧栏开启时禁用本隐藏。机制——
      // fork material_desktop.dart:746-750 的控制条 MouseRegion 在 `mount=false`（控制条隐藏）
      // 时取 `cursor:none` 分支、否则 `basic`（走 MouseTracker，几何只覆盖视频列 Expanded）；
      // hideMouseOnControlsRemoval 翻 false 后，列表开态视频列 controls MouseRegion 恒走 basic
      // 分支、视频列光标从未隐藏 → 鼠标跨进侧栏前那次 none→basic 转换根本不存在 → 从源头消除
      // #84039 竞态来源（不是缩小窗口）。**这是框架层 MouseRegion，不是 native SetCursor**。
      // r5：选集列表 [_episodeListVisible] 与字幕列表同为 push-aside 侧栏（[_videoWithSubtitlePanel]
      // 的 Row 兄弟列），机理完全相同 → 必须一并排除，否则切到选集列表时视频列 controls MouseRegion
      // 仍走 cursor:none 分支、跨列 none→basic 竞态复现（此前只排除字幕列表 = 选集列表光标照样隐藏）。
      // ⚠️ 防哑火：本值依赖 [_subtitleListVisible] / [_episodeListVisible]，但构造本 theme 的 builder
      // （layout.part.dart :_buildVideoControlsInner）必须同时监听这两个 notifier、否则其翻转时 theme
      // 不重建 = 改了值也白改（见 layout.part.dart 的 ListenableBuilder.merge）。仅桌面 theme，移动端不动。
      hideMouseOnControlsRemoval:
          !(_subtitleListVisible.value || _episodeListVisible.value),
      // 单击画面 = 播放/暂停（media_kit 桌面默认 false，故此前点画面毫无反应，
      // BUG-130）。字幕字符点击在更上层 [VideoSubtitleOverlay] 的 opaque GestureDetector
      // 独立处理、不会冒泡到这里，故启用后点字幕仍是查词、点空白区才暂停，不冲突。
      playAndPauseOnTap: true,
      toggleFullscreenOnDoublePress: false,
      // 播放器 chrome 前景固定亮色（UI 巡检 PR-4 P1）：控制条压在 fork 固定深色
      // scrim（material_desktop.dart 0x61000000）上，表面固定深色 OSD 体系不随
      // colorScheme——此前 cs.primary 在浅色 / eink 主题下是深色，黑压黑不可读。
      // [_videoChromeAccent] 恒取亮 tone primary，深色主题取值与旧实现一致。
      seekBarPositionColor: _videoChromeAccent(cs),
      seekBarThumbColor: _videoChromeAccent(cs),
      buttonBarButtonColor: _videoChromeAccent(cs),
      buttonBarHeight: _videoButtonBarHeight,
      buttonBarButtonSize: _videoControlIconSize,
      // BUG-1224：进度条触摸热区高与「骑按钮行上沿的下压量」显式传入（取值 = fork 原本
      // 的默认 36 / 16，桌面渲染逐像素不变）。目的是让**控制条实际布局**与**字幕避让计算**
      // 读同一份常量：此前避让只让出一个按钮行高，而热区上缘其实还高出 36−16=20px，字幕
      // 恰好压住那条带 → 点进度条上缘被字幕 glyph 命中层吸走成查词（seek 收不到指针）。
      seekBarContainerHeight:
          _VideoHibikiPageState._videoDesktopSeekBarContainerHeight,
      seekBarBottomButtonBarOverlap:
          _VideoHibikiPageState._videoDesktopSeekBarButtonBarOverlap,
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
      // TODO-1059：把重启自动隐藏计时的信号接进 fork。fork 侧订阅它，在底部按钮栏
      // play / 快进 / 快退按下（经 [_pokeControlsVisible] → [_restartHideTimerSignal.poke]）
      // 时于控制条可见态续命隐藏 Timer，消除「按着按钮控制条却自动隐藏 → 手指落到画面
      // 误触」。仅移动 theme 需要（桌面走合成 hover 经 media_kit 自身 MouseRegion 续命）。
      restartHideTimerSignal: _restartHideTimerSignal,
      // TODO-565：进度条（seek bar）经 media_kit 内部 player.seek 绕过 controller 的
      // seekMs 统一清除点，用户开始拖动时清掉「主动跳转目标」快照——否则点字幕行后
      // 的在途 seek 宽限窗口内拖进度条到更早句，会被误 snap 回旧目标句。fork 的 seek
      // bar 把内部 onSeekStart 与本回调合并调用（third_party/media_kit_video）。
      onSeekStart: () => controller.clearSeekTargetSnap(),
      // BUG-796 后续（同桌面 theme）：进度条落点补调 notifyExternalSeek，暂停态拖到无字幕段
      // 旧字幕立即消失、不被滞后旧 position 拉回；不重复 seek（进度条内部已 seek）。
      onSeekEnd: (Duration target) =>
          controller.notifyExternalSeek(target.inMilliseconds),
      // TODO-057: 启用 media_kit 移动控制条内建的「左半区竖滑调亮度 / 右半区竖滑
      // 调音量」手势，指示器由 Hibiki 的左右百分比 HUD 接管。仅移动端有此控制条；桌面走
      // [_desktopControlsTheme]（无此手势，屏幕亮度本就不可控，诚实降级）。横滑 seek
      // 见下方 [seekGesture]（TODO-916 症状①，按时长比例换算 + 居中 HUD 显目标绝对
      // 时间；与既有 seek 键 085/090 / 双击全屏语义并存，竞技场先达成者胜）。
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
      // TODO-916 症状①：启用 fork 内置横滑 seek（third_party/media_kit_video 的
      // MaterialVideoControls.onHorizontalDragUpdate/End）：按 [position + diff *
      // duration / horizontalGestureSensitivity] 换算目标、松手 player.seek，拖回
      // 原点（swipeDuration==0）自动取消。仅移动端 theme 启用；桌面
      // [_desktopControlsTheme] 不含此字段（鼠标拖进度条 + 键盘 seek 键，诚实降级）。
      seekGesture: true,
      horizontalGestureSensitivity:
          _VideoHibikiPageState._videoHorizontalGestureSensitivity,
      // 居中 HUD：fork 默认只显增量，这里替换成「目标绝对时间 + 增量」两行（主流
      // 播放器手感）。builder 每帧随拖动重建，读 controller 实时 position + 增量算
      // 目标时间（clamp [0,duration]）。delta 为 fork 回传的有符号 swipeDuration。
      seekIndicatorBuilder: (BuildContext context, Duration delta) =>
          _buildSeekIndicator(controller, delta),
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
      // chrome 前景固定亮色（同桌面 theme，UI 巡检 PR-4 P1）：压固定深色 scrim
      // （material.dart 0x66000000），不随 colorScheme。
      seekBarPositionColor: _videoChromeAccent(cs),
      seekBarThumbColor: _videoChromeAccent(cs),
      buttonBarButtonColor: _videoChromeAccent(cs),
      buttonBarHeight: _videoButtonBarHeight,
      buttonBarButtonSize: _videoControlIconSize,
      primaryButtonBar: const <Widget>[],
      // 视频内顶栏抬离状态栏 / 刘海（BUG-463）：移动端视频永不进 media_kit 全屏路由
      // （BUG-221），fork 只在全屏分支给顶栏套 `MediaQuery.padding` 顶部内缩、窗口分支恒
      // `EdgeInsets.zero` → 顶栏按钮永远贴 y=0 被系统栏 / 刘海盖住。这里把系统顶部 / 左 / 右
      // inset 补进 `topButtonBarMargin`（[_videoTopBarMargin]），与底栏 `bottomButtonBarMargin`
      // 的 [_videoBottomSystemInset] 对称。仅移动端 theme；桌面 theme 不含本字段、无系统栏。
      topButtonBarMargin: _videoTopBarMargin(),
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

  /// TODO-916 症状①：横滑 seek 居中 HUD（替换 fork 默认只显增量的 HUD）。
  ///
  /// fork 的 `seekIndicatorBuilder` 只回传增量 [delta]（有符号 swipeDuration）。主流
  /// 播放器横滑时显示**目标绝对时间**，故这里读 [controller] 实时位置/时长，经纯函数
  /// [VideoSeekIndicatorLabel.target] /
  /// [VideoSeekIndicatorLabel.deltaSigned] 算出「目标时间」与「±增量」
  /// 两行。fork 把本 widget 套在居中 `IgnorePointer + AnimatedOpacity` 里，故这里只画
  /// 圆角半透明盒，不再处理定位/淡入淡出。
  Widget _buildSeekIndicator(
    VideoPlayerController controller,
    Duration delta,
  ) {
    final Duration position =
        Duration(milliseconds: controller.positionMs ?? 0);
    final Duration duration =
        Duration(milliseconds: controller.durationMs ?? 0);
    final String targetLabel =
        VideoSeekIndicatorLabel.target(position, delta, duration);
    final String deltaLabel = VideoSeekIndicatorLabel.deltaSigned(delta);
    // UI 巡检 PR-4：HUD 表面 / 前景与页内其余 OSD 同源（[_osdSurfaceColor] /
    // [_osdTextColor]，inverseSurface 自配对），字号 / 内边距吃 [_videoUiScale]
    // ——此前硬编码 0xCC000000 / 白 / 22px，是页内唯一不吃缩放的 OSD。
    final ColorScheme cs = _videoChromeColorScheme(context);
    final Color textColor = _osdTextColor(cs);
    final double scale = _videoUiScale;
    return Container(
      alignment: Alignment.center,
      padding:
          EdgeInsets.symmetric(horizontal: 20 * scale, vertical: 12 * scale),
      decoration: BoxDecoration(
        color: _osdSurfaceColor(cs),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            targetLabel,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22 * scale,
              fontWeight: FontWeight.w600,
              color: textColor,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            deltaLabel,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14 * scale,
              color: textColor.withValues(alpha: 0.8),
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
