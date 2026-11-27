import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// Source-scan guards for BUG-1933 (Windows 全屏/取消全屏闪一帧白色).
///
/// window_manager's `SetFullScreen` and media_kit's `EnterNativeFullscreen`
/// both implement fullscreen by stripping `WS_CAPTION|WS_THICKFRAME`; the
/// style change makes DWM rebuild the window's frame visual and for at least
/// one composition the Flutter view's layer is absent, revealing the
/// redirection surface (theme surface colour — white in a light theme) for a
/// full frame. The fix makes the runner the single owner of Windows
/// fullscreen: frame styles kept, window oversized so the client area covers
/// the monitor, HWND_TOPMOST over the taskbar, a pre-transition screen
/// snapshot stretched onto the surface as a race fallback, and every Dart
/// entry point routed through the `app.fushi/window` channel.
///
/// The Win32 runner cannot run on the Dart host, so these pin the wiring.
/// Comments are masked (not deleted) before order checks so a stale
/// explanatory comment cannot satisfy an `indexOf` on the real call site,
/// while every offset still lines up with the original source.
/// `maskComments` is the shared lexical primitive — it also covers block
/// comments, which a line-only regex lets through.
void main() {
  late String cpp;
  late String header;
  late String flutterWindow;
  late String navDart;
  late String videoFullscreenDart;
  late String webVideoDart;
  late String placementDart;
  late String channelDart;

  setUpAll(() {
    cpp = maskComments(
      File('windows/runner/win32_window.cpp').readAsStringSync(),
    );
    header = File('windows/runner/win32_window.h').readAsStringSync();
    flutterWindow = maskComments(
      File('windows/runner/flutter_window.cpp').readAsStringSync(),
    );
    navDart = maskComments(
      File('lib/src/shortcuts/global_navigation.dart').readAsStringSync(),
    );
    videoFullscreenDart = maskComments(
      File(
        'lib/src/pages/implementations/video_fushi/fullscreen.part.dart',
      ).readAsStringSync(),
    );
    webVideoDart = maskComments(
      File(
        'lib/src/pages/implementations/web_video_fushi_page.dart',
      ).readAsStringSync(),
    );
    placementDart = maskComments(
      File('lib/src/startup/desktop_window_placement.dart').readAsStringSync(),
    );
    channelDart = maskComments(
      File('lib/src/utils/window_caption_channel.dart').readAsStringSync(),
    );
  });

  group('BUG-1933 runner-owned fullscreen', () {
    test('the runner never strips frame styles (no GWL_STYLE writes)', () {
      // Style stripping is the root cause: it forces a DWM frame-visual
      // rebuild that drops the Flutter view layer for a frame. Reading
      // GWL_STYLE (for AdjustWindowRectExForDpi) is fine; writing it is not.
      expect(
        RegExp(r'SetWindowLongPtr\([^,]+,\s*GWL_STYLE').hasMatch(cpp),
        isFalse,
        reason:
            'fullscreen must keep WS_CAPTION|WS_THICKFRAME; stripping them '
            'reveals the surface for a frame (the white flash).',
      );
      expect(header.contains('void SetFullscreen(bool fullscreen);'), isTrue);
      expect(header.contains('bool IsFullscreen() const'), isTrue);
    });

    test('SetFullscreen oversizes by the DPI frame and goes topmost', () {
      final int fnAt = cpp.indexOf('void Win32Window::SetFullscreen(');
      expect(fnAt, isNonNegative);
      final int fnEnd = cpp.indexOf('\n}', fnAt);
      final String body = cpp.substring(fnAt, fnEnd);
      expect(
        body.contains('ClientToScreen(hwnd, &client_origin);'),
        isTrue,
        reason:
            'the client area must cover the monitor exactly, and the frame '
            'must be MEASURED (window rect vs client origin) — '
            'AdjustWindowRectExForDpi is wrong under window_manager\'s '
            'hidden-title-bar WM_NCCALCSIZE reshaping.',
      );
      expect(body.contains('AdjustWindowRectExForDpi'), isFalse);
      expect(
        body.contains('HWND_TOPMOST'),
        isTrue,
        reason:
            'the shell does not classify an oversized framed window as '
            'fullscreen, so without topmost the taskbar stays on top.',
      );
      expect(body.contains('GetWindowPlacement(hwnd'), isTrue);
      expect(body.contains('CaptureTransitionSnapshot();'), isTrue);
    });

    test('BUG-5591: one geometry step each way, no DWM animation', () {
      // The old entry un-maximized onto the monitor (SetWindowPlacement
      // SW_SHOWNORMAL) and then oversized; the old exit restored the
      // pre-maximize normal rectangle and then re-maximized (ShowWindow
      // SW_MAXIMIZE). Each show-state change played DWM's restore / maximize
      // animation, which animates the window surface without the Flutter
      // view: ~15 frames of bare Mica (RGB 243) on entry, a ~330 ms detour
      // through the small normal rectangle on exit (60 fps capture).
      final int fnAt = cpp.indexOf('void Win32Window::SetFullscreen(');
      final int fnEnd = cpp.indexOf('\n}', fnAt);
      final String body = cpp.substring(fnAt, fnEnd);

      final int guardAt = body.indexOf(
        'const ScopedNoDwmTransitions no_transitions(hwnd);',
      );
      final int firstPlacementAt = body.indexOf('SetWindowPlacement(');
      final int firstPosAt = body.indexOf('SetWindowPos(');
      expect(guardAt, isNonNegative);
      expect(firstPlacementAt, greaterThan(guardAt));
      expect(firstPosAt, greaterThan(guardAt));
      final int scopeAt = cpp.indexOf('class ScopedNoDwmTransitions');
      expect(scopeAt, isNonNegative);
      expect(
        cpp
            .substring(scopeAt, cpp.indexOf('};', scopeAt))
            .contains('DWMWA_TRANSITIONS_FORCEDISABLED'),
        isTrue,
      );

      final int exitAt = body.indexOf('} else {');
      expect(exitAt, isNonNegative);
      final String enter = body.substring(0, exitAt);
      expect(
        enter.contains('ShowWindow('),
        isFalse,
        reason: 'entering never re-shows / re-maximizes the window.',
      );
      expect(
        enter.contains('fushi::FullscreenUnzoomPlacement('),
        isTrue,
        reason:
            'a zoomed window ignores SetWindowPos sizes (measured), so it is '
            'un-zoomed — straight onto the fullscreen rectangle '
            '(fullscreen_geometry_test pins rcNormalPosition = target).',
      );
      expect(
        RegExp(r'SetWindowPlacement\(').allMatches(enter).length,
        1,
        reason: 'exactly one show-state change on entry.',
      );

      final String exit = body.substring(exitAt);
      expect(
        exit.contains('restore.showCmd = SW_SHOWNORMAL'),
        isFalse,
        reason: 'no restore-to-normal step before re-maximizing.',
      );
      final int rectStepAt = exit.indexOf(
        'SetWindowPos(hwnd, HWND_NOTOPMOST, rect.left, rect.top',
      );
      expect(
        rectStepAt,
        isNonNegative,
        reason: 'a normal window goes back with one SetWindowPos.',
      );
      final int maxBranchAt = exit.indexOf(
        'restore.showCmd == SW_SHOWMAXIMIZED',
      );
      final int maximizeAt = exit.indexOf(
        'ShowWindow(hwnd, SW_MAXIMIZE);',
        maxBranchAt,
      );
      final int bookkeepingAt = exit.indexOf(
        'SetWindowPlacement(hwnd, &restore);',
        maximizeAt,
      );
      expect(maxBranchAt, isNonNegative);
      expect(
        maximizeAt,
        greaterThan(maxBranchAt),
        reason:
            'SetWindowPlacement(SW_SHOWMAXIMIZED) on a normal window first '
            'moves it to rcNormalPosition — the small window (measured); '
            'maximize straight from the fullscreen rectangle instead.',
      );
      expect(
        bookkeepingAt,
        greaterThan(maximizeAt),
        reason:
            'the saved placement is applied to the already-zoomed window, '
            'which only records the normal rectangle for a later restore.',
      );
      expect(
        body.contains('GetWindowRect(hwnd, &rect_before_fullscreen_)'),
        isTrue,
      );
      expect(
        body.contains('zoomed_before_fullscreen_ = IsZoomed(hwnd)'),
        isTrue,
      );
    });

    test('BUG-5591: a Mica surface gets its backdrop back only after the '
        'view rasterized the new size', () {
      final int fnAt = cpp.indexOf('void Win32Window::SetFullscreen(');
      final int fnEnd = cpp.indexOf('\n}', fnAt);
      final String body = cpp.substring(fnAt, fnEnd);
      final int seeThroughAt = body.lastIndexOf(
        '!fushi::MainSurfaceSeeThrough(main_surface_state())',
      );
      expect(
        seeThroughAt,
        isNonNegative,
        reason:
            'an opaque surface keeps the snapshot pixels under the view '
            '(BUG-1933); only a see-through one must be cleared.',
      );
      expect(body.contains('snapshot_release_size_ = SIZE{'), isTrue);

      final int rasterAt = cpp.indexOf(
        'void Win32Window::OnChildFrameRasterized(',
      );
      final String raster = cpp.substring(
        rasterAt,
        cpp.indexOf('\n}', rasterAt),
      );
      final int matchAt = raster.indexOf('snapshot_release_size_.cx');
      final int releaseAt = raster.indexOf(
        'DropTransitionSnapshot(fushi::SnapshotReleaseReason::kRasterized);',
      );
      final int fillAt = raster.indexOf('FillSurfaceBackdrop();');
      expect(matchAt, isNonNegative);
      expect(releaseAt, greaterThan(matchAt));
      expect(
        fillAt,
        greaterThan(releaseAt),
        reason:
            'clearing as soon as the child resize returned left 2 frames of '
            'bare Mica after every jump (measured): the view is not on '
            'screen yet at that point.',
      );

      final int sizeAt = cpp.indexOf('case WM_SIZE:');
      final String size = cpp.substring(
        sizeAt,
        cpp.indexOf('case WM_ERASEBKGND', sizeAt),
      );
      final int staleAt = size.indexOf('!fullscreen_transition_');
      final int sizeFillAt = size.indexOf('FillSurfaceBackdrop();');
      expect(staleAt, isNonNegative);
      expect(
        sizeFillAt,
        greaterThan(staleAt),
        reason:
            'a resize outside a fullscreen transition drops a still-held '
            'snapshot before the brush fill (no stretched stale frame).',
      );
    });

    test('BUG-5591: the fullscreen client is pinned before any plugin', () {
      // window_manager answers WM_NCCALCSIZE for a zoomed window by pinning
      // the client to the work-area origin; a zoomed fullscreen window needs
      // the monitor. Must run in the static WndProc, ahead of
      // FlutterWindow::MessageHandler's plugin dispatch.
      final int wndProcAt = cpp.indexOf(
        'LRESULT CALLBACK Win32Window::WndProc(',
      );
      expect(wndProcAt, isNonNegative);
      final int dispatchAt = cpp.indexOf(
        'return that->MessageHandler(window, message, wparam, lparam);',
        wndProcAt,
      );
      final int ncAt = cpp.indexOf(
        'message == WM_NCCALCSIZE && wparam != 0 && that->fullscreen_',
        wndProcAt,
      );
      expect(ncAt, isNonNegative);
      expect(dispatchAt, greaterThan(ncAt));
      expect(
        cpp.substring(ncAt, dispatchAt).contains('FullscreenClientRect('),
        isTrue,
      );
    });

    test('the transition snapshot is opaque on every surface', () {
      final int fnAt = cpp.indexOf('void Win32Window::FillSurfaceBackdrop()');
      expect(fnAt, isNonNegative);
      final int fnEnd = cpp.indexOf('\n}', fnAt);
      final String body = cpp.substring(fnAt, fnEnd);
      final int snapshotAt = body.indexOf('transition_snapshot_ != nullptr');
      final int blendAt = body.indexOf('AlphaBlend(');
      final int brushAt = body.indexOf('PaintBackdrop(dc)');
      expect(snapshotAt, isNonNegative);
      expect(blendAt, greaterThan(snapshotAt));
      expect(
        brushAt,
        greaterThan(blendAt),
        reason:
            'a raced composition during the fullscreen jump must show the '
            'previous frame, not a solid colour flash; everything without a '
            'snapshot (interactive resize) keeps the cheap brush fill.',
      );
      expect(
        body.contains('MainSurfaceSeeThrough'),
        isFalse,
        reason:
            'BUG-5591: skipping the snapshot on Mica left the bare material '
            '(RGB 243 in a light theme) on screen for 1-3 frames of every '
            'jump. The snapshot is opaque (alpha 255 + AlphaBlend), so it is '
            'safe on a see-through surface.',
      );
      expect(
        body.contains('StretchBlt('),
        isFalse,
        reason: 'StretchBlt writes alpha 0: additive ghost on Mica.',
      );

      final int capAt = cpp.indexOf(
        'void Win32Window::CaptureTransitionSnapshot()',
      );
      final int capEnd = cpp.indexOf('\n}', capAt);
      final String capture = cpp.substring(capAt, capEnd);
      expect(capture.contains('CreateDIBSection('), isTrue);
      expect(capture.contains('biBitCount = 32'), isTrue);
      expect(capture.contains('0xFF000000u'), isTrue);
    });

    test('WM_ACTIVATE drops topmost while fullscreen and deactivated', () {
      final int activateAt = cpp.indexOf('case WM_ACTIVATE:');
      expect(activateAt, isNonNegative);
      final int nextAt = cpp.indexOf('case WM_DISPLAYCHANGE:', activateAt);
      expect(nextAt, greaterThan(activateAt));
      final String body = cpp.substring(activateAt, nextAt);
      expect(body.contains('fullscreen_'), isTrue);
      expect(
        body.contains('WA_INACTIVE'),
        isTrue,
        reason:
            'holding topmost while another app is active would keep a '
            'screen-sized window over everything.',
      );
      expect(body.contains('HWND_NOTOPMOST'), isTrue);
    });

    test('WM_GETMINMAXINFO is lifted after the plugin delegates ran', () {
      final int dispatchAt = flutterWindow.indexOf(
        'HandleTopLevelWindowProc(hwnd, message, wparam',
      );
      expect(dispatchAt, isNonNegative);
      final int liftAt = flutterWindow.indexOf(
        'ApplyFullscreenMinMaxInfo(reinterpret_cast<MINMAXINFO*>(lparam))',
      );
      expect(
        liftAt,
        greaterThan(dispatchAt),
        reason:
            "window_manager's delegate consumes WM_GETMINMAXINFO (it applies "
            'the minimum window size); the max-track lift must run after it, '
            'or the fullscreen SetWindowPos is clamped ~30px short and a '
            'taskbar strip stays exposed (measured).',
      );
      final int fnAt = cpp.indexOf(
        'bool Win32Window::ApplyFullscreenMinMaxInfo(',
      );
      expect(fnAt, isNonNegative);
      final String body = cpp.substring(fnAt, cpp.indexOf('\n}', fnAt));
      expect(body.contains('if (!fullscreen_'), isTrue);
      expect(body.contains('ptMaxTrackSize'), isTrue);
    });

    test('BUG-5591: opaque video content composes the Mica surface opaque', () {
      // A see-through surface has to drop the transition snapshot back to the
      // material before DWM has composed the view's first frame at the new
      // size (the runner cannot observe that): 1-3 frames of bare Mica per
      // jump, measured. Opaque content keeps the surface opaque instead.
      final String surface = maskComments(
        File('windows/runner/main_surface_composition.h').readAsStringSync(),
      );
      expect(
        surface.contains(
          'return state.system_backdrop && !state.content_opaque;',
        ),
        isTrue,
      );
      expect(
        surface.contains('if (MainSurfaceSeeThrough(state)) {'),
        isTrue,
        reason: 'the DWM margins follow the same single policy',
      );
      expect(
        flutterWindow.contains('call.method_name() == "setContentOpaque"'),
        isTrue,
      );
      final int setAt = flutterWindow.indexOf('SetContentOpaque(opaque);');
      expect(setAt, isNonNegative);
      expect(
        flutterWindow.indexOf('ApplyMainSurfaceComposition();', setAt),
        greaterThan(setAt),
        reason: 'margins re-derived after the state changed',
      );
      expect(
        channelDart.contains("invokeMethod<void>('setContentOpaque'"),
        isTrue,
      );
      final String claim = maskComments(
        File(
          'lib/src/utils/opaque_window_content_claim.dart',
        ).readAsStringSync(),
      );
      expect(
        claim.contains('AnimationStatus.completed'),
        isTrue,
        reason: 'claimed only once the route covers the window',
      );
      // The single declarer is the opaque frame under every route: the
      // claim follows that frame's colour, so making the frame translucent
      // (to let Mica through) drops the claim automatically.
      final String titleBar = maskComments(
        File(
          'lib/src/utils/components/fushi_desktop_title_bar.dart',
        ).readAsStringSync(),
      );
      final int claimAt = titleBar.indexOf('OpaqueWindowContentClaim(');
      expect(claimAt, isNonNegative, reason: 'the root frame declares');
      final String claimCall = titleBar.substring(
        claimAt,
        titleBar.indexOf(');', claimAt),
      );
      expect(
        claimCall.contains('enabled: underlay || frameColor.a >= 1.0'),
        isTrue,
      );
      expect(
        claimCall.contains('ColoredBox(color: frameColor'),
        isTrue,
        reason: 'the claim wraps the very box whose colour it reports',
      );
      expect(
        claim.contains('_routeAnimation == null ||'),
        isTrue,
        reason: 'outside any route (the root frame) the claim is settled',
      );
    });

    test('BUG-5591: every transition is traced for the geometry itest', () {
      final int procAt = cpp.indexOf('Win32Window::WndProc(');
      final String proc = cpp.substring(procAt, cpp.indexOf('\n}', procAt));
      expect(proc.contains('message == WM_WINDOWPOSCHANGED'), isTrue);
      expect(
        proc.contains('FullscreenTraceKind::kWindowPos'),
        isTrue,
        reason: 'every geometry change, including system-inserted ones',
      );
      final int fnAt = cpp.indexOf('void Win32Window::SetFullscreen(');
      final String body = cpp.substring(fnAt, cpp.indexOf('\n}', fnAt));
      expect(body.contains('fullscreen_trace_.Begin('), isTrue);
      expect(body.contains('FullscreenTraceKind::kEnd'), isTrue);
      final int deliverAt = cpp.indexOf('void Win32Window::DeliverChildSize(');
      expect(
        cpp
            .substring(deliverAt, cpp.indexOf('\n}', deliverAt))
            .contains('FullscreenTraceKind::kChildDelivered'),
        isTrue,
      );
      final int rasterAt = cpp.indexOf(
        'void Win32Window::OnChildFrameRasterized(',
      );
      expect(
        cpp
            .substring(rasterAt, cpp.indexOf('\n}', rasterAt))
            .contains('FullscreenTraceKind::kRasterized'),
        isTrue,
      );
      expect(
        flutterWindow.contains('call.method_name() == "fullscreenTrace"'),
        isTrue,
      );
      expect(
        File(
          'integration_test/win_fullscreen_geometry_itest.dart',
        ).existsSync(),
        isTrue,
      );
    });

    test('the window channel exposes setFullscreen/isFullscreen', () {
      expect(
        flutterWindow.contains('call.method_name() == "setFullscreen"'),
        isTrue,
      );
      expect(
        flutterWindow.contains('call.method_name() == "isFullscreen"'),
        isTrue,
      );
      expect(flutterWindow.contains('SetFullscreen(enter);'), isTrue);
      expect(
        flutterWindow.contains(
          'result->Success(flutter::EncodableValue(IsFullscreen()))',
        ),
        isTrue,
      );
      expect(
        channelDart.contains("invokeMethod<void>('setFullscreen'"),
        isTrue,
      );
      expect(
        channelDart.contains("invokeMethod<bool>('isFullscreen')"),
        isTrue,
      );
    });

    test('every Dart fullscreen entry routes Windows through the runner', () {
      // The single Windows mutation/read point behind
      // toggleDesktopWindowFullscreen / setDesktopWindowFullscreen must talk
      // to the runner, never to window_manager (whose SetFullScreen strips
      // the frame styles — the flash).
      final int resolveAt = navDart.indexOf(
        'Future<bool?> _resolveWindowsFullscreen(',
      );
      expect(resolveAt, isNonNegative);
      final int resolveEnd = navDart.indexOf('\n}', resolveAt);
      final String resolveBody = navDart.substring(resolveAt, resolveEnd);
      expect(
        resolveBody.contains('WindowCaptionChannel.setFullscreen(fullscreen)'),
        isTrue,
      );
      expect(
        resolveBody.contains('WindowCaptionChannel.isFullscreen()'),
        isTrue,
      );
      expect(
        resolveBody.contains('windowManager.'),
        isFalse,
        reason:
            'window_manager.setFullScreen strips the frame styles on '
            'Windows — it must only remain as the Linux path.',
      );

      // The Windows state read must also come from the runner
      // (window_manager.isFullScreen is permanently false there).
      final int readAt = navDart.indexOf(
        'Future<bool?> readDesktopWindowFullscreen()',
      );
      expect(readAt, isNonNegative);
      final int readWinAt = navDart.indexOf(
        'WindowCaptionChannel.isFullscreen()',
        readAt,
      );
      final int readChromeAt = navDart.indexOf(
        'FushiDesktopTitleBar.setWindowManagerFullscreen(fullscreen)',
        readAt,
      );
      expect(readWinAt, isNonNegative);
      expect(
        readChromeAt,
        greaterThan(readWinAt),
        reason:
            'the app-frame chrome must be derived from the runner-owned '
            'state.',
      );

      // Video player native fullscreen callbacks (media_kit replacement).
      final int enterAt = videoFullscreenDart.indexOf(
        '_enterVideoNativeFullscreen()',
      );
      expect(enterAt, isNonNegative);
      final int enterRouteAt = videoFullscreenDart.indexOf(
        'WindowCaptionChannel.setFullscreen(true)',
        enterAt,
      );
      final int enterDefaultAt = videoFullscreenDart.indexOf(
        'defaultEnterNativeFullscreen()',
        enterAt,
      );
      expect(enterRouteAt, isNonNegative);
      expect(enterDefaultAt, greaterThan(enterRouteAt));

      final int exitAt = videoFullscreenDart.indexOf(
        '_exitVideoNativeFullscreen()',
      );
      expect(exitAt, isNonNegative);
      final int exitRouteAt = videoFullscreenDart.indexOf(
        'WindowCaptionChannel.setFullscreen(false)',
        exitAt,
      );
      final int exitDefaultAt = videoFullscreenDart.indexOf(
        'defaultExitNativeFullscreen()',
        exitAt,
      );
      expect(exitRouteAt, isNonNegative);
      expect(exitDefaultAt, greaterThan(exitRouteAt));

      // Web video page: the entry BUG-1933 originally missed. Its F key always
      // took media_kit's style-stripping path, and once F11 was routed to the
      // page's own toggle (BUG-2462) F11 regressed to it too. One toggle body
      // serves F / F11 / the button, so a single Windows branch covers all.
      final int webToggleAt = webVideoDart.indexOf(
        'Future<void> _toggleFullscreen()',
      );
      expect(webToggleAt, isNonNegative);
      final int webEnterAt = webVideoDart.indexOf(
        'WindowCaptionChannel.setFullscreen(true)',
        webToggleAt,
      );
      final int webExitAt = webVideoDart.indexOf(
        'WindowCaptionChannel.setFullscreen(false)',
        webToggleAt,
      );
      final int webDefaultAt = webVideoDart.indexOf(
        'defaultEnterNativeFullscreen()',
        webToggleAt,
      );
      expect(webEnterAt, isNonNegative);
      expect(webExitAt, isNonNegative);
      expect(
        webDefaultAt,
        greaterThan(webEnterAt),
        reason:
            'Windows branch (runner fullscreen) must come before the '
            'media_kit default that the other desktops keep',
      );
      // Leaving the page while fullscreen must hand the window back: the
      // runner-owned state does not go away with the route.
      final int disposeAt = webVideoDart.indexOf('void dispose()');
      expect(disposeAt, isNonNegative);
      final int disposeExitAt = webVideoDart.indexOf(
        'WindowCaptionChannel.setFullscreen(false)',
        disposeAt,
      );
      expect(disposeExitAt, isNonNegative);
      expect(
        disposeExitAt,
        lessThan(webToggleAt),
        reason:
            'dispose() precedes _toggleFullscreen() in the file; the '
            'exit call found after dispose() must be the one in dispose()',
      );
    });

    test('bounds saving skips the runner-owned fullscreen state', () {
      // window_manager.isFullScreen() is permanently false on Windows now;
      // without asking the runner, the oversized fullscreen rect would be
      // saved as normal bounds and the next launch starts monitor-sized
      // (measured).
      final int saveAt = placementDart.indexOf(
        'Future<void> saveCurrentBoundsNow()',
      );
      expect(saveAt, isNonNegative);
      final int checkAt = placementDart.indexOf(
        'WindowCaptionChannel.isFullscreen()',
        saveAt,
      );
      final int readBoundsAt = placementDart.indexOf(
        'windowManager.getBounds()',
        saveAt,
      );
      expect(checkAt, isNonNegative);
      expect(readBoundsAt, greaterThan(checkAt));
    });
  });

  group('BUG-2006 edge-to-edge windows suppress the DWM frame chrome', () {
    // Windows 11 paints the thin window border and rounds the window's
    // corners in the compositor, ON TOP of the client area — neither belongs
    // to the non-client area window_manager's hidden-title-bar WM_NCCALCSIZE
    // leaves this window. Whenever the client reaches the screen edges that
    // chrome lands on app content: measured on Windows 11 26200, the runner's
    // own fullscreen (the BUG-1933 framed giant window) has frame insets
    // 8/1/8/8, so its 1 px top border lands on screen row 0 — 3830/3840 of
    // that row is the accent colour, with the desktop showing through all
    // four corners. That is the user's report.
    //
    // The condition pinned here is "does the client reach the screen edges",
    // NOT "which window state is this": the insets come out of WM_NCCALCSIZE,
    // DPI and Windows version (window_manager itself branches on
    // IsWindows11OrGreater), so a genuinely maximized window measured
    // 11/11/11/11 and no line on this machine while another machine may put
    // its border back on screen.

    test('the policy covers fullscreen, maximized AND screen-sized', () {
      final int fnAt = cpp.indexOf('void Win32Window::UpdateFrameChrome()');
      expect(
        fnAt,
        isNonNegative,
        reason:
            'a single policy point decides whether DWM may paint chrome over '
            'the client area.',
      );
      final int fnEnd = cpp.indexOf('\n}', fnAt);
      expect(fnEnd, greaterThan(fnAt));
      final String body = cpp.substring(fnAt, fnEnd);

      expect(
        body.contains('fullscreen_'),
        isTrue,
        reason: 'runner-owned fullscreen covers the monitor.',
      );
      expect(
        body.contains('IsZoomed(hwnd)'),
        isTrue,
        reason:
            'Windows drops the border and the rounding for a maximized '
            'window on its own; a custom-frame window has to ask.',
      );
      expect(
        body.contains('ClientCoversMonitor(hwnd)'),
        isTrue,
        reason:
            'the geometry test is the durable one: the frame insets that '
            'decide whether the border lands on screen come out of '
            'WM_NCCALCSIZE, DPI and Windows version, not out of the window '
            'state name, so "does the client reach the edges" must be a '
            'condition in its own right.',
      );
      expect(
        body.contains('frame_chrome_suppressed_'),
        isTrue,
        reason:
            'transition-only: a DwmSetWindowAttribute round trip on every '
            'WM_SIZE would tax interactive resizing (BUG-1917 cadence).',
      );
    });

    test('both DWM attributes are set, and both are restorable', () {
      final int fnAt = cpp.indexOf('void ApplyFrameChrome(');
      expect(fnAt, isNonNegative);
      final int fnEnd = cpp.indexOf('\n}', fnAt);
      final String body = cpp.substring(fnAt, fnEnd);

      expect(
        body.contains('DWMWA_BORDER_COLOR'),
        isTrue,
        reason:
            'DWMWA_BORDER_COLOR=DWMWA_COLOR_NONE is the measured fix for the '
            'top line (600/600 chrome pixels on the client top row before, '
            '0/600 after, and the line returns when the default is restored).',
      );
      expect(body.contains('DWMWA_COLOR_NONE'), isTrue);
      expect(
        body.contains('DWMWA_COLOR_DEFAULT'),
        isTrue,
        reason:
            'an ordinary windowed Fushi must keep its normal border — this '
            'is a state-dependent policy, not a permanent window attribute.',
      );
      expect(
        body.contains('DWMWA_WINDOW_CORNER_PREFERENCE'),
        isTrue,
        reason:
            'the rounded corners clip the client and show the desktop '
            'through all four corners; DWMWCP_DONOTROUND is a separate fix '
            'from the border colour (measured: it alone leaves the top line '
            'untouched, and the border colour alone leaves the corners cut).',
      );
      expect(body.contains('DWMWCP_DONOTROUND'), isTrue);
      expect(body.contains('DWMWCP_DEFAULT'), isTrue);
      expect(
        cpp.contains('#include <dwmapi.h>'),
        isTrue,
        reason: 'DwmSetWindowAttribute needs the DWM header.',
      );
    });

    test('every geometry change re-evaluates the policy', () {
      final int sizeAt = cpp.indexOf('case WM_SIZE:');
      expect(sizeAt, isNonNegative);
      final int sizeEnd = cpp.indexOf('case WM_ERASEBKGND', sizeAt);
      expect(sizeEnd, greaterThan(sizeAt));
      expect(
        cpp.substring(sizeAt, sizeEnd).contains('UpdateFrameChrome()'),
        isTrue,
        reason:
            'maximize / restore / drag-resize all cross the edge-to-edge '
            'boundary; without a WM_SIZE hook the chrome would only ever be '
            'updated by the fullscreen toggle.',
      );

      final int fnAt = cpp.indexOf('void Win32Window::SetFullscreen(');
      final int fnEnd = cpp.indexOf('\n}', fnAt);
      final String body = cpp.substring(fnAt, fnEnd);
      final int enterChromeAt = body.indexOf('UpdateFrameChrome()');
      final int topmostAt = body.indexOf('SetWindowPos(hwnd, HWND_TOPMOST');
      expect(enterChromeAt, isNonNegative);
      expect(
        topmostAt,
        greaterThan(enterChromeAt),
        reason:
            'suppress the chrome before the jump, or the compositor paints '
            'the border over a client area that already covers the monitor.',
      );

      final int notopmostAt = body.indexOf('HWND_NOTOPMOST');
      final int exitChromeAt = body.indexOf('UpdateFrameChrome()', notopmostAt);
      expect(notopmostAt, isNonNegative);
      expect(
        exitChromeAt,
        greaterThan(notopmostAt),
        reason:
            're-evaluate only once the geometry is back, so the policy sees '
            'the restored window instead of the still-oversized one.',
      );
    });
  });
}
