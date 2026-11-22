// GENERATED-NOTE: extracted from video_fushi_page.dart (TODO-590 batch7).
part of '../video_fushi_page.dart';

/// Volume + OSD / level-HUD / brightness domain methods extracted via part-of
/// (TODO-590 batch7); shared private scope. Behaviour-preserving: bodies are
/// verbatim except (a) the bare `static const _volumeStep` reference inside
/// [_onVolumeWheel] is fully qualified through `_VideoFushiPageState.` — an
/// extension cannot resolve a host class's private static by bare name, so the
/// qualification is mandatory and otherwise byte-exact; and (b) the lone
/// `setState(() {})` rebuild inside [_ensureEnterBrightness] is routed through
/// the main shell's `_rebuild(...)` forwarder (the established part paradigm for
/// touching `setState`). Everything else is moved character-for-character.
///
/// The `_volumeStep` static, all instance fields/notifiers
/// (`_osdNotifier` / `_osdTimer` / `_levelHudNotifier` / `_levelHudTimer` /
/// `_volumeDisplay` / `_playbackVolume` / `_pendingVolumePersist` /
/// `_volumePersistDebounce` / `_enterBrightness` / `_brightness`), the
/// top-level private types (`_VideoOsdMessage` / `_VideoLevelHudKind` /
/// `_VideoLevelHudState`) and the chrome helper getters/methods
/// (`_videoChromeColorScheme` / `_osdSurfaceColor` / `_osdTextColor` /
/// `_videoUiScale`) stay in the main shell; the extension reads/calls them
/// through the shared private scope.
/// 突出 OSD（制卡结果）的停留时长；结果卡的倒计时条按它耗尽。
const Duration _kProminentOsdDuration = Duration(milliseconds: 3600);

extension _VideoVolumeOsd on _VideoFushiPageState {
  /// 在视频左上角短暂显示一条 OSD 通知（约 2.6s 后自动消失）。mounted-safe，可在
  /// `await` 之后直接调（取代各处 `ScaffoldMessenger.showSnackBar`）。
  void _showOsd(
    String message, {
    IconData? icon,
    double? progress,
    bool prominent = false,
    ToastSeverity severity = ToastSeverity.neutral,
  }) {
    if (!mounted) return;
    _osdNotifier.value = _VideoOsdMessage(
      message: message,
      icon: icon,
      progress: progress?.clamp(0.0, 1.0).toDouble(),
      prominent: prominent,
      severity: severity,
    );
    _osdTimer?.cancel();
    // TODO-971：突出 OSD（制卡成功）停留更久，普通通知仍 2.6s；带「撤销」按钮的
    // 再久一点，留出去点的时间。
    _osdTimer = Timer(
      prominent ? _kProminentOsdDuration : const Duration(milliseconds: 2600),
      () {
        _osdNotifier.value = null;
      },
    );
  }

  /// 制卡结果的 OSD 出口：先过「制卡提示」开关（[MineNotices.shown]，与底部制卡
  /// toast 同一个裁决点），再进左上角的制卡结果队列（[_mineNotices]，与底部 toast
  /// 同一个 [FushiMineNoticeStack]：处理中原地变成结果、连续几张叠起来）。视频页所有
  /// 制卡结果（成功 / 重复 / 待发 / 失败）都从这里出，不许直接 [_showOsd]（守卫
  /// `test/anki/mine_notice_single_exit_guard_test.dart`）。
  ///
  /// [term] / [reading] / [detail]：卡片第一行的词与第二行的短说明（见
  /// [FushiMineNoticeCard]）。
  ///
  /// [undo]（反馈 JNyykxvuY9）：新制成功时卡片上出「撤销」，点下收起这张、删卡，
  /// 结局再用一条普通 OSD 说出来（视频页不走底部 toast，BUG-931）。
  ///
  /// [retry]（反馈 OeS0m8tLHc）：不陪等的制卡失败时卡片上出「重试」，点下收起这张、
  /// 用那一次冻结的输入重跑。与 [undo] 互斥（成功才有撤销、失败才有重试）。
  void _showMineOsd(
    String message,
    MineToastStatus status, {
    MinedCardUndo? undo,
    VoidCallback? retry,
    String? term,
    String? reading,
    String? detail,
  }) {
    if (!MineNotices.shown(status)) return;
    if (!mounted) return;
    _mineNotices.show(
      MineNotice(
        status: status,
        message: message,
        term: term,
        reading: reading,
        detail: detail,
        action: retry != null
            ? MineNoticeAction(label: t.card_notice_retry, onPressed: retry)
            : undo == null
            ? null
            : MineNoticeAction(
                label: t.card_notice_undo,
                onPressed: () async {
                  final MinedCardDeleteResult result = await undo.run();
                  _showOsd(
                    minedCardDeleteResultText(result),
                    severity: minedCardDeleteResultSeverity(result),
                  );
                },
              ),
      ),
    );
  }

  /// 顶部浮层（OSD、制卡结果、右上角角标、字幕转文字进度卡）离安全区顶边多远：
  /// 顶栏显示时落在顶栏下沿下方，收起时贴到安全区顶端（用户 2026-11-22：此前恒为
  /// 「顶栏高 + 8」，顶栏收起后照样空着那段）。与底部 toast 同一个纯函数
  /// [noticeTopOffset]；顶栏是 media_kit 内部控件包不进 [FushiNoticeObstacle]，这里
  /// 给出合成的顶栏矩形与显隐进度（[presence] 0..1）。
  double _videoTopChromeInset(double presence) => noticeTopOffset(
    fallback: kNoticeChromeGap * _videoUiScale,
    obstacles: <NoticeObstacle>[
      (
        edge: NoticeObstacleEdge.top,
        rect: Rect.fromLTWH(0, 0, 1, _videoButtonBarHeight),
        presence: presence,
      ),
    ],
    laneLeft: 0,
    laneRight: 1,
    gap: 8 * _videoUiScale,
  );

  /// 跟着顶栏显隐算顶部浮层的上边距：显隐进度与控制条同速过渡
  /// （[_videoControlsTransitionDuration]），浮层随顶栏平滑上下，不跳。
  Widget _followTopChrome(
    Widget Function(BuildContext context, double top) builder,
  ) {
    return ValueListenableBuilder<bool>(
      valueListenable: _videoControlsVisible,
      builder: (BuildContext context, bool visible, Widget? _) =>
          TweenAnimationBuilder<double>(
            tween: Tween<double>(end: visible ? 1 : 0),
            duration: _videoControlsTransitionDuration,
            curve: FushiMotion.standard,
            builder: (BuildContext context, double presence, Widget? _) =>
                builder(context, _videoTopChromeInset(presence)),
          ),
    );
  }

  /// 音量上限（百分比）：随 controller 的 [VideoPlayerController.maxVolume]（mpv 配置
  /// 「音量上限」100 / 150 / 200；网页后端恒 100）。滑条、HUD、手势与持久化同一口径。
  double get _maxVideoVolume => _controller?.maxVolume ?? 100.0;

  /// 滑条拖动写音量：即时写 controller + OSD + 同步显示真相源（TODO-377）。
  void _setVolumeFromSlider(double value) {
    final double next = value.clamp(0.0, _maxVideoVolume).toDouble();
    unawaited(_applyUserVideoVolume(next));
  }

  /// 桌面：悬停音量控件时滚轮调音量（向上滚增、向下滚减，[_volumeStep] 步进）。滚轮
  /// 的 [scrollDelta] 向下为正，故取负号让「上滚 = 增大」符合直觉。
  void _onVolumeWheel(VideoPlayerController controller, double scrollDeltaY) {
    final double delta = scrollDeltaY > 0
        ? -_VideoFushiPageState._volumeStep
        : _VideoFushiPageState._volumeStep;
    unawaited(_adjustVolume(delta));
  }

  /// 同步音量显示真相源（[_volumeDisplay]）→ 驱动音量图标与浮层滑条重建。
  /// 所有改音量入口（滑条 / 滚轮 / 键盘音量键 / 静音切换 / media_kit 移动竖滑）统一调它。
  void _syncVolumeDisplay(double volume) {
    _volumeDisplay.value = volume.clamp(0.0, _maxVideoVolume).toDouble();
  }

  /// 应用一次用户真实音量变化。默认持久化；M 静音传 [persist]=false，只更新显示和 HUD。
  Future<void> _applyUserVideoVolume(
    double volume, {
    bool persist = true,
    bool applyToController = true,
  }) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final double clamped = volume.clamp(0.0, controller.maxVolume).toDouble();
    _syncVolumeDisplay(clamped);
    if (mounted) _showVolumeOsd(clamped);
    if (applyToController) {
      await controller.setVolume(clamped);
    }
    if (persist) {
      _playbackVolume = clamped;
      _queuePersistVideoVolume(clamped);
    }
  }

  void _queuePersistVideoVolume(double volume) {
    _pendingVolumePersist = volume.clamp(0.0, _maxVideoVolume).toDouble();
    _volumePersistDebounce?.cancel();
    _volumePersistDebounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_flushPersistedVideoVolume());
    });
  }

  Future<void> _flushPersistedVideoVolume() async {
    final double? pending = _pendingVolumePersist;
    if (pending == null) return;
    _volumePersistDebounce?.cancel();
    _volumePersistDebounce = null;
    _pendingVolumePersist = null;
    await appModel.prefsRepo.setPref(_volumePrefKey, pending);
  }

  /// 键盘音量键 / 滚轮调音量：交给 controller 的 [VideoPlayerController.adjustVolume]
  /// 算（base = 静音时 0，否则当前有效音量），用其**返回的确定新音量**刷新 OSD/显示，
  /// 不再自己 `controller.volume + delta`（[VideoPlayerController.volume] 读 libmpv
  /// 异步滞后的 `state.volume`，这条歧义路径会让连续按键叠加在旧值上，TODO-433）。
  Future<void> _adjustVolume(double delta) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final double next = await controller.adjustVolume(delta);
    await _applyUserVideoVolume(next);
  }

  /// 静音切换：用 controller 的 [VideoPlayerController.toggleMute] **返回的确定目标音量**
  /// 刷新 OSD/底栏图标/滑条——取消静音返回静音前音量、静音返回 0。不再读
  /// [VideoPlayerController.volume]（取消静音那一帧 libmpv 的 `state.volume` 仍是 0，
  /// 读它会让显示卡在 0、恢复不了音量，正是 TODO-433 bug2）。
  Future<void> _toggleMute() async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final double next = await controller.toggleMute();
    await _applyUserVideoVolume(next, persist: false, applyToController: false);
  }

  void _showLevelHud(_VideoLevelHudKind kind, double value) {
    if (!mounted) return;
    final double max = kind == _VideoLevelHudKind.rightVolume
        ? _maxVideoVolume
        : 100.0;
    final double clamped = value.clamp(0.0, max).toDouble();
    _levelHudNotifier.value = _VideoLevelHudState(kind: kind, value: clamped);
    _levelHudTimer?.cancel();
    _levelHudTimer = Timer(const Duration(milliseconds: 1600), () {
      if (!mounted) return;
      _levelHudNotifier.value = null;
    });
  }

  void _showVolumeOsd(double volume) {
    _showLevelHud(_VideoLevelHudKind.rightVolume, volume);
  }

  void _showBrightnessOsd(double brightness) {
    _showLevelHud(_VideoLevelHudKind.leftBrightness, brightness);
  }

  /// media_kit 移动控制条的「右半区竖滑调音量」回调（TODO-057）。media_kit
  /// 已做好区域判定、逐帧累积与 clamp，传入 [value] 为 0..1。我们只把它转成现有
  /// 音量通道的 0..[_maxVideoVolume]（满程 = 音量上限）并复用 [VideoPlayerController.setVolume]——与 TODO-044 方向键
  /// 音量、音量条 UI 同一条 setter，不另开并行状态。可见反馈由页面级 level HUD 接管；
  /// media_kit 内部 indicator builder 仅返回空占位，避免 200ms 内部动画与页面 HUD 叠影。
  void _onMediaKitVolumeChanged(double value) {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final double pct = (value.clamp(0.0, 1.0) * _maxVideoVolume).toDouble();
    unawaited(_applyUserVideoVolume(pct));
  }

  /// media_kit 移动控制条的「左半区竖滑调屏幕亮度」回调（TODO-057）。[value] 为
  /// 0..1，经 [ScreenBrightnessController] 写设备背光（Android 窗口级 / iOS 系统级）。
  /// 桌面 [ScreenBrightnessController.canControl] 为 false → 静默 no-op（且我们不在
  /// 桌面控制条启用该手势，见 [_desktopControlsTheme] 不传回调），诚实降级。
  void _onMediaKitBrightnessChanged(double value) {
    if (!_brightness.canControl) return;
    final double clamped = value.clamp(0.0, 1.0).toDouble();
    _showBrightnessOsd(clamped * 100.0);
    unawaited(_brightness.setBrightness(clamped));
  }

  /// 进入视频时取一次系统屏幕亮度快照（移动端）作为亮度手势初值与退出还原值；
  /// 退出（[dispose]）把它写回，防止把用户系统亮度永久留在拖动后的值。
  Future<void> _ensureEnterBrightness() async {
    if (_enterBrightness != null || !_brightness.canControl) return;
    final double? current = await _brightness.currentBrightness();
    if (current == null) return;
    _enterBrightness = current;
    // 重建让 [_mobileControlsTheme] 把真实 initialBrightness 喂给 media_kit，
    // 否则首次亮度拖动会从其默认 0.5 起跳（而非用户当前实际亮度）。
    if (mounted) _rebuild(() {});
  }

  Widget _buildRightVolumeIndicator(double volume) {
    final ColorScheme cs = _videoChromeColorScheme(context);
    final double max = _maxVideoVolume;
    final double clamped = volume.clamp(0.0, max).toDouble();
    final Color textColor = _osdTextColor(cs);
    final double scale = _videoUiScale;
    return IgnorePointer(
      child: VideoLevelHudCard(
        value: clamped,
        maximum: max,
        uiScale: scale,
        icon: _volumeIconFor(clamped),
        alignment: Alignment.centerRight,
        minimum: EdgeInsets.only(
          left: 16,
          top: 16,
          right: 76 * scale,
          bottom: 16,
        ),
        surfaceColor: _osdSurfaceColor(cs),
        textColor: textColor,
        shadowColor: cs.shadow,
        frameKey: videoVolumeHudFrameKey,
        progressKey: videoVolumeHudProgressKey,
      ),
    );
  }

  Widget _buildLeftBrightnessIndicator(double brightness) {
    final ColorScheme cs = _videoChromeColorScheme(context);
    final double clamped = brightness.clamp(0.0, 100.0).toDouble();
    final Color textColor = _osdTextColor(cs);
    final double scale = _videoUiScale;
    return IgnorePointer(
      child: VideoLevelHudCard(
        value: clamped,
        uiScale: scale,
        icon: _brightnessIconFor(clamped),
        alignment: Alignment.centerLeft,
        minimum: EdgeInsets.only(
          left: 76 * scale,
          top: 16,
          right: 16,
          bottom: 16,
        ),
        surfaceColor: _osdSurfaceColor(cs),
        textColor: textColor,
        shadowColor: cs.shadow,
        frameKey: videoBrightnessHudFrameKey,
        progressKey: videoBrightnessHudProgressKey,
      ),
    );
  }

  Widget _buildLevelHudOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        child: ValueListenableBuilder<_VideoLevelHudState?>(
          valueListenable: _levelHudNotifier,
          builder: (BuildContext _, _VideoLevelHudState? hud, __) {
            return AnimatedSwitcher(
              // eink 下归零（墨水屏残影，UI 巡检 PR-4）。
              duration: einkSafeDuration(
                context,
                const Duration(milliseconds: 160),
              ),
              child: hud == null
                  ? const SizedBox.shrink()
                  : switch (hud.kind) {
                      _VideoLevelHudKind.leftBrightness =>
                        _buildLeftBrightnessIndicator(hud.value),
                      _VideoLevelHudKind.rightVolume =>
                        _buildRightVolumeIndicator(hud.value),
                    },
            );
          },
        ),
      ),
    );
  }

  /// mpv 式左上角 OSD 通知层。普通 OSD（监听 [_osdNotifier]）淡入一条圆角半透明
  /// 提示，2.6s 后自动淡出，[IgnorePointer]，从不拦截点击（单击暂停 / 拖放 / 字幕
  /// 查词都不受影响）。其下是制卡结果队列（[_mineNotices]，小号卡）：只有卡片本身
  /// 吃指针（撤销 / 重试 / 悬停暂停）。整层跟着顶栏显隐上下（[_followTopChrome]），
  /// 窗口与全屏复用。
  Widget _buildOsdOverlay() {
    return Positioned.fill(
      child: SafeArea(
        child: _followTopChrome(
          (BuildContext context, double top) => Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: EdgeInsets.only(left: 16, right: 16, top: top),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  ValueListenableBuilder<_VideoOsdMessage?>(
                    valueListenable: _osdNotifier,
                    builder: (BuildContext _, _VideoOsdMessage? osd, __) {
                      return IgnorePointer(
                        child: AnimatedSwitcher(
                          // eink 下归零（墨水屏残影，UI 巡检 PR-4）。
                          duration: einkSafeDuration(
                            context,
                            const Duration(milliseconds: 180),
                          ),
                          // M3E 进场（与底部 FushiToast 同一手感）：淡入 + 从左上角
                          // 锚点由 0.86 弹到 1（spatialFast 带一点过冲）；退场反向。
                          transitionBuilder:
                              (Widget child, Animation<double> animation) {
                                return FadeTransition(
                                  opacity: CurvedAnimation(
                                    parent: animation,
                                    curve: FushiMotion.enter,
                                    reverseCurve: FushiMotion.exit,
                                  ),
                                  child: ScaleTransition(
                                    alignment: Alignment.topLeft,
                                    scale: Tween<double>(begin: 0.86, end: 1)
                                        .animate(
                                          CurvedAnimation(
                                            parent: animation,
                                            curve: FushiMotion.release,
                                            reverseCurve: FushiMotion.exit,
                                          ),
                                        ),
                                    child: child,
                                  ),
                                );
                              },
                          child: osd == null
                              ? const SizedBox.shrink()
                              : Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: _buildOsdCard(osd),
                                ),
                        ),
                      );
                    },
                  ),
                  FushiMineNoticeStack(
                    controller: _mineNotices,
                    anchor: MineNoticeStackAnchor.top,
                    compact: true,
                    maxWidth: math.min(
                      360,
                      MediaQuery.sizeOf(context).width - 32,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// TODO-1154：长按倍速跟随徽章层。监听 [_longPressSpeedBadge]，非空时在长按/拖动指针
  /// 上方渲染一枚「Nx」圆角徽章跟手移动（B 站/YouTube 长按倍速气泡观感），松手清空。
  /// 位置用 `details.localPosition`（与本 Stack 同坐标系），[FractionalTranslation] 把徽章
  /// 水平居中于指针、并整体上移一个多身位避免被手指/光标遮挡。[IgnorePointer] 纯视觉，不
  /// 拦长按拖动手势本身。**不**复用钉死左上角的 [_buildOsdOverlay]。
  Widget _buildLongPressSpeedBadgeOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        child: ValueListenableBuilder<({Offset position, double speed})?>(
          valueListenable: _longPressSpeedBadge,
          builder:
              (BuildContext _, ({Offset position, double speed})? badge, __) {
                if (badge == null) return const SizedBox.shrink();
                final ColorScheme cs = _videoChromeColorScheme(context);
                return Stack(
                  children: <Widget>[
                    VideoLongPressSpeedBadge(
                      position: badge.position,
                      speed: badge.speed,
                      surfaceColor: _osdSurfaceColor(cs),
                      textColor: _osdTextColor(cs),
                    ),
                  ],
                );
              },
        ),
      ),
    );
  }

  // 单条 OSD 卡片（不含定位：左上角锚点与避让顶栏的上边距由 [_buildOsdOverlay] 统一
  // 给）。普通通知是小角标；TODO-971 突出变体用更大字号、更厚卡片醒目区别于音量 /
  // 亮度被动小角标。TODO-1254：任何变体都不居中（居中会遮挡画面、干扰观看）。
  // 制卡结果不走这里，走 [_mineNotices]。
  Widget _buildOsdCard(_VideoOsdMessage osd) {
    final ColorScheme cs = _videoChromeColorScheme(context);
    final bool prominent = osd.prominent;
    // 语义（severity）只落在前置图标上：OSD 压在画面上，整块饱和色既挡视线又和
    // 全应用的 M3E 通知长得不一样。
    final ({Color background, Color foreground, IconData icon})? palette =
        toastSeverityPalette(osd.severity);
    final bool apple = _appleChrome;
    // 图标：调用点给的 > 语义图标（e-ink / 灰阶下形状是唯一区分手段）> 突出变体
    // 的勾。
    final IconData? leadingIcon =
        osd.icon ?? palette?.icon ?? (prominent ? Icons.check_circle : null);
    final double maxWidth = math.min(
      440,
      MediaQuery.sizeOf(context).width - 32,
    );
    if (!apple) {
      // Material：与底部 [FushiToast] 同一副 M3E 通知胶囊（全胶囊 + 语义图标色块），
      // 表面换成播放器浮层色，和顶栏 / 底栏胶囊同一族。M3E 进场：淡入 + 从 0.86
      // 弹到 1（见 [_buildOsdOverlay] 的 transitionBuilder）。
      return FushiToastCapsule(
        key: ValueKey<String>(osd.message),
        message: osd.message,
        icon: leadingIcon,
        severity: osd.severity,
        surfaceColor: _osdSurfaceColor(cs),
        foregroundColor: _osdTextColor(cs),
        progress: osd.progress,
        maxWidth: maxWidth,
      );
    }
    const Color textColor = videoChromeNeutralForeground;
    final Color iconColor = palette != null ? palette.background : textColor;
    final double fontSize = prominent ? 18 : 14;
    final double iconSize = prominent ? 24 : 18;
    final EdgeInsets cardPadding = prominent
        ? const EdgeInsets.symmetric(horizontal: 20, vertical: 14)
        : const EdgeInsets.symmetric(horizontal: 12, vertical: 8);
    final Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (leadingIcon != null) ...<Widget>[
          FushiIcon(leadingIcon, size: iconSize, color: iconColor),
          SizedBox(width: prominent ? 12 : 8),
        ],
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                osd.message,
                style: TextStyle(
                  color: textColor,
                  fontSize: fontSize,
                  fontWeight: prominent ? FontWeight.w600 : FontWeight.normal,
                  height: 1.2,
                ),
              ),
              if (osd.progress != null) ...<Widget>[
                const SizedBox(height: 6),
                SizedBox(
                  width: 112,
                  child: FushiLinearProgressIndicator(
                    value: osd.progress,
                    minHeight: 3,
                    backgroundColor: textColor.withValues(alpha: 0.25),
                    valueColor: AlwaysStoppedAnimation<Color>(textColor),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
    return ConstrainedBox(
      key: ValueKey<String>(osd.message),
      constraints: BoxConstraints(maxWidth: maxWidth),
      // Apple：通知是一枚深色液态玻璃胶囊（iOS 26 系统 HUD），白字；语义色只
      // 上在图标上（玻璃本身不着色），突出变体更大的圆角与内边距不变。
      child: VideoGlassHud(
        radius: prominent ? 20 : 16,
        padding: cardPadding,
        child: content,
      ),
    );
  }

  IconData _volumeIconFor(double volume) {
    if (volume <= 0) return Icons.volume_off;
    if (volume < 50) return Icons.volume_down;
    return Icons.volume_up;
  }

  IconData _brightnessIconFor(double brightness) {
    if (brightness < 33) return Icons.brightness_low;
    if (brightness < 67) return Icons.brightness_medium;
    return Icons.brightness_high;
  }
}
