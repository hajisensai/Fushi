// GENERATED-NOTE: extracted from video_hibiki_page.dart (TODO-590 batch7).
part of '../video_hibiki_page.dart';

/// Volume + OSD / level-HUD / brightness domain methods extracted via part-of
/// (TODO-590 batch7); shared private scope. Behaviour-preserving: bodies are
/// verbatim except (a) the bare `static const _volumeStep` reference inside
/// [_onVolumeWheel] is fully qualified through `_VideoHibikiPageState.` — an
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
extension _VideoVolumeOsd on _VideoHibikiPageState {
  /// 在视频左上角短暂显示一条 OSD 通知（约 2.6s 后自动消失）。mounted-safe，可在
  /// `await` 之后直接调（取代各处 `ScaffoldMessenger.showSnackBar`）。
  void _showOsd(
    String message, {
    IconData? icon,
    double? progress,
    bool prominent = false,
  }) {
    if (!mounted) return;
    _osdNotifier.value = _VideoOsdMessage(
      message: message,
      icon: icon,
      progress: progress?.clamp(0.0, 1.0).toDouble(),
      prominent: prominent,
    );
    _osdTimer?.cancel();
    // TODO-971：突出 OSD（制卡成功）停留更久（3.6s），普通通知仍 2.6s。
    _osdTimer = Timer(
      Duration(milliseconds: prominent ? 3600 : 2600),
      () {
        _osdNotifier.value = null;
      },
    );
  }

  /// 滑条拖动写音量：即时写 controller + OSD + 同步显示真相源（TODO-377）。
  void _setVolumeFromSlider(double value) {
    final double next = value.clamp(0.0, 100.0).toDouble();
    unawaited(_applyUserVideoVolume(next));
  }

  /// 桌面：悬停音量控件时滚轮调音量（向上滚增、向下滚减，[_volumeStep] 步进）。滚轮
  /// 的 [scrollDelta] 向下为正，故取负号让「上滚 = 增大」符合直觉。
  void _onVolumeWheel(VideoPlayerController controller, double scrollDeltaY) {
    final double delta = scrollDeltaY > 0
        ? -_VideoHibikiPageState._volumeStep
        : _VideoHibikiPageState._volumeStep;
    unawaited(_adjustVolume(delta));
  }

  /// 同步音量显示真相源（[_volumeDisplay]）→ 驱动音量图标与浮层滑条重建。
  /// 所有改音量入口（滑条 / 滚轮 / 键盘音量键 / 静音切换 / media_kit 移动竖滑）统一调它。
  void _syncVolumeDisplay(double volume) {
    _volumeDisplay.value = volume.clamp(0.0, 100.0).toDouble();
  }

  /// 应用一次用户真实音量变化。默认持久化；M 静音传 [persist]=false，只更新显示和 HUD。
  Future<void> _applyUserVideoVolume(
    double volume, {
    bool persist = true,
    bool applyToController = true,
  }) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final double clamped = volume.clamp(0.0, 100.0).toDouble();
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
    _pendingVolumePersist = volume.clamp(0.0, 100.0).toDouble();
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
    await _applyUserVideoVolume(
      next,
      persist: false,
      applyToController: false,
    );
  }

  void _showLevelHud(_VideoLevelHudKind kind, double value) {
    if (!mounted) return;
    final double clamped = value.clamp(0.0, 100.0).toDouble();
    _levelHudNotifier.value = _VideoLevelHudState(
      kind: kind,
      value: clamped,
    );
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
  /// 音量通道的 0..100 并复用 [VideoPlayerController.setVolume]——与 TODO-044 方向键
  /// 音量、音量条 UI 同一条 setter，不另开并行状态。可见反馈由页面级 level HUD 接管；
  /// media_kit 内部 indicator builder 仅返回空占位，避免 200ms 内部动画与页面 HUD 叠影。
  void _onMediaKitVolumeChanged(double value) {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final double pct = (value.clamp(0.0, 1.0) * 100.0).toDouble();
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
    final double clamped = volume.clamp(0.0, 100.0).toDouble();
    final Color textColor = _osdTextColor(cs);
    final double scale = _videoUiScale;
    return IgnorePointer(
      child: VideoLevelHudCard(
        value: clamped,
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
              duration: const Duration(milliseconds: 160),
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

  /// mpv 式左上角 OSD 通知层。监听 [_osdNotifier]，非空时淡入一条圆角半透明提示，
  /// 2.6s 后自动淡出。[IgnorePointer] 确保它从不拦截点击（单击暂停 / 拖放 / 字幕
  /// 查词都不受影响）。放在控制条上方一点（避开顶栏返回/标题），窗口与全屏复用。
  Widget _buildOsdOverlay() {
    return Positioned.fill(
      child: SafeArea(
        child: IgnorePointer(
          child: ValueListenableBuilder<_VideoOsdMessage?>(
            valueListenable: _osdNotifier,
            builder: (BuildContext _, _VideoOsdMessage? osd, __) {
              return AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child:
                    osd == null ? const SizedBox.shrink() : _buildOsdCard(osd),
              );
            },
          ),
        ),
      ),
    );
  }

  // 单条 OSD 卡片。普通通知沿用左上角小角标；TODO-971 突出变体（制卡成功）改成
  // 居中、更大字号、更厚卡片，醒目区别于音量/亮度被动小角标。
  Widget _buildOsdCard(_VideoOsdMessage osd) {
    final ColorScheme cs = _videoChromeColorScheme(context);
    final bool prominent = osd.prominent;
    final double fontSize = prominent ? 18 : 14;
    final double iconSize = prominent ? 24 : 18;
    final EdgeInsets cardPadding = prominent
        ? const EdgeInsets.symmetric(horizontal: 20, vertical: 14)
        : const EdgeInsets.symmetric(horizontal: 12, vertical: 8);
    final BorderRadius radius = BorderRadius.circular(prominent ? 12 : 6);
    final AlignmentGeometry alignment =
        prominent ? Alignment.center : Alignment.topLeft;
    final EdgeInsets outerPadding = prominent
        ? const EdgeInsets.all(24)
        : const EdgeInsets.only(left: 16, top: 52);
    return Align(
      alignment: alignment,
      child: Padding(
        padding: outerPadding,
        child: ConstrainedBox(
          key: ValueKey<String>(osd.message),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width - 32,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _osdSurfaceColor(cs),
              borderRadius: radius,
              boxShadow: prominent
                  ? <BoxShadow>[
                      BoxShadow(
                        color: cs.shadow.withValues(alpha: 0.4),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Padding(
              padding: cardPadding,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (osd.icon != null) ...<Widget>[
                    Icon(osd.icon, size: iconSize, color: _osdTextColor(cs)),
                    SizedBox(width: prominent ? 12 : 8),
                  ] else if (prominent) ...<Widget>[
                    Icon(
                      Icons.check_circle,
                      size: iconSize,
                      color: _osdTextColor(cs),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          osd.message,
                          style: TextStyle(
                            color: _osdTextColor(cs),
                            fontSize: fontSize,
                            fontWeight:
                                prominent ? FontWeight.w600 : FontWeight.normal,
                            height: 1.2,
                          ),
                        ),
                        if (osd.progress != null) ...<Widget>[
                          const SizedBox(height: 6),
                          SizedBox(
                            width: 112,
                            child: LinearProgressIndicator(
                              value: osd.progress,
                              minHeight: 3,
                              backgroundColor:
                                  _osdTextColor(cs).withValues(alpha: 0.25),
                              valueColor: AlwaysStoppedAnimation<Color>(
                                _osdTextColor(cs),
                              ),
                            ),
                          ),
                        ],
                      ],
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
