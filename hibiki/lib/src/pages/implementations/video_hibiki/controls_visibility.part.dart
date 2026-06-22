// GENERATED-NOTE: extracted from video_hibiki_page.dart (TODO-590 batch3).
part of '../video_hibiki_page.dart';

/// controls-visibility / hover / poke / autohide domain methods extracted via
/// part-of (TODO-590 batch3); shared private scope. Behaviour-preserving:
/// bodies are verbatim except references to the main shell's `static` members
/// (`_syntheticHoverDevice` / `_videoControlsHoverDuration`) are fully qualified
/// through `_VideoHibikiPageState.` — an extension cannot resolve a host class's
/// private static by bare name, so the qualification is mandatory and otherwise
/// byte-exact. No `setState(` lives in this domain, so no `_rebuild(` forwarding
/// is needed (unlike batch1/batch2). The `static` definitions themselves and the
/// `_videoControlsTransitionDuration` / `_hasVideoOverlay` /
/// `_videoSideActionRailStronglySuppressed` getters stay in the main shell.
extension _VideoControlsVisibility on _VideoHibikiPageState {
  /// 把 media_kit 控制条「唤醒」并重置其自动隐藏计时（BUG-175 ②）。
  ///
  /// 根因：media_kit 的 [MaterialDesktopVideoControls] / [MaterialVideoControls]
  /// 把控制条可见性与隐藏 `Timer`（`controlsHoverDuration`）藏在私有 State 里，**只**
  /// 在鼠标 `MouseRegion.onHover`/`onEnter` 或拖动进度条时重置；键盘快捷键
  /// （上下句快进 / ±秒 seek）与编程 seek 都不触发重置 → 用户一直按键快进，控制条
  /// 仍只活 2 秒就消失，得反复呼出。media_kit 不暴露任何「重置计时」公开 API。
  ///
  /// 这里不绕开症状、而是驱动 media_kit **自己设计的**重置路径：往控制条区域中心派发
  /// 一个合成 [PointerHoverEvent]，命中其 `MouseRegion` → `onHover()` → 重置隐藏
  /// `Timer` 并翻可见。等价于「用户把鼠标移到了控制条上」，与键盘交互语义一致。
  /// 仅桌面有 hover 语义（移动端 controls 用 tap 唤起、各按钮 onPressed 自带反馈，
  /// 无此问题），故仅桌面派发。[_videoControlsContext] 是 controls 子树 context
  /// （全屏复用同一 builder 时为全屏子树），其 RenderBox 即控制条命中区。
  void _pokeControlsVisible() {
    if (!_isDesktopVideoControls) return;
    // 强压制态下不派合成 hover，避免控制条和 rail 被 poke 拉回。
    if (_immersiveLocked.value) return;
    if (_videoSidePanel.value != null) return;
    if (_subtitleListVisible.value) return;
    if (_videoControlEditMode.value) return;
    final BuildContext? ctx = _videoControlsContext;
    if (ctx == null || !ctx.mounted) return;
    final RenderObject? renderObject = ctx.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    final Offset center = renderObject.localToGlobal(
      renderObject.size.center(Offset.zero),
    );
    // ±1px 抖动 x 坐标（TODO-148/BUG-215）：连续派发到同一坐标会被 MouseTracker
    // 去重、media_kit onHover 不再触发；每次翻转让坐标始终变化，强制每次都续命
    // 隐藏定时。1px 仍稳落控制条命中区内。
    _pokeParity = !_pokeParity;
    final Offset pokePosition = Offset(
      center.dx + (_pokeParity ? 1.0 : -1.0),
      center.dy,
    );
    GestureBinding.instance.handlePointerEvent(
      PointerHoverEvent(
        position: pokePosition,
        // 复用一个稳定的合成设备 id，避免与真实鼠标/触控设备冲突。
        device: _VideoHibikiPageState._syntheticHoverDevice,
        kind: PointerDeviceKind.mouse,
      ),
    );
    // 不再在 Hibiki 侧另翻镜像可见性（TODO-364）：刚派发的合成 hover 会命中 media_kit
    // 自己的 MouseRegion → 其 onHover 翻 `visible=true` 并重置 **它唯一的** 隐藏 Timer、
    // 把真实可见性推进 [_mediaKitControlsVisible]，由 [_applyControlsVisibilityFromMediaKit]
    // 派生进 [_videoControlsVisible]。键盘 / seek 唤起控制条时字幕跟着上顶，且与真实控制条
    // 同相位（旧实现这里直接翻镜像 + 另起 Timer 是相位反的根因）。
  }

  void _clearRailHover() {
    if (_railHovered.value) {
      _railHovered.value = false;
    }
  }

  /// 控制条避让可见性的 **唯一派生 / 写入点**（TODO-364）。
  ///
  /// 输入只有两类真相：①media_kit 控制条自己推来的真实可见性
  /// （[_mediaKitControlsVisible]，由 vendored fork 的 `visibilityNotifier` 在每次
  /// `visible` 变化时推送）②Hibiki 侧三个遮挡门控（沉浸锁 [_immersiveLocked] / 侧栏
  /// [_videoSidePanel] / 字幕跳转列表 [_subtitleListVisible]）。门控成立时控制条本被
  /// [IgnorePointer] 挡掉 / 被 overlay 盖住，字幕不该避让 → 强制 false；否则字幕避让恒
  /// 等于真实可见态。任何这五个输入变化都重跑本函数（在 [initState] 订阅），故
  /// [_videoControlsVisible] 永不与真实控制条相位反（消除旧镜像 + 第二个 Timer 的漂移）。
  ///
  /// 同时承接两个跟随控制条显隐的副作用（旧 `_markControlsVisible` 内的逻辑）：
  /// - 门控隐藏控制条时关闭音量 popover（TODO-337，其锚点随控制条消失）；
  /// - OS 光标隐藏（TODO-318 / BUG-258）：控制条不可见且无 overlay → 隐藏画面光标
  ///   （镜像 media_kit `hideMouseOnControlsRemoval`）；可见或有 overlay → 显示。真实鼠标
  ///   移动经 [_handleVideoControlsHover] 仍随时唤回光标，不被本派生压制。
  void _applyControlsVisibilityFromMediaKit() {
    if (!mounted) return;
    // BUG-371：[_subtitleListVisible] 不再纳入门控——字幕跳转列表是 push-aside 侧栏
    // （把画面挤窄到左侧、不遮控制条），开列表时控制条应继续在被挤窄的画面上可见可用，
    // 不像真 overlay（[_videoSidePanel]）那样盖住控制条需强制隐藏。仅沉浸锁 / 真 overlay
    // 面板 / 剧集列表（其 push-aside 但仍占右栏）/ 编辑态压制。
    final bool gated = _immersiveLocked.value ||
        _videoSidePanel.value != null ||
        _episodeListVisible.value ||
        _videoControlEditMode.value;
    final bool visible = !gated && _mediaKitControlsVisible.value;
    _videoControlsVisible.value = visible;
    if (!visible && _videoControlPopover.value != null) {
      _hideControlPopover();
    }
    // 音量 / 倍速轻浮层随控制条整体显隐；控制条消失时锚点也消失，浮层立即关闭。
    // 光标：可见 → 显示；不可见但有 overlay（用户要在 overlay 上操作）→ 显示；不可见且
    // 无 overlay（纯沉浸 / 自动淡出）→ 隐藏（保 BUG-258 / 镜像 hideMouseOnControlsRemoval）。
    _setCursorHidden(!visible && !_hasVideoOverlay);
  }

  /// 收起控制条可见性的兼容入口（TODO-364 后只接受 `false`）。沉浸锁 / 开侧栏 / 开字幕
  /// 列表的调用方在翻转各自门控 [ValueNotifier] 后调本方法，立即重派生
  /// [_videoControlsVisible]（门控订阅本就会触发，但同帧调用确保即时收起、不等微任务）。
  /// 不再接受「乐观翻 true」——可见性由 media_kit 真实态唯一决定（[_pokeControlsVisible]
  /// / 真实 hover 经 media_kit 自己唤起并推送），杜绝旧镜像与真实控制条相位反。
  void _markControlsVisible(bool visible) {
    if (!mounted) return;
    assert(
      !visible,
      '_markControlsVisible 仅用于门控收起（false）；唤起交给 media_kit 真实可见性（TODO-364）',
    );
    _applyControlsVisibilityFromMediaKit();
  }

  /// 桌面鼠标移出视频区：光标交还系统 / 外部（TODO-318）。控制条的隐藏由 media_kit
  /// 自己的 `onExit` 决定并推送 [_mediaKitControlsVisible]，不在 Hibiki 侧另判（TODO-364）。
  void _onVideoControlsHoverExit() {
    if (!mounted) return;
    _setCursorHidden(false);
  }

  bool _isSyntheticControlsHover(PointerEvent event) =>
      event.device == _VideoHibikiPageState._syntheticHoverDevice;

  void _handleVideoControlsHover(PointerEvent event) {
    if (!_isSyntheticControlsHover(event)) {
      // 真实鼠标移动 → 唤回光标（TODO-318）。合成 poke（键盘/seek 续命）不强制显示光标，
      // 否则键盘连按快进会让本该隐藏的光标常驻。沉浸锁态也借此唤回光标找解锁按钮。
      _setCursorHidden(false);
    }
    // 控制条可见性不在此翻（TODO-364）：本 hover 包裹层 `opaque:false`，真实鼠标 hover 会
    // 继续下探命中 media_kit 自己的 MouseRegion → 其 onHover 翻 `visible` 并推送
    // [_mediaKitControlsVisible]，字幕避让由 [_applyControlsVisibilityFromMediaKit] 派生，
    // 与真实控制条同相位。
    _pokeLockButton();
  }

  void _handleVideoControlsHoverExit(PointerEvent event) {
    if (_isSyntheticControlsHover(event)) return;
    _onVideoControlsHoverExit();
  }

  /// 鼠标进 / 出**字幕盒**（BUG-283）。字幕盒覆盖在 media_kit 控制条之上：鼠标停字幕上
  /// 读字 / 查词时，控制条 2s 自动隐藏会让 media_kit 的 `hideMouseOnControlsRemoval` 把
  /// 画面光标隐藏（再叠上 hibiki 顶层 [_cursorHidden] 的 cursor:none）——用户报「鼠标放
  /// 字幕上消失」。hover 字幕时唤回光标（[_setCursorHidden]false 让顶层胜出层让位）并
  /// [_pokeControlsVisible] 续命控制条（避免 media_kit `mount=false` 让它自己的 cursor 置
  /// none）；移出由 media_kit / 自动隐藏定时按既有路径接管，不强制改光标。仅桌面有 OS 光标
  /// 语义，[_setCursorHidden] / [_pokeControlsVisible] 内部已各自桌面门控。
  ///
  /// BUG-391 第三轮注记：对**字幕跳转列表侧栏**而言此 helper 两臂均无效（保留无害）——
  /// ① [_setCursorHidden]`(false)` 只控 [_buildCursorOverlay] 自层 `cursor:none`，几何上
  ///   **不覆盖** push-aside 侧栏，且同值写入被 [ValueNotifier] 去重；
  /// ② [_pokeControlsVisible] 开头 `if (_subtitleListVisible.value) return;` 列表开时早退。
  /// 侧栏 OS 光标真正靠 [_forceRevealOsCursorForPanel] 直发通道重现，别误以为这两臂有用。
  void _handleSubtitleHover(bool hovering) {
    if (!mounted || !hovering) return;
    _setCursorHidden(false);
    _pokeControlsVisible();
  }

  /// 强制让 OS 真光标在侧栏上重现（BUG-391 第三轮根因修复）。
  ///
  /// 根因：从视频画面区（控制条 2s 淡出后 media_kit `hideMouseOnControlsRemoval` 把 OS
  /// 光标 SetCursor(nullptr) 隐藏）移进字幕跳转列表 push-aside 侧栏时，Win embedder 那次
  /// `none→basic` 的 `SetCursor` 在帧序窗口期没生效 / 被 `WM_SETCURSOR` 竞态回退
  /// （Flutter #84039 同类）；而框架 [MouseCursorManager.handleDeviceCursorUpdate] 的
  /// `lastSession == next` 去重会吞掉「再次声明 basic」，纯声明式 `MouseRegion(cursor:
  /// basic)` 救不了（被去重吞）。
  ///
  /// 唯一下手点：直发 `activateSystemCursor` 通道消息，强制 OS 真 `SetCursor(IDC_ARROW)`，
  /// 绕开框架 `lastSession==next` 去重。**双门控**：
  /// ① 仅桌面（[_isDesktopVideoControls]，移动端无 OS 光标语义）；
  /// ② 仅当前光标确为隐藏态（`_cursorHidden.value == true`）才发——否则会压掉 cue 行
  ///   [InkWell] 的手型（click），且与框架 lastSession 去同步（屏幕停 basic、框架记 click）。
  /// 设备 id 与 `kind:'basic'` 与框架 [_SystemMouseCursorSession.activate] 的消息格式一致
  /// （`{'device', 'kind'}`，`SystemMouseCursors.basic.kind == 'basic'`）。
  void _forceRevealOsCursorForPanel(int device) {
    if (!_isDesktopVideoControls) return;
    if (_cursorHidden.value != true) return;
    SystemChannels.mouseCursor.invokeMethod<void>(
      'activateSystemCursor',
      <String, dynamic>{'device': device, 'kind': 'basic'},
    );
  }

  /// 给字幕跳转列表侧栏内容包一层「光标唤回」[MouseRegion]（BUG-391）。
  ///
  /// 根因：字幕列表是 push-aside 侧栏（[_videoWithSubtitlePanel] 的 Row 兄弟列），几何上
  /// 不在视频区 controls 的 cursor:none 胜出层内；但鼠标从画面区（控制条 2s 淡出后
  /// media_kit `hideMouseOnControlsRemoval` + 顶层 [_buildCursorOverlay] 把 OS 光标置
  /// none）移进侧栏时，侧栏没有任何 region 主动唤回光标 / 续命 media_kit 控制条 → 桌面
  /// OS 光标残留隐藏态（与画面字幕盒 BUG-283 同根：cursor:none 胜出 + 缺 hover 唤回）。
  ///
  /// 复用字幕盒同款救场 [_handleSubtitleHover]：鼠标进 / 移动在侧栏上即唤回光标 + 续命
  /// 控制条。`opaque:false`：本层只收 hover、不阻断指针下探（cue 行点击 / 查词 / 滚动
  /// 照常命中下层 [VideoSubtitleJumpPanel]）。仅桌面有 OS 光标语义才挂（移动端透传 child，
  /// 像素级不变、零开销）；[_handleSubtitleHover] 内部也各自桌面门控（双保险）。
  Widget _withSubtitleListCursorReveal(Widget child) {
    if (!_isDesktopVideoControls) return child;
    return MouseRegion(
      opaque: false,
      // onEnter：进侧栏必发一次直发通道强制 OS 光标重现（[_forceRevealOsCursorForPanel]
      // 内部双门控桌面 + _cursorHidden==true），同时保留 [_handleSubtitleHover] 救场
      // （对侧栏虽 no-op 见其注释，但与画面字幕盒同款语义、无害）。
      onEnter: (PointerEnterEvent event) {
        _forceRevealOsCursorForPanel(event.device);
        _handleSubtitleHover(true);
      },
      // onHover：仅在光标仍为隐藏态时补发直发通道（门控在 [_forceRevealOsCursorForPanel]
      // 内）——别无条件每次 onHover 都发，否则 cue 行 InkWell 的 click 手型会被压成箭头，
      // 且框架 lastSession=click 与屏幕 basic 去同步永久停 basic。
      onHover: (PointerHoverEvent event) =>
          _forceRevealOsCursorForPanel(event.device),
      child: child,
    );
  }

  /// 唤回视频左侧锁 / 解锁按钮并重置 2s 自动淡出（TODO-126）。鼠标移动（hover）/ 触屏点画面
  /// 时调用。**不被锁 gate**（与 [_markControlsVisible] 不同）——沉浸态解锁按钮要能淡出后再
  /// 被唤回，否则用户失去可见退出口。Esc / Shift+L 始终另有退出路径，不依赖此可见性。
  void _pokeLockButton() {
    if (!mounted) return;
    _lockButtonVisible.value = true;
    _lockButtonHideTimer?.cancel();
    _lockButtonHideTimer =
        Timer(_VideoHibikiPageState._videoControlsHoverDuration, () {
      if (mounted) _lockButtonVisible.value = false;
    });
  }
}
