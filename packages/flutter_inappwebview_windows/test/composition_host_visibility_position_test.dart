import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _readPluginSource(String relativePath) {
  final List<String> candidates = <String>[
    relativePath,
    'packages/flutter_inappwebview_windows/$relativePath',
    '../packages/flutter_inappwebview_windows/$relativePath',
  ];
  final File? file = candidates
      .map(File.new)
      .cast<File?>()
      .firstWhere((File? f) => f != null && f.existsSync(), orElse: () => null);
  expect(file, isNotNull, reason: '$relativePath not found');
  return file!.readAsStringSync();
}

String _sliceBetween(String source, String startMarker, String endMarker) {
  final int start = source.indexOf(startMarker);
  expect(start, greaterThanOrEqualTo(0), reason: '$startMarker not found');
  final int end = source.indexOf(endMarker, start + startMarker.length);
  expect(
    end,
    greaterThan(start),
    reason: '$startMarker must be bounded by $endMarker',
  );
  return source.substring(start, end);
}

void main() {
  group('composition host window visibility sync', () {
    test(
      'InAppWebViewManager tracks top-level visibility/bounds and unregisters in dtor',
      () {
        final String managerHeader = _readPluginSource(
          'windows/in_app_webview/in_app_webview_manager.h',
        );
        final String managerSource = _readPluginSource(
          'windows/in_app_webview/in_app_webview_manager.cpp',
        );

        expect(managerHeader, contains('int host_window_proc_delegate_id_'));
        expect(managerHeader, contains('bool host_window_visible_'));
        expect(
          managerHeader,
          contains('void onHostWindowVisibilityChanged(bool visible);'),
        );
        expect(managerHeader, contains('void onHostWindowBoundsChanged();'));

        final String ctorBody = _sliceBetween(
          managerSource,
          'InAppWebViewManager::InAppWebViewManager(',
          'void InAppWebViewManager::HandleMethodCall(',
        );
        expect(
          ctorBody,
          contains(
            'host_window_proc_delegate_id_ = plugin->registrar->RegisterTopLevelWindowProcDelegate(',
          ),
        );
        expect(ctorBody, contains('WM_SIZE'));
        expect(ctorBody, contains('SIZE_MINIMIZED'));
        expect(ctorBody, contains('SIZE_RESTORED'));
        expect(ctorBody, contains('SIZE_MAXIMIZED'));
        expect(ctorBody, contains('WM_SHOWWINDOW'));
        expect(ctorBody, contains('WM_WINDOWPOSCHANGED'));
        expect(ctorBody, contains('SWP_HIDEWINDOW'));
        expect(ctorBody, contains('IsWindowVisible'));
        expect(ctorBody, contains('IsIconic'));
        expect(ctorBody, contains('WM_MOVE'));
        expect(ctorBody, contains('onHostWindowVisibilityChanged'));
        expect(ctorBody, contains('onHostWindowBoundsChanged'));

        final String createBody = _sliceBetween(
          managerSource,
          'void InAppWebViewManager::createInAppWebView(',
          'void InAppWebViewManager::disposeKeepAlive(',
        );
        expect(
          'setHostWindowVisible(host_window_visible_)'
              .allMatches(createBody)
              .length,
          greaterThanOrEqualTo(2),
          reason:
              'keepAlive reuse and async create paths must both inherit host_window_visible_',
        );

        final String dtorBody = _sliceBetween(
          managerSource,
          'InAppWebViewManager::~InAppWebViewManager()',
          'void InAppWebViewManager::releaseSharedCompositionResources()',
        );
        expect(
          dtorBody,
          contains(
            'UnregisterTopLevelWindowProcDelegate(host_window_proc_delegate_id_)',
          ),
        );

        final String visitorsBody = _sliceBetween(
          managerSource,
          'void InAppWebViewManager::forEachManagedWebView(',
          'InAppWebViewManager::~InAppWebViewManager()',
        );
        expect(visitorsBody, contains('webViews'));
        expect(visitorsBody, contains('keepAliveWebViews'));
      },
    );

    test(
      'InAppWebView keeps hostWindowVisible_ and isPaused_ orthogonal across resume, host hide/show, and createSurface',
      () {
        final String webviewHeader = _readPluginSource(
          'windows/in_app_webview/in_app_webview.h',
        );
        final String webviewSource = _readPluginSource(
          'windows/in_app_webview/in_app_webview.cpp',
        );

        expect(
          webviewHeader,
          contains('void setHostWindowVisible(bool visible);'),
        );
        expect(webviewHeader, contains('void onHostWindowBoundsChanged();'));
        expect(webviewHeader, contains('bool hostWindowVisible_ = true;'));
        expect(webviewHeader, contains('bool isPaused_ = false;'));

        final String pauseBody = _sliceBetween(
          webviewSource,
          'void InAppWebView::pause()',
          'void InAppWebView::resume()',
        );
        expect(pauseBody, contains('isPaused_ = true;'));

        final String resumeBody = _sliceBetween(
          webviewSource,
          'void InAppWebView::resume()',
          'void InAppWebView::getCertificate(',
        );
        expect(resumeBody, contains('isPaused_ = false;'));
        expect(resumeBody, contains('surface_ && !hostWindowVisible_'));

        final String hostVisibleBody = _sliceBetween(
          webviewSource,
          'void InAppWebView::setHostWindowVisible(bool visible)',
          'void InAppWebView::onHostWindowBoundsChanged()',
        );
        expect(hostVisibleBody, contains('if (!isPaused_)'));
        expect(hostVisibleBody, contains('put_IsVisible(TRUE)'));
        expect(hostVisibleBody, contains('put_IsVisible(FALSE)'));
        expect(hostVisibleBody, contains('syncCompositionHostPosition()'));

        final String createSurfaceBody = _sliceBetween(
          webviewSource,
          'bool InAppWebView::createSurface(',
          'return true;\n  }',
        );
        expect(
          createSurfaceBody,
          contains('GetAncestor(parentWindow, GA_ROOT)'),
        );
        expect(createSurfaceBody, contains('IsWindowVisible'));
        expect(createSurfaceBody, contains('IsIconic'));
        expect(createSurfaceBody, contains('hostWindowVisible_ && !isPaused_'));
        expect(
          createSurfaceBody,
          isNot(contains('webViewController->put_IsVisible(true)')),
          reason:
              'createSurface must not unconditionally make WebView visible when host window is minimized or hidden',
        );
        expect(
          createSurfaceBody,
          isNot(contains('webViewController->put_IsVisible(TRUE)')),
          reason:
              'createSurface must not unconditionally make WebView visible when host window is minimized or hidden',
        );
      },
    );
  });

  group('composition host child position sync', () {
    test(
      'custom_platform_view and InAppWebView pass finite double coordinates and clamp WS_CHILD client coords',
      () {
        final String platformViewSource = _readPluginSource(
          'windows/custom_platform_view/custom_platform_view.cc',
        );
        final String webviewHeader = _readPluginSource(
          'windows/in_app_webview/in_app_webview.h',
        );
        final String webviewSource = _readPluginSource(
          'windows/in_app_webview/in_app_webview.cpp',
        );

        final String setPositionCallBody = _sliceBetween(
          platformViewSource,
          'method_name.compare(kMethodSetPosition) == 0',
          'return result->Error(kErrorInvalidArgs);\n    }',
        );
        expect(setPositionCallBody, contains('std::isfinite(x)'));
        expect(setPositionCallBody, contains('std::isfinite(y)'));
        expect(setPositionCallBody, contains('std::isfinite(scale_factor)'));
        expect(setPositionCallBody, isNot(contains('static_cast<size_t>(x)')));
        expect(setPositionCallBody, isNot(contains('static_cast<size_t>(y)')));

        expect(
          webviewHeader,
          contains('void setPosition(double x, double y, float scale_factor);'),
        );
        expect(
          webviewHeader,
          isNot(
            contains(
              'void setPosition(size_t x, size_t y, float scale_factor);',
            ),
          ),
        );

        final String setPositionBody = _sliceBetween(
          webviewSource,
          'void InAppWebView::setPosition(double x, double y, float scale_factor)',
          'void InAppWebView::setHostWindowVisible(bool visible)',
        );
        expect(setPositionBody, isNot(contains('SM_CYCAPTION')));
        expect(setPositionBody, isNot(contains('SM_CXBORDER')));
        expect(setPositionBody, isNot(contains('GetWindowRect')));
        expect(setPositionBody, contains('GetClientRect'));
        expect(setPositionBody, contains('std::clamp'));
        expect(
          setPositionBody,
          contains('NotifyParentWindowPositionChanged()'),
        );

        final String setSurfaceSizeBody = _sliceBetween(
          webviewSource,
          'void InAppWebView::setSurfaceSize(',
          'void InAppWebView::setPosition(',
        );
        expect(setSurfaceSizeBody, contains('syncCompositionHostPosition()'));

        final String boundsChangedBody = _sliceBetween(
          webviewSource,
          'void InAppWebView::onHostWindowBoundsChanged()',
          'void InAppWebView::setScrollDelta(',
        );
        expect(boundsChangedBody, contains('syncCompositionHostPosition()'));
        expect(
          boundsChangedBody,
          contains('NotifyParentWindowPositionChanged()'),
        );
      },
    );
  });
}
