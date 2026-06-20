import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-648 / BUG-361 源码守卫：vendored fork `flutter_inappwebview_windows`
/// 的 WebView2 控制器初始化路径必须显式 `put_AllowExternalDrop(FALSE)`。
///
/// 根因（已验真）：WebView2 运行时默认 `AllowExternalDrop=TRUE`，会在**宿主主窗口**
/// HWND 上注册自己的 `IDropTarget`（让 OS 文件能拖进网页），抢占 desktop_drop 的整窗
/// 单点 `RegisterDragDrop`。WebView2 关闭时（`~InAppWebView` -> `Close()`）`RevokeDragDrop`
/// 自己的 target 但**不恢复** desktop_drop 的 → 主 HWND 无有效 `IDropTarget` → 拖 .epub
/// 进书架显示「禁止」光标（瞬态：开过 reader/查词 WebView 才触发，重启恢复）。
///
/// 修复不变量：在 fork 的 WebView2 控制器初始化路径（`InAppWebView::prepare`）QI 拿
/// `ICoreWebView2Controller4` 后显式 `put_AllowExternalDrop(FALSE)`，使 WebView2 不在宿主
/// 窗口注册 drop target，desktop_drop 主 HWND 注册全程不被抢占。本守卫扫源码钉死这条，
/// 防回归把它退回 WebView2 的默认 TRUE。
void main() {
  test(
      'TODO-648/BUG-361: fork WebView2 controller init disables AllowExternalDrop '
      'so desktop_drop keeps the host HWND drop registration', () {
    final List<String> sourceCandidates = <String>[
      'packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp',
      '../packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp',
    ];
    final File? sourceFile = sourceCandidates
        .map(File.new)
        .cast<File?>()
        .firstWhere((File? f) => f != null && f.existsSync(),
            orElse: () => null);
    expect(sourceFile, isNotNull, reason: 'in_app_webview.cpp 未找到');

    final String src = sourceFile!.readAsStringSync();

    // 修复说明注释必须保留 BUG-361 / TODO-648 标识，钉住根因与修复契约。
    expect(src.contains('BUG-361'), isTrue,
        reason: '修复说明注释应保留 BUG-361，标识 WebView2 抢占主窗口 drop 注册根因');

    // 必须显式关闭 AllowExternalDrop（默认 TRUE 是根因，不关就回归）。
    expect(src.contains('put_AllowExternalDrop(FALSE)'), isTrue,
        reason: 'WebView2 控制器初始化必须显式 put_AllowExternalDrop(FALSE)，否则默认 TRUE '
            '会在宿主主窗口注册 IDropTarget，关闭后留主 HWND 无有效 drop target -> 禁止光标');

    // AllowExternalDrop 在 ICoreWebView2Controller4，必须经 QueryInterface 拿到再调，
    // 老 Runtime 无该接口时 QI 失败应静默跳过（不崩）。
    expect(src.contains('ICoreWebView2Controller4'), isTrue,
        reason: 'put_AllowExternalDrop 在 ICoreWebView2Controller4，必须 QI 拿到该接口');

    // 守卫调用位置：必须落在控制器初始化路径（prepare），且 QI 成功才调（容错）。
    final int prepareIdx = src.indexOf('void InAppWebView::prepare(');
    expect(prepareIdx, greaterThanOrEqualTo(0),
        reason: 'AllowExternalDrop 必须在 InAppWebView::prepare 控制器初始化路径设置');
    final int qiIdx =
        src.indexOf('IID_PPV_ARGS(&webViewController4)', prepareIdx);
    expect(qiIdx, greaterThan(prepareIdx),
        reason: 'prepare 内必须 QueryInterface 拿 ICoreWebView2Controller4');
    final int dropIdx = src.indexOf('put_AllowExternalDrop(FALSE)', qiIdx);
    expect(dropIdx, greaterThan(qiIdx),
        reason: 'put_AllowExternalDrop(FALSE) 必须在 QueryInterface 成功之后调用');
  });
}
